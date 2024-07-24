local config = require('minuet').config
local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'

local M = {}

M.is_available = function()
    local options = vim.deepcopy(config.provider_options.openai_compatible)
    if options.end_point == '' or options.api_key == '' or options.name == '' then
        return false
    end

    if vim.env[options.api_key] == nil or vim.env[options.api_key] == '' then
        return false
    else
        return true
    end
end

if not M.is_available() then
    utils.notify(
        'The provider specified as OpenAI compatible is not properly configured.',
        'error',
        vim.log.levels.ERROR
    )
end

M.complete = function(context_before_cursor, context_after_cursor, callback)
    local options = vim.deepcopy(config.provider_options.openai_compatible)
    common.complete_openai_base(options, context_before_cursor, context_after_cursor, callback)
end

return M
