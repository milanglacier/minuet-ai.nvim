local api = vim.api
local context = require 'minuet.duet.context'
local preview = require 'minuet.duet.preview'
local utils = require 'minuet.duet.utils'

local M = {}

M.augroup = api.nvim_create_augroup('MinuetDuet', { clear = true })

local internal = {
    states = {},
    request_seq = 0,
}

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

local function predict()
    local bufnr = api.nvim_get_current_buf()
    local state = get_state(bufnr)

    clear_state(bufnr, state)

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
    local bufnr = api.nvim_get_current_buf()
    clear_state(bufnr, get_state(bufnr))
end

---@param info { buf: integer }
local function on_text_changed(info)
    local state = internal.states[info.buf]
    if not state then
        return
    end

    clear_state(info.buf, state)
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
}

M.action = action

function M.setup()
    api.nvim_clear_autocmds { group = M.augroup }

    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
        group = M.augroup,
        callback = on_text_changed,
        desc = '[minuet.duet] clear preview on text change',
    })

    api.nvim_create_autocmd('BufWipeout', {
        group = M.augroup,
        callback = function(info)
            internal.states[info.buf] = nil
        end,
        desc = '[minuet.duet] clear state on buf wipeout',
    })
end

return M
