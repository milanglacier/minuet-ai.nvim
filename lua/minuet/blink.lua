local M = {}
local utils = require 'minuet.utils'

if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = 'BlinkCmpItemKindMinuet' })) then
    vim.api.nvim_set_hl(0, 'BlinkCmpItemKindMinuet', { link = 'BlinkCmpItemKind' })
end

function M.get_trigger_characters()
    return { '@', '.', '(', '[', ':', '{' }
end

function M:enabled()
    local config = require('minuet').config
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
    local config = require('minuet').config

    -- Early return if minuet is not allowed to trigger
    if not utils.should_trigger() then
        callback()
        return
    end

    -- we want to always invoke completion when invoked manually
    if not config.blink.enable_auto_complete and ctx.trigger.kind ~= 'manual' then
        callback()
        return
    end

    local function _complete()
        -- NOTE: blink will accumulate completion items during multiple
        -- callbacks, So for each back we must ensure we only deliver new
        -- arrived completion items to avoid duplicated completion items.
        local delivered_completion_items = {}

        if config.throttle > 0 then
            self.is_in_throttle = true
            vim.defer_fn(function()
                self.is_in_throttle = nil
            end, config.throttle)
        end

        local context = utils.get_context(utils.make_cmp_context(ctx))
        utils.notify('Minuet completion started', 'verbose')

        local provider = require('minuet.backends.' .. config.provider)

        provider.complete(context, function(data)
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

            local new_data = {}

            for _, item in ipairs(data) do
                if not delivered_completion_items[item] then
                    table.insert(new_data, item)
                    delivered_completion_items[item] = true
                end
            end

            local success, max_label_width = pcall(function()
                return require('blink.cmp.config').completion.menu.draw.components.label.width.max
            end)
            if not success then
                max_label_width = 60
            end

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
                    kind_name = config.provider_options[config.provider].name or config.provider,
                    kind_hl = 'BlinkCmpItemKindMinuet',
                    documentation = {
                        kind = 'markdown',
                        value = '```' .. (vim.bo.ft or '') .. '\n' .. result .. '\n```',
                    },
                })
            end
            callback {
                is_incomplete_forward = false,
                is_incomplete_backward = false,
                items = items,
            }
        end)
    end

    if ctx.trigger.kind == 'manual' then
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
