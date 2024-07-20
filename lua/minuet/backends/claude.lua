local config = require('minuet').config
local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'
local job = require 'plenary.job'

local M = {}

M.is_available = function()
    if vim.env.ANTHROPIC_API_KEY == nil or vim.env.ANTHROPIC_API_KEY == '' then
        return false
    else
        return true
    end
end

if not M.is_available() then
    vim.notify('Anthropic API key is not set', vim.log.levels.ERROR)
end

local function make_request_data()
    local options = vim.deepcopy(config.provider_options.claude)
    local system = utils.make_system_prompt(options.system, config.n_completions)

    local request_data = {
        system = system,
        max_tokens = options.max_tokens,
        model = options.model,
    }

    request_data = vim.tbl_deep_extend('force', request_data, options.optional or {})

    return options, request_data
end

M.complete = function(context_before_cursor, context_after_cursor, callback)
    local options, data = make_request_data()
    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()

    local context = language
        .. '\n'
        .. tab
        .. '\n'
        .. '<beginCode>'
        .. context_before_cursor
        .. '<cursorPosition>'
        .. context_after_cursor
        .. '<endCode>'

    local messages = vim.deepcopy(options.few_shots)
    table.insert(messages, { role = 'user', content = context })

    data.messages = messages

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    job:new({
        command = 'curl',
        args = {
            'https://api.anthropic.com/v1/messages',
            '-H',
            'Content-Type: application/json',
            '-H',
            'x-api-key: ' .. vim.env.ANTHROPIC_API_KEY,
            '-H',
            'anthropic-version: 2023-06-01',
            '--max-time',
            tostring(config.request_timeout),
            '-d',
            '@' .. data_file,
        },
        on_exit = vim.schedule_wrap(function(response, exit_code)
            local json = utils.json_decode(response, exit_code, data_file, 'Claude', callback)

            if not json then
                return
            end

            if not json.content then
                if config.notify then
                    vim.notify('Claude API returns no content', vim.log.levels.INFO)
                end
                callback()
                return
            end

            local items_raw = json.content[1].text

            local items = common.initial_process_completion_items(items_raw, 'claude')

            callback(items)
        end),
    }):start()
end

return M
