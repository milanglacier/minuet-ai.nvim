local config = require('minuet').config
local utils = require 'minuet.utils'
local job = require 'plenary.job'
local common = require 'minuet.backends.common'

local function make_request_data()
    local request_data = {
        parameters = {
            return_full_text = false,
            num_return_sequences = config.n_completions,
        },
        options = {
            use_cache = false,
        },
    }

    local options = vim.deepcopy(config.provider_options.huggingface)

    request_data = vim.tbl_deep_extend('force', request_data, options.optional or {})

    return options, request_data
end

local M = {}

M.is_available = function()
    if vim.env.HF_API_KEY == nil or vim.env.HF_API_KEY == '' then
        return false
    else
        return true
    end
end

if not M.is_available() then
    utils.notify('Huggingface API key is not set', 'error', vim.log.levels.ERROR)
end

M.complete_completion = function(context_before_cursor, context_after_cursor, callback)
    local options, data = make_request_data()
    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()

    local inputs
    local markers = options.strategies.completion.markers

    if options.strategies.completion.strategy == 'PSM' then
        inputs = markers.prefix
            .. language
            .. '\n'
            .. tab
            .. '\n'
            .. context_before_cursor
            .. markers.suffix
            .. context_after_cursor
            .. markers.middle
    elseif options.strategies.completion.strategy == 'SPM' then
        inputs = markers.suffix
            .. context_after_cursor
            .. markers.prefix
            .. language
            .. '\n'
            .. tab
            .. '\n'
            .. context_before_cursor
            .. markers.middle
    elseif options.strategies.completion.strategy == 'PM' then
        inputs = markers.prefix .. language .. '\n' .. tab .. '\n' .. context_before_cursor .. markers.middle
    else
        utils.notify('huggingface: Unknown completion strategy', 'error', vim.log.levels.ERROR)
        return
    end

    data.inputs = inputs

    local data_file = utils.make_tmp_file(data)

    if data_file == nil then
        return
    end

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
            'Authorization: Bearer ' .. vim.env.HF_API_KEY,
            '--max-time',
            tostring(config.request_timeout),
            '-d',
            '@' .. data_file,
        },
        on_exit = vim.schedule_wrap(function(response, exit_code)
            local json = utils.no_stream_decode(response, exit_code, data_file, 'huggingface', function(json)
                return json
            end)

            if not json then
                callback()
                return
            end

            if json.error then
                utils.notify(json.error, 'error', vim.log.levels.ERROR)
                callback()
                return
            end

            local items = {}

            for _, item in ipairs(json) do
                if item.generated_text then
                    table.insert(items, item.generated_text)
                end
            end

            items = common.filter_context_sequences_in_items(items, context_after_cursor)

            items = utils.remove_spaces(items)

            callback(items)
        end),
    }):start()
end

M.complete = function(context_before_cursor, context_after_cursor, callback)
    local options, _ = make_request_data()
    if options.type == 'completion' then
        M.complete_completion(context_before_cursor, context_after_cursor, callback)
    else
        utils.notify('huggingface: Unknown type', 'error', vim.log.levels.ERROR)
        callback()
    end
end

return M
