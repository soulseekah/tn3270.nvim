local Screen = require('tn3270.screen')
local stream = require('tn3270.stream')
local detect = require('tn3270.detect')
local h = require('tests.helpers')

describe('stream.process', function()
    it('parses ERASE WRITE and WCC keyboard-restore bit', function()
        local s = Screen.new(24, 80)
        s.locked = true
        stream.process(s, h.concat(h.cmd_erase_write(), h.wcc(0xC3)))
        assert.is_false(s.locked) -- bit 0x02 set -> unlock
    end)

    it('keeps keyboard locked when WCC bit 0x02 unset', function()
        local s = Screen.new(24, 80)
        stream.process(s, h.concat(h.cmd_write(), h.wcc(0xC1)))
        assert.is_true(s.locked)
    end)

    it('writes EBCDIC text at SBA-set address', function()
        local s = Screen.new(24, 80)
        local data = h.concat(
            h.cmd_erase_write(), h.wcc(0xC3),
            h.sba(0), h.sf(0x60),                -- protected field at 0
            h.sba(1), h.text_bytes('Hello')
        )
        stream.process(s, data)
        local lines = s:to_lines()
        assert.equals(' Hello', lines[1]:sub(1, 6))
    end)

    it('sets field attribute on SF', function()
        local s = Screen.new(24, 80)
        stream.process(s, h.concat(
            h.cmd_erase_write(), h.wcc(0xC3),
            h.sba(80), h.sf(0x4C)
        ))
        assert.equals(0x4C, s.attrs[81])
    end)

    it('RA fills range with byte', function()
        local s = Screen.new(24, 80)
        stream.process(s, h.concat(
            h.cmd_erase_write(), h.wcc(0xC3),
            h.sba(0), h.ra(5, 0x40)
        ))
        for i = 1, 5 do
            assert.equals(0x40, s.buffer[i])
        end
    end)

    it('places cursor at IC order', function()
        local s = Screen.new(24, 80)
        stream.process(s, h.concat(
            h.cmd_erase_write(), h.wcc(0xC3),
            h.sba(81), h.ic()
        ))
        assert.equals(81, s.cursor)
    end)

    it('SA tracks foreground color for subsequent writes', function()
        local s = Screen.new(24, 80)
        stream.process(s, h.concat(
            h.cmd_erase_write(), h.wcc(0xC3),
            h.sba(0),
            h.sa(0x42, 0xF6),                    -- SA fg = yellow
            h.text_bytes('YE'),
            h.sa(0x00, 0x00),                    -- reset
            h.text_bytes('LO')
        ))
        assert.equals(0xF6, s.color[1]) -- 'Y' yellow
        assert.equals(0xF6, s.color[2]) -- 'E' yellow
        assert.equals(0,    s.color[3]) -- 'L' default
        assert.equals(0,    s.color[4]) -- 'O' default
    end)
end)

describe('end-to-end: stream.process + detect', function()
    it('builds the TK5 password screen and detects tso_password', function()
        local s = Screen.new(32, 80)
        local data = h.concat(
            h.cmd_erase_write(), h.wcc(0xC3),
            h.sba(1919), h.sf(0x40),
            h.sba(0),    h.sf(0xC8),
            h.text_bytes(' ENTER CURRENT PASSWORD FOR HERC01-'),
            h.sf(0x40),
            h.sba(80),   h.sf(0x4C),
            h.ic()
        )
        stream.process(s, data)
        assert.equals('tso_password', detect.detect(s))
        assert.equals(81, s.cursor)
        assert.equals(0x4C, s.attrs[81]) -- non-display field present
    end)
end)
