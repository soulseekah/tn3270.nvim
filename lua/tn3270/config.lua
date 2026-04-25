local M = {}

M.defaults = {
    host     = '127.0.0.1',
    port     = 3270,
    debug    = false,
    log_file = '/tmp/tn3270nvim.log',
    autologin = nil, -- { userid = '...', password = '...' }
}

M.current = vim.deepcopy(M.defaults)

function M.setup(opts)
    M.current = vim.tbl_deep_extend('force', M.current, opts or {})
end

function M.get(opts)
    if not opts then return M.current end
    return vim.tbl_deep_extend('force', M.current, opts)
end

return M
