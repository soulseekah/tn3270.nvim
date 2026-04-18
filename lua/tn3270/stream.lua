local bit = require('bit')
local ebcdic = require('tn3270.ebcdic')

local M = {}

local CMD_WRITE           = 0xF1
local CMD_ERASE_WRITE     = 0xF5
local CMD_ERASE_WRITE_ALT = 0x7E

local ORDER_SBA = 0x11
local ORDER_SF  = 0x1D
local ORDER_IC  = 0x13
local ORDER_PT  = 0x05
local ORDER_SA  = 0x28
local ORDER_RA  = 0x3C

local function decode_address(b1, b2)
    return bit.band(b1, 0x3F) * 64 + bit.band(b2, 0x3F)
end

local CMD_WSF = 0xF3

function M.process(screen, data, log)
    log = log or function() end

    local pos = 1
    local cmd = data[pos]
    pos = pos + 1

    if cmd == CMD_WSF then
        log(string.format('[%04d] WSF', 0))
        return 'wsf_query'
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
        elseif byte == ORDER_IC then
            screen.cursor = addr
            ic_set = true
            log(string.format('[%04d] IC @%d', p, addr))
            pos = pos + 1
        elseif byte == ORDER_SA then
            log(string.format('[%04d] SA 0x%02X=0x%02X', p, data[pos + 1], data[pos + 2]))
            pos = pos + 3
        elseif byte == ORDER_RA then
            local target = decode_address(data[pos + 1], data[pos + 2])
            local fill = data[pos + 3]
            log(string.format('[%04d] RA fill=0x%02X %d->%d', p, fill, addr, target))
            repeat
                screen:put(addr, fill)
                addr = (addr + 1) % screen.size
            until addr == target
            pos = pos + 4
        elseif byte == ORDER_PT then
            log(string.format('[%04d] PT', p))
            pos = pos + 1
        else
            screen:put(addr, byte)
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
