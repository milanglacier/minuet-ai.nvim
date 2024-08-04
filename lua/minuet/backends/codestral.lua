local config = require('minuet').config
local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'

local M = {}

M.is_available = function()
    local options = config.provider_options.codestral
    if vim.env[options.api_key] == nil or vim.env[options.api_key] == '' then
        return false
    else
        return true
    end
end

if not M.is_available() then
    utils.notify('Codestral API key is not set', 'error', vim.log.levels.ERROR)
end

local function get_text_fn_no_stream(json)
    return json.choices[1].message.content
end

local function get_text_fn_stream(json)
    return json.choices[1].delta.content
end

M.complete = function(context_before_cursor, context_after_cursor, callback)
    local options = vim.deepcopy(config.provider_options.codestral)

    options.name = 'Codestral'

    common.complete_openai_fim_base(
        options,
        options.stream and get_text_fn_stream or get_text_fn_no_stream,
        context_before_cursor,
        context_after_cursor,
        callback
    )
end

return M
