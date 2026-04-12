local M = {}
local shared_utils = require('minuet.utils')

local editable_region_start_marker = '<editable_region_start>'
local editable_region_end_marker = '<editable_region_end>'
local cursor_position_marker = '<cursor_position>'

function M.get_root_config()
    return require('minuet').config
end

function M.get_config()
    return M.get_root_config().duet
end

M.notify = shared_utils.notify
M.get_api_key = shared_utils.get_api_key
M.get_or_eval_value = shared_utils.get_or_eval_value
M.make_tmp_file = shared_utils.make_tmp_file

function M.make_system_prompt(template)
    if type(template) == 'string' then
        return template
    end

    local values = vim.deepcopy(template or {})
    local rendered = values.template or ''
    values.template = nil

    for key, value in pairs(values) do
        if type(value) == 'function' then
            value = value()
        end

        if type(value) == 'string' then
            rendered = rendered:gsub('{{{' .. key .. '}}}', value)
        end
    end

    return rendered:gsub('{{{.-}}}', '')
end

function M.make_duet_llm_shot(context, chat_input)
    local template = type(chat_input) == 'table' and chat_input.template or ''
    return template
        :gsub('{{{non_editable_region_before}}}', context.non_editable_region_before)
        :gsub('{{{editable_region_before_cursor}}}', context.editable_region_before_cursor)
        :gsub('{{{editable_region_after_cursor}}}', context.editable_region_after_cursor)
        :gsub('{{{non_editable_region_after}}}', context.non_editable_region_after)
        :gsub('{{{.-}}}', '')
end

function M.make_curl_args(end_point, headers, data_file, timeout)
    local root_config = M.get_root_config()
    local args = { '-L' }

    for _, arg in ipairs(root_config.curl_extra_args or {}) do
        table.insert(args, arg)
    end

    for key, value in pairs(headers) do
        table.insert(args, '-H')
        table.insert(args, key .. ': ' .. value)
    end

    table.insert(args, '--max-time')
    table.insert(args, tostring(timeout))
    table.insert(args, '-d')
    table.insert(args, '@' .. data_file)

    if root_config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, root_config.proxy)
    end

    table.insert(args, end_point)

    return args
end

M.stream_decode = shared_utils.stream_decode
M.run_event = shared_utils.run_event

function M.get_changedtick(bufnr)
    return vim.api.nvim_buf_get_changedtick(bufnr)
end

local function count_occurrences(text, needle)
    local count = 0
    local init = 1

    while true do
        local start_pos, end_pos = text:find(needle, init, true)
        if not start_pos then
            break
        end

        count = count + 1
        init = end_pos + 1
    end

    return count
end

function M.parse_duet_response(text)
    if type(text) ~= 'string' or text == '' then
        return nil, 'empty response'
    end

    if count_occurrences(text, editable_region_start_marker) ~= 1 then
        return nil, 'expected exactly one editable region start marker'
    end

    if count_occurrences(text, editable_region_end_marker) ~= 1 then
        return nil, 'expected exactly one editable region end marker'
    end

    local start_pos, start_end = text:find(editable_region_start_marker, 1, true)
    local end_pos = text:find(editable_region_end_marker, start_end + 1, true)
    if not start_pos or not end_pos then
        return nil, 'failed to locate editable region markers'
    end

    local inner = text:sub(start_end + 1, end_pos - 1)
    if inner:sub(1, 1) == '\n' then
        inner = inner:sub(2)
    end
    if inner:sub(-1) == '\n' then
        inner = inner:sub(1, -2)
    end

    if count_occurrences(inner, cursor_position_marker) ~= 1 then
        return nil, 'expected exactly one cursor marker inside editable region'
    end

    local cursor_pos, cursor_end = inner:find(cursor_position_marker, 1, true)
    local before = inner:sub(1, cursor_pos - 1)
    local after = inner:sub(cursor_end + 1)
    local text_without_cursor = before .. after

    local cursor_lines = vim.split(before, '\n', { plain = true })
    local replacement_lines = vim.split(text_without_cursor, '\n', { plain = true })

    if #cursor_lines == 0 then
        cursor_lines = { '' }
    end

    if #replacement_lines == 0 then
        replacement_lines = { '' }
    end

    return {
        lines = replacement_lines,
        cursor = {
            row_offset = #cursor_lines - 1,
            col = #cursor_lines[#cursor_lines],
        },
    },
        nil
end

return M
