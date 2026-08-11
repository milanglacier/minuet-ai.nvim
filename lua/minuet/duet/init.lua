local api = vim.api
local context = require 'minuet.duet.context'
local edits = require 'minuet.duet.edits'
local preview = require 'minuet.duet.preview'
local utils = require 'minuet.duet.utils'
local shared_utils = require 'minuet.utils'

local M = {}

M.augroup = api.nvim_create_augroup('MinuetDuet', { clear = true })

local internal = {
    states = {},
    request_seq = 0,
    timer = nil,
}

local function stop_timer()
    if internal.timer and not internal.timer:is_closing() then
        internal.timer:stop()
        internal.timer:close()
        internal.timer = nil
    end
end

local function get_state(bufnr)
    local state = internal.states[bufnr]
    if not state then
        state = {}
        internal.states[bufnr] = state
    end

    return state
end

local function clear_state(bufnr, state)
    state = state or get_state(bufnr)
    preview.clear(bufnr, state)
    state.pending_seq = nil
    state.changedtick = nil
    state.range = nil
    state.original_lines = nil
    state.proposed_lines = nil
    state.proposed_cursor = nil
end

local function current_provider()
    return require('minuet').config.duet.provider
end

---@param opts? { flush_timeout?: integer } flush_timeout bounds the recent-edits wait in milliseconds; defaults to recent_edits.flush_timeout
local function predict(opts)
    stop_timer()

    local bufnr = api.nvim_get_current_buf()
    local state = get_state(bufnr)

    clear_state(bufnr, state)

    -- With recent_edits.enabled = 'lazy' the recorder is set up on the first
    -- prediction rather than at plugin setup, so users who never invoke duet
    -- pay nothing for it. No-op when already set up or disabled.
    edits.ensure_setup()

    -- Record edits made since the last idle flush so the freshest burst is
    -- part of the prompt's recent-edits history; wait (bounded) for the
    -- in-flight diffs so the history is as fresh as possible.
    edits.flush(bufnr, { wait = true, timeout = opts and opts.flush_timeout })

    local current_context = context.build(bufnr)
    local provider_name = current_provider()
    local ok, backend = pcall(require, 'minuet.duet.backends.' .. provider_name)

    if not ok then
        utils.notify('Minuet duet provider is not supported: ' .. provider_name, 'error', vim.log.levels.ERROR)
        return
    end

    internal.request_seq = internal.request_seq + 1
    local request_seq = internal.request_seq
    state.pending_seq = request_seq

    utils.notify('Minuet duet started', 'verbose', vim.log.levels.INFO)

    backend.complete(current_context, function(text)
        vim.schedule(function()
            if not api.nvim_buf_is_loaded(bufnr) or state.pending_seq ~= request_seq then
                return
            end

            state.pending_seq = nil

            if not text then
                return
            end

            if utils.get_changedtick(bufnr) ~= current_context.changedtick then
                utils.notify(
                    'Minuet duet result arrived after the buffer changed; discarded stale preview.',
                    'verbose',
                    vim.log.levels.INFO
                )
                return
            end

            local parsed, err = utils.parse_duet_response(text, current_context)
            if not parsed then
                utils.notify('Minuet duet returned invalid output: ' .. err, 'warn', vim.log.levels.WARN)
                return
            end

            state.changedtick = current_context.changedtick
            state.range = current_context.range
            state.original_lines = current_context.original_lines
            state.proposed_lines = parsed.lines
            state.proposed_cursor = parsed.cursor

            preview.render(bufnr, state)
        end)
    end)
end

local function apply()
    local bufnr = api.nvim_get_current_buf()
    local state = get_state(bufnr)

    if not state.proposed_lines or not state.range or not state.proposed_cursor then
        utils.notify('No Minuet duet prediction to apply.', 'warn', vim.log.levels.WARN)
        return
    end

    if utils.get_changedtick(bufnr) ~= state.changedtick then
        clear_state(bufnr, state)
        utils.notify('Minuet duet prediction is stale and has been discarded.', 'warn', vim.log.levels.WARN)
        return
    end

    api.nvim_buf_set_lines(bufnr, state.range.start_row, state.range.end_row, false, state.proposed_lines)

    local target_row = state.range.start_row + state.proposed_cursor.row_offset + 1
    local target_line = api.nvim_buf_get_lines(bufnr, target_row - 1, target_row, false)[1] or ''
    local target_col = math.min(state.proposed_cursor.col, #target_line)

    api.nvim_win_set_cursor(0, { target_row, target_col })

    clear_state(bufnr, state)
end

local function dismiss()
    stop_timer()
    local bufnr = api.nvim_get_current_buf()
    clear_state(bufnr, get_state(bufnr))
end

---Debounced automatic prediction: each text change restarts the timer, so a
---prediction only fires after the configured idle gap. The guards run at
---fire time because the buffer, mode, or completion menu may have changed
---during the delay.
---@param bufnr integer
local function schedule(bufnr)
    stop_timer()

    local config = require('minuet').config

    internal.timer = vim.defer_fn(function()
        if
            bufnr ~= api.nvim_get_current_buf()
            or not api.nvim_buf_is_loaded(bufnr)
            or vim.bo[bufnr].buftype ~= ''
            or not vim.bo[bufnr].modifiable
            or shared_utils.completion_menu_visible()
            or not shared_utils.run_hooks_until_failure(config.enable_predicates)
        then
            return
        end

        predict { flush_timeout = config.duet.auto_trigger.flush_timeout }
    end, config.duet.auto_trigger.debounce)
end

---@param info { buf: integer }
local function on_text_changed(info)
    local state = internal.states[info.buf]
    if state then
        clear_state(info.buf, state)
    end

    if vim.b[info.buf].minuet_duet_auto_trigger then
        schedule(info.buf)
    end
end

local action = {
    predict = predict,
    apply = apply,
    dismiss = dismiss,
    is_visible = function()
        local bufnr = api.nvim_get_current_buf()
        local state = get_state(bufnr)
        return preview.is_visible(bufnr, state)
    end,
    enable_auto_trigger = function()
        vim.b.minuet_duet_auto_trigger = true
        vim.notify('Minuet Duet auto trigger enabled', vim.log.levels.INFO)
    end,
    disable_auto_trigger = function()
        vim.b.minuet_duet_auto_trigger = false
        vim.notify('Minuet Duet auto trigger disabled', vim.log.levels.INFO)
    end,
    toggle_auto_trigger = function()
        vim.b.minuet_duet_auto_trigger = not vim.b.minuet_duet_auto_trigger
        vim.notify(
            'Minuet Duet auto trigger ' .. (vim.b.minuet_duet_auto_trigger and 'enabled' or 'disabled'),
            vim.log.levels.INFO
        )
    end,
}

M.action = action

function M.setup()
    api.nvim_clear_autocmds { group = M.augroup }

    local config = require('minuet').config
    if #config.duet.auto_trigger.auto_trigger_ft > 0 then
        api.nvim_create_autocmd('FileType', {
            pattern = config.duet.auto_trigger.auto_trigger_ft,
            callback = function()
                if not vim.tbl_contains(config.duet.auto_trigger.auto_trigger_ignore_ft, vim.bo.ft) then
                    vim.b.minuet_duet_auto_trigger = true
                end
            end,
            group = M.augroup,
            desc = '[minuet.duet] filetype auto trigger',
        })
    end

    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
        group = M.augroup,
        callback = on_text_changed,
        desc = '[minuet.duet] clear preview and schedule auto trigger on text change',
    })

    api.nvim_create_autocmd('BufWipeout', {
        group = M.augroup,
        callback = function(info)
            internal.states[info.buf] = nil
        end,
        desc = '[minuet.duet] clear state on buf wipeout',
    })

    edits.setup()
end

return M
