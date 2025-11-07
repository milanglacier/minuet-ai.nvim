local M = {}
local utils = require 'minuet.utils'
local cmp = require 'cmp'
local lsp = require 'cmp.types.lsp'

if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = 'CmpItemKindMinuet' })) then
    vim.api.nvim_set_hl(0, 'CmpItemKindMinuet', { link = 'CmpItemKind' })
end

function M:is_available()
    local config = require('minuet').config
    local provider = require('minuet.backends.' .. config.provider)
    return provider.is_available()
end

function M.get_trigger_characters()
    return { '@', '.', '(', '[', ':', ' ' }
end

function M.get_keyword_pattern()
    -- NOTE: Don't trigger the completion by any keywords (use a pattern that
    -- is not likely to be triggered.). only trigger on the given characters.
    -- This is because candidates returned by LLMs are easily filtered out by
    -- cmp due to that LLM oftern returns candidates contains the full content
    -- in current line before the cursor.
    return '^$'
end

function M:get_debug_name()
    return 'minuet'
end

function M:new()
    local source = setmetatable({}, { __index = self })
    source.is_in_throttle = nil
    source.debounce_timer = nil
    return source
end

function M:complete(ctx, callback)
    local config = require('minuet').config

    -- Early return if minuet is not allowed to trigger
    if not utils.should_trigger() then
        callback()
        return
    end

    -- we want to always invoke completion when invoked manually
    if not config.cmp.enable_auto_complete and ctx.context.option.reason ~= 'manual' then
        callback()
        return
    end

    local function _complete()
        if config.throttle > 0 then
            self.is_in_throttle = true
            vim.defer_fn(function()
                self.is_in_throttle = nil
            end, config.throttle)
        end

        -- Ensure the context has the buffer number
        local cmp_context = ctx.context
        if not cmp_context.bufnr then
            cmp_context.bufnr = bufnr
        end
        local context = utils.get_context(cmp_context)
        utils.notify('Minuet completion started', 'verbose')

        local provider = require('minuet.backends.' .. config.provider)

        provider.complete(context, function(data)
            if not data then
                callback()
                return
            end

            if config.add_single_line_entry then
                data = utils.add_single_line_entry(data)
            end

            data = utils.list_dedup(data)

            local items = {}
            for _, result in ipairs(data) do
                table.insert(items, {
                    label = result,
                    documentation = {
                        kind = cmp.lsp.MarkupKind.Markdown,
                        value = '```' .. (vim.bo.ft or '') .. '\n' .. result .. '\n```',
                    },
                    insertTextMode = lsp.InsertTextMode.AdjustIndentation,
                    cmp = {
                        kind_hl_group = 'CmpItemKindMinuet',
                        kind_text = config.provider_options[config.provider].name or config.provider,
                    },
                })
            end
            callback {
                items = items,
            }
        end)
    end

    -- manual mode always complete immediately without debounce or throttle
    if ctx.context.option.reason == 'manual' then
        _complete()
        return
    end

    if config.throttle > 0 and self.is_in_throttle then
        callback()
        return
    end

    if config.debounce > 0 then
        if self.debounce_timer and not self.debounce_timer:is_closing() then
            self.debounce_timer:stop()
            self.debounce_timer:close()
        end
        self.debounce_timer = vim.defer_fn(_complete, config.debounce)
    else
        _complete()
    end
end

return M
