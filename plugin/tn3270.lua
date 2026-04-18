vim.api.nvim_create_user_command('TN3270', function()
    require('tn3270').connect()
end, {})
