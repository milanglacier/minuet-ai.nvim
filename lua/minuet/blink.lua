local M = {}
local config = require('minuet').config
local utils = require 'minuet.utils'

if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = 'BlinkCmpItemKindMinuet' })) then
    vim.api.nvim_set_hl(0, 'BlinkCmpItemKindMinuet', { link = 'BlinkCmpItemKind' })
end

function M.get_trigger_characters()
    return { '@', '.', '(', '[', ':', '{' }
end

function M:enabled()
    local provider = require('minuet.backends.' .. config.provider)
    return provider.is_available()
end

function M.new()
    local source = setmetatable({}, { __index = M })
    source.is_in_throttle = nil
    source.debounce_timer = nil
    return source
end

function M:get_completions(ctx, callback)
    local function _complete()
        if config.throttle > 0 then
            self.is_in_throttle = true
            vim.defer_fn(function()
                self.is_in_throttle = nil
            end, config.throttle)
        end

        local context = utils.get_context(utils.make_cmp_context(ctx))
        utils.notify('Minuet completion started', 'verbose')

        local provider = require('minuet.backends.' .. config.provider)

        provider.complete(context.lines_before, context.lines_after, function(data)
            if not data then
                callback()
                return
            end

            -- HACK: workaround to address an undesired behavior: When using
            -- completion with the cursor positioned mid-word, the partial word
            -- under the cursor is erased.
            -- Example: Current cursor position:
            -- he|
            -- (| represents the cursor)
            -- If the completion item is "llo" and selected, "he" will be
            -- removed from the buffer. To resolve this, we will determine
            -- whether to prepend the last word to the completion items,
            -- avoiding the overwriting issue.

            data = vim.tbl_map(function(item)
                return utils.prepend_to_complete_word(item, context.lines_before)
            end, data)

            if config.add_single_line_entry then
                data = utils.add_single_line_entry(data)
            end

            data = utils.list_dedup(data)

            local items = {}
            for _, result in ipairs(data) do
                table.insert(items, {
                    label = result,
                    documentation = {
                        kind = 'markdown',
                        value = '```' .. (vim.bo.ft or '') .. '\n' .. result .. '\n```',
                    },
                    -- TODO: use the provider name as kind name like nvim-cmp
                    -- when blink supports non-lsp kind name.
                    kind = vim.lsp.protocol.CompletionItemKind.Text,
                })
            end
            callback {
                is_incomplete_forward = false,
                is_incomplete_backward = false,
                items = items,
            }
        end)
    end

    if config.throttle > 0 and self.is_in_throttle then
        callback()
        return
    end

    if config.debounce > 0 then
        if self.debounce_timer and not self.debounce_timer:is_closing() then
            self.debounce_timer:close()
        end
        self.debounce_timer = vim.defer_fn(_complete, config.debounce)
    else
        _complete()
    end
end

return M
