local M = {}
local config = require('minuet').config
local utils = require 'minuet.utils'
local cmp = require 'cmp'
local lsp = require 'cmp.types.lsp'

function M:is_available()
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
    -- we want to always invoke completion when invoked manually
    if not config.enabled and ctx.context.option.reason ~= 'manual' then
        callback()
        return
    end

    if config.throttle > 0 and self.is_in_throttle then
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

        local context = utils.get_context(ctx.context)
        utils.notify('Minuet completion started', 'verbose')

        local provider = require('minuet.backends.' .. config.provider)

        provider.complete(context.lines_before, context.lines_after, function(data)
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
                result = result:gsub('^%s*', '')
                table.insert(items, {
                    label = result,
                    documentation = {
                        kind = cmp.lsp.MarkupKind.Markdown,
                        value = '```' .. (vim.bo.ft or '') .. '\n' .. result .. '\n```',
                    },
                    insertTextMode = lsp.InsertTextMode.AdjustIndentation,
                })
            end
            callback {
                items = items,
            }
        end)
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
