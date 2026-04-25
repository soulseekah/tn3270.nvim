local ebcdic = require('tn3270.ebcdic')

local M = {}

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

function M.encode_addr(addr)
    return ADDR_TABLE[math.floor(addr / 64)], ADDR_TABLE[addr % 64]
end

function M.write_text(screen, row, col, text)
    for i = 1, #text do
        local pos = row * screen.cols + col + i - 1
        screen.buffer[pos + 1] = ebcdic.encode(text:sub(i, i))
    end
end

function M.set_field(screen, pos, attr)
    screen.attrs[pos + 1] = attr
end

function M.text_bytes(text)
    local out = {}
    for i = 1, #text do out[#out + 1] = ebcdic.encode(text:sub(i, i)) end
    return out
end

function M.concat(...)
    local out = {}
    for _, t in ipairs({...}) do
        for _, b in ipairs(t) do out[#out + 1] = b end
    end
    return out
end

-- 3270 order builders. Each returns a flat byte array for splice into a stream.
function M.cmd_erase_write() return {0xF5} end
function M.cmd_write()       return {0xF1} end
function M.wcc(b)            return {b} end
function M.sba(addr)
    local b1, b2 = M.encode_addr(addr)
    return {0x11, b1, b2}
end
function M.sf(attr) return {0x1D, attr} end
function M.ic()     return {0x13} end
function M.ra(addr, fill)
    local b1, b2 = M.encode_addr(addr)
    return {0x3C, b1, b2, fill}
end
function M.sa(typ, val) return {0x28, typ, val} end

return M
