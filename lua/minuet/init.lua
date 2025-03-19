local default_config = require 'minuet.config'

local M = {}

function M.setup(config)
    M.presets = config.presets or {}
    M.presets.orignal = config

    config.presets = nil
    M.config = vim.tbl_deep_extend('force', default_config, config or {})

    local has_cmp = pcall(require, 'cmp')

    if has_cmp then
        require('cmp').register_source('minuet', require('minuet.cmp'):new())
    end

    require('minuet.virtualtext').setup()
    require('minuet.lsp').setup()
    require 'minuet.deprecate'
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

    if fargs[1] == 'change_model' then
        M.change_model(fargs[2])
    elseif fargs[1] == 'change_preset' then
        M.change_preset(fargs[2])
    else
        actions[fargs[1]][fargs[2]]()
    end
end, {
    nargs = '+',
    complete = function(_, cmdline, _)
        if not M.config then
            vim.notify 'Minuet config is not set up yet, please call the setup function firstly.'
            return
        end

        cmdline = cmdline or ''

        if cmdline:find 'change_model' then
            return complete_change_model_options()
        end

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

        if cmdline:find 'change_preset' then
            local presets = {}
            for k, _ in pairs(M.presets) do
                table.insert(presets, k)
            end
            return presets
        end

        return { 'cmp', 'virtualtext', 'blink', 'change_provider', 'change_model', 'change_preset' }
    end,
})

return M
