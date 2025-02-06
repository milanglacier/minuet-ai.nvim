local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'

local M = {}

M.is_available = function()
    local config = require('minuet').config
    return utils.get_api_key(config.provider_options.codestral.api_key) and true or false
end

if not M.is_available() then
    utils.notify('Codestral API key is not set', 'error', vim.log.levels.ERROR)
end

function M.get_text_fn_no_stream(json)
    return json.choices[1].message.content
end

function M.get_text_fn_stream(json)
    return json.choices[1].delta.content
end

M.complete = function(context, callback)
    local config = require('minuet').config

    local options = vim.deepcopy(config.provider_options.codestral)

    options.name = 'Codestral'

    common.complete_openai_fim_base(
        options,
        options.stream and M.get_text_fn_stream or M.get_text_fn_no_stream,
        context,
        callback
    )
end

return M
