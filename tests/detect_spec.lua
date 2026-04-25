local Screen = require('tn3270.screen')
local detect = require('tn3270.detect')
local h = require('tests.helpers')

describe('detect.detect', function()
    it('classifies tso_logon by row 22 prompt', function()
        local s = Screen.new(32, 80)
        h.write_text(s, 22, 0, 'Logon ===>')
        assert.equals('tso_logon', detect.detect(s))
    end)

    it('classifies tso_password by row 0 prompt', function()
        local s = Screen.new(32, 80)
        h.write_text(s, 0, 1, 'ENTER CURRENT PASSWORD FOR HERC01-')
        assert.equals('tso_password', detect.detect(s))
    end)

    it('classifies ispf_primary by panel id', function()
        local s = Screen.new(32, 80)
        h.write_text(s, 6, 60, 'PANEL    : ISP@PRIM')
        assert.equals('ispf_primary', detect.detect(s))
    end)

    it('classifies tso_ready by lone READY line', function()
        local s = Screen.new(32, 80)
        h.write_text(s, 0, 1, 'READY')
        assert.equals('tso_ready', detect.detect(s))
    end)

    it('classifies revedit by row 0 EDIT/VIEW/REVEDIT marker', function()
        local s = Screen.new(32, 80)
        h.write_text(s, 0, 0, 'EDIT  USER.DATASET(MEMBER)')
        assert.equals('revedit', detect.detect(s))
    end)

    it('returns unknown for unmatched screens', function()
        local s = Screen.new(32, 80)
        assert.equals('unknown', detect.detect(s))
    end)

    it('does not misclassify ISPF as tso_ready when READY appears in body', function()
        -- Hypothetical: ISPF panel that mentions READY somewhere shouldn't
        -- match tso_ready unless it's a lone-READY line.
        local s = Screen.new(32, 80)
        h.write_text(s, 6, 60, 'PANEL    : ISP@PRIM')
        h.write_text(s, 10, 5, 'READY to proceed')
        assert.equals('ispf_primary', detect.detect(s))
    end)
end)
