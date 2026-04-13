local common = require 'minuet.duet.backends.common'
local utils = require 'minuet.duet.utils'

local M = {}

local function get_text_fn(json)
    return json.candidates[1].content.parts[1].text
end

local function transform_openai_chat_to_gemini_chat(chat)
    local new_chat = {}

    for _, message in ipairs(chat) do
        if message.role == 'user' then
            table.insert(new_chat, {
                role = 'user',
                parts = {
                    { text = message.content },
                },
            })
        elseif message.role == 'assistant' then
            table.insert(new_chat, {
                role = 'model',
                parts = {
                    { text = message.content },
                },
            })
        end
    end

    return new_chat
end

function M.complete(context, callback)
    local root_config = require('minuet').config
    local duet_config = root_config.duet
    local options = vim.deepcopy(duet_config.provider_options.gemini)
    local api_key = utils.get_api_key(options.api_key)

    if not api_key then
        utils.notify('Minuet duet Gemini API key is not set.', 'error', vim.log.levels.ERROR)
        callback(nil)
        return
    end

    common.terminate_all_jobs()

    local prompt = utils.make_duet_llm_shot(context, options.chat_input)
    local messages =
        transform_openai_chat_to_gemini_chat(vim.deepcopy(utils.get_or_eval_value(options.few_shots) or {}))
    table.insert(messages, {
        role = 'user',
        parts = {
            { text = prompt },
        },
    })

    local data = {
        system_instruction = {
            parts = {
                { text = utils.make_system_prompt(options.system) },
            },
        },
        contents = messages,
    }

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local end_point = string.format('%s/%s:%s', options.end_point, options.model, 'streamGenerateContent?alt=sse')
    local headers = {
        ['Content-Type'] = 'application/json',
        ['x-goog-api-key'] = api_key,
    }

    local transformed_data = common.apply_transforms(options.transform, end_point, headers, data)
    local data_file = utils.make_tmp_file(transformed_data.body)

    if not data_file then
        callback(nil)
        return
    end

    local args = utils.make_curl_args(
        transformed_data.end_point,
        transformed_data.headers,
        data_file,
        duet_config.request_timeout
    )

    local timestamp = os.time()
    utils.run_event('MinuetDuetRequestStartedPre', {
        provider = 'gemini',
        name = 'Gemini',
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    local job = common.start_job(root_config.curl_cmd, args, {
        on_exit = function(_, result)
            utils.run_event('MinuetDuetRequestFinished', {
                provider = 'gemini',
                name = 'Gemini',
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            local text = utils.stream_decode(result, data_file, 'Gemini', get_text_fn)
            callback(text)
        end,
        on_spawn_error = function()
            os.remove(data_file)
            utils.run_event('MinuetDuetRequestFinished', {
                provider = 'gemini',
                name = 'Gemini',
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })
            callback(nil)
        end,
    })

    if not job then
        return
    end

    utils.run_event('MinuetDuetRequestStarted', {
        provider = 'gemini',
        name = 'Gemini',
        model = options.model,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })
end

return M
