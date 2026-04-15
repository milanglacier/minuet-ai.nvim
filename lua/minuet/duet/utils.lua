local M = {}
local shared_utils = require 'minuet.utils'

function M.get_root_config()
    return require('minuet').config
end

function M.get_config()
    return M.get_root_config().duet
end

local function get_markers()
    local config = M.get_config()
    local markers = config and config.markers or {}
    local default_markers = require('minuet.duet.config').markers
    return {
        editable_region_start = markers.editable_region_start or default_markers.editable_region_start,
        editable_region_end = markers.editable_region_end or default_markers.editable_region_end,
        cursor_position = markers.cursor_position or default_markers.cursor_position,
    }
end

M.notify = shared_utils.notify
M.get_api_key = shared_utils.get_api_key
M.get_or_eval_value = shared_utils.get_or_eval_value
M.make_tmp_file = shared_utils.make_tmp_file

function M.make_system_prompt(template)
    local values = vim.deepcopy(template or {})
    local rendered = M.get_or_eval_value(values.template) or ''
    values.template = nil

    for key, value in pairs(values) do
        if type(value) == 'function' then
            value = value()
        end

        if type(value) == 'string' then
            rendered = shared_utils.replace_string_literal(rendered, '{{{' .. key .. '}}}', value)
        end
    end

    return rendered:gsub('{{{.-}}}', '')
end

---@param chat_input minuet.DuetChatInput
---@param context table
---@return string
function M.make_duet_llm_shot(context, chat_input)
    local resolved_chat_input = M.get_or_eval_value(chat_input)
    resolved_chat_input = vim.deepcopy(resolved_chat_input) or {}
    local template = M.get_or_eval_value(resolved_chat_input.template) or ''
    resolved_chat_input.template = nil

    local parts = {}
    local last_pos = 1

    while true do
        local start_pos, end_pos = template:find('{{{.-}}}', last_pos)
        if not start_pos then
            table.insert(parts, template:sub(last_pos))
            break
        end

        table.insert(parts, template:sub(last_pos, start_pos - 1))

        local key = template:sub(start_pos + 3, end_pos - 3)
        local value = resolved_chat_input[key]

        if type(value) == 'function' then
            value = value(context)
        end

        if type(value) == 'string' then
            table.insert(parts, value)
        end

        last_pos = end_pos + 1
    end

    local results = table.concat(parts)
    results = results:gsub('{{{.-}}}', '')

    return results
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

---@param text string
---@return string
local function trim_boundary_newlines(text)
    if text:sub(1, 1) == '\n' then
        text = text:sub(2)
    end
    if text:sub(-1) == '\n' then
        text = text:sub(1, -2)
    end
    return text
end

---@class minuet.DuetParseCursor
---@field row_offset integer
---@field col integer

---@class minuet.DuetParseResult
---@field lines string[]
---@field cursor minuet.DuetParseCursor

---@class minuet.DuetFilterContext
---@field non_editable_region_before? string
---@field non_editable_region_after? string

---@alias minuet.DuetParseContext minuet.DuetFilterContext|minuet.DuetContext

---@param inner string
---@param context minuet.DuetParseContext?
---@return string
local function filter_inner_text(inner, context)
    if type(inner) ~= 'string' or inner == '' or type(context) ~= 'table' then
        return inner
    end

    local config = M.get_config() or {}
    local editable_region = config.editable_region or {}
    local before_region_filter_length = math.max(editable_region.before_region_filter_length or 0, 0)
    local after_region_filter_length = math.max(editable_region.after_region_filter_length or 0, 0)
    local filtered_inner = inner

    if before_region_filter_length > 0 and type(context.non_editable_region_before) == 'string' then
        local match_before = shared_utils.find_longest_match(filtered_inner, context.non_editable_region_before)
        local match_len = vim.fn.strchars(match_before)
        if match_len >= before_region_filter_length then
            filtered_inner = vim.fn.strcharpart(filtered_inner, match_len)
        end
    end

    if after_region_filter_length > 0 and type(context.non_editable_region_after) == 'string' then
        local match_after = shared_utils.find_longest_match(context.non_editable_region_after, filtered_inner)
        local match_len = vim.fn.strchars(match_after)
        if match_len >= after_region_filter_length then
            local filtered_len = vim.fn.strchars(filtered_inner)
            filtered_inner = vim.fn.strcharpart(filtered_inner, 0, filtered_len - match_len)
        end
    end

    return filtered_inner
end

---@param text string
---@param context minuet.DuetParseContext?
---@return minuet.DuetParseResult?, string?
function M.parse_duet_response(text, context)
    local markers = get_markers()

    if type(text) ~= 'string' or text == '' then
        return nil, 'empty response'
    end

    if count_occurrences(text, markers.editable_region_start) ~= 1 then
        return nil, 'expected exactly one editable region start marker'
    end

    if count_occurrences(text, markers.editable_region_end) ~= 1 then
        return nil, 'expected exactly one editable region end marker'
    end

    local start_pos, start_end = text:find(markers.editable_region_start, 1, true)
    local end_pos = text:find(markers.editable_region_end, start_end + 1, true)
    if not start_pos or not end_pos then
        return nil, 'failed to locate editable region markers'
    end

    local inner = text:sub(start_end + 1, end_pos - 1)
    inner = trim_boundary_newlines(inner)
    inner = filter_inner_text(inner, context)
    inner = trim_boundary_newlines(inner)

    if count_occurrences(inner, markers.cursor_position) ~= 1 then
        return nil, 'expected exactly one cursor marker inside editable region'
    end

    local cursor_pos, cursor_end = inner:find(markers.cursor_position, 1, true)
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
