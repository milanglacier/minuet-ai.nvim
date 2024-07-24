local config = require('minuet').config
local utils = require 'minuet.utils'
local job = require 'plenary.job'

local M = {}

M.is_available = function()
    if vim.env.CODESTRAL_API_KEY == nil or vim.env.CODESTRAL_API_KEY == '' then
        return false
    else
        return true
    end
end

if not M.is_available() then
    utils.notify('Codestral API key is not set', 'error', vim.log.levels.ERROR)
end

local function make_request_data()
    local options = vim.deepcopy(config.provider_options.codestral)

    local request_data = {}

    request_data.model = options.model

    request_data = vim.tbl_deep_extend('force', request_data, options.optional or {})

    return options, request_data
end

M.complete = function(context_before_cursor, context_after_cursor, callback)
    local _, data = make_request_data()
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
                'https://codestral.mistral.ai/v1/fim/completions',
                '-H',
                'Content-Type: application/json',
                '-H',
                'Accept: application/json',
                '-H',
                'Authorization: Bearer ' .. vim.env.CODESTRAL_API_KEY,
                '--max-time',
                tostring(config.request_timeout),
                '-d',
                '@' .. data_file,
            },
            on_exit = vim.schedule_wrap(function(response, exit_code)
                -- Increment the request_send counter
                request_complete = request_complete + 1

                local json = utils.json_decode(response, exit_code, data_file, 'Codestral', check_and_callback)

                if not json then
                    return
                end

                if not json.choices then
                    utils.notify('Codestral API returns no content', 'error', vim.log.levels.INFO)
                    check_and_callback()
                    return
                end

                local result = json.choices[1].message.content

                table.insert(items, result)

                check_and_callback()
            end),
        }):start()
    end
end

return M
