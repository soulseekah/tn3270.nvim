local Screen = require('tn3270.screen')
local ebcdic = require('tn3270.ebcdic')
local h = require('tests.helpers')

describe('Screen:next_field', function()
    it('returns data start of first unprotected field after cursor', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 0, 0x60)   -- protected at 0
        h.set_field(s, 80, 0x40)  -- unprotected at 80
        assert.equals(81, s:next_field(0))
    end)

    it('wraps around end of buffer', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 80, 0x40)
        assert.equals(81, s:next_field(1500))
    end)

    it('skips protected fields', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 100, 0x60) -- protected
        h.set_field(s, 200, 0x40) -- unprotected
        assert.equals(201, s:next_field(0))
    end)

    it('skips zero-length fields (two adjacent SFs)', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 80, 0x40)  -- unprotected, but zero-length (next pos is SF)
        h.set_field(s, 81, 0x60)  -- protected terminator
        h.set_field(s, 200, 0x40)
        assert.equals(201, s:next_field(0))
    end)

    it('skips zero-length wraparound on 24-row screen', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 0,    0x40)
        h.set_field(s, 1919, 0x40) -- wraparound; data_start = 0 = next SF
        assert.equals(1, s:next_field(81))
    end)
end)

describe('Screen:prev_field', function()
    it('jumps backward to previous unprotected field data start', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 0,  0x40)
        h.set_field(s, 80, 0x40)
        assert.equals(81, s:prev_field(160))
    end)

    it('does not return the same position when already at field start', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 0,  0x40)
        h.set_field(s, 80, 0x40)
        -- Cursor at data start of @80 (pos 81); prev should walk back to @0's data
        assert.equals(1, s:prev_field(81))
    end)
end)

describe('Screen:modified_fields', function()
    it('collects MDT-flagged unprotected fields with EBCDIC data', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 80, bit.bor(0x40, 0x01)) -- unprotected, MDT set
        s.buffer[82] = ebcdic.encode('A')
        s.buffer[83] = ebcdic.encode('B')
        local fields = s:modified_fields()
        assert.equals(1, #fields)
        assert.equals(81, fields[1].start)
        assert.same({0xC1, 0xC2}, fields[1].data)
    end)

    it('strips trailing nulls but preserves spaces', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 80, bit.bor(0x40, 0x01))
        s.buffer[82] = ebcdic.encode('A')
        s.buffer[83] = 0x40 -- EBCDIC space
        s.buffer[84] = 0x00 -- null, should be stripped
        local fields = s:modified_fields()
        assert.same({0xC1, 0x40}, fields[1].data)
    end)

    it('skips fields without MDT', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 80, 0x40) -- unprotected, MDT clear
        s.buffer[82] = ebcdic.encode('A')
        assert.equals(0, #s:modified_fields())
    end)

    it('skips protected fields even with MDT set', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 80, bit.bor(0x60, 0x01)) -- protected + MDT
        s.buffer[82] = ebcdic.encode('A')
        assert.equals(0, #s:modified_fields())
    end)
end)

describe('Screen:cell_style', function()
    local function styled(attr, pos)
        local s = Screen.new(24, 80)
        h.set_field(s, 0, attr)
        return s:cell_style(pos or 5)
    end

    it('green for unprotected normal', function()
        local fg = styled(0x40)
        assert.equals(0xF4, fg)
    end)

    it('red for unprotected intense', function()
        local fg = styled(0xC8) -- 0x08 intensity bits, no protect
        assert.equals(0xF2, fg)
    end)

    it('blue for protected normal', function()
        local fg = styled(0x60)
        assert.equals(0xF1, fg)
    end)

    it('white for protected intense', function()
        local fg = styled(0x68)
        assert.equals(0xF7, fg)
    end)

    it('SA-set fg overrides field default', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 0, 0x40) -- unprotected normal -> default green
        s.color[6] = 0xF6       -- yellow at pos 5
        local fg = s:cell_style(5)
        assert.equals(0xF6, fg)
    end)
end)

describe('Screen:sync_from_lines', function()
    it('captures typed input into buffer and sets MDT', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 0, 0x40) -- unprotected
        local lines = {}
        for r = 1, 24 do lines[r] = string.rep(' ', 80) end
        lines[1] = ' HI' .. string.rep(' ', 77)
        s:sync_from_lines(lines)
        assert.equals(0xC8, s.buffer[2]) -- 'H'
        assert.equals(0xC9, s.buffer[3]) -- 'I'
        assert.is_truthy(bit.band(s.attrs[1], 0x01) ~= 0)
    end)

    it('skips non-display fields entirely', function()
        local s = Screen.new(24, 80)
        h.set_field(s, 0, 0x4C) -- unprotected non-display
        s.buffer[2] = ebcdic.encode('S') -- pre-stored "secret"
        s:set_mdt(0)
        local lines = {}
        for r = 1, 24 do lines[r] = string.rep(' ', 80) end
        lines[1] = ' *' .. string.rep(' ', 78)
        s:sync_from_lines(lines)
        assert.equals(ebcdic.encode('S'), s.buffer[2]) -- preserved
        assert.is_truthy(bit.band(s.attrs[1], 0x01) ~= 0) -- MDT preserved
    end)
end)
