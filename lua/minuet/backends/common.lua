local M = {}
local utils = require 'minuet.utils'
local Job = require 'plenary.job'
local uv = vim.uv or vim.loop

-- currently running completion jobs, basically forked curl processes
M.current_jobs = {}

---@param job Job
function M.register_job(job)
    table.insert(M.current_jobs, job)
    utils.notify('Registered completion job', 'debug')
end

---@param job Job
function M.remove_job(job)
    for i, j in ipairs(M.current_jobs) do
        if j.pid == job.pid then
            table.remove(M.current_jobs, i)
            utils.notify('Completion job ' .. job.pid .. ' finished and removed from current_jobs', 'debug')
            break
        end
    end
end

---@param pid number
local function terminate_job(pid)
    if not uv.kill(pid, 15) then -- SIGTERM
        utils.notify('Failed to terminate completion job ' .. pid, 'warn', vim.log.levels.WARN)
        return false
    end

    utils.notify('Terminate completion job ' .. pid, 'debug')

    return true
end

function M.terminate_all_jobs()
    for _, job in ipairs(M.current_jobs) do
        terminate_job(job.pid)
    end

    M.current_jobs = {}
end

---@param items_raw string?
---@param provider string
---@return table<string>
function M.parse_completion_items(items_raw, provider)
    local success, items_table = pcall(vim.split, items_raw, '<endCompletion>')
    if not success then
        utils.notify('Failed to parse ' .. provider .. "'s content text", 'error', vim.log.levels.INFO)
        return {}
    end

    return items_table
end

function M.filter_context_sequences_in_items(items, context)
    local config = require('minuet').config
    if config.after_cursor_filter_length == 0 then
        return items
    end

    local filter_sequence = utils.make_context_filter_sequence(context, config.after_cursor_filter_length)

    items = vim.tbl_map(function(x)
        return utils.filter_text(x, filter_sequence)
    end, items)

    return items
end

function M.openai_get_text_fn_no_stream(json)
    return json.choices[1].message.content
end

function M.openai_get_text_fn_stream(json)
    return json.choices[1].delta.content
end

function M.complete_openai_base(options, context, callback)
    local config = require('minuet').config

    M.terminate_all_jobs()

    local ctx = utils.make_chat_llm_shot(context, options.chat_input)

    local few_shots = vim.deepcopy(utils.get_or_eval_value(options.few_shots))

    local system = utils.make_system_prompt(options.system, config.n_completions)

    table.insert(few_shots, 1, { role = 'system', content = system })
    table.insert(few_shots, { role = 'user', content = ctx })

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

    local args = {
        options.end_point,
        '-H',
        'Content-Type: application/json',
        '-H',
        'Authorization: Bearer ' .. utils.get_api_key(options.api_key),
        '--max-time',
        tostring(config.request_timeout),
        '-d',
        '@' .. data_file,
    }

    if config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, config.proxy)
    end

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
            M.remove_job(job)

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

            local items = M.parse_completion_items(items_raw, options.name)

            items = M.filter_context_sequences_in_items(items, context.lines_after)

            items = utils.remove_spaces(items)

            callback(items)
        end),
    }

    M.register_job(new_job)
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

    M.terminate_all_jobs()

    local data = {
        model = options.model,
        stream = options.stream,
        prompt = options.template.prompt(context.lines_before, context.lines_after),
        suffix = options.template.suffix and options.template.suffix(context.lines_before, context.lines_after) or nil,
    }
    data = vim.tbl_deep_extend('force', data, options.optional or {})

    if type(options.body_transform) == 'function' then
        data = options.body_transform(data)
    end

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    local endpoint = options.end_point
    local headers = {
        ['Content-Type'] = 'application/json',
        ['Accept'] = 'application/json',
        ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
    }

    if type(options.header_transform) == 'function' then
        endpoint, headers = options.header_transform(endpoint, headers)
    end

    local args = {
        '-L',
        endpoint,
    }
    for k, v in pairs(headers) do
        table.insert(args, '-H')
        table.insert(args, k .. ': ' .. v)
    end
    table.insert(args, '--max-time')
    table.insert(args, tostring(config.request_timeout))
    table.insert(args, '-d')
    table.insert(args, '@' .. data_file)

    if config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, config.proxy)
    end

    local effective_get_text_fn
    if type(options.get_text_fn) == 'table' then
        if options.stream then
            effective_get_text_fn = options.get_text_fn.stream or get_text_fn
        else
            effective_get_text_fn = options.get_text_fn.no_stream or get_text_fn
        end
    else
        effective_get_text_fn = get_text_fn
    end

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
                M.remove_job(job)

                utils.run_event('MinuetRequestFinished', {
                    provider = provider_name,
                    name = options.name,
                    n_requests = n_completions,
                    request_idx = idx,
                    timestamp = timestamp,
                })

                local result

                if options.stream then
                    result = utils.stream_decode(job, exit_code, data_file, options.name, effective_get_text_fn)
                else
                    result = utils.no_stream_decode(job, exit_code, data_file, options.name, effective_get_text_fn)
                end

                if result then
                    table.insert(items, result)
                end

                items = M.filter_context_sequences_in_items(items, context.lines_after)
                items = utils.remove_spaces(items)
                callback(items)
            end),
        }

        M.register_job(new_job)
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
