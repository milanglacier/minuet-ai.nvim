local api = vim.api
local M = {}

M.ns_id = api.nvim_create_namespace 'minuet.duet'

local default_highlights = {
    MinuetDuetAdd = 'DiffAdd',
    MinuetDuetDelete = 'DiffDelete',
    MinuetDuetComment = 'Comment',
}

for hl_group, default_link in pairs(default_highlights) do
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = hl_group })) then
        api.nvim_set_hl(0, hl_group, { link = default_link })
    end
end

local diff = (vim.text and vim.text.diff) or vim.diff

local function join_lines(lines)
    if not lines or #lines == 0 then
        return ''
    end

    return table.concat(lines, '\n') .. '\n'
end

local function get_hunks(state)
    local original = join_lines(state.original_lines)
    local proposed = join_lines(state.proposed_lines)
    return diff(original, proposed, {
        result_type = 'indices',
        algorithm = 'histogram',
        linematch = true,
    }) or {}
end

local function add_extmark(bufnr, state, row, opts)
    state.extmark_ids = state.extmark_ids or {}
    local extmark_id = api.nvim_buf_set_extmark(bufnr, M.ns_id, row, 0, opts)
    table.insert(state.extmark_ids, extmark_id)
end

local function render_inserted_lines(bufnr, state, row, lines, above)
    if #lines == 0 then
        return
    end

    local virt_lines = {}
    for _, line in ipairs(lines) do
        table.insert(virt_lines, { { line, 'MinuetDuetAdd' } })
    end

    add_extmark(bufnr, state, row, {
        virt_lines = virt_lines,
        virt_lines_above = above or false,
    })
end

local function render_hunk(bufnr, state, hunk)
    local original_start, original_count, proposed_start, proposed_count = unpack(hunk)
    local pair_count = math.min(original_count, proposed_count)
    local first_buffer_row = state.range.start_row + original_start - 1

    for offset = 0, pair_count - 1 do
        local buffer_row = first_buffer_row + offset
        local proposed_line = state.proposed_lines[proposed_start + offset] or ''

        add_extmark(bufnr, state, buffer_row, {
            line_hl_group = 'MinuetDuetDelete',
            virt_text = { { ' ' .. proposed_line, 'MinuetDuetAdd' } },
            virt_text_pos = 'eol',
        })
    end

    for offset = pair_count, original_count - 1 do
        add_extmark(bufnr, state, first_buffer_row + offset, {
            line_hl_group = 'MinuetDuetDelete',
        })
    end

    if proposed_count > pair_count then
        local inserted_lines = {}
        for offset = pair_count, proposed_count - 1 do
            table.insert(inserted_lines, state.proposed_lines[proposed_start + offset] or '')
        end

        local insertion_anchor_row = first_buffer_row + math.max(original_count - 1, 0)
        local render_above = original_count == 0 and original_start == 0

        if original_count == 0 then
            insertion_anchor_row = state.range.start_row
            if original_start > 0 then
                insertion_anchor_row = insertion_anchor_row + original_start - 1
            end
        end

        render_inserted_lines(bufnr, state, insertion_anchor_row, inserted_lines, render_above)
    end
end

function M.clear(bufnr, state)
    if not state then
        return
    end

    for _, extmark_id in ipairs(state.extmark_ids or {}) do
        pcall(api.nvim_buf_del_extmark, bufnr, M.ns_id, extmark_id)
    end

    if state.extmark_id then
        pcall(api.nvim_buf_del_extmark, bufnr, M.ns_id, state.extmark_id)
    end

    state.extmark_id = nil
    state.extmark_ids = nil
end

function M.render(bufnr, state)
    local config = require('minuet').config.duet
    M.clear(bufnr, state)

    if not config.preview.enabled then
        return
    end

    local hunks = get_hunks(state)

    if #hunks == 0 then
        add_extmark(bufnr, state, math.max(state.range.end_row - 1, 0), {
            virt_text = { { ' no text changes', 'MinuetDuetComment' } },
            virt_text_pos = 'eol',
        })
        return
    end

    for _, hunk in ipairs(hunks) do
        render_hunk(bufnr, state, hunk)
    end
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

    if not state.extmark_id then
        return false
    end

    local extmark = api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, state.extmark_id, {})
    return extmark[1] ~= nil
end

return M
