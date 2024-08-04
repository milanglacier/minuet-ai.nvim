local config = require('minuet').config
local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'
local job = require 'plenary.job'

local M = {}

M.is_available = function()
    if vim.env.GEMINI_API_KEY == nil or vim.env.GEMINI_API_KEY == '' then
        return false
    else
        return true
    end
end

if not M.is_available() then
    utils.notify('Gemini API key is not set', 'error', vim.log.levels.ERROR)
end

local function make_request_data()
    local options = vim.deepcopy(config.provider_options.gemini)

    local contents = {}

    for _, shot in ipairs(options.few_shots) do
        if shot.role == 'user' then
            table.insert(contents, {
                role = 'user',
                parts = {
                    { text = shot.content },
                },
            })
        elseif shot.role == 'assistant' then
            table.insert(contents, {
                role = 'model',
                parts = {
                    { text = shot.content },
                },
            })
        end
    end

    local system = utils.make_system_prompt(options.system, config.n_completions)

    local request_data = {
        system_instruction = {
            parts = {
                text = system,
            },
        },
        contents = contents,
    }

    request_data = vim.tbl_deep_extend('force', request_data, options.optional or {})

    return options, request_data
end

function M.complete(context_before_cursor, context_after_cursor, callback)
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

    table.insert(data.contents, {
        role = 'user',
        parts = {
            { text = context },
        },
    })

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    local function get_raw_items_no_stream(response, exit_code)
        local json = utils.json_decode(response, exit_code, data_file, 'Gemini', callback)

        if not json then
            return
        end

        if not json.candidates then
            utils.notify('Gemini API returns no content', 'error', vim.log.levels.INFO)
            callback()
            return
        end

        if not json.candidates[1].content then
            utils.notify('Gemini API returns no content, probably due to safety settings', 'error', vim.log.levels.INFO)
            callback()
            return
        end

        local items_raw = json.candidates[1].content.parts[1].text

        return items_raw
    end

    local function get_text_fn_stream(json)
        return json.candidates[1].content.parts[1].text
    end

    job:new({
        command = 'curl',
        args = {
            string.format(
                'https://generativelanguage.googleapis.com/v1beta/models/%s:%skey=%s',
                options.model,
                options.stream and 'streamGenerateContent?alt=sse&' or 'generateContent?',
                vim.env.GEMINI_API_KEY
            ),
            '-H',
            'Content-Type: application/json',
            '--max-time',
            tostring(config.request_timeout),
            '-d',
            '@' .. data_file,
        },
        on_exit = vim.schedule_wrap(function(response, exit_code)
            local items_raw
            if options.stream then
                items_raw = utils.stream_decode(response, exit_code, data_file, 'Gemini', get_text_fn_stream, callback)
            else
                items_raw = get_raw_items_no_stream(response, exit_code)
            end

            if not items_raw then
                return
            end

            local items = common.initial_process_completion_items(items_raw, 'gemini')

            callback(items)
        end),
    }):start()
end

return M
