local api = vim.api
local utils = require 'minuet.duet.utils'
local M = {}

M.ns_id = api.nvim_create_namespace 'minuet.duet'

local default_highlights = {
    MinuetDuetAdd = 'DiffAdd',
    MinuetDuetDelete = 'DiffDelete',
    MinuetDuetComment = 'Comment',
    MinuetDuetCursor = 'Cursor',
}

for hl_group, default_link in pairs(default_highlights) do
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = hl_group })) then
        api.nvim_set_hl(0, hl_group, { link = default_link })
    end
end

---@diagnostic disable-next-line: deprecated
local diff = (vim.text and vim.text.diff) or vim.diff

---@alias MinuetDuetHunk integer[]

local function join_lines(lines)
    if not lines or #lines == 0 then
        return ''
    end

    return table.concat(lines, '\n') .. '\n'
end

---@return MinuetDuetHunk[]
local function get_hunks(state)
    local original = join_lines(state.original_lines)
    local proposed = join_lines(state.proposed_lines)
    local hunks = diff(original, proposed, {
        result_type = 'indices',
        algorithm = 'histogram',
        linematch = true,
        ignore_whitespace = false,
        ignore_whitespace_change = false,
        ignore_whitespace_change_at_eol = false,
        ignore_blank_lines = false,
    })

    -- make the LSP type checking happy.
    if type(hunks) == 'string' or hunks == nil then
        return {}
    end
    return hunks
end

local function add_extmark(bufnr, state, row, opts)
    state.extmark_ids = state.extmark_ids or {}
    local extmark_id = api.nvim_buf_set_extmark(bufnr, M.ns_id, row, 0, opts)
    table.insert(state.extmark_ids, extmark_id)
end

--- Build styled chunks for a proposed line, inserting the cursor character
--- when the cursor falls on this line.
---@param text string the proposed line content
---@param hl_group string highlight group for the text
---@param cursor_col integer|nil byte column of cursor on this line, nil if cursor is elsewhere
---@param cursor_char string the cursor character to render
---@return table[] chunks list of {text, hl_group} pairs
local function make_chunks(text, hl_group, cursor_col, cursor_char)
    if not cursor_col then
        return { { text, hl_group } }
    end
    local before = text:sub(1, cursor_col)
    local after = text:sub(cursor_col + 1)
    local chunks = {}
    if #before > 0 then
        table.insert(chunks, { before, hl_group })
    end
    table.insert(chunks, { cursor_char, 'MinuetDuetCursor' })
    if #after > 0 then
        table.insert(chunks, { after, hl_group })
    end
    return chunks
end

--- Return the cursor column if the proposed line at `proposed_idx` (0-based)
--- carries the cursor, otherwise nil.
local function cursor_col_for(state, proposed_idx)
    local c = state.proposed_cursor
    if not c then
        return nil
    end
    if proposed_idx == c.row_offset then
        return c.col
    end
    return nil
end

local function render_inserted_lines(bufnr, state, row, lines, proposed_indices, cursor_char, above)
    if #lines == 0 then
        return
    end

    local virt_lines = {}
    for i, line in ipairs(lines) do
        local col = cursor_col_for(state, proposed_indices[i])
        local chunks = make_chunks(line, 'MinuetDuetAdd', col, cursor_char)
        table.insert(virt_lines, chunks)
    end

    add_extmark(bufnr, state, row, {
        virt_lines = virt_lines,
        virt_lines_above = above or false,
    })
end

---@param hunk MinuetDuetHunk
local function render_hunk(bufnr, state, hunk, cursor_char)
    local original_start, original_count, proposed_start, proposed_count = unpack(hunk)
    local pair_count = math.min(original_count, proposed_count)
    local first_buffer_row = state.range.start_row + original_start - 1

    for offset = 0, pair_count - 1 do
        local buffer_row = first_buffer_row + offset
        local buffer_line = api.nvim_buf_get_lines(bufnr, buffer_row, buffer_row + 1, false)[1] or ''
        local proposed_line = state.proposed_lines[proposed_start + offset] or ''
        local proposed_idx = proposed_start + offset - 1 -- 0-based index into proposed_lines
        local col = cursor_col_for(state, proposed_idx)
        local chunks = make_chunks(' ' .. proposed_line, 'MinuetDuetAdd', col and col + 1, cursor_char)

        add_extmark(bufnr, state, buffer_row, {
            end_col = #buffer_line,
            hl_group = 'MinuetDuetDelete',
            virt_text = chunks,
            virt_text_pos = 'eol',
        })
    end

    for offset = pair_count, original_count - 1 do
        local buffer_row = first_buffer_row + offset
        local buffer_line = api.nvim_buf_get_lines(bufnr, buffer_row, buffer_row + 1, false)[1] or ''
        add_extmark(bufnr, state, buffer_row, {
            end_col = #buffer_line,
            hl_group = 'MinuetDuetDelete',
        })
    end

    if proposed_count > pair_count then
        local inserted_lines = {}
        local proposed_indices = {}
        for offset = pair_count, proposed_count - 1 do
            table.insert(inserted_lines, state.proposed_lines[proposed_start + offset] or '')
            table.insert(proposed_indices, proposed_start + offset - 1) -- 0-based
        end

        local insertion_anchor_row = first_buffer_row + math.max(original_count - 1, 0)
        local render_above = original_count == 0 and original_start == 0

        if original_count == 0 then
            insertion_anchor_row = state.range.start_row
            if original_start > 0 then
                insertion_anchor_row = insertion_anchor_row + original_start - 1
            end
        end

        render_inserted_lines(
            bufnr,
            state,
            insertion_anchor_row,
            inserted_lines,
            proposed_indices,
            cursor_char,
            render_above
        )
    end
end

--- Render the cursor on an unchanged line (not covered by any hunk).
---@param hunks MinuetDuetHunk[]
local function render_cursor_on_unchanged_line(bufnr, state, hunks, cursor_char)
    local c = state.proposed_cursor
    if not c then
        return
    end

    local proposed_row_1based = c.row_offset + 1

    -- If the cursor falls inside a hunk it was already rendered there.
    for _, hunk in ipairs(hunks) do
        local _, _, ps, pc = unpack(hunk)
        if proposed_row_1based >= ps and proposed_row_1based < ps + pc then
            return
        end
    end

    -- Map proposed row → original row by undoing the cumulative insert/delete shift.
    local shift = 0
    for _, hunk in ipairs(hunks) do
        local _, oc, ps, pc = unpack(hunk)
        if ps + pc <= proposed_row_1based then
            shift = shift + (pc - oc)
        end
    end

    local original_row_1based = proposed_row_1based - shift
    local buffer_row = state.range.start_row + original_row_1based - 1

    local line_text = state.proposed_lines[proposed_row_1based] or ''
    local chunks = make_chunks(' ' .. line_text, 'MinuetDuetComment', c.col + 1, cursor_char)

    add_extmark(bufnr, state, buffer_row, {
        virt_text = chunks,
        virt_text_pos = 'eol',
    })
end

function M.clear(bufnr, state)
    if not state then
        return
    end

    for _, extmark_id in ipairs(state.extmark_ids or {}) do
        pcall(api.nvim_buf_del_extmark, bufnr, M.ns_id, extmark_id)
    end

    state.extmark_ids = nil
end

function M.render(bufnr, state)
    local config = require('minuet').config.duet
    M.clear(bufnr, state)

    ---@type MinuetDuetHunk[]
    local hunks = get_hunks(state)
    local cursor_char = config.preview.cursor

    if #hunks == 0 then
        render_cursor_on_unchanged_line(bufnr, state, hunks, cursor_char)
        if not state.proposed_cursor then
            utils.notify('Minuet duet predicts no text changes.', 'warn', vim.log.levels.WARN)
        end
        return
    end

    for _, hunk in ipairs(hunks) do
        render_hunk(bufnr, state, hunk, cursor_char)
    end

    render_cursor_on_unchanged_line(bufnr, state, hunks, cursor_char)
end

function M.is_visible(bufnr, state)
    if not state then
        return false
    end

    for _, extmark_id in ipairs(state.extmark_ids or {}) do
        local extmark = api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, extmark_id, {})
        if extmark[1] ~= nil then
            return true
        end
    end
    return false
end

return M
