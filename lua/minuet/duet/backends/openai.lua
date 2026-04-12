local base = require 'minuet.duet.backends.openai_base'
local utils = require 'minuet.duet.utils'

local M = {}

function M.complete(context, callback)
    local options = vim.deepcopy(require('minuet').config.duet.provider_options.openai)
    local api_key = utils.get_api_key(options.api_key)

    if not api_key then
        utils.notify('Minuet duet OpenAI API key is not set.', 'error', vim.log.levels.ERROR)
        callback(nil)
        return
    end

    options.provider = 'openai'
    options.name = 'OpenAI'

    base.complete_openai_base(options, context, callback)
end

return M
