local M = {}
local utils = require 'minuet.utils'
local job = require 'plenary.job'
local config = require('minuet').config

function M.initial_process_completion_items(items_raw, provider)
    local success
    success, items_raw = pcall(vim.split, items_raw, '<endCompletion>')
    if not success then
        utils.notify('Failed to parse ' .. provider .. "'s content text", 'error', vim.log.levels.INFO)
        return
    end

    local items = {}

    for _, item in ipairs(items_raw) do
        if item:find '%S' then -- only include entries that contains non-whitespace
            -- replace the last \n charecter if it exists
            item = item:gsub('\n$', '')
            -- replace leading \n characters
            item = item:gsub('^\n+', '')
            table.insert(items, item)
        end
    end

    return items
end

function M.complete_openai_base(options, context_before_cursor, context_after_cursor, callback)
    local context = utils.make_chat_llm_shot(context_before_cursor, context_after_cursor)

    local messages = vim.deepcopy(options.few_shots)
    local system = utils.make_system_prompt(options.system, config.n_completions)

    table.insert(messages, 1, { role = 'system', content = system })
    table.insert(messages, { role = 'user', content = context })

    local data = {
        model = options.model,
        messages = messages,
        stream = options.stream,
    }

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    local function get_text_fn_no_stream(json)
        return json.choices[1].message.content
    end

    local function get_text_fn_stream(json)
        return json.choices[1].delta.content
    end

    job:new({
        command = 'curl',
        args = {
            options.end_point,
            '-H',
            'Content-Type: application/json',
            '-H',
            'Authorization: Bearer ' .. vim.env[options.api_key],
            '--max-time',
            tostring(config.request_timeout),
            '-d',
            '@' .. data_file,
        },
        on_exit = vim.schedule_wrap(function(response, exit_code)
            local items_raw

            if options.stream then
                items_raw = utils.stream_decode(response, exit_code, data_file, options.name, get_text_fn_stream)
            else
                items_raw = utils.no_stream_decode(response, exit_code, data_file, options.name, get_text_fn_no_stream)
            end

            if not items_raw then
                callback()
                return
            end

            local items = M.initial_process_completion_items(items_raw, options.name)

            callback(items)
        end),
    }):start()
end

function M.complete_openai_fim_base(options, get_text_fn, context_before_cursor, context_after_cursor, callback)
    local data = {}

    data.model = options.model
    data.stream = options.stream

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()
    context_before_cursor = language .. '\n' .. tab .. '\n' .. context_before_cursor

    data.prompt = context_before_cursor
    data.suffix = context_after_cursor

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

    local items = {}
    local request_complete = 0
    local n_completions = config.n_completions
    local has_called_back = false

    local function check_and_callback()
        if request_complete >= n_completions and not has_called_back then
            has_called_back = true
            callback(items)
        end
    end

    for _ = 1, n_completions do
        job:new({
            command = 'curl',
            args = {
                '-L',
                options.end_point,
                '-H',
                'Content-Type: application/json',
                '-H',
                'Accept: application/json',
                '-H',
                'Authorization: Bearer ' .. vim.env[options.api_key],
                '--max-time',
                tostring(config.request_timeout),
                '-d',
                '@' .. data_file,
            },
            on_exit = vim.schedule_wrap(function(response, exit_code)
                -- Increment the request_send counter
                request_complete = request_complete + 1

                local result

                if options.stream then
                    result = utils.stream_decode(response, exit_code, data_file, options.name, get_text_fn)
                else
                    result = utils.no_stream_decode(response, exit_code, data_file, options.name, get_text_fn)
                end

                if result then
                    table.insert(items, result)
                end

                check_and_callback()
            end),
        }):start()
    end
end
return M
