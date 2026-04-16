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

    return {
        bufnr = bufnr,
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
        non_editable_region_before = table.concat(non_editable_region_before, '\n'),
        editable_region_before_cursor = table.concat(editable_region_before_cursor, '\n'),
        editable_region_after_cursor = table.concat(editable_region_after_cursor, '\n'),
        non_editable_region_after = table.concat(non_editable_region_after, '\n'),
        original_lines = editable_region_lines,
        range = {
            start_row = start_row,
            end_row = end_row_inclusive + 1,
        },
    }
end

return M
