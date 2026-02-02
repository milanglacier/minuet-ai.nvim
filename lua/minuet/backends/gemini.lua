local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'
local Job = require 'plenary.job'

local M = {}

M.is_available = function()
    local config = require('minuet').config
    return utils.get_api_key(config.provider_options.gemini.api_key) and true or false
end

if not M.is_available() then
    utils.notify('Gemini API key is not set', 'error', vim.log.levels.ERROR)
end

function M.get_text_fn(json)
    return json.candidates[1].content.parts[1].text
end

function M.transform_openai_chat_to_gemini_chat(chat)
    local new_chat = {}
    for _, message in ipairs(chat) do
        local gemini_message = {}
        if message.role == 'user' then
            gemini_message = {
                role = 'user',
                parts = {
                    { text = message.content },
                },
            }
        elseif message.role == 'assistant' then
            gemini_message = {
                role = 'model',
                parts = {
                    { text = message.content },
                },
            }
        end
        table.insert(new_chat, gemini_message)
    end
    return new_chat
end

local function make_request_data()
    local config = require('minuet').config
    local options = vim.deepcopy(config.provider_options.gemini)

    local few_shots = utils.get_or_eval_value(options.few_shots)

    few_shots = M.transform_openai_chat_to_gemini_chat(few_shots)

    local system = utils.make_system_prompt(options.system, config.n_completions)

    local request_data = {
        system_instruction = {
            parts = {
                text = system,
            },
        },
        contents = few_shots,
    }

    request_data = vim.tbl_deep_extend('force', request_data, options.optional or {})

    return options, request_data
end

function M.complete(context, callback)
    local config = require('minuet').config
    common.terminate_all_jobs()

    local options, data = make_request_data()

    local ctx = utils.make_chat_llm_shot(context, options.chat_input)
    ctx = common.create_chat_messages_from_list(ctx)
    ctx = M.transform_openai_chat_to_gemini_chat(ctx)

    vim.list_extend(data.contents, ctx)

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        callback()
        return
    end

    local end_point = string.format(
        '%s/%s:%s',
        options.end_point,
        options.model,
        options.stream and 'streamGenerateContent?alt=sse' or 'generateContent'
    )
    local headers = {
        ['Content-Type'] = 'application/json',
        ['x-goog-api-key'] = utils.get_api_key(options.api_key),
    }
    local args = utils.make_curl_args(end_point, headers, data_file)

    local provider_name = 'Gemini'
    local timestamp = os.time()

    utils.run_event('MinuetRequestStartedPre', {
        provider = provider_name,
        name = provider_name,
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    local new_job = Job:new {
        command = config.curl_cmd,
        args = args,
        on_exit = vim.schedule_wrap(function(job, exit_code)
            common.remove_job(job)

            utils.run_event('MinuetRequestFinished', {
                provider = provider_name,
                name = provider_name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            local items_raw
            if options.stream then
                items_raw = utils.stream_decode(job, exit_code, data_file, provider_name, M.get_text_fn)
            else
                items_raw = utils.no_stream_decode(job, exit_code, data_file, provider_name, M.get_text_fn)
            end

            if not items_raw then
                callback()
                return
            end

            local items = common.parse_completion_items(items_raw, provider_name)

            items = common.filter_context_sequences_in_items(items, context)

            items = utils.remove_spaces(items)

            callback(items)
        end),
    }

    common.register_job(new_job)
    new_job:start()

    utils.run_event('MinuetRequestStarted', {
        provider = provider_name,
        name = provider_name,
        model = options.model,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })
end

return M
