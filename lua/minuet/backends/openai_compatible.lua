local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'

local M = {}

local notified_on_using_chat_endpoint = false

M.is_available = function()
    local config = require('minuet').config
    local options = config.provider_options.openai_compatible
    if options.end_point == '' or options.api_key == '' or options.name == '' then
        return false
    end

    if not options.end_point:find 'chat' and not notified_on_using_chat_endpoint then
        utils.notify('Please make sure your endpoint supports `/chat/completion`', 'warn', vim.log.levels.WARN)
        notified_on_using_chat_endpoint = true
    end

    return utils.get_api_key(options.api_key) and true or false
end

if not M.is_available() then
    utils.notify(
        [[The API key has not been provided as an environment variable, or the specified API key environment variable does not exist.
Or the api-key function doesn't return the value.
If you are using Ollama, you can simply set it to 'TERM'.]],
        'error',
        vim.log.levels.ERROR
    )
end

M.complete = function(context, callback)
    local config = require('minuet').config
    local options = vim.deepcopy(config.provider_options.openai_compatible)
    common.complete_openai_base(options, context, callback)
end

return M
