local default_config = require 'minuet.config'

local M = {}

function M.setup(config)
    if config.enabled ~= nil then
        vim.deprecate('enabled', 'cmp.enable_auto_complete', 'next release', 'minuet-ai.nvim', false)
    end
    M.config = vim.tbl_deep_extend('force', default_config, config or {})

    local has_cmp = pcall(require, 'cmp')

    if has_cmp then
        require('cmp').register_source('minuet', require('minuet.cmp'):new())
    end

    require('minuet.virtualtext').setup()
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

function M.make_blink_map()
    return {
        function(cmp)
            cmp.show { providers = { 'minuet' } }
        end,
    }
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

vim.api.nvim_create_user_command('MinuetChangeProvider', function(_)
    vim.deprecate('MinuetChangeProvider', '`Minuet change_provider`', 'next release', 'minuet-ai.nvim', false)
end, {
    nargs = 1,
    complete = function()
        vim.deprecate('MinuetChangeProvider', '`Minuet change_provider`', 'next release', 'minuet-ai.nvim', false)
    end,
    desc = 'Change the provider of Minuet.',
})

vim.api.nvim_create_user_command('MinuetToggle', function()
    vim.deprecate('MinuetToggle', '`Minuet cmp toggle`', 'next release', 'minuet-ai.nvim', false)
end, {})

for cmd_name, complete_frontend in pairs { Blink = 'blink', Cmp = 'cmp' } do
    vim.api.nvim_create_user_command('MinuetToggle' .. cmd_name, function()
        vim.deprecate(
            'MinuetToggle' .. cmd_name,
            '`Minuet ' .. complete_frontend .. ' toggle`',
            'next release',
            'minuet-ai.nvim',
            false
        )
    end, {
        desc = 'Toggle Minuet Auto Completion',
    })
end

vim.api.nvim_create_user_command('Minuet', function(args)
    if not M.config then
        vim.notify 'Minuet config is not set up yet, please call the setup function firstly.'
        return
    end

    local fargs = args.fargs

    local actions = {}

    for _, complete_frontend in ipairs { 'blink', 'cmp' } do
        actions[complete_frontend] = {
            enable = function()
                M.config[complete_frontend].enable_auto_complete = true
                vim.notify('Minuet ' .. complete_frontend .. ' enabled', vim.log.levels.INFO)
            end,
            disable = function()
                M.config[complete_frontend].enable_auto_complete = false
                vim.notify('Minuet ' .. complete_frontend .. ' disabled', vim.log.levels.INFO)
            end,
            toggle = function()
                M.config[complete_frontend].enable_auto_complete = not M.config[complete_frontend].enable_auto_complete
                vim.notify('Minuet ' .. complete_frontend .. ' toggled', vim.log.levels.INFO)
            end,
        }
    end

    actions.virtualtext = {
        enable = require('minuet.virtualtext').action.enable_auto_trigger,
        disable = require('minuet.virtualtext').action.disable_auto_trigger,
        toggle = require('minuet.virtualtext').action.toggle_auto_trigger,
    }

    actions.change_provider = setmetatable({}, {
        __index = function(_, key)
            return function()
                M.change_provider(key)
            end
        end,
    })

    actions[fargs[1]][fargs[2]]()
end, {
    nargs = '+',
    complete = function(_, cmdline, _)
        cmdline = cmdline or ''

        if cmdline:find 'cmp' or cmdline:find 'blink' or cmdline:find 'virtualtext' then
            return {
                'enable',
                'disable',
                'toggle',
            }
        end

        if cmdline:find 'change_provider' then
            if not M.config then
                return
            end
            local providers = {}
            for k, _ in pairs(M.config.provider_options) do
                table.insert(providers, k)
            end
            return providers
        end

        return { 'cmp', 'virtualtext', 'blink', 'change_provider' }
    end,
})

return M
