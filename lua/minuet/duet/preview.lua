local api = vim.api
local M = {}

M.ns_id = api.nvim_create_namespace 'minuet.duet'

local function build_diff_lines(state)
    local virt_lines = {
        { { 'duet preview', 'Comment' } },
    }

    local original = table.concat(state.original_lines or {}, '\n')
    local proposed = table.concat(state.proposed_lines or {}, '\n')
    local hunks = vim.diff(original, proposed, { result_type = 'indices', algorithm = 'histogram' })

    if #hunks == 0 then
        table.insert(virt_lines, { { '  no text changes', 'Comment' } })
        return virt_lines
    end

    for _, hunk in ipairs(hunks) do
        local original_start, original_count, proposed_start, proposed_count = unpack(hunk)

        for idx = original_start, original_start + original_count - 1 do
            table.insert(virt_lines, { { '- ' .. (state.original_lines[idx] or ''), 'DiffDelete' } })
        end

        for idx = proposed_start, proposed_start + proposed_count - 1 do
            table.insert(virt_lines, { { '+ ' .. (state.proposed_lines[idx] or ''), 'DiffAdd' } })
        end
    end

    return virt_lines
end

function M.clear(bufnr, state)
    if state and state.extmark_id then
        pcall(api.nvim_buf_del_extmark, bufnr, M.ns_id, state.extmark_id)
        state.extmark_id = nil
    end
end

function M.render(bufnr, state)
    local config = require('minuet').config.duet
    M.clear(bufnr, state)

    if not config.preview.enabled then
        return
    end

    local anchor_row = math.max(state.range.end_row - 1, 0)
    local virt_lines = build_diff_lines(state)

    state.extmark_id = api.nvim_buf_set_extmark(bufnr, M.ns_id, anchor_row, 0, {
        virt_lines = virt_lines,
    })
end

function M.is_visible(bufnr, state)
    if not state or not state.extmark_id then
        return false
    end

    local extmark = api.nvim_buf_get_extmark_by_id(bufnr, M.ns_id, state.extmark_id, {})
    return extmark[1] ~= nil
end

return M
