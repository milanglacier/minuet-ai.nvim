local M = {}
local utils = require 'minuet.utils'
local job = require 'plenary.job'
local config = require('minuet').config

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
    if config.after_cursor_filter_length == 0 then
        return items
    end

    local filter_sequence = utils.make_context_filter_sequence(context, config.after_cursor_filter_length)

    items = vim.tbl_map(function(x)
        return utils.filter_text(x, filter_sequence)
    end, items)

    return items
end

function M.complete_openai_base(options, context_before_cursor, context_after_cursor, callback)
    local context = utils.make_chat_llm_shot(context_before_cursor, context_after_cursor)

    local few_shots = vim.deepcopy(utils.get_or_eval_value(options.few_shots))

    local system = utils.make_system_prompt(options.system, config.n_completions)

    table.insert(few_shots, 1, { role = 'system', content = system })
    table.insert(few_shots, { role = 'user', content = context })

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

    local function get_text_fn_no_stream(json)
        return json.choices[1].message.content
    end

    local function get_text_fn_stream(json)
        return json.choices[1].delta.content
    end

    local args = {
        options.end_point,
        '-H',
        'Content-Type: application/json',
        '-H',
        'Authorization: Bearer ' .. vim.env[options.api_key],
        '--max-time',
        tostring(config.request_timeout),
        '-d',
        '@' .. data_file,
    }

    if config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, config.proxy)
    end

    job:new({
        command = 'curl',
        args = args,
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

            local items = M.parse_completion_items(items_raw, options.name)

            items = M.filter_context_sequences_in_items(items, context_after_cursor)

            items = utils.remove_spaces(items)

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
    local n_completions = config.n_completions

    for _ = 1, n_completions do
        local args = {
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
        }

        if config.proxy then
            table.insert(args, '--proxy')
            table.insert(args, config.proxy)
        end

        job:new({
            command = 'curl',
            args = args,
            on_exit = vim.schedule_wrap(function(response, exit_code)
                local result

                if options.stream then
                    result = utils.stream_decode(response, exit_code, data_file, options.name, get_text_fn)
                else
                    result = utils.no_stream_decode(response, exit_code, data_file, options.name, get_text_fn)
                end

                if result then
                    table.insert(items, result)
                end

                items = M.filter_context_sequences_in_items(items, context_after_cursor)
                items = utils.remove_spaces(items)
                callback(items)
            end),
        }):start()
    end
end

return M
