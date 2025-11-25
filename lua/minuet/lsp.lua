local M = {}

if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = 'LspKindMinuet' })) then
    vim.api.nvim_set_hl(0, 'LspKindMinuet', { link = 'LspKindText' })
end

local utils = require 'minuet.utils'

M.augroup = vim.api.nvim_create_augroup('MinuetLSP', { clear = true })

M.is_in_throttle = nil
M.debounce_timer = nil

function M.get_trigger_characters()
    return { '@', '.', '(', '[', ':', ' ' }
end

function M.get_capabilities()
    return {
        completionProvider = {
            triggerCharacters = M.get_trigger_characters(),
        },
    }
end

function M.generate_request_id()
    return os.time()
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

    local function _complete()
        -- NOTE: builtin completion will accumulate completion items during
        -- multiple callbacks, So for each back we must ensure we only deliver
        -- new arrived completion items to avoid duplicated completion items.
        local delivered_completion_items = {}

        if config.throttle > 0 then
            M.is_in_throttle = true
            vim.defer_fn(function()
                M.is_in_throttle = nil
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
                if config.lsp.adjust_indentation then
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

    if config.throttle > 0 and M.is_in_throttle then
        vim.schedule(function()
            callback(nil, { isIncomplete = false, items = {} })
            if notify_callback then
                notify_callback(id)
            end
        end)
        return true, id
    end

    if config.debounce > 0 then
        if M.debounce_timer and not M.debounce_timer:is_closing() then
            M.debounce_timer:stop()
            M.debounce_timer:close()
        end
        M.debounce_timer = vim.defer_fn(_complete, config.debounce)
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
            local auto_trigger_ft = config.lsp.enabled_auto_trigger_ft
            local disable_trigger_ft = config.lsp.disabled_auto_trigger_ft
            local ft = vim.bo[bufnr].filetype

            utils.notify('Minuet LSP attached to current buffer', 'verbose', vim.log.levels.INFO)

            if vim.b[bufnr].minuet_lsp_enable_auto_trigger then
                vim.lsp.completion.enable(true, client.id, bufnr, { autotrigger = true })
                utils.notify('Minuet LSP is enabled for auto triggering', 'verbose', vim.log.levels.INFO)
            elseif
                (vim.tbl_contains(auto_trigger_ft, ft) or vim.tbl_contains(auto_trigger_ft, '*'))
                and not vim.tbl_contains(disable_trigger_ft, ft)
            then
                vim.lsp.completion.enable(true, client.id, bufnr, { autotrigger = true })
                utils.notify('Minuet LSP is enabled for auto triggering', 'verbose', vim.log.levels.INFO)
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

    if (has_cmp or has_blink) and (#config.lsp.enabled_ft > 0) and config.lsp.warn_on_blink_or_cmp then
        vim.notify(
            'Blink or Nvim-cmp detected, it is recommended to use the native source instead of lsp',
            vim.log.levels.WARN
        )
    end

    vim.api.nvim_clear_autocmds { group = M.augroup }

    if #config.lsp.enabled_ft > 0 then
        vim.api.nvim_create_autocmd('FileType', {
            pattern = config.lsp.enabled_ft,
            callback = function(args)
                -- Early return if minuet is not allowed to trigger
                if not utils.should_trigger() then
                    return
                end

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

M.actions.enable_auto_trigger = function()
    local bufnr = vim.api.nvim_get_current_buf()
    local lsps = vim.lsp.get_clients { name = 'minuet', bufnr = bufnr }

    if #lsps == 0 then
        vim.b[bufnr].minuet_lsp_enable_auto_trigger = true
        M.actions.attach()
        return
    end

    for _, client in ipairs(lsps) do
        vim.lsp.completion.enable(true, client.id, bufnr, { autotrigger = true })
    end

    utils.notify('Minuet LSP is enabled for auto triggering', 'verbose', vim.log.levels.INFO)
end

M.actions.disable_auto_trigger = function()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.b[bufnr].minuet_lsp_enable_auto_trigger = nil
    local lsps = vim.lsp.get_clients { name = 'minuet', bufnr = bufnr }

    if #lsps == 0 then
        return
    end

    for _, client in ipairs(lsps) do
        vim.lsp.completion.enable(false, client.id, bufnr)
        utils.notify('Minuet LSP is disabled for auto triggering', 'verbose', vim.log.levels.INFO)
    end
end

return M
