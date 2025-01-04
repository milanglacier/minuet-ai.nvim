local api = vim.api

api.nvim_create_user_command('MinuetToggleVirtualText', function()
    vim.deprecate('MinuetToggleVirtualText', '`Minuet virtualtext toggle`', 'next release', 'minuet-ai.nvim', false)
    vim.cmd 'Minuet virtualtext toggle'
end, {})

for cmd_name, complete_frontend in pairs { Blink = 'blink', Cmp = 'cmp' } do
    api.nvim_create_user_command('MinuetToggle' .. cmd_name, function()
        vim.deprecate(
            'MinuetToggle' .. cmd_name,
            '`Minuet ' .. complete_frontend .. ' toggle`',
            'next release',
            'minuet-ai.nvim',
            false
        )

        vim.cmd('Minuet ' .. complete_frontend .. ' toggle')
    end, {})
end

api.nvim_create_user_command('MinuetToggle', function()
    vim.deprecate('MinuetToggle', '`Minuet cmp toggle`', 'next release', 'minuet-ai.nvim', false)
    vim.cmd 'Minuet cmp toggle'
end, {})

api.nvim_create_user_command('MinuetChangeProvider', function(args)
    vim.deprecate('MinuetChangeProvider', '`Minuet change_provider`', 'next release', 'minuet-ai.nvim', false)
    vim.cmd('Minuet change_provider ' .. args.args)
end, {
    nargs = 1,
    complete = function()
        vim.deprecate('MinuetChangeProvider', '`Minuet change_provider`', 'next release', 'minuet-ai.nvim', false)
    end,
    desc = 'Change the provider of Minuet.',
})
