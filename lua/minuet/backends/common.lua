local M = {}
local utils = require 'minuet.utils'
local job = require 'plenary.job'
local config = require('minuet').config

function M.initial_process_completion_items(items_raw, provider)
    local success
    success, items_raw = pcall(vim.split, items_raw, '<endCompletion>')
    if not success then
        if config.notify then
            vim.notify('Failed to parse ' .. provider .. "'s content text", vim.log.levels.INFO)
        end
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
    local system = utils.make_system_prompt(options.system, config.n_completions)

    table.insert(messages, 1, { role = 'system', content = system })
    table.insert(messages, { role = 'user', content = context })

    local data = {
        model = options.model,
        -- response_format = { type = 'json_object' }, -- NOTE: in practice this option yiled even worse result
        messages = messages,
    }

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
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
            local json = utils.json_decode(response, exit_code, data_file, options.name, callback)

            if not json then
                return
            end

            if not json.choices then
                if config.notify then
                    vim.notify(options.name .. ' API returns no content', vim.log.levels.INFO)
                end
                callback()
                return
            end

            local items_raw = json.choices[1].message.content

            local items = M.initial_process_completion_items(items_raw, options.name)

            callback(items)
        end),
    }):start()
end

return M
