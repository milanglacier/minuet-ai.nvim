local M = {}

--- Flatten the main trunk of the undo tree (ignore .alt branches), newest-first.
---@param entries vim.fn.undotree.entry[]
---@return { seq: integer, time: integer }[]
local function flatten_trunk(entries)
    local trunk = {}
    for i = #entries, 1, -1 do
        table.insert(trunk, { seq = entries[i].seq, time = entries[i].time })
    end
    return trunk
end

--- Find boundary sequence numbers where time gaps exceed the threshold.
--- Returns a list of seq numbers (oldest first) representing the start of each edit group.
---@param trunk { seq: integer, time: integer }[]
---@param max_entries integer
---@param time_gap integer
---@return integer[]
local function find_time_boundaries(trunk, max_entries, time_gap)
    if #trunk == 0 then
        return {}
    end

    local boundaries = {}

    -- trunk is newest-first; walk it to find time gaps
    for i = 1, #trunk - 1 do
        if trunk[i].time - trunk[i + 1].time >= time_gap then
            table.insert(boundaries, trunk[i + 1].seq)
            if #boundaries >= max_entries then
                break
            end
        end
    end

    -- If no time gaps found, just take the oldest entry we can reach
    if #boundaries == 0 and #trunk > 1 then
        table.insert(boundaries, trunk[#trunk].seq)
    end

    -- Reverse so boundaries are oldest-first
    local reversed = {}
    for i = #boundaries, 1, -1 do
        table.insert(reversed, boundaries[i])
    end

    return reversed
end

--- Build a diff history string from the undo tree.
--- Must be called while bufnr is the current buffer.
---@param bufnr integer
---@param config minuet.DuetConfig
---@return string
function M.build(bufnr, config)
    local diff_config = config.diff_history or {}
    local max_entries = diff_config.max_entries or 5
    local max_chars = diff_config.max_chars or 2000
    local time_gap = diff_config.time_gap or 30

    local tree = vim.fn.undotree(bufnr)
    if tree.seq_cur == 0 or not tree.entries or #tree.entries == 0 then
        return ''
    end

    local trunk = flatten_trunk(tree.entries)
    local boundaries = find_time_boundaries(trunk, max_entries, time_gap)

    if #boundaries == 0 then
        return ''
    end

    local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Capture snapshots at each boundary
    local snapshots = {}
    for _, seq in ipairs(boundaries) do
        vim.cmd.undo { seq, mods = { silent = true, noautocmd = true } }
        table.insert(snapshots, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end

    -- Restore current state
    vim.cmd.undo { tree.seq_cur, mods = { silent = true, noautocmd = true } }

    -- Append current state as the final snapshot
    table.insert(snapshots, current_lines)

    -- Diff consecutive snapshots
    local parts = {}
    local total_chars = 0

    for i = 1, #snapshots - 1 do
        local old_text = table.concat(snapshots[i], '\n') .. '\n'
        local new_text = table.concat(snapshots[i + 1], '\n') .. '\n'
        local diff = vim.diff(old_text, new_text, { ctxlen = 2 })

        if diff and diff ~= '' then
            total_chars = total_chars + #diff
            if total_chars > max_chars then
                -- Truncate to fit within budget
                local remaining = max_chars - (total_chars - #diff)
                if remaining > 0 then
                    table.insert(parts, diff:sub(1, remaining))
                end
                break
            end
            table.insert(parts, diff)
        end
    end

    local result = table.concat(parts, '\n')
    if result == '' then
        return ''
    end

    return 'Recent edits (oldest first):\n' .. result
end

return M
