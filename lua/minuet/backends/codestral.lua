local config = require('minuet').config
local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'

local M = {}

M.is_available = function()
    if vim.env.CODESTRAL_API_KEY == nil or vim.env.CODESTRAL_API_KEY == '' then
        return false
    else
        return true
    end
end

if not M.is_available() then
    utils.notify('Codestral API key is not set', 'error', vim.log.levels.ERROR)
end

local function get_text_fn(json)
    return json.choices[1].message.content
end

M.complete = function(context_before_cursor, context_after_cursor, callback)
    local options = vim.deepcopy(config.provider_options.codestral)

    options.name = 'Codestral'
    options.end_point = 'https://codestral.mistral.ai/v1/fim/completions'
    options.api_key = 'CODESTRAL_API_KEY'

    common.complete_openai_fim_base(options, get_text_fn, context_before_cursor, context_after_cursor, callback)
end

return M
