local base = require 'minuet.duet.backends.openai_base'
local utils = require 'minuet.duet.utils'

local M = {}

local notified_on_endpoint = false

function M.complete(context, callback)
    local options = vim.deepcopy(require('minuet').config.duet.provider_options.openai_compatible)
    local api_key = utils.get_api_key(options.api_key)

    if not api_key then
        utils.notify(
            'Minuet duet OpenAI-compatible API key is not set, or the configured environment variable is missing.',
            'error',
            vim.log.levels.ERROR
        )
        callback(nil)
        return
    end

    if not notified_on_endpoint and not options.end_point:find 'chat' then
        utils.notify('Minuet duet expects an OpenAI-compatible chat endpoint.', 'warn', vim.log.levels.WARN)
        notified_on_endpoint = true
    end

    options.provider = 'openai_compatible'
    options.name = options.name or 'OpenAI Compatible'

    base.complete_openai_base(options, context, callback)
end

return M
