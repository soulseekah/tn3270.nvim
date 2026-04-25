local bit = require('bit')
local ebcdic = require('tn3270.ebcdic')

local M = {}

local CMD_WRITE           = 0xF1
local CMD_ERASE_WRITE     = 0xF5
local CMD_ERASE_WRITE_ALT = 0x7E

local ORDER_SBA = 0x11
local ORDER_SF  = 0x1D
local ORDER_SFE = 0x29
local ORDER_IC  = 0x13
local ORDER_PT  = 0x05
local ORDER_SA  = 0x28
local ORDER_RA  = 0x3C

local SA_RESET  = 0x00
local SA_HIGH   = 0x41 -- extended highlighting
local SA_FG     = 0x42 -- foreground color
local SA_CHARSET= 0x43
local SA_BG     = 0x45 -- background color

local SFE_FIELD = 0xC0 -- basic 3270 field attribute

local function decode_address(b1, b2)
    return bit.band(b1, 0x3F) * 64 + bit.band(b2, 0x3F)
end

local CMD_WSF = 0xF3

function M.process(screen, data, log, handlers)
    log = log or function() end
    handlers = handlers or {}

    local pos = 1
    local cmd = data[pos]
    pos = pos + 1

    if cmd == CMD_WSF then
        local had_query = false
        while pos <= #data - 2 do
            local sf_len = (data[pos] or 0) * 256 + (data[pos + 1] or 0)
            if sf_len < 3 or pos + sf_len - 1 > #data then break end
            local sf_id = data[pos + 2]
            log(string.format('[%04d] SF len=%d id=0x%02X', pos - 1, sf_len, sf_id))
            if sf_id == 0x01 then
                had_query = true
            elseif handlers.sf then
                local sf_data = {}
                for i = pos + 3, pos + sf_len - 1 do
                    sf_data[#sf_data + 1] = data[i]
                end
                handlers.sf(sf_id, sf_data)
            end
            pos = pos + sf_len
        end
        if had_query then return 'wsf_query' end
        return
    end

    log(string.format('[%04d] CMD 0x%02X%s', 0, cmd,
        (cmd == CMD_ERASE_WRITE or cmd == CMD_ERASE_WRITE_ALT) and ' (ERASE)' or ''))

    if cmd == CMD_ERASE_WRITE or cmd == CMD_ERASE_WRITE_ALT then
        screen:clear()
    end

    local wcc = data[pos]
    pos = pos + 1

    screen.locked = bit.band(wcc, 0x02) == 0
    log(string.format('[%04d] WCC 0x%02X locked=%s', 1, wcc, tostring(screen.locked)))

    local addr = screen.cursor
    local ic_set = false
    local cur_hl, cur_fg, cur_bg = 0, 0, 0

    while pos <= #data do
        local byte = data[pos]
        local p = pos - 1

        if byte == ORDER_SBA then
            addr = decode_address(data[pos + 1], data[pos + 2])
            log(string.format('[%04d] SBA -> %d', p, addr))
            pos = pos + 3
        elseif byte == ORDER_SF then
            screen:set_attr(addr, data[pos + 1])
            log(string.format('[%04d] SF attr=0x%02X @%d', p, data[pos + 1], addr))
            addr = (addr + 1) % screen.size
            pos = pos + 2
        elseif byte == ORDER_SFE then
            local count = data[pos + 1] or 0
            local field_attr = 0
            for i = 0, count - 1 do
                local t = data[pos + 2 + i * 2]
                local v = data[pos + 3 + i * 2]
                if t == SFE_FIELD then field_attr = v end
            end
            screen:set_attr(addr, field_attr)
            log(string.format('[%04d] SFE count=%d attr=0x%02X @%d', p, count, field_attr, addr))
            addr = (addr + 1) % screen.size
            pos = pos + 2 + count * 2
        elseif byte == ORDER_IC then
            screen.cursor = addr
            ic_set = true
            log(string.format('[%04d] IC @%d', p, addr))
            pos = pos + 1
        elseif byte == ORDER_SA then
            local t = data[pos + 1]
            local v = data[pos + 2]
            log(string.format('[%04d] SA 0x%02X=0x%02X', p, t, v))
            if t == SA_RESET then
                cur_hl, cur_fg, cur_bg = 0, 0, 0
            elseif t == SA_HIGH then
                cur_hl = v
            elseif t == SA_FG then
                cur_fg = v
            elseif t == SA_BG then
                cur_bg = v
            end
            pos = pos + 3
        elseif byte == ORDER_RA then
            local target = decode_address(data[pos + 1], data[pos + 2])
            local fill = data[pos + 3]
            log(string.format('[%04d] RA fill=0x%02X %d->%d', p, fill, addr, target))
            repeat
                screen:put(addr, fill, cur_hl, cur_fg, cur_bg)
                addr = (addr + 1) % screen.size
            until addr == target
            pos = pos + 4
        elseif byte == ORDER_PT then
            log(string.format('[%04d] PT', p))
            pos = pos + 1
        else
            screen:put(addr, byte, cur_hl, cur_fg, cur_bg)
            log(string.format("[%04d] WR @%d '%s' 0x%02X", p, addr, ebcdic.decode(byte), byte))
            addr = (addr + 1) % screen.size
            pos = pos + 1
        end
    end

    if not ic_set then
        screen.cursor = addr
    end
end

return M
