local M = {}

---@class minuet.DuetContextRange
---@field start_row integer
---@field end_row integer

---@class minuet.DuetContext
---@field bufnr integer
---@field changedtick integer
---@field non_editable_region_before string
---@field editable_region_before_cursor string
---@field editable_region_after_cursor string
---@field non_editable_region_after string
---@field original_lines string[]
---@field range minuet.DuetContextRange

---@param context_before string
---@param context_after string
---@param config minuet.DuetConfig
---@return string, string
local function truncate_non_editable_regions(context_before, context_after, config)
    local non_editable_region = config.non_editable_region or {}
    local context_window = math.max(non_editable_region.context_window or 0, 0)
    local context_ratio = non_editable_region.context_ratio or 0.75
    local n_chars_before = vim.fn.strchars(context_before)
    local n_chars_after = vim.fn.strchars(context_after)
    local is_incomplete_before = false
    local is_incomplete_after = false

    if n_chars_before + n_chars_after > context_window then
        if n_chars_before < context_window * context_ratio then
            -- Before context fits its budget; spend the remaining window after the editable region.
            context_after = vim.fn.strcharpart(context_after, 0, context_window - n_chars_before)
            is_incomplete_after = true
        elseif n_chars_after < context_window * (1 - context_ratio) then
            -- After context fits its budget; spend the remaining window before the editable region.
            context_before = vim.fn.strcharpart(context_before, n_chars_before + n_chars_after - context_window)
            is_incomplete_before = true
        else
            -- Both sides exceed their budgets; split the window by context_ratio.
            context_after = vim.fn.strcharpart(context_after, 0, math.floor(context_window * (1 - context_ratio)))
            context_before =
                vim.fn.strcharpart(context_before, n_chars_before - math.floor(context_window * context_ratio))
            is_incomplete_before = true
            is_incomplete_after = true
        end
    end

    if is_incomplete_before then
        -- Drop the first line because suffix truncation may start in the middle of a line.
        local _, rest = context_before:match '([^\n]*)\n(.*)'
        context_before = rest or context_before
    end

    if is_incomplete_after then
        -- Drop the last line because prefix truncation may end in the middle of a line.
        local content = context_after:match '(.*)[\n][^\n]*$'
        context_after = content or context_after
    end

    return context_before, context_after
end

---@param bufnr integer
---@return minuet.DuetContext
function M.build(bufnr)
    local config = require('minuet').config.duet
    local cursor = vim.api.nvim_win_get_cursor(0)
    local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local line_count = math.max(#all_lines, 1)
    local cursor_line = cursor[1] - 1
    local cursor_col = cursor[2]

    if #all_lines == 0 then
        all_lines = { '' }
    end

    local region_before = math.max(config.editable_region.lines_before or 0, 0)
    local region_after = math.max(config.editable_region.lines_after or 0, 0)

    local start_row = math.max(0, cursor_line - region_before)
    local end_row_inclusive = math.min(line_count - 1, cursor_line + region_after)

    local non_editable_region_before = vim.list_slice(all_lines, 1, start_row)
    local editable_region_lines = vim.list_slice(all_lines, start_row + 1, end_row_inclusive + 1)
    local non_editable_region_after = vim.list_slice(all_lines, end_row_inclusive + 2, #all_lines)

    local cursor_index = cursor_line - start_row + 1
    local current_line = editable_region_lines[cursor_index] or ''

    local editable_region_before_cursor = vim.list_slice(editable_region_lines, 1, cursor_index - 1)
    table.insert(editable_region_before_cursor, current_line:sub(1, cursor_col))

    local editable_region_after_cursor = { current_line:sub(cursor_col + 1) }
    for index = cursor_index + 1, #editable_region_lines do
        table.insert(editable_region_after_cursor, editable_region_lines[index])
    end

    local non_editable_region_before_text = table.concat(non_editable_region_before, '\n')
    local non_editable_region_after_text = table.concat(non_editable_region_after, '\n')
    non_editable_region_before_text, non_editable_region_after_text =
        truncate_non_editable_regions(non_editable_region_before_text, non_editable_region_after_text, config)

    return {
        bufnr = bufnr,
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
        non_editable_region_before = non_editable_region_before_text,
        editable_region_before_cursor = table.concat(editable_region_before_cursor, '\n'),
        editable_region_after_cursor = table.concat(editable_region_after_cursor, '\n'),
        non_editable_region_after = non_editable_region_after_text,
        original_lines = editable_region_lines,
        range = {
            start_row = start_row,
            end_row = end_row_inclusive + 1,
        },
    }
end

return M
