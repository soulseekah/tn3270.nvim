local M = {}

local function rows(screen) return screen:to_lines() end

local detectors = {
    {
        name = 'tso_logon',
        test = function(s)
            local r = rows(s)
            return (r[23] or ''):find('Logon ===>') ~= nil
        end,
    },
    {
        name = 'tso_password',
        test = function(s)
            return ((rows(s)[1] or ''):find('ENTER CURRENT PASSWORD')) ~= nil
        end,
    },
    {
        name = 'ispf_primary',
        test = function(s)
            local r = rows(s)
            return (r[7] or ''):find('PANEL%s+:%s+ISP@PRIM') ~= nil
        end,
    },
    {
        name = 'tso_ready',
        test = function(s)
            for _, line in ipairs(rows(s)) do
                if line:match('^%s*READY%s*$') then return true end
            end
            return false
        end,
    },
    {
        name = 'revedit',
        test = function(s)
            local r0 = rows(s)[1] or ''
            return r0:find('REVEDIT') or r0:find('EDIT ') or r0:find('VIEW ')
        end,
    },
}

function M.detect(screen)
    for _, d in ipairs(detectors) do
        if d.test(screen) then return d.name end
    end
    return 'unknown'
end

return M
