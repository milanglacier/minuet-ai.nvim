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
    utils.notify('Anthropic API key is not set', 'error', vim.log.levels.ERROR)
end

local function make_request_data()
    local options = vim.deepcopy(config.provider_options.claude)
    local system = utils.make_system_prompt(options.system, config.n_completions)

    local request_data = {
        system = system,
        max_tokens = options.max_tokens,
        model = options.model,
        stream = options.stream,
    }

    request_data = vim.tbl_deep_extend('force', request_data, options.optional or {})

    return options, request_data
end

M.complete = function(context_before_cursor, context_after_cursor, callback)
    local options, data = make_request_data()
    local context = utils.make_chat_llm_shot(context_before_cursor, context_after_cursor)

    local messages = vim.deepcopy(options.few_shots)
    table.insert(messages, { role = 'user', content = context })

    data.messages = messages

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    local function get_text_fn_no_steam(json)
        return json.content[1].text
    end

    local function get_text_fn_stream(json)
        return json.delta.text
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
            local items_raw

            if options.stream then
                items_raw = utils.stream_decode(response, exit_code, data_file, 'Claude', get_text_fn_stream)
            else
                items_raw = utils.no_stream_decode(response, exit_code, data_file, 'Claude', get_text_fn_no_steam)
            end

            if not items_raw then
                callback()
                return
            end

            local items = common.initial_process_completion_items(items_raw, 'claude')

            if config.after_cursor_filter_length > 0 then
                local filter_sequence =
                    utils.make_context_filter_sequence(context_after_cursor, config.after_cursor_filter_length)

                items = vim.tbl_map(function(x)
                    return utils.filter_text(x, filter_sequence)
                end, items)
            end

            callback(items)
        end),
    }):start()
end

return M
