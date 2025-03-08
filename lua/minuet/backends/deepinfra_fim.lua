local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'

local M = {}

M.is_available = function()
    local config = require('minuet').config
    local options = config.provider_options.deepinfra_fim
    if options.model == '' or options.api_key == '' or options.name == '' then
        return false
    end
    return utils.get_api_key(options.api_key) and true or false
end

if not M.is_available() then
    utils.notify('DeepInfra FIM API key, model or name is not set', 'error', vim.log.levels.ERROR)
end

function M.get_text_fn_no_stream(json)
    return json.results[1].generated_text
end

function M.get_text_fn_stream(json)
    return json.token.text
end

M.complete = function(context, callback)
    local config = require('minuet').config
    local options = vim.deepcopy(config.provider_options.deepinfra_fim)

    common.complete_deepinfra_fim_base(
        options,
        options.stream and M.get_text_fn_stream or M.get_text_fn_no_stream,
        context,
        callback
    )
end

return M
