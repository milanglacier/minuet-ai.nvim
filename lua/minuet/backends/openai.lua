local config = require('minuet').config
local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'

local M = {}

M.is_available = function()
    if vim.env.OPENAI_API_KEY == nil or vim.env.OPENAI_API_KEY == '' then
        return false
    else
        return true
    end
end

if not M.is_available() then
    utils.notify('OpenAI API key is not set', 'error', vim.log.levels.ERROR)
end

M.complete = function(context, callback)
    local options = vim.deepcopy(config.provider_options.openai)
    options.name = 'OpenAI'
    options.end_point = 'https://api.openai.com/v1/chat/completions'
    options.api_key = 'OPENAI_API_KEY'

    common.complete_openai_base(options, context, callback)
end

return M
