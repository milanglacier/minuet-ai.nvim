local default_config = require 'minuet.config'

local M = {}

function M.setup(config)
    M.config = vim.tbl_deep_extend('force', default_config, config or {})

    if M.config.notify == true then
        vim.notify(
            'Minuet config.notify specs has been updated. Please change true to one of false, "error" or "verbose".',
            vim.log.levels.WARN
        )
        M.config.notify = 'verbose'
    end

    M.notify_breaking_change_only_once(
        'Minuet has reversed the context order for prompt',
        'prompt-context-order-reversed',
        '2024-08-08'
    )

    require('cmp').register_source('minuet', require('minuet.source'):new())
end

function M.make_cmp_map()
    local cmp = require 'cmp'
    return cmp.mapping(cmp.mapping.complete {
        config = {
            sources = cmp.config.sources {
                { name = 'minuet' },
            },
        },
    })
end

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

function M.change_provider(provider)
    if not M.config then
        vim.notify 'Minuet config is not set up yet, please call the setup function firstly.'
        return
    end

    if not M.config.provider_options[provider] then
        vim.notify(
            'The provider is not supported, please refer to minuet.nvim document for more information.',
            vim.log.levels.ERROR
        )
        return
    end

    M.config.provider = provider
    vim.notify('Minuet Provider changed to: ' .. provider, vim.log.levels.INFO)
end

vim.api.nvim_create_user_command('MinuetChangeProvider', function(args)
    M.change_provider(args.args)
end, {
    nargs = 1,
    complete = function()
        local providers = {}
        for k, _ in pairs(M.config.provider_options) do
            table.insert(providers, k)
        end
        return providers
    end,
    desc = 'Change the provider of Minuet.',
})

vim.api.nvim_create_user_command('MinuetToggle', function()
    if not M.config then
        vim.notify 'Minuet config is not set up yet, please call the setup function firstly.'
        return
    end

    M.config.enabled = not M.config.enabled

    vim.notify('Auto completion for minuet is ' .. (M.config.enabled and 'enabled' or 'disabled'), vim.log.levels.INFO)
end, {
    desc = 'Toggle Minuet Auto Completion',
})

return M
