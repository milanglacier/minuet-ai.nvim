local M = {}
local config = require('minuet').config
local provider = require('minuet.backends.' .. config.provider)
local utils = require 'minuet.utils'
local cmp = require 'cmp'
local lsp = require 'cmp.types.lsp'

function M:is_available()
    return provider.is_available()
end

function M.get_trigger_characters()
    return { '@', '.', '(', '{', ' ' }
end

function M.get_keyword_pattern()
    return [[\%(\k\|\.\)\+]]
end

function M:get_debug_name()
    return 'minuet'
end

function M:new()
    return setmetatable({}, { __index = self })
end

function M:complete(ctx, callback)
    if config.throttle > 0 and self.is_in_throttle then
        callback()
        return
    end

    if config.notify then
        vim.notify 'Minuet completion started'
    end

    local context = utils.get_context(ctx.context)

    if config.throttle > 0 then
        self.is_in_throttle = true
        vim.defer_fn(function()
            self.is_in_throttle = nil
        end, config.throttle)
    end

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

return M
