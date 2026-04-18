local uv = vim.loop
local bit = require('bit')
local Telnet = require('tn3270.telnet')
local Screen = require('tn3270.screen')
local stream = require('tn3270.stream')
local ebcdic = require('tn3270.ebcdic')

local M = {}

local function log(buf, msg)
    vim.schedule(function()
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, {msg})
    end)
end

local OPT_BINARY        = 0x00
local OPT_TERMINAL_TYPE = 0x18
local OPT_EOR           = 0x19

local SUPPORTED = {
    [OPT_BINARY]        = true,
    [OPT_TERMINAL_TYPE] = true,
    [OPT_EOR]           = true,
}

local function option_name(opt)
    local names = {
        [OPT_TERMINAL_TYPE] = 'TERMINAL-TYPE',
        [OPT_EOR]           = 'END-OF-RECORD',
        [OPT_BINARY]        = 'BINARY',
    }
    return names[opt] or string.format('0x%02X', opt)
end

local function send_command(client, cmd, option)
    client:write(string.char(0xFF, cmd, option))
end

local AID_ENTER = 0x7D
local AID_PF = {
    [1]=0xF1, [2]=0xF2, [3]=0xF3, [4]=0xF4, [5]=0xF5, [6]=0xF6,
    [7]=0xF7, [8]=0xF8, [9]=0xF9, [10]=0x7A, [11]=0x7B, [12]=0x7C,
    [13]=0xC1, [14]=0xC2, [15]=0xC3, [16]=0xC4, [17]=0xC5, [18]=0xC6,
    [19]=0xC7, [20]=0xC8, [21]=0xC9, [22]=0x4A, [23]=0x4B, [24]=0x4C,
}

local ADDR_TABLE = {
    [0]=0x40, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7,
    0xC8, 0xC9, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
    0x50, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7,
    0xD8, 0xD9, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
    0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67,
    0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
    0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7,
    0xF8, 0xF9, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F,
}

local function encode_address(addr)
    return ADDR_TABLE[bit.rshift(addr, 6)],
           ADDR_TABLE[bit.band(addr, 0x3F)]
end

local function send_aid(client, aid, screen)
    local bytes = {}
    bytes[#bytes + 1] = aid
    local b1, b2 = encode_address(screen.cursor)
    bytes[#bytes + 1] = b1
    bytes[#bytes + 1] = b2

    for _, field in ipairs(screen:modified_fields()) do
        bytes[#bytes + 1] = 0x11 -- SBA
        local fb1, fb2 = encode_address(field.start)
        bytes[#bytes + 1] = fb1
        bytes[#bytes + 1] = fb2
        for _, db in ipairs(field.data) do
            bytes[#bytes + 1] = db
        end
    end

    local out = ''
    for _, b in ipairs(bytes) do
        out = out .. string.char(b)
    end
    client:write(out)
    client:write(string.char(0xFF, 0xEF))
end

local function send_terminal_type(client)
    local term = 'IBM-3278-3-E'
    local bytes = {0xFF, 0xFA, OPT_TERMINAL_TYPE, 0x00}
    for i = 1, #term do
        bytes[#bytes + 1] = string.byte(term, i)
    end
    bytes[#bytes + 1] = 0xFF
    bytes[#bytes + 1] = 0xF0
    local out = ''
    for _, b in ipairs(bytes) do
        out = out .. string.char(b)
    end
    client:write(out)
end

local function send_query_reply(client)
    local qr = {}

    local function add(bytes)
        for _, b in ipairs(bytes) do qr[#qr + 1] = b end
    end

    local function add_sf(data)
        local len = #data + 2
        qr[#qr + 1] = bit.rshift(len, 8)
        qr[#qr + 1] = bit.band(len, 0xFF)
        add(data)
    end

    -- AID: structured field response
    qr[#qr + 1] = 0x88

    -- QCODE 0x80: Summary (lists our supported QCODEs)
    add_sf({0x81, 0x80,
        0x80, -- summary
        0x81, -- usable area
        0xA6, -- implicit partition
    })

    -- QCODE 0x81: Usable Area (screen dimensions)
    add_sf({0x81, 0x81,
        0x01,       -- 12-bit addressing
        0x00, 0x00, -- flags
        0x00, 0x50, -- width: 80
        0x00, 0x20, -- height: 32 (model 3)
        0x01,       -- units: character cell
        0x00, 0x0A, -- default cell width
        0x02, 0xE5, -- default cell height
        0x00, 0x50, -- alternate width: 80
        0x00, 0x20, -- alternate height: 32
    })



    -- QCODE 0xA6: Implicit Partition (default/alternate screen sizes)
    add_sf({0x81, 0xA6,
        0x00, 0x00, -- flags
        0x0B,       -- data length
        0x01, 0x00, -- reserved
        0x00, 0x50, -- default width: 80
        0x00, 0x20, -- default height: 32
        0x00, 0x50, -- alternate width: 80
        0x00, 0x20, -- alternate height: 32
    })

    local out = ''
    for _, b in ipairs(qr) do
        out = out .. string.char(b)
    end
    client:write(out)
    client:write(string.char(0xFF, 0xEF))
end

local ns = vim.api.nvim_create_namespace('tn3270')

local function update_display(buf, screen)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, screen:to_lines())

    -- Position nvim cursor to match 3270 cursor
    local row = math.floor(screen.cursor / screen.cols)
    local col = screen.cursor % screen.cols
    pcall(vim.api.nvim_win_set_cursor, 0, {row + 1, col})

    -- TODO: highlight unprotected fields when color support is added
end

function M.connect()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].buftype = 'nofile'

    local logfile = io.open('tn3270.log', 'w')
    local screen = Screen.new(32, 80)
    local data_buf = {}

    local function trace(line)
        if logfile then
            logfile:write(line)
            logfile:write('\n')
            logfile:flush()
        end
    end

    local function dump_screen()
        if not logfile then return end
        logfile:write('--- screen ---\n')
        for i, line in ipairs(screen:to_lines()) do
            logfile:write(string.format('%02d|%s|\n', i - 1, line))
        end
        logfile:write('--- end ---\n')
        logfile:flush()
    end

    local client = uv.new_tcp()

    local telnet = Telnet.new({
        on_do = function(option)
            log(buf, 'RECV DO ' .. option_name(option))
            if SUPPORTED[option] then
                send_command(client, 0xFB, option)
                log(buf, 'SENT WILL ' .. option_name(option))
            else
                send_command(client, 0xFC, option)
                log(buf, 'SENT WONT ' .. option_name(option))
            end
        end,
        on_will = function(option)
            log(buf, 'RECV WILL ' .. option_name(option))
            if SUPPORTED[option] then
                send_command(client, 0xFD, option)
                log(buf, 'SENT DO ' .. option_name(option))
            else
                send_command(client, 0xFE, option)
                log(buf, 'SENT DONT ' .. option_name(option))
            end
        end,
        on_dont = function(option)
            log(buf, 'RECV DONT ' .. option_name(option))
        end,
        on_wont = function(option)
            log(buf, 'RECV WONT ' .. option_name(option))
        end,
        on_subneg = function(option, data)
            if option == OPT_TERMINAL_TYPE and data[1] == 0x01 then
                log(buf, 'RECV SB TERMINAL-TYPE SEND')
                send_terminal_type(client)
                log(buf, 'SENT SB TERMINAL-TYPE IS IBM-3278-3-E')
            else
                local hex = {}
                for _, b in ipairs(data) do
                    hex[#hex + 1] = string.format('%02X', b)
                end
                log(buf, 'RECV SB ' .. option_name(option) .. ' ' .. table.concat(hex, ' '))
            end
        end,
        on_data = function(byte)
            data_buf[#data_buf + 1] = string.byte(byte)
        end,
        on_eor = function()
            if #data_buf > 0 then
                trace(string.format('=== EOR %d bytes ===', #data_buf))
                local result = stream.process(screen, data_buf, trace)
                dump_screen()
                data_buf = {}
                if result == 'wsf_query' then
                    send_query_reply(client)
                else
                    vim.schedule(function()
                        update_display(buf, screen)
                    end)
                end
            end
        end,
    })

    local port = 3271
    client:connect('127.0.0.1', port, function(err)
        if err then
            log(buf, 'ERROR: ' .. err)
            return
        end

        vim.schedule(function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'Connected to 127.0.0.1:3270', ''})
            vim.keymap.set('n', '<CR>', function()
                if screen.locked then return end
                local lines = vim.api.nvim_buf_get_lines(buf, 0, screen.rows, false)
                screen:sync_from_lines(lines)
                -- Sync vim cursor position back to screen model
                local pos = vim.api.nvim_win_get_cursor(0)
                screen.cursor = (pos[1] - 1) * screen.cols + pos[2]
                send_aid(client, AID_ENTER, screen)
                screen.locked = true
            end, { buffer = buf })
            vim.keymap.set('n', '<Tab>', function()
                local lines = vim.api.nvim_buf_get_lines(buf, 0, screen.rows, false)
                screen:sync_from_lines(lines)
                screen.cursor = screen:next_field(screen.cursor)
                update_display(buf, screen)
            end, { buffer = buf })

            -- i enters replace mode (3270 overtype)
            vim.keymap.set('n', '<S-Tab>', function()
                local lines = vim.api.nvim_buf_get_lines(buf, 0, screen.rows, false)
                screen:sync_from_lines(lines)
                screen.cursor = screen:prev_field(screen.cursor)
                update_display(buf, screen)
            end, { buffer = buf })
            vim.keymap.set('n', 'i', 'R', { buffer = buf })
            vim.keymap.set('n', 'I', 'R', { buffer = buf })

            vim.keymap.set('n', '<leader>h', function()
                local lines = vim.api.nvim_buf_get_lines(buf, 0, screen.rows, false)
                screen:sync_from_lines(lines)
                screen.cursor = screen:next_field(screen.size - 1)
                update_display(buf, screen)
            end, { buffer = buf })

            for n, aid in pairs(AID_PF) do
                vim.keymap.set('n', string.format('<leader>pf%d', n), function()
                    if screen.locked then return end
                    local lines = vim.api.nvim_buf_get_lines(buf, 0, screen.rows, false)
                    screen:sync_from_lines(lines)
                    local pos = vim.api.nvim_win_get_cursor(0)
                    screen.cursor = (pos[1] - 1) * screen.cols + pos[2]
                    send_aid(client, aid, screen)
                    screen.locked = true
                end, { buffer = buf })
            end
        end)

        client:read_start(function(err, data)
            if err then
                return
            end

            if not data then
                log(buf, '-- connection closed --')
                return
            end

            telnet:feed(data)
        end)
    end)
end

return M
