local M = {}

if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = 'LspKindMinuet' })) then
    vim.api.nvim_set_hl(0, 'LspKindMinuet', { link = 'LspKindText' })
end

local utils = require 'minuet.utils'

M.augroup = vim.api.nvim_create_augroup('MinuetLSP', { clear = true })

-- Per-feature, per-buffer runtime state so completion and inline completion
-- never share timers or throttle flags.
M.state = {
    completion = {},
    inline_completion = {},
}

local function get_state(feature)
    return M.state[feature]
end

function M.get_trigger_characters()
    return { '@', '.', '(', '[', ':', ' ' }
end

function M.get_capabilities()
    local config = require('minuet').config
    local caps = {}

    if config.lsp.completion.enable then
        caps.completionProvider = {
            triggerCharacters = M.get_trigger_characters(),
        }
    end

    if config.lsp.inline_completion.enable then
        caps.inlineCompletionProvider = true
    end

    return caps
end

function M.generate_request_id()
    return os.time()
end

local auto_trigger_buf_var = {
    completion = 'minuet_lsp_completion_auto_trigger',
    inline_completion = 'minuet_lsp_inline_completion_auto_trigger',
}

local function should_auto_trigger(feature, bufnr, ft)
    local override = vim.b[bufnr][auto_trigger_buf_var[feature]]
    if override ~= nil then
        return override
    end

    local feature_config = require('minuet').config.lsp[feature]
    local enabled_ft = feature_config.enabled_auto_trigger_ft
    local disabled_ft = feature_config.disabled_auto_trigger_ft

    return (vim.tbl_contains(enabled_ft, ft) or vim.tbl_contains(enabled_ft, '*'))
        and not vim.tbl_contains(disabled_ft, ft)
end

local function set_auto_trigger(feature, bufnr, value)
    vim.b[bufnr][auto_trigger_buf_var[feature]] = value
end

M.request_handler = {}

M.request_handler.initialize = function(_, _, callback, _)
    local id = M.generate_request_id()
    vim.schedule(function()
        callback(nil, { capabilities = M.get_capabilities() })
    end)
    return true, id
end

-- We want to trigger the notification callback to explicitly mark the
-- operation as complete. This ensures the "complete" event is dispatched and
-- associated completion requests are no longer considered pending.
M.request_handler['textDocument/completion'] = function(_, params, callback, notify_callback)
    local id = M.generate_request_id()
    local config = require('minuet').config

    if not config.lsp.completion.enable then
        vim.schedule(function()
            callback(nil, { isIncomplete = false, items = {} })
            if notify_callback then
                notify_callback(id)
            end
        end)
        return true, id
    end

    local st = get_state 'completion'

    local function _complete()
        -- NOTE: Since the enable predicates are evaluated at runtime, this
        -- condition must be checked within the deferred function body, right
        -- before sending the request.
        if not utils.run_hooks_until_failure(config.enable_predicates) then
            callback(nil, { isIncomplete = false, items = {} })
            return
        end

        -- NOTE: builtin completion will accumulate completion items during
        -- multiple callbacks, So for each back we must ensure we only deliver
        -- new arrived completion items to avoid duplicated completion items.
        local delivered_completion_items = {}

        if config.throttle > 0 then
            st.is_in_throttle = true
            vim.defer_fn(function()
                st.is_in_throttle = nil
            end, config.throttle)
        end
        local ctx = utils.make_cmp_context_from_lsp_params(params)

        local context = utils.get_context(ctx)
        utils.notify('Minuet completion started', 'verbose')

        local provider = require('minuet.backends.' .. config.provider)

        provider.complete(context, function(data)
            if not data then
                callback(nil, { isIncomplete = false, items = {} })
                return
            end

            -- The `blink.lua` comments explain the rationale for invoking
            -- `prepend_to_complete_word`.
            data = vim.tbl_map(function(item)
                if config.lsp.completion.adjust_indentation then
                    -- FIXME: Refer to [neovim/neovim#32972] for the rationale behind this
                    -- operation.
                    item = utils.adjust_indentation(item, ctx.cursor_before_line, '-')
                end
                item = utils.prepend_to_complete_word(item, context.lines_before)
                return item
            end, data)

            if config.add_single_line_entry then
                data = utils.add_single_line_entry(data)
            end

            data = utils.list_dedup(data)

            local new_data = {}

            for _, item in ipairs(data) do
                if not delivered_completion_items[item] then
                    table.insert(new_data, item)
                    delivered_completion_items[item] = true
                end
            end

            local max_label_width = 80

            local multi_lines_indicators = ' ⏎'

            local items = {}
            for _, result in ipairs(new_data) do
                local item_lines = vim.split(result, '\n')
                local item_label

                if #item_lines == 1 then
                    item_label = result
                else
                    item_label = vim.fn.strcharpart(item_lines[1], 0, max_label_width - #multi_lines_indicators)
                        .. multi_lines_indicators
                end

                table.insert(items, {
                    label = item_label,
                    insertText = result,
                    -- insert, don't adjust indentation
                    insertTextMode = 1,
                    documentation = {
                        kind = 'markdown',
                        value = '```' .. (vim.bo.ft or '') .. '\n' .. result .. '\n```',
                    },
                    kind = vim.lsp.protocol.CompletionItemKind.Text,
                    detail = config.provider_options[config.provider].name or config.provider,
                    -- for nvim-cmp
                    cmp = {
                        kind_text = config.provider_options[config.provider].name or config.provider,
                        kind_hl = 'LspKindMinuet',
                    },
                    -- for blink-cmp
                    kind_name = config.provider_options[config.provider].name or config.provider,
                    kind_hl_group = 'LspKindMinuet',
                })
            end

            callback(nil, {
                isIncomplete = false,
                items = items,
            })

            if notify_callback then
                notify_callback(id)
            end
        end)
    end

    if config.throttle > 0 and st.is_in_throttle then
        vim.schedule(function()
            callback(nil, { isIncomplete = false, items = {} })
            if notify_callback then
                notify_callback(id)
            end
        end)
        return true, id
    end

    if config.debounce > 0 then
        if st.debounce_timer and not st.debounce_timer:is_closing() then
            st.debounce_timer:stop()
            st.debounce_timer:close()
        end
        st.debounce_timer = vim.defer_fn(_complete, config.debounce)
    else
        _complete()
    end

    return true, id
end

M.request_handler['textDocument/inlineCompletion'] = function(_, params, callback, notify_callback)
    local id = M.generate_request_id()
    local config = require('minuet').config

    if not config.lsp.inline_completion.enable then
        vim.schedule(function()
            callback(nil, { items = {} })
            if notify_callback then
                notify_callback(id)
            end
        end)
        return true, id
    end

    local st = get_state 'inline_completion'

    local function _complete()
        if not utils.run_hooks_until_failure(config.enable_predicates) then
            callback(nil, { items = {} })
            return
        end

        if config.throttle > 0 then
            st.is_in_throttle = true
            vim.defer_fn(function()
                st.is_in_throttle = nil
            end, config.throttle)
        end

        local ctx = utils.make_cmp_context_from_lsp_params(params)
        local context = utils.get_context(ctx)
        utils.notify('Minuet inline completion started', 'verbose')

        local provider = require('minuet.backends.' .. config.provider)

        provider.complete(context, function(data)
            if not data then
                callback(nil, { items = {} })
                return
            end

            data = utils.list_dedup(data)

            local items = {}
            for _, result in ipairs(data) do
                table.insert(items, {
                    insertText = result,
                })
            end

            callback(nil, { items = items })

            if notify_callback then
                notify_callback(id)
            end
        end)
    end

    if config.throttle > 0 and st.is_in_throttle then
        vim.schedule(function()
            callback(nil, { items = {} })
            if notify_callback then
                notify_callback(id)
            end
        end)
        return true, id
    end

    if config.debounce > 0 then
        if st.debounce_timer and not st.debounce_timer:is_closing() then
            st.debounce_timer:stop()
            st.debounce_timer:close()
        end
        st.debounce_timer = vim.defer_fn(_complete, config.debounce)
    else
        _complete()
    end

    return true, id
end

M.request_handler.shutdown = function(_, _, callback, _)
    local id = M.generate_request_id()
    vim.schedule(function()
        callback(nil, nil)
    end)
    return true, id
end

---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
function M.server(dispatchers)
    local closing = false
    return {
        request = function(method, params, callback, notify_callback)
            if M.request_handler[method] then
                local ok, id = M.request_handler[method](method, params, callback, notify_callback)
                return ok, id
            else
                return false, nil
            end
        end,
        notify = function(method, _)
            if method == 'exit' then
                -- code 0 (success), signal 15 (SIGTERM)
                dispatchers.on_exit(0, 15)
            end
            return true
        end,
        is_closing = function()
            return closing
        end,
        terminate = function()
            closing = true
        end,
    }
end

function M.start_server(args)
    if vim.fn.has 'nvim-0.11' == 0 then
        vim.notify('minuet LSP requires nvim-0.11+', vim.log.levels.WARN)
        return
    end

    ---@type vim.lsp.ClientConfig
    local config = {
        name = 'minuet',
        cmd = M.server,
        on_attach = function(client, bufnr)
            local config = require('minuet').config
            local ft = vim.bo[bufnr].filetype

            utils.notify('Minuet LSP attached to current buffer', 'verbose', vim.log.levels.INFO)

            -- Built-in completion auto-trigger
            if config.lsp.completion.enable then
                if should_auto_trigger('completion', bufnr, ft) then
                    vim.lsp.completion.enable(true, client.id, bufnr, { autotrigger = true })
                    utils.notify('Minuet LSP completion is enabled for auto triggering', 'verbose', vim.log.levels.INFO)
                end
            end

            -- Inline completion auto-enable
            if config.lsp.inline_completion.enable and vim.lsp.inline_completion then
                if should_auto_trigger('inline_completion', bufnr, ft) then
                    vim.lsp.inline_completion.enable(true, { bufnr = bufnr })
                    utils.notify(
                        'Minuet LSP inline completion is enabled for auto triggering',
                        'verbose',
                        vim.log.levels.INFO
                    )
                end
            end
        end,
    }
    ---@type vim.lsp.start.Opts
    local opts = {
        bufnr = args.buf,
        reuse_client = function(lsp_client, lsp_config)
            return lsp_client.name == lsp_config.name
        end,
    }
    vim.lsp.start(config, opts)
end

function M.setup()
    local config = require('minuet').config

    local has_cmp = pcall(require, 'cmp')
    local has_blink = pcall(require, 'blink-cmp')

    if
        config.lsp.completion.enable
        and (has_cmp or has_blink)
        and (#config.lsp.enabled_ft > 0)
        and config.lsp.completion.warn_on_blink_or_cmp
    then
        vim.notify(
            'Blink or Nvim-cmp detected, it is recommended to use the native source instead of lsp',
            vim.log.levels.WARN
        )
    end

    if
        config.lsp.inline_completion.enable
        and config.lsp.inline_completion.warn_on_virtualtext
        and #config.virtualtext.auto_trigger_ft > 0
    then
        vim.notify(
            'Minuet LSP inline completion and Minuet virtual text should not be used together. '
                .. 'Disable one of them, or set lsp.inline_completion.warn_on_virtualtext = false to suppress this warning.',
            vim.log.levels.WARN
        )
    end

    if config.lsp.inline_completion.enable and not vim.lsp.inline_completion then
        vim.notify('Minuet LSP inline completion requires nvim.lsp.inline_completion', vim.log.levels.WARN)
    end

    vim.api.nvim_clear_autocmds { group = M.augroup }

    if #config.lsp.enabled_ft > 0 then
        vim.api.nvim_create_autocmd('FileType', {
            pattern = config.lsp.enabled_ft,
            callback = function(args)
                if vim.tbl_contains(config.lsp.disabled_ft, vim.b[args.buf].ft) then
                    return
                end

                M.start_server(args)
            end,
            desc = 'Starts the minuet LSP server',
            group = M.augroup,
        })
    end
end

M.actions = {}

M.actions.attach = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local lsps = vim.lsp.get_clients { name = 'minuet', bufnr = bufnr }

    if #lsps and #lsps > 0 then
        utils.notify('Minuet LSP already attached to current buffer', 'verbose', vim.log.levels.INFO)
        return
    end

    M.start_server { buf = bufnr }
end

M.actions.detach = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local lsps = vim.lsp.get_clients { name = 'minuet', bufnr = bufnr }

    if #lsps == 0 then
        utils.notify('Minuet LSP not attached to current buffer', 'verbose', vim.log.levels.INFO)
        return
    end

    for _, client in ipairs(lsps) do
        vim.lsp.buf_detach_client(bufnr, client.id)
    end

    utils.notify('Minuet LSP detached from current buffer', 'verbose', vim.log.levels.INFO)
end

M.actions.completion = {}
M.actions.inline_completion = {}

M.actions.enable_auto_trigger = function()
    vim.deprecate(
        ':Minuet lsp enable_auto_trigger',
        ':Minuet lsp completion enable_auto_trigger',
        'next release',
        'minuet',
        false
    )
end

M.actions.disable_auto_trigger = function()
    vim.deprecate(
        ':Minuet lsp disable_auto_trigger',
        ':Minuet lsp completion disable_auto_trigger',
        'next release',
        'minuet',
        false
    )
end

M.actions.completion.enable_auto_trigger = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local lsps = vim.lsp.get_clients { name = 'minuet', bufnr = bufnr }
    set_auto_trigger('completion', bufnr, true)

    if #lsps == 0 then
        M.actions.attach()
        return
    end

    for _, client in ipairs(lsps) do
        vim.lsp.completion.enable(true, client.id, bufnr, { autotrigger = true })
    end

    utils.notify('Minuet LSP completion is enabled for auto triggering', 'verbose', vim.log.levels.INFO)
end

M.actions.completion.disable_auto_trigger = function()
    local bufnr = vim.api.nvim_get_current_buf()
    set_auto_trigger('completion', bufnr, false)
    local lsps = vim.lsp.get_clients { name = 'minuet', bufnr = bufnr }

    if #lsps == 0 then
        return
    end

    for _, client in ipairs(lsps) do
        vim.lsp.completion.enable(false, client.id, bufnr)
    end

    utils.notify('Minuet LSP completion is disabled for auto triggering', 'verbose', vim.log.levels.INFO)
end

M.actions.inline_completion.enable_auto_trigger = function()
    if not vim.lsp.inline_completion then
        vim.notify('Minuet LSP inline completion requires nvim.lsp.inline_completion', vim.log.levels.WARN)
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local lsps = vim.lsp.get_clients { name = 'minuet', bufnr = bufnr }
    set_auto_trigger('inline_completion', bufnr, true)

    if #lsps == 0 then
        M.actions.attach()
        return
    end

    vim.lsp.inline_completion.enable(true, { bufnr = bufnr })
    utils.notify('Minuet LSP inline completion is enabled for auto triggering', 'verbose', vim.log.levels.INFO)
end

M.actions.inline_completion.disable_auto_trigger = function()
    if not vim.lsp.inline_completion then
        vim.notify('Minuet LSP inline completion requires nvim.lsp.inline_completion', vim.log.levels.WARN)
        return
    end

    local bufnr = vim.api.nvim_get_current_buf()
    set_auto_trigger('inline_completion', bufnr, false)
    local lsps = vim.lsp.get_clients { name = 'minuet', bufnr = bufnr }

    if #lsps == 0 then
        return
    end

    vim.lsp.inline_completion.enable(false, { bufnr = bufnr })
    utils.notify('Minuet LSP inline completion is disabled for auto triggering', 'verbose', vim.log.levels.INFO)
end

return M
