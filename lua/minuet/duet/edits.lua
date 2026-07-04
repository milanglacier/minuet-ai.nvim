local api = vim.api

local M = {}

---@class minuet.DuetEditEvent
---@field bufnr integer
---@field filename string buffer name relative to cwd, or '[No Name]'
---@field diff string unified diff hunks without file headers or trailing newline
---@field text string fully formatted prompt block for this event

---@class minuet.DuetEditBufferState
---@field baseline string full buffer text, newline-joined with a trailing newline
---@field changedtick integer changedtick when the baseline was captured
---@field timer uv.uv_timer_t? lazily created debounce timer

local internal = {
    ---@type table<integer, minuet.DuetEditBufferState>
    buffers = {},
    ---@type minuet.DuetEditEvent[] oldest first
    events = {},
    total_chars = 0,
}

---@diagnostic disable-next-line: deprecated
local diff = (vim.text and vim.text.diff) or vim.diff

---@return minuet.DuetRecentEdits?
local function get_config()
    local minuet = require 'minuet'
    return minuet.config and minuet.config.duet.recent_edits or nil
end

---@param bufnr integer
---@return boolean
local function is_trackable(bufnr)
    local config = get_config()
    if not config or not config.enabled then
        return false
    end

    if not api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].buftype ~= '' or not vim.bo[bufnr].modifiable then
        return false
    end

    return api.nvim_buf_get_offset(bufnr, api.nvim_buf_line_count(bufnr)) <= config.max_buffer_size
end

---@param bufnr integer
local function drop_buffer_state(bufnr)
    local state = internal.buffers[bufnr]
    if not state then
        return
    end

    if state.timer then
        state.timer:stop()
        state.timer:close()
    end
    internal.buffers[bufnr] = nil
end

---@param bufnr integer
---@return string
local function get_buffer_text(bufnr)
    -- The trailing newline makes xdiff treat the last line as complete, the
    -- same convention used by minuet.duet.preview.
    return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n') .. '\n'
end

---Start tracking a buffer by capturing its baseline without emitting an
---event. No-op if the buffer is already tracked or fails the guards.
---@param bufnr integer
function M.track(bufnr)
    if internal.buffers[bufnr] or not is_trackable(bufnr) then
        return
    end

    internal.buffers[bufnr] = {
        baseline = get_buffer_text(bufnr),
        changedtick = api.nvim_buf_get_changedtick(bufnr),
    }
end

---Trim a unified diff to the leading whole hunks that fit the budget, so an
---oversized burst (a large paste or refactor, often the strongest intent
---signal) keeps its head instead of vanishing from history. Cutting mid-hunk
---would produce an invalid diff, so returns nil when not even the first hunk
---fits.
---@param unified string
---@param budget integer
---@return string?
local function truncate_to_hunks(unified, budget)
    if #unified <= budget then
        return unified
    end

    local kept_end = nil
    local search_from = 1
    while true do
        local boundary = unified:find('\n@@', search_from, true)
        local hunk_end = boundary and (boundary - 1) or #unified
        if hunk_end > budget then
            break
        end
        kept_end = hunk_end
        search_from = boundary + 1
    end

    return kept_end and unified:sub(1, kept_end) or nil
end

---@param bufnr integer
---@param unified string
local function push_event(bufnr, unified)
    local config = get_config()
    if not config then
        return
    end

    local name = api.nvim_buf_get_name(bufnr)
    local filename = name == '' and '[No Name]' or vim.fn.fnamemodify(name, ':~:.')

    -- Cap the diff so the formatted event on its own also fits
    -- max_total_chars; otherwise the eviction loop below would immediately
    -- evict the event it just pushed, silently keeping the history empty.
    local overhead = #string.format('User edited "%s":\n\n```diff\n\n```', filename)
    local bounded = truncate_to_hunks(unified, math.min(config.max_event_chars, config.max_total_chars - overhead))
    if not bounded then
        return
    end

    local text = string.format('User edited "%s":\n\n```diff\n%s\n```', filename, bounded)

    table.insert(internal.events, {
        bufnr = bufnr,
        filename = filename,
        diff = bounded,
        text = text,
    })
    internal.total_chars = internal.total_chars + #text

    while
        #internal.events > 0 and (#internal.events > config.max_events or internal.total_chars > config.max_total_chars)
    do
        local evicted = table.remove(internal.events, 1)
        internal.total_chars = internal.total_chars - #evicted.text
    end
end

---Synchronously flush the pending edit burst for a buffer: diff the baseline
---against the current text, record an event when the diff is non-empty, and
---reset the baseline. Establishes the baseline without emitting an event when
---the buffer is not tracked yet.
---@param bufnr integer
function M.flush(bufnr)
    local state = internal.buffers[bufnr]

    if state and state.timer then
        state.timer:stop()
    end

    if not is_trackable(bufnr) then
        drop_buffer_state(bufnr)
        return
    end

    if not state then
        M.track(bufnr)
        return
    end

    local changedtick = api.nvim_buf_get_changedtick(bufnr)
    if changedtick == state.changedtick then
        return
    end

    local config = get_config()
    if not config then
        return
    end

    local current = get_buffer_text(bufnr)
    local unified = diff(state.baseline, current, {
        result_type = 'unified',
        ctxlen = config.diff_context_lines,
        algorithm = 'histogram',
    })

    -- Always reset the baseline, even when the event is skipped, so the next
    -- burst is diffed against the text the user actually sees now.
    state.baseline = current
    state.changedtick = changedtick

    if type(unified) ~= 'string' then
        return
    end

    unified = unified:gsub('\n$', '')
    -- An empty diff (e.g. undo back to the baseline) is not worth an event.
    if unified == '' then
        return
    end

    push_event(bufnr, unified)
end

---Formatted edit history for the prompt: stored events ordered oldest to
---newest, joined by blank lines. Returns an empty string when the recorder is
---disabled or there is no history. The stored events are already bounded by
---max_total_chars.
---@return string
function M.render()
    local config = get_config()
    if not config or not config.enabled then
        return ''
    end

    local parts = {}
    for _, event in ipairs(internal.events) do
        table.insert(parts, event.text)
    end

    return table.concat(parts, '\n\n')
end

---@return minuet.DuetEditEvent[] oldest first; a copy, so callers cannot
---corrupt the recorder's total_chars accounting by mutating it
function M.get_events()
    return vim.deepcopy(internal.events)
end

---Drop all events and buffer baselines and close all timers.
function M.reset()
    for bufnr in pairs(internal.buffers) do
        drop_buffer_state(bufnr)
    end
    internal.events = {}
    internal.total_chars = 0
end

---@param info { buf: integer }
local function on_text_changed(info)
    local bufnr = info.buf
    local state = internal.buffers[bufnr]

    if not state then
        -- Baseline is established after this change, so edits made before
        -- tracking began never produce an event.
        M.track(bufnr)
        return
    end

    local config = get_config()
    if not config or not config.enabled then
        return
    end

    state.timer = state.timer or vim.uv.new_timer()
    state.timer:stop()
    -- schedule_wrap is required: uv timer callbacks run in a fast context
    -- where buffer API calls are disallowed.
    state.timer:start(
        config.debounce,
        0,
        vim.schedule_wrap(function()
            M.flush(bufnr)
        end)
    )
end

---Register the recorder autocmds into the duet augroup.
---@param augroup integer
function M.setup(augroup)
    api.nvim_create_autocmd('BufEnter', {
        group = augroup,
        callback = function(info)
            M.track(info.buf)
        end,
        desc = '[minuet.duet.edits] establish edit baseline',
    })

    api.nvim_create_autocmd('BufReadPost', {
        group = augroup,
        callback = function(info)
            -- A disk read (:e!, autoread, checktime) replaces the buffer
            -- content without the user editing it. Re-capture the baseline so
            -- the reload is never diffed as if it were a user edit; any
            -- pending burst was discarded by the reload as well.
            drop_buffer_state(info.buf)
            M.track(info.buf)
        end,
        desc = '[minuet.duet.edits] re-establish edit baseline after a disk read',
    })

    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
        group = augroup,
        callback = on_text_changed,
        desc = '[minuet.duet.edits] debounce edit burst',
    })

    api.nvim_create_autocmd('InsertLeave', {
        group = augroup,
        callback = function(info)
            M.flush(info.buf)
        end,
        desc = '[minuet.duet.edits] flush edit burst on insert leave',
    })

    -- Dropping on unload (not just wipeout) bounds memory: without it every
    -- buffer visited in a session would keep a full-text baseline alive
    -- indefinitely. An unloaded buffer cannot be edited, and re-entering it
    -- reloads from disk and re-tracks via BufEnter/BufReadPost.
    api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
        group = augroup,
        callback = function(info)
            drop_buffer_state(info.buf)
        end,
        desc = '[minuet.duet.edits] drop edit tracking state on buf unload',
    })

    -- The current buffer was opened before the autocmds above existed.
    M.track(api.nvim_get_current_buf())
end

return M
