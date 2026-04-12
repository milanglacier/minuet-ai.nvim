local M = {}

function M.setup(config)
    local default_config = require 'minuet.config'

    M.presets = config.presets or {}
    M.presets.original = config

    if config.enabled then
        vim.deprecate('minuet.config.enabled', 'minuet.config.enable_predicates', 'next release', 'minuet', false)
        config.enable_predicates = config.enable_predicates or config.enabled
    end

    config.presets = nil

    -- Migrate deprecated flat LSP keys into nested lsp.completion.*
    if config.lsp then
        local flat_to_nested = {
            enabled_auto_trigger_ft = 'enabled_auto_trigger_ft',
            disabled_auto_trigger_ft = 'disabled_auto_trigger_ft',
            warn_on_blink_or_cmp = 'warn_on_blink_or_cmp',
            adjust_indentation = 'adjust_indentation',
        }
        for flat_key, nested_key in pairs(flat_to_nested) do
            if config.lsp[flat_key] ~= nil then
                config.lsp[flat_key] = nil
                vim.deprecate(
                    'minuet.config.lsp.' .. flat_key,
                    'minuet.config.lsp.completion.' .. nested_key,
                    'next release',
                    'minuet',
                    false
                )
            end
        end
    end

    M.config = vim.tbl_deep_extend('force', default_config, config or {})

    local has_cmp = pcall(require, 'cmp')

    if has_cmp then
        require('cmp').register_source('minuet', require('minuet.cmp'):new())
    end

    require('minuet.duet').setup()
    require('minuet.virtualtext').setup()
    require('minuet.lsp').setup()
    require 'minuet.deprecate'
end

function M.make_cmp_map()
    local cmp = require 'cmp'
    return cmp.mapping(cmp.mapping.complete {
        config = {
            ---@diagnostic disable-next-line: redundant-parameter
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

local function complete_change_model_options()
    local modelcard = require 'minuet.modelcard'
    local choices = {}

    -- Build the list of available models
    for provider, models in pairs(modelcard.models) do
        if provider == 'openai_compatible' or provider == 'openai_fim_compatible' then
            -- Handle subproviders for compatible APIs
            local subprovider = M.config.provider_options[provider]
                and string.lower(M.config.provider_options[provider].name)
            if subprovider and models[subprovider] then
                for _, model in ipairs(models[subprovider]) do
                    table.insert(choices, provider .. ':' .. model)
                end
            end
        elseif type(models) == 'table' then
            -- Handle regular providers
            for _, model in ipairs(models) do
                table.insert(choices, provider .. ':' .. model)
            end
        end
    end

    return choices
end

function M.change_model(provider_model)
    if not M.config then
        vim.notify 'Minuet config is not set up yet, please call the setup function firstly.'
        return
    end

    -- If no provider_model is provided, use vim.ui.select to choose one
    if not provider_model then
        local choices = complete_change_model_options()

        vim.ui.select(choices, {
            prompt = 'Select a model:',
            format_item = function(item)
                return item
            end,
        }, function(choice)
            if choice then
                M.change_model(choice)
            end
        end)
        return
    end

    local provider, model = provider_model:match '([^:]+):(.+)'
    if not provider or not model then
        vim.notify('Invalid format. Use format provider:model (e.g., openai:gpt-4o)', vim.log.levels.ERROR)
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
    M.config.provider_options[provider].model = model
    vim.notify(string.format('Minuet model changed to: %s (%s)', model, provider), vim.log.levels.INFO)
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

function M.change_preset(preset)
    if not M.config then
        vim.notify 'Minuet config is not set up yet, please call the setup function firstly.'
        return
    end

    if not M.presets[preset] then
        vim.notify('The preset is not supported.', vim.log.levels.ERROR)
        return
    end

    local preset_config = M.presets[preset]

    -- deep extend the config with preset_config
    M.config = vim.tbl_deep_extend('force', M.config, preset_config)
    vim.notify('Minuet Preset changed to: ' .. preset, vim.log.levels.INFO)
end

local function minuet_complete(arglead, cmdline, _)
    if not M.config then
        vim.notify 'Minuet config is not set up yet, please call the setup function firstly.'
        return
    end

    local completions = {
        cmp = { enable = true, disable = true, toggle = true },
        blink = { enable = true, disable = true, toggle = true },
        duet = { predict = true, apply = true, dismiss = true },
        virtualtext = { enable = true, disable = true, toggle = true },
        lsp = {
            attach = true,
            detach = true,
            completion = { enable_auto_trigger = true, disable_auto_trigger = true },
            inline_completion = { enable_auto_trigger = true, disable_auto_trigger = true },
        },
        change_model = complete_change_model_options,
        change_provider = function()
            local providers = {}
            for k, _ in pairs(M.config.provider_options) do
                table.insert(providers, k)
            end
            return providers
        end,
        change_preset = function()
            local presets = {}
            for k, _ in pairs(M.presets) do
                table.insert(presets, k)
            end
            return presets
        end,
    }

    cmdline = cmdline or ''
    local parts = vim.split(vim.trim(cmdline), '%s+')

    ---@type table|function
    local node = completions

    -- The current part may be partial, so keep `node` at the parent level
    -- and filter by prefix.
    local n_fully_typed_parts = #parts
    if arglead ~= '' and #parts > 0 then
        n_fully_typed_parts = n_fully_typed_parts - 1
    end

    for i = 2, n_fully_typed_parts do
        local part = parts[i]
        if type(node) ~= 'table' or node[part] == nil then
            return {}
        end
        node = node[part]
    end

    if type(node) == 'function' then
        return vim.tbl_filter(function(item)
            return vim.startswith(item, arglead)
        end, node())
    elseif type(node) == 'table' then
        return vim.tbl_filter(function(item)
            return vim.startswith(item, arglead)
        end, vim.tbl_keys(node))
    end

    return {}
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

    actions.lsp = require('minuet.lsp').actions

    actions.duet = require('minuet.duet').action

    actions.change_provider = setmetatable({}, {
        __index = function(_, key)
            return function()
                M.change_provider(key)
            end
        end,
    })

    local command = fargs[1]

    if command == 'change_model' then
        M.change_model(fargs[2])
    elseif command == 'change_preset' then
        M.change_preset(fargs[2])
    else
        local action_group = actions[command]
        if not action_group then
            vim.notify('Invalid Minuet command: ' .. tostring(command), vim.log.levels.ERROR)
            return
        end

        -- For commands like `lsp`, the action_group may contain nested
        -- sub-groups (e.g. `lsp completion enable_auto_trigger`).
        -- Walk one level deeper when fargs[2] resolves to a table.
        local action_name = fargs[2]
        if type(action_group[action_name]) == 'table' then
            action_group = action_group[action_name]
            action_name = fargs[3]
        end

        local action_fn = action_group[action_name]
        if not action_fn then
            vim.notify('Minuet ' .. command .. ' requires a valid action', vim.log.levels.ERROR)
            return
        end

        action_fn()
    end
end, {
    nargs = '+',
    complete = minuet_complete,
})

return M
