local config = require('minuet').config
local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'
local Job = require 'plenary.job'

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

function M.get_text_fn(json)
    return json.candidates[1].content.parts[1].text
end

local function make_request_data()
    local options = vim.deepcopy(config.provider_options.gemini)

    local contents = {}

    local few_shots = utils.get_or_eval_value(options.few_shots)

    for _, shot in ipairs(few_shots) do
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

function M.complete(context, callback)
    common.terminate_all_jobs()

    local options, data = make_request_data()

    local ctx = utils.make_chat_llm_shot(context, options.chat_input)

    table.insert(data.contents, {
        role = 'user',
        parts = {
            { text = ctx },
        },
    })

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        callback()
        return
    end

    local args = {
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
    }

    if config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, config.proxy)
    end

    local new_job = Job:new {
        command = 'curl',
        args = args,
        on_exit = vim.schedule_wrap(function(job, exit_code)
            common.remove_job(job)

            local items_raw
            if options.stream then
                items_raw = utils.stream_decode(job, exit_code, data_file, 'Gemini', M.get_text_fn)
            else
                items_raw = utils.no_stream_decode(job, exit_code, data_file, 'Gemini', M.get_text_fn)
            end

            if not items_raw then
                callback()
                return
            end

            local items = common.parse_completion_items(items_raw, 'Gemini')

            items = common.filter_context_sequences_in_items(items, context_after_cursor)

            items = utils.remove_spaces(items)

            callback(items)
        end),
    }

    common.register_job(new_job)
    new_job:start()
end

return M
