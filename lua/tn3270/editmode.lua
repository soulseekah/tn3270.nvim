local bit = require('bit')
local ebcdic = require('tn3270.ebcdic')

local M = {}

function M.detect(screen)
    local line0 = screen:to_lines()[1] or ''
    if line0:find('REVEDIT') or line0:find('EDIT ') or line0:find('VIEW ') then
        return 'revedit'
    end
    return 'normal'
end

function M.setup(buf, screen, submit)
    local function send_line_cmd(cmd_char, row)
        if screen.mode ~= 'revedit' then return end
        local lines = vim.api.nvim_buf_get_lines(buf, 0, screen.rows, false)
        screen:sync_from_lines(lines)
        local attr_pos = row * screen.cols
        if not screen.attrs[attr_pos + 1] then return end
        if bit.band(screen.attrs[attr_pos + 1], 0x20) ~= 0 then return end
        local data_start = attr_pos + 1
        local field_end = screen:field_end(attr_pos)
        screen:put(data_start, ebcdic.encode(cmd_char))
        for p = data_start + 1, field_end do
            screen:put(p, 0x40)
        end
        screen:set_mdt(attr_pos)
        submit()
    end

    local function submit_command(text)
        if screen.mode ~= 'revedit' then return end
        local lines = vim.api.nvim_buf_get_lines(buf, 0, screen.rows, false)
        screen:sync_from_lines(lines)
        local data_start = screen:next_field(screen.size - 1)
        local attr_pos = (data_start - 1 + screen.size) % screen.size
        local field_end = screen:field_end(attr_pos)
        text = text:upper()
        for p = data_start, field_end do
            local i = p - data_start + 1
            if i <= #text then
                screen:put(p, ebcdic.encode(text:sub(i, i)))
            else
                screen:put(p, 0x40)
            end
        end
        screen:set_mdt(attr_pos)
        submit()
    end

    vim.keymap.set('n', 'o', function()
        local cpos = vim.api.nvim_win_get_cursor(0)
        send_line_cmd('I', cpos[1] - 1)
    end, { buffer = buf })

    vim.keymap.set('n', 'O', function()
        local cpos = vim.api.nvim_win_get_cursor(0)
        if cpos[1] > 1 then
            send_line_cmd('I', cpos[1] - 2)
        end
    end, { buffer = buf })

    vim.keymap.set('n', 'dd', function()
        local cpos = vim.api.nvim_win_get_cursor(0)
        send_line_cmd('D', cpos[1] - 1)
    end, { buffer = buf })

    local yank_row = nil

    local function write_cmd_at(row, ch)
        local attr_pos = row * screen.cols
        if not screen.attrs[attr_pos + 1] then return false end
        if bit.band(screen.attrs[attr_pos + 1], 0x20) ~= 0 then return false end
        local data_start = attr_pos + 1
        local field_end = screen:field_end(attr_pos)
        screen:put(data_start, ebcdic.encode(ch))
        for p = data_start + 1, field_end do
            screen:put(p, 0x40)
        end
        screen:set_mdt(attr_pos)
        return true
    end

    vim.keymap.set('n', 'yy', function()
        if screen.mode ~= 'revedit' then return end
        local cpos = vim.api.nvim_win_get_cursor(0)
        yank_row = cpos[1] - 1
    end, { buffer = buf })

    vim.keymap.set('n', 'pp', function()
        if screen.mode ~= 'revedit' then return end
        if yank_row == nil then return end
        local cpos = vim.api.nvim_win_get_cursor(0)
        local dest_row = cpos[1] - 1
        local lines = vim.api.nvim_buf_get_lines(buf, 0, screen.rows, false)
        screen:sync_from_lines(lines)
        if yank_row == dest_row then
            if not write_cmd_at(dest_row, 'R') then return end
        else
            if not write_cmd_at(yank_row, 'C') then return end
            if not write_cmd_at(dest_row, 'A') then return end
        end
        submit()
    end, { buffer = buf })

    vim.keymap.set('n', 'gg', function()
        submit_command('TOP')
    end, { buffer = buf })

    vim.keymap.set('n', 'G', function()
        submit_command('BOT')
    end, { buffer = buf })

    vim.api.nvim_buf_create_user_command(buf, 'LINE', function(opts)
        submit_command('L ' .. opts.args)
    end, { nargs = 1 })

    vim.keymap.set('n', 'A', function()
        if screen.mode ~= 'revedit' then return end
        local cpos = vim.api.nvim_win_get_cursor(0)
        local line = vim.api.nvim_buf_get_lines(buf, cpos[1] - 1, cpos[1], false)[1] or ''
        local trimmed = line:gsub('%s+$', '')
        pcall(vim.api.nvim_win_set_cursor, 0, {cpos[1], #trimmed})
        vim.cmd('startreplace')
    end, { buffer = buf })
end

return M
