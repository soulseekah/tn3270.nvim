local uv = vim.loop
local bit = require('bit')
local Telnet = require('tn3270.telnet')
local Screen = require('tn3270.screen')
local stream = require('tn3270.stream')
local ebcdic = require('tn3270.ebcdic')
local editmode = require('tn3270.editmode')
local transfer = require('tn3270.transfer')
local detect = require('tn3270.detect')
local config = require('tn3270.config')

local M = {}

M.setup = config.setup

local active = nil  -- one in-flight connection at a time

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
local AID_CLEAR = 0x6D
local AID_PA = { [1]=0x6C, [2]=0x6E }
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

local function send_aid(client, aid, screen, short)
    local bytes = {}
    bytes[#bytes + 1] = aid
    local b1, b2 = encode_address(screen.cursor)
    bytes[#bytes + 1] = b1
    bytes[#bytes + 1] = b2

    if not short then
        for _, field in ipairs(screen:modified_fields()) do
            bytes[#bytes + 1] = 0x11 -- SBA
            local fb1, fb2 = encode_address(field.start)
            bytes[#bytes + 1] = fb1
            bytes[#bytes + 1] = fb2
            for _, db in ipairs(field.data) do
                bytes[#bytes + 1] = db
            end
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
        0x84, -- alphanumeric partitions
        0x86, -- color
        0x87, -- highlighting
        0x88, -- reply modes
        0xA6, -- implicit partition
    })

    -- QCODE 0x81: Usable Area (matches c3270's layout; model 3 80x32)
    add_sf({0x81, 0x81,
        0x01,       -- 12-bit addressing
        0x00,       -- flags
        0x00, 0x50, -- width: 80
        0x00, 0x20, -- height: 32
        0x01,       -- units: character cell
        0x00, 0x0A, -- default cell width
        0x02, 0xE5, -- default cell height
        0x00, 0x02, -- partition ID / max partitions
        0x00, 0x6F, -- buffer chars max (unused)
        0x09, 0x0C, 0x0D, 0x70, -- unknown (from c3270)
    })

    -- QCODE 0x84: Alphanumeric Partitions
    add_sf({0x81, 0x84,
        0x00,       -- partitions
        0x0D, 0x70, -- total buffer chars
        0x00,       -- flags
    })

    -- QCODE 0x86: Color (8 base colors plus 8 extended)
    add_sf({0x81, 0x86,
        0x00, -- flags
        0x10, -- 16 color pairs follow
        0x00, 0xF4, -- default base attribute -> green
        0xF1, 0xF1, 0xF2, 0xF2, 0xF3, 0xF3, 0xF4, 0xF4,
        0xF5, 0xF5, 0xF6, 0xF6, 0xF7, 0xF7, 0xF8, 0xF8,
        0xF9, 0xF9, 0xFA, 0xFA, 0xFB, 0xFB, 0xFC, 0xFC,
        0xFD, 0xFD, 0xFE, 0xFE, 0xFF, 0xFF,
    })

    -- QCODE 0x87: Highlighting
    add_sf({0x81, 0x87,
        0x05, -- 5 highlight pairs
        0x00, 0x00, -- default
        0xF1, 0xF1, -- blink
        0xF2, 0xF2, -- reverse
        0xF4, 0xF4, -- underscore
        0xF8, 0xF8, -- intensify
    })

    -- QCODE 0x88: Reply Modes (enables IND$FILE structured-field responses)
    add_sf({0x81, 0x88,
        0x00, -- field mode
        0x01, -- extended field mode
        0x02, -- character mode
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

local COLOR_NAME = {
    [0xF0] = 'Neutral',   [0xF1] = 'Blue',  [0xF2] = 'Red',    [0xF3] = 'Pink',
    [0xF4] = 'Green',     [0xF5] = 'Turquoise', [0xF6] = 'Yellow', [0xF7] = 'White',
}

local HL_NAME = {
    [0xF1] = 'Tn3270Blink',
    [0xF2] = 'Tn3270Reverse',
    [0xF4] = 'Tn3270Underline',
    [0xF8] = 'Tn3270Bold',
}

local function setup_highlights()
    local fg = {
        Neutral   = { ctermfg = 'NONE', fg = 'NONE' },
        Blue      = { ctermfg = 75,     fg = '#5f9fff' },
        Red       = { ctermfg = 196,    fg = '#ff5f5f' },
        Pink      = { ctermfg = 213,    fg = '#ff87d7' },
        Green     = { ctermfg = 46,     fg = '#5fff5f' },
        Turquoise = { ctermfg = 51,     fg = '#5fffff' },
        Yellow    = { ctermfg = 226,    fg = '#ffff5f' },
        White     = { ctermfg = 231,    fg = '#ffffff' },
    }
    for name, def in pairs(fg) do
        vim.api.nvim_set_hl(0, 'Tn3270' .. name,
            { ctermfg = def.ctermfg, fg = def.fg, default = true })
        local bg = {
            ctermbg = def.ctermfg ~= 'NONE' and def.ctermfg or nil,
            bg = def.fg ~= 'NONE' and def.fg or nil,
            default = true,
        }
        vim.api.nvim_set_hl(0, 'Tn3270Bg' .. name, bg)
    end
    vim.api.nvim_set_hl(0, 'Tn3270Reverse',   { reverse = true,   default = true })
    vim.api.nvim_set_hl(0, 'Tn3270Underline', { underline = true, default = true })
    vim.api.nvim_set_hl(0, 'Tn3270Bold',      { bold = true,      default = true })
    vim.api.nvim_set_hl(0, 'Tn3270Blink',     { undercurl = true, default = true })
end

setup_highlights()

local function update_display(buf, screen)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, screen:to_lines())
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

    for row = 0, screen.rows - 1 do
        local col = 0
        while col < screen.cols do
            local pos = row * screen.cols + col
            local fg, bg, hl = screen:cell_style(pos)
            local end_col = col + 1
            while end_col < screen.cols do
                local p2 = row * screen.cols + end_col
                local fg2, bg2, hl2 = screen:cell_style(p2)
                if fg2 ~= fg or bg2 ~= bg or hl2 ~= hl then break end
                end_col = end_col + 1
            end
            local fg_name = COLOR_NAME[fg]
            if fg_name then
                vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
                    end_col = end_col,
                    hl_group = 'Tn3270' .. fg_name,
                    priority = 100,
                })
            end
            local bg_name = COLOR_NAME[bg]
            if bg ~= 0 and bg_name then
                vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
                    end_col = end_col,
                    hl_group = 'Tn3270Bg' .. bg_name,
                    priority = 110,
                })
            end
            local mod_name = HL_NAME[hl]
            if mod_name then
                vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
                    end_col = end_col,
                    hl_group = mod_name,
                    priority = 120,
                })
            end
            col = end_col
        end
    end

    local cur_row = math.floor(screen.cursor / screen.cols)
    local cur_col = screen.cursor % screen.cols
    pcall(vim.api.nvim_win_set_cursor, 0, {cur_row + 1, cur_col})
end

function M.connect(opts)
    if active then M.disconnect() end
    local cfg = config.get(opts)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].buftype = 'nofile'

    local logfile = cfg.debug and io.open(cfg.log_file, 'w') or nil
    local screen = Screen.new(32, 80)
    local data_buf = {}
    local autologin_state = cfg.autologin and 'logon' or 'done'

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

    local function write_to_cursor_field(text)
        local attr_pos = screen:field_attr_at(screen.cursor)
        if not attr_pos then return false end
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

    local function write_to_command_field(text)
        local data_start = screen:next_field(screen.size - 1)
        local attr_pos = (data_start - 1 + screen.size) % screen.size
        if not screen.attrs[attr_pos + 1] then return false end
        if bit.band(screen.attrs[attr_pos + 1], 0x20) ~= 0 then return false end
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

    local function logoff_from_ready()
        if not write_to_cursor_field('LOGOFF') then return end
        send_aid(client, AID_ENTER, screen)
        screen.locked = true
        vim.wait(1500, function() return false end)
    end

    local function exit_ispf_then_logoff()
        if not write_to_cursor_field('X') then return end
        send_aid(client, AID_ENTER, screen)
        screen.locked = true
        vim.wait(2000, function() return screen.mode == 'tso_ready' end)
        if screen.mode == 'tso_ready' then logoff_from_ready() end
    end

    local function jump_exit_then_logoff()
        if not write_to_command_field('=X') then return end
        send_aid(client, AID_ENTER, screen)
        screen.locked = true
        vim.wait(2500, function() return screen.mode == 'tso_ready' end)
        if screen.mode == 'tso_ready' then logoff_from_ready() end
    end

    local function run_logoff_for_mode()
        if screen.mode == 'ispf_primary' then
            exit_ispf_then_logoff()
        elseif screen.mode == 'revedit' then
            jump_exit_then_logoff()
        elseif screen.mode == 'tso_ready' then
            logoff_from_ready()
        end
    end

    local function handle_autologin()
        if not cfg.autologin or autologin_state == 'done' then return end
        if autologin_state == 'logon' and screen.mode == 'tso_logon' then
            if write_to_command_field('LOGON ' .. cfg.autologin.userid) then
                send_aid(client, AID_ENTER, screen)
                screen.locked = true
                autologin_state = 'password'
            end
        elseif autologin_state == 'password' and screen.mode == 'tso_password' then
            if write_to_cursor_field(cfg.autologin.password) then
                send_aid(client, AID_ENTER, screen)
                screen.locked = true
                autologin_state = 'finishing'
            end
        elseif screen.mode == 'ispf_primary' or screen.mode == 'tso_ready' then
            autologin_state = 'done'
        end
    end

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
                local result = stream.process(screen, data_buf, trace, {
                    sf = function(sf_id, sf_data)
                        if sf_id == 0xD0 then
                            transfer.handle_sf(sf_data, { trace = trace, client = client })
                        end
                    end,
                })
                screen.mode = detect.detect(screen)
                trace(string.format('[mode] %s', screen.mode))
                dump_screen()
                data_buf = {}
                handle_autologin()
                if result == 'wsf_query' then
                    send_query_reply(client)
                else
                    vim.schedule(function()
                        update_display(buf, screen)
                        transfer.step(screen, {
                            trace = trace,
                            submit = function()
                                send_aid(client, AID_ENTER, screen)
                                screen.locked = true
                            end,
                        })
                    end)
                end
            end
        end,
    })

    active = { client = client, run_logoff = run_logoff_for_mode }

    client:connect(cfg.host, cfg.port, function(err)
        if err then
            log(buf, 'ERROR: ' .. err)
            return
        end

        vim.schedule(function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false,
                {string.format('Connected to %s:%d', cfg.host, cfg.port), ''})
            local function submit_enter()
                if screen.locked then return end
                local lines = vim.api.nvim_buf_get_lines(buf, 0, screen.rows, false)
                screen:sync_from_lines(lines)
                local pos = vim.api.nvim_win_get_cursor(0)
                screen.cursor = (pos[1] - 1) * screen.cols + pos[2]
                send_aid(client, AID_ENTER, screen)
                screen.locked = true
            end

            vim.keymap.set('n', '<CR>', submit_enter, { buffer = buf })
            vim.keymap.set('i', '<CR>', function()
                vim.cmd('stopinsert')
                submit_enter()
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

            local masking = false
            vim.api.nvim_create_autocmd('TextChangedI', {
                buffer = buf,
                callback = function()
                    if masking then return end
                    local cpos = vim.api.nvim_win_get_cursor(0)
                    local row, col = cpos[1] - 1, cpos[2] - 1
                    if col < 0 then return end
                    local pos = row * screen.cols + col
                    local attr_pos = screen:field_attr_at(pos)
                    if not attr_pos or not screen.attrs[attr_pos + 1] then return end
                    if bit.band(screen.attrs[attr_pos + 1], 0x0C) ~= 0x0C then return end
                    local line = (vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]) or ''
                    local typed = line:sub(col + 1, col + 1)
                    if typed == '' or typed == '*' then return end
                    screen.buffer[pos + 1] = ebcdic.encode(typed)
                    screen:set_mdt(attr_pos)
                    masking = true
                    local masked = line:sub(1, col) .. '*' .. line:sub(col + 2)
                    vim.api.nvim_buf_set_lines(buf, row, row + 1, false, { masked })
                    pcall(vim.api.nvim_win_set_cursor, 0, { row + 1, col + 1 })
                    masking = false
                end,
            })

            for _, key in ipairs({'p', 'P', 'x', 'X', 'D', 'J', 'cc', 'C', 's', 'S'}) do
                vim.keymap.set('n', key, '<Nop>', { buffer = buf })
            end

            local submit_enter_at_cursor = function()
                local cpos = vim.api.nvim_win_get_cursor(0)
                screen.cursor = (cpos[1] - 1) * screen.cols + cpos[2]
                send_aid(client, AID_ENTER, screen)
                screen.locked = true
            end

            editmode.setup(buf, screen, submit_enter_at_cursor)
            transfer.setup(buf, screen, {
                trace = trace,
                client = client,
                send_enter = function()
                    send_aid(client, AID_ENTER, screen)
                    screen.locked = true
                end,
            })

            vim.api.nvim_create_autocmd('QuitPre', {
                buffer = buf,
                callback = function() M.disconnect() end,
            })

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

            vim.keymap.set('n', '<PageUp>', '<leader>pf7', { buffer = buf, remap = true })
            vim.keymap.set('n', '<PageDown>', '<leader>pf8', { buffer = buf, remap = true })

            for n, aid in pairs(AID_PA) do
                vim.keymap.set('n', string.format('<leader>pa%d', n), function()
                    local pos = vim.api.nvim_win_get_cursor(0)
                    screen.cursor = (pos[1] - 1) * screen.cols + pos[2]
                    send_aid(client, aid, screen, true)
                    screen.locked = true
                end, { buffer = buf })
            end

            vim.keymap.set('n', '<leader>pcl', function()
                screen:clear()
                send_aid(client, AID_CLEAR, screen, true)
                screen.locked = true
                update_display(buf, screen)
            end, { buffer = buf })
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

function M.disconnect()
    if not active then return end
    pcall(function() active.run_logoff() end)
    pcall(function() active.client:shutdown() end)
    pcall(function() active.client:close() end)
    active = nil
end

vim.api.nvim_create_user_command('TN3270', function(o)
    local args = vim.split(o.args or '', '%s+', { trimempty = true })
    local opts = {}
    if args[1] and args[1] ~= '' then opts.host = args[1] end
    if args[2] then opts.port = tonumber(args[2]) end
    M.connect(opts)
end, { nargs = '*' })

return M
