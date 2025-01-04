local M = {}
local api = vim.api
local minuet = require 'minuet'

if minuet.config and minuet.config.enabled ~= nil then
    vim.deprecate(
        'minuet.config.enabled',
        'minuet.config.cmp.enable_auto_complete',
        'next release',
        'minuet-ai.nvim',
        false
    )
end

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

function M.notify_breaking_change_only_once(message, filename, date)
    ---@diagnostic disable-next-line
    local file = vim.fs.joinpath(vim.fn.stdpath 'cache', 'minuet-' .. filename .. '-' .. date)

    if vim.fn.filereadable(file) == 1 then
        return
    end

    vim.notify(
        'Please confirm that you have fully read the documentation (yes/no).'
            .. '\nThis notification will only appear once after you choose "yes".\n'
            .. message
            .. ' as of '
            .. date,
        vim.log.levels.WARN
    )

    vim.defer_fn(function()
        vim.ui.select({
            1,
            2,
        }, {
            prompt = message,
            format_item = function(item)
                local format = {
                    'Yes, I have understand what is happening here.\nNotification will not be sent again.',
                    'No, Please send the notification again after relaunch.',
                }
                return format[item]
            end,
        }, function(choice)
            if choice == 1 then
                local f = io.open(file, 'w')
                if not f then
                    vim.notify('Cannot open temporary message file: ' .. file, vim.log.levels.ERROR)
                    return
                end
                f:close()
            end
        end)
    end, 500)
end

return M
