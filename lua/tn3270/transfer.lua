local bit = require('bit')
local ebcdic = require('tn3270.ebcdic')

local M = {}

local state = nil

local function is_beacon(screen)
    local line0 = screen:to_lines()[1] or ''
    return line0:sub(1, 4) == 'Caaa'
end

local function write_command_at_cursor(screen, text)
    local attr_pos = screen:field_attr_at(screen.cursor)
    if attr_pos == nil then return false end
    if bit.band(screen.attrs[attr_pos + 1], 0x20) ~= 0 then return false end
    local data_start = (attr_pos + 1) % screen.size
    local field_end = screen:field_end(attr_pos)
    for p = data_start, field_end do
        local i = p - data_start + 1
        if i <= #text then
            screen:put(p, ebcdic.encode(text:sub(i, i)))
        else
            screen:put(p, 0x40)
        end
    end
    screen:set_mdt(attr_pos)
    screen.cursor = data_start + #text
    return true
end

local function start_transfer(op, args, screen, ctx)
    local parts = {}
    for p in string.gmatch(args, '%S+') do parts[#parts + 1] = p end
    if #parts ~= 2 then
        local usage = op == 'get'
            and ':TN3270Save <dsname> <local-file>'
            or  ':TN3270Load <local-file> <dsname>'
        vim.notify('Usage: ' .. usage, vim.log.levels.ERROR)
        return
    end
    local dsn, local_file
    if op == 'get' then
        dsn, local_file = parts[1], parts[2]
    else
        local_file, dsn = parts[1], parts[2]
    end
    state = {
        op = op,
        dsn = dsn,
        local_file = local_file,
        buffer = {},
        msg = '',
        phase = 'init',
    }
    ctx.trace(string.format('[TF] init op=%s dsn=%s local=%s', op, dsn, local_file))
    local cmd = string.format("IND$FILE %s '%s' ASCII CRLF",
        op == 'get' and 'GET' or 'PUT', dsn)
    if not write_command_at_cursor(screen, cmd) then
        state = nil
        vim.notify('No writable field at cursor; get to TSO READY first', vim.log.levels.ERROR)
        return
    end
    ctx.send_enter()
end

function M.setup(buf, screen, ctx)
    vim.api.nvim_buf_create_user_command(buf, 'TN3270Save', function(opts)
        start_transfer('get', opts.args, screen, ctx)
    end, { nargs = '+' })

    vim.api.nvim_buf_create_user_command(buf, 'TN3270Load', function(opts)
        start_transfer('put', opts.args, screen, ctx)
    end, { nargs = '+' })
end

local function ends_with(data, bytes)
    local n = #data
    if n < #bytes then return false end
    for i = 1, #bytes do
        if data[n - #bytes + i] ~= bytes[i] then return false end
    end
    return true
end

local FT_DATA = { 0x46, 0x54, 0x3A, 0x44, 0x41, 0x54, 0x41 } -- "FT:DATA"
local FT_MSG  = { 0x46, 0x54, 0x3A, 0x4D, 0x53, 0x47 }       -- "FT:MSG"

local function send_ack(client, bytes)
    local s = ''
    for _, b in ipairs(bytes) do s = s .. string.char(b) end
    s = s .. string.char(0xFF, 0xEF)
    client:write(s)
end

function M.handle_sf(sf_data, ctx)
    if state == nil then return end
    local sub = sf_data[1]
    if sub == 0x00 then
        if ends_with(sf_data, FT_DATA) then
            state.phase = 'data'
            ctx.trace('[TF] FT:DATA start')
        elseif ends_with(sf_data, FT_MSG) then
            state.phase = 'msg'
            state.msg = ''
            ctx.trace('[TF] FT:MSG start')
        end
        send_ack(ctx.client, { 0x88, 0x00, 0x05, 0xD0, 0x00, 0x09 })
    elseif sub == 0x47 then
        local second = sf_data[2]
        if second == 0x04 then
            -- sf_data is { 0x47, 0x04, 0xC0, 0x80, 0x61, hi, lo, <ASCII...> }
            if state.phase == 'data' then
                for i = 8, #sf_data do
                    state.buffer[#state.buffer + 1] = sf_data[i]
                end
                ctx.trace(string.format('[TF] data +%d (total %d)', #sf_data - 7, #state.buffer))
            elseif state.phase == 'msg' then
                for i = 8, #sf_data do
                    state.msg = state.msg .. string.char(sf_data[i])
                end
            end
        end
        send_ack(ctx.client, { 0x88, 0x00, 0x0B, 0xD0, 0x47, 0x05, 0x63, 0x06, 0x00, 0x00, 0x00, 0x01 })
    elseif sub == 0x41 then
        ctx.trace('[TF] D0 41 end')
        send_ack(ctx.client, { 0x88, 0x00, 0x05, 0xD0, 0x41, 0x09 })
        if state.phase == 'msg' then
            local bytes = ''
            for _, b in ipairs(state.buffer) do
                bytes = bytes .. string.char(b)
            end
            local f = io.open(state.local_file, 'wb')
            if f then
                f:write(bytes)
                f:close()
                vim.schedule(function()
                    vim.notify(string.format('[TF] wrote %d bytes to %s -- %s',
                        #bytes, state.local_file, (state.msg or ''):gsub('%s+$', '')))
                end)
            else
                vim.schedule(function()
                    vim.notify('[TF] failed to open ' .. state.local_file, vim.log.levels.ERROR)
                end)
            end
            state = nil
        end
    else
        ctx.trace(string.format('[TF] unknown D0 sub 0x%02X', sub))
    end
end

function M.step(screen, ctx)
    -- kept for future needs (beacon-based flows); SF handling drives IND$FILE now
end

function M.state()
    return state
end

function M.reset()
    state = nil
end

return M
