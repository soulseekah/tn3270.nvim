local cwd = vim.fn.getcwd()

vim.opt.runtimepath:prepend(cwd)
vim.opt.runtimepath:prepend(cwd .. '/deps/plenary.nvim')

-- Allow `require('tests.helpers')` from spec files
package.path = cwd .. '/?.lua;' .. cwd .. '/?/init.lua;' .. package.path

require('plenary.busted')
