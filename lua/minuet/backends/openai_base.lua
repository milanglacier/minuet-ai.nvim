local M = {}
local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'
local Job = require 'plenary.job'

function M.openai_get_text_fn_no_stream(json)
    return json.choices[1].message.content
end

function M.openai_get_text_fn_stream(json)
    return json.choices[1].delta.content
end

function M.complete_openai_base(options, context, callback)
    local config = require('minuet').config

    common.terminate_all_jobs()

    local ctx = utils.make_chat_llm_shot(context, options.chat_input)
    if type(ctx) == 'string' then
        ctx = common.create_chat_messages_from_list { ctx }
    else
        ctx = common.create_chat_messages_from_list(ctx)
    end

    local few_shots = vim.deepcopy(utils.get_or_eval_value(options.few_shots))

    local system = utils.make_system_prompt(options.system, config.n_completions)

    table.insert(few_shots, 1, { role = 'system', content = system })
    vim.list_extend(few_shots, ctx)

    local data = {
        model = options.model,
        messages = few_shots,
        stream = options.stream,
    }

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    local headers = {
        ['Content-Type'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
    }
    local args = utils.make_curl_args(options.end_point, headers, data_file)

    local provider_name = 'openai_compatible'
    local timestamp = os.time()

    utils.run_event('MinuetRequestStartedPre', {
        provider = provider_name,
        name = options.name,
        n_requests = 1,
        timestamp = timestamp,
    })

    local new_job = Job:new {
        command = 'curl',
        args = args,
        on_exit = vim.schedule_wrap(function(job, exit_code)
            common.remove_job(job)

            utils.run_event('MinuetRequestFinished', {
                provider = provider_name,
                name = options.name,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            local items_raw

            if options.stream then
                items_raw = utils.stream_decode(job, exit_code, data_file, options.name, M.openai_get_text_fn_stream)
            else
                items_raw =
                    utils.no_stream_decode(job, exit_code, data_file, options.name, M.openai_get_text_fn_no_stream)
            end

            if not items_raw then
                callback()
                return
            end

            local items = common.parse_completion_items(items_raw, options.name)

            items = common.filter_context_sequences_in_items(items, context.lines_after)

            items = utils.remove_spaces(items)

            callback(items)
        end),
    }

    common.register_job(new_job)
    new_job:start()

    utils.run_event('MinuetRequestStarted', {
        provider = provider_name,
        name = options.name,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })
end

function M.complete_openai_fim_base(options, get_text_fn, context, callback)
    local config = require('minuet').config

    common.terminate_all_jobs()

    local data = {}

    data.model = options.model
    data.stream = options.stream
    local context_before_cursor = context.lines_before
    local context_after_cursor = context.lines_after
    local opts = context.opts

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    data.prompt = options.template.prompt(context_before_cursor, context_after_cursor, opts)
    data.suffix = options.template.suffix and options.template.suffix(context_before_cursor, context_after_cursor, opts)
        or nil

    local end_point = options.end_point
    local headers = {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
    }

    local transformed_data = {
        end_point = end_point,
        headers = headers,
        body = data,
    }

    for _, fun in ipairs(options.transform) do
        transformed_data = fun(transformed_data)
    end

    local data_file = utils.make_tmp_file(transformed_data.body)

    if data_file == nil then
        return
    end

    local args = utils.make_curl_args(transformed_data.end_point, transformed_data.headers, data_file)

    local items = {}
    local n_completions = config.n_completions

    local provider_name = 'openai_fim_compatible'
    local timestamp = os.time()

    utils.run_event('MinuetRequestStartedPre', {
        provider = provider_name,
        name = options.name,
        n_requests = n_completions,
        timestamp = timestamp,
    })

    for idx = 1, n_completions do
        local new_job = Job:new {
            command = 'curl',
            args = args,
            on_exit = vim.schedule_wrap(function(job, exit_code)
                common.remove_job(job)

                utils.run_event('MinuetRequestFinished', {
                    provider = provider_name,
                    name = options.name,
                    n_requests = n_completions,
                    request_idx = idx,
                    timestamp = timestamp,
                })

                local result

                if options.stream then
                    result = utils.stream_decode(job, exit_code, data_file, options.name, get_text_fn)
                else
                    result = utils.no_stream_decode(job, exit_code, data_file, options.name, get_text_fn)
                end

                if result then
                    table.insert(items, result)
                end

                items = common.filter_context_sequences_in_items(items, context_after_cursor)
                items = utils.remove_spaces(items, true)

                callback(items)
            end),
        }

        common.register_job(new_job)
        new_job:start()

        utils.run_event('MinuetRequestStarted', {
            provider = provider_name,
            name = options.name,
            n_requests = n_completions,
            request_idx = idx,
            timestamp = timestamp,
        })
    end
end

return M
