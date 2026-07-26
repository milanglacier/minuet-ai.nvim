local api = vim.api

local M = {}

---@class minuet.DuetEditEvent
---@field bufnr integer
---@field filename string home-relative buffer name ('~'-shortened), or '[No Name]'
---@field diff string unified diff hunks without file headers or trailing newline
---@field text string fully formatted prompt block for this event

---@class minuet.DuetEditBufferState
---@field snapshot_file string temp file holding the baseline text
---@field pending_file string temp file the next burst is written into
---@field changedtick integer changedtick when snapshot_file was written
---@field timer uv.uv_timer_t? lazily created debounce timer
---@field process vim.SystemObj? in-flight diff process
---@field orphaned boolean? the buffer died while this state's final diff was in flight

local internal = {
    ---@type table<integer, minuet.DuetEditBufferState>
    buffers = {},
    ---States whose buffer died with a diff still in flight. They are no
    ---longer reachable through `buffers`, so reset needs this set to cancel
    ---them; a completing orphan removes itself.
    ---@type table<minuet.DuetEditBufferState, true>
    orphans = {},
    ---@type minuet.DuetEditEvent[] oldest first
    events = {},
    total_chars = 0,
    -- Set when the diff program vanishes mid-session, so the recorder fails
    -- once with a notification instead of retrying on every burst.
    disabled = false,
}

---@return minuet.DuetRecentEdits?
local function get_config()
    local minuet = require 'minuet'
    return minuet.config and minuet.config.duet.recent_edits or nil
end

---@param bufnr integer
---@return boolean
local function is_trackable(bufnr)
    local config = get_config()
    if internal.disabled or not config or not config.enabled then
        return false
    end

    if not api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].buftype ~= '' or not vim.bo[bufnr].modifiable then
        return false
    end

    return api.nvim_buf_get_offset(bufnr, api.nvim_buf_line_count(bufnr)) <= config.max_buffer_size
end

---Cancel a state's in-flight diff, if any, and delete its snapshot files.
---Nils the process field before killing: the late on_exit callback compares
---its process object against state.process and reduces to a no-op after this
---swap, so a cancelled diff can never record an event.
---@param state minuet.DuetEditBufferState
local function cancel_state(state)
    local process = state.process
    state.process = nil
    if process then
        process:kill(15)
    end
    vim.uv.fs_unlink(state.snapshot_file)
    vim.uv.fs_unlink(state.pending_file)
end

---Stop tracking a buffer. With `finalize` (buffer unload/wipeout after the
---BufLeave flush) an in-flight diff is left running as an orphan so the
---final burst still gets recorded; otherwise (reload, reset, guard failures)
---the diff is cancelled and nothing is recorded.
---@param bufnr integer
---@param finalize boolean?
local function drop_buffer_state(bufnr, finalize)
    local state = internal.buffers[bufnr]
    if not state then
        return
    end
    internal.buffers[bufnr] = nil

    if state.timer then
        state.timer:stop()
        state.timer:close()
    end

    if finalize and state.process then
        -- The on_exit callback records the orphan's event and deletes the
        -- files. Registered in the orphan set so reset can still cancel it.
        state.orphaned = true
        internal.orphans[state] = true
        return
    end

    cancel_state(state)
end

---Write the whole buffer to a temp file. writefile terminates every line
---with a newline, so the file always ends with one - the same
---last-line-is-complete convention the old in-memory snapshot used.
---@param bufnr integer
---@param path string
---@return integer? changedtick captured just before the write, nil when the write failed
local function write_snapshot(bufnr, path)
    local changedtick = api.nvim_buf_get_changedtick(bufnr)
    -- writefile signals failure both by raising (caught by the pcall) and by
    -- returning -1; check both, since diffing against a bad snapshot would
    -- record a wrong burst rather than skip one.
    local ok, ret = pcall(vim.fn.writefile, api.nvim_buf_get_lines(bufnr, 0, -1, false), path)
    return (ok and ret == 0) and changedtick or nil
end

---Start tracking a buffer by snapshotting it to a temp file without emitting
---an event. No-op if the buffer is already tracked or fails the guards.
---@param bufnr integer
function M.track(bufnr)
    if internal.buffers[bufnr] or not is_trackable(bufnr) then
        return
    end

    -- tempname() paths live in Neovim's private 0700 temp directory, which
    -- is removed when Neovim exits - stranded snapshots cannot outlive the
    -- session even if a buffer dies without its autocmds firing.
    local snapshot_file = vim.fn.tempname()
    local changedtick = write_snapshot(bufnr, snapshot_file)
    if not changedtick then
        vim.uv.fs_unlink(snapshot_file)
        return
    end

    internal.buffers[bufnr] = {
        snapshot_file = snapshot_file,
        pending_file = vim.fn.tempname(),
        changedtick = changedtick,
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

---@param display_name string
---@param diff string
---@return string
local function format_event(display_name, diff)
    return string.format('User edited "%s":\n\n```diff\n%s\n```', display_name, diff)
end

---@param bufnr integer
---@param filename string captured when the diff was started, since the
---buffer may no longer exist by the time an orphaned diff completes
---@param unified string
local function push_event(bufnr, filename, unified)
    local config = get_config()
    if not config then
        return
    end

    -- Cap the diff so the formatted event on its own also fits
    -- max_total_chars; otherwise the eviction loop below would immediately
    -- evict the event it just pushed, silently keeping the history empty.
    local overhead = #format_event(filename, '')
    local bounded = truncate_to_hunks(unified, math.min(config.max_event_chars, config.max_total_chars - overhead))
    if not bounded then
        return
    end

    local text = format_event(filename, bounded)

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

---Restart the debounce timer so the pending burst flushes after the
---configured idle pause.
---@param bufnr integer
---@param state minuet.DuetEditBufferState
local function arm_debounce(bufnr, state)
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

---Start an async flush of the pending edit burst: snapshot the current text
---into the pending temp file and spawn the external diff against the
---baseline snapshot. The completion callback records an event and rotates
---the snapshot files. No-op while a diff for this buffer is already in
---flight - the dirty changedtick makes the next flush retry the burst.
---Establishes the baseline without emitting an event when the buffer is not
---tracked yet.
---@param bufnr integer
local function start_flush(bufnr)
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

    if state.process then
        return
    end

    if api.nvim_buf_get_changedtick(bufnr) == state.changedtick then
        return
    end

    local config = get_config()
    if not config then
        return
    end

    local pending_tick = write_snapshot(bufnr, state.pending_file)
    if not pending_tick then
        return
    end

    local name = api.nvim_buf_get_name(bufnr)
    -- Home-relative (rather than cwd-relative) names keep the history
    -- unambiguous when the cwd changes between flushes (e.g. project.nvim):
    -- the same file never appears under two names, and same-named files from
    -- different project roots never collide.
    local filename = name == '' and '[No Name]' or vim.fn.fnamemodify(name, ':~')

    ---@type vim.SystemObj?
    local process

    ---@param result vim.SystemCompleted
    ---@return string? unified diff hunks, nil when the output is unusable
    local function extract_hunks(result)
        if result.signal ~= 0 or result.code ~= 1 then
            return nil
        end
        -- Strip the `--- OLD` / `+++ NEW` file headers (they leak temp
        -- paths into the prompt) and the trailing newline.
        local unified = (result.stdout or ''):gsub('^%-%-%-[^\n]*\n%+%+%+[^\n]*\n', ''):gsub('\n$', '')
        return unified:find '^@@' and unified or nil
    end

    local function on_exit(result)
        vim.schedule(function()
            -- Cancelled (buffer reloaded, reset, or guard failure) while in
            -- flight; vim.system disposes its own pipes, and the canceller
            -- owns the files - nothing to clean up here.
            if state.process ~= process then
                return
            end
            state.process = nil

            if state.orphaned then
                -- The buffer died after this final burst's pending file was
                -- written (BufLeave flush, then unload/wipeout): record the
                -- burst, then delete the files nobody else owns anymore.
                internal.orphans[state] = nil
                local unified = extract_hunks(result)
                if unified then
                    push_event(bufnr, filename, unified)
                end
                vim.uv.fs_unlink(state.snapshot_file)
                vim.uv.fs_unlink(state.pending_file)
                return
            end

            if not is_trackable(bufnr) then
                drop_buffer_state(bufnr)
                return
            end

            local utils = require 'minuet.utils'

            if result.signal ~= 0 or result.code > 1 then
                -- No rotation: the changedtick stays dirty, so the next
                -- flush retries this burst.
                utils.notify(
                    string.format(
                        'minuet duet recent-edits diff failed (code %d, signal %d): %s',
                        result.code,
                        result.signal,
                        vim.trim(result.stderr or '')
                    ),
                    'verbose',
                    vim.log.levels.INFO
                )
                return
            end

            -- Always rotate, even when no event is recorded, so the next
            -- burst is diffed against the text the user actually sees now.
            state.snapshot_file, state.pending_file = state.pending_file, state.snapshot_file
            state.changedtick = pending_tick

            if result.code == 1 then
                local unified = extract_hunks(result)
                if unified then
                    push_event(bufnr, filename, unified)
                else
                    -- Binary or otherwise unparseable output: skipping but
                    -- rotating is deliberate - retrying would loop forever.
                    utils.notify(
                        'minuet duet recent-edits: no hunks in diff output, burst skipped',
                        'verbose',
                        vim.log.levels.INFO
                    )
                end
            end

            -- Edits that arrived while the diff was running: re-arm the
            -- debounce so the burst flushes without waiting for the next
            -- TextChanged. Only reached on success - a failing diff must not
            -- re-arm itself into a retry loop.
            if api.nvim_buf_get_changedtick(bufnr) ~= state.changedtick then
                arm_debounce(bufnr, state)
            end
        end)
    end

    local ok, result = pcall(vim.system, {
        config.diff_program,
        '-U' .. config.diff_context_lines,
        state.snapshot_file,
        state.pending_file,
    }, { text = true, env = { LC_ALL = 'C' } }, on_exit)

    if not ok then
        -- The executable() check at setup passed, so the program vanished
        -- mid-session. Disable the recorder instead of failing on every
        -- burst.
        internal.disabled = true
        require('minuet.utils').notify(
            string.format(
                'minuet duet recent-edits recorder disabled: failed to run diff program "%s": %s',
                config.diff_program,
                result
            ),
            'error',
            vim.log.levels.ERROR
        )
        return
    end

    process = result
    state.process = result
end

---Flush the pending edit burst for a buffer: the burst is written to a temp
---file and diffed against the baseline snapshot by an external diff process,
---asynchronously; its completion callback records an event when the diff is
---non-empty and rotates the baseline. Establishes the baseline without
---emitting an event when the buffer is not tracked yet.
---
---With `opts.wait` the call additionally blocks, bounded by
---`recent_edits.flush_timeout` milliseconds, until no diff is in flight in
---any buffer, so a caller about to build a prompt sees the freshest possible
---history; past the deadline it returns anyway and the prompt is built with
---slightly stale history. A wedged diff can therefore never hang the caller.
---@param bufnr integer
---@param opts? { wait?: boolean }
function M.flush(bufnr, opts)
    start_flush(bufnr)

    local config = get_config()
    if not (opts and opts.wait) or not config then
        return
    end

    local deadline = vim.uv.hrtime() + config.flush_timeout * 1e6
    local starts = 1

    while true do
        local remaining = math.floor((deadline - vim.uv.hrtime()) / 1e6)
        if remaining <= 0 then
            return
        end

        -- Waiting on every buffer, not just bufnr, keeps cross-buffer
        -- chronology: a BufLeave flush of another buffer moments ago must
        -- land before this buffer's prompt is rendered. vim.wait pumps the
        -- event loop, so the scheduled on_exit callbacks run during the
        -- wait; re-entrant autocmd flushes are safe behind the in-flight
        -- guard in start_flush.
        local settled = vim.wait(remaining, function()
            for _, state in pairs(internal.buffers) do
                if state.process then
                    return false
                end
            end
            return true
        end, 5)

        if not settled then
            return
        end

        local state = internal.buffers[bufnr]
        if not state or starts >= 2 or api.nvim_buf_get_changedtick(bufnr) == state.changedtick then
            return
        end

        -- Edits arrived after the in-flight diff snapshotted its pending
        -- text; one follow-up flush captures the freshest burst within the
        -- same deadline. Capped so a persistently failing diff spawns at
        -- most twice per call instead of respawning in a loop.
        starts = starts + 1
        start_flush(bufnr)
    end
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

---Drop all events and buffer snapshots, cancel in-flight diffs (including
---orphans whose buffer already died), close all timers, and delete the
---snapshot temp files.
function M.reset()
    for bufnr in pairs(internal.buffers) do
        drop_buffer_state(bufnr)
    end
    for state in pairs(internal.orphans) do
        internal.orphans[state] = nil
        cancel_state(state)
    end
    internal.events = {}
    internal.total_chars = 0
    internal.disabled = false
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

    arm_debounce(bufnr, state)
end

---Register the recorder autocmds into the duet augroup. When the recorder is
---enabled but the configured diff program is not executable, notifies once
---and leaves the recorder off.
---@param augroup integer
function M.setup(augroup)
    local config = get_config()
    if config and config.enabled and vim.fn.executable(config.diff_program) ~= 1 then
        require('minuet.utils').notify(
            string.format(
                'minuet duet recent-edits recorder disabled: diff program "%s" is not executable.'
                    .. ' Install it or set duet.recent_edits.diff_program.',
                config.diff_program
            ),
            'warn',
            vim.log.levels.WARN
        )
        return
    end

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

    api.nvim_create_autocmd('BufLeave', {
        group = augroup,
        callback = function(info)
            M.flush(info.buf)
        end,
        desc = '[minuet.duet.edits] flush edit burst on buffer leave',
    })

    -- Dropping on unload (not just wipeout) bounds disk usage: without it
    -- every buffer visited in a session would keep a pair of snapshot files
    -- alive until Neovim exits. An unloaded buffer cannot be edited, and
    -- re-entering it reloads from disk and re-tracks via
    -- BufEnter/BufReadPost.
    api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
        group = augroup,
        callback = function(info)
            -- finalize: the BufLeave flush just before an unload may still
            -- have its diff in flight; it must record the final burst rather
            -- than be cancelled.
            drop_buffer_state(info.buf, true)
        end,
        desc = '[minuet.duet.edits] drop edit tracking state on buf unload',
    })

    -- The current buffer was opened before the autocmds above existed.
    M.track(api.nvim_get_current_buf())
end

return M
