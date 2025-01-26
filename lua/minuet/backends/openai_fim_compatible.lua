local config = require('minuet').config
local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'

local M = {}

M.is_available = function()
    local options = vim.deepcopy(config.provider_options.openai_fim_compatible)
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
        [[The API key has not been provided as an environment variable, or the specified API key environment variable does not exist.
If you are using Ollama, you can simply set it to 'TERM'.]],
        'error',
        vim.log.levels.ERROR
    )
end

function M.get_text_fn(json)
    return json.choices[1].text
end

M.complete = function(context, callback)
    local options = vim.deepcopy(config.provider_options.openai_fim_compatible)
    common.complete_openai_fim_base(options, M.get_text_fn, context, callback)
end

return M
