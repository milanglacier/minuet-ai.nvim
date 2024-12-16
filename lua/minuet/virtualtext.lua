-- referenced from copilot.lua https://github.com/zbirenbaum/copilot.lua
local M = {}
local utils = require 'minuet.utils'
local api = vim.api

M.ns_id = api.nvim_create_namespace 'minuet.virtualtext'
M.augroup = api.nvim_create_augroup('MinuetVirtualText', { clear = true })

if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'MinuetVirtualText' })) then
    api.nvim_set_hl(0, 'MinuetVirtualText', { link = 'Comment' })
end

local internal = {
    augroup = M.augroup,
    ns_id = M.ns_id,
    extmark_id = 1,

    timer = nil,
    context = {},
    is_on_throttle = false,
}

local function should_auto_trigger()
    return vim.b.minuet_virtual_text_auto_trigger
end

local function completion_menu_visible()
    local has_cmp = pcall(require, 'cmp')
    local cmp_visible = false
    if has_cmp then
        local ok, _cmp_visible = pcall(function()
            return require('cmp').core.view:visible()
        end)

        if ok then
            cmp_visible = _cmp_visible
        end
    end

    return vim.fn.pumvisible() == 1 or cmp_visible
end

---@param bufnr? integer
---@return minuet_suggestions_context
local function get_ctx(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    if bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    local ctx = internal.context[bufnr]
    if not ctx then
        ctx = {}
        internal.context[bufnr] = ctx
    end
    return ctx
end

---@alias minuet_suggestions_context { suggestions?: string[], choice?: integer, shown_choices?: table<string, true> }
---@param ctx? minuet_suggestions_context
local function reset_ctx(ctx)
    ctx.suggestions = nil
    ctx.choice = nil
    ctx.shown_choices = nil
end

local function stop_timer()
    if internal.timer and not internal.timer:is_closing() then
        internal.timer:close()
        internal.timer = nil
    end
end

local function clear_preview()
    api.nvim_buf_del_extmark(0, internal.ns_id, internal.extmark_id)
end

---@param ctx? minuet_suggestions_context
local function get_current_suggestion(ctx)
    ctx = ctx or get_ctx()

    local ok, choice = pcall(function()
        if not vim.fn.mode():match '^[iR]' or not ctx.suggestions or #ctx.suggestions == 0 then
            return nil
        end

        local choice = ctx.suggestions[ctx.choice]

        return choice
    end)

    if ok then
        return choice
    end

    return nil
end

---@param ctx? minuet_suggestions_context
local function update_preview(ctx)
    ctx = ctx or get_ctx()

    local suggestion = get_current_suggestion(ctx)
    local display_lines = suggestion and vim.split(suggestion, '\n', { plain = true }) or {}

    clear_preview()

    if not suggestion or #display_lines == 0 or completion_menu_visible() then
        return
    end

    local annot = ''

    if ctx.suggestions and #ctx.suggestions > 1 then
        annot = '(' .. ctx.choice .. '/' .. #ctx.suggestions .. ')'
    end

    local cursor_col = vim.fn.col '.'
    local cursor_line = vim.fn.line '.'

    local extmark = {
        id = internal.extmark_id,
        virt_text = { { display_lines[1], 'MinuetVirtualText' } },
        virt_text_pos = 'inline',
    }

    if #display_lines > 1 then
        extmark.virt_lines = {}
        for i = 2, #display_lines do
            extmark.virt_lines[i - 1] = { { display_lines[i], 'MinuetVirtualText' } }
        end

        local last_line = #display_lines - 1
        extmark.virt_lines[last_line][1][1] = extmark.virt_lines[last_line][1][1] .. ' ' .. annot
    elseif #annot > 0 then
        extmark.virt_text[1][1] = extmark.virt_text[1][1] .. ' ' .. annot
    end

    extmark.hl_mode = 'combine'

    api.nvim_buf_set_extmark(0, internal.ns_id, cursor_line - 1, cursor_col - 1, extmark)

    if not ctx.shown_choices[suggestion] then
        ctx.shown_choices[suggestion] = true
    end
end

---@param ctx? minuet_suggestions_context
local function cleanup(ctx)
    ctx = ctx or get_ctx()
    stop_timer()
    reset_ctx(ctx)
    clear_preview()
end

local function trigger(bufnr)
    if bufnr ~= api.nvim_get_current_buf() or vim.fn.mode() ~= 'i' then
        return
    end

    utils.notify('Minuet virtual text started', 'verbose')

    local config = require('minuet').config

    local context = utils.get_context(utils.make_cmp_context())

    local provider = require('minuet.backends.' .. config.provider)

    provider.complete(context.lines_before, context.lines_after, function(data)
        data = utils.list_dedup(data or {})

        local ctx = get_ctx()
        ctx.suggestions = data
        ctx.choice = 1
        ctx.shown_choices = {}

        update_preview()
    end)
end

local function advance(count, ctx)
    if ctx ~= get_ctx() then
        return
    end

    ctx.choice = (ctx.choice + count) % #ctx.suggestions
    if ctx.choice < 1 then
        ctx.choice = #ctx.suggestions
    end

    update_preview(ctx)
end

local function schedule()
    if internal.is_on_throttle then
        return
    end

    stop_timer()

    local config = require('minuet').config
    local bufnr = api.nvim_get_current_buf()

    internal.timer = vim.defer_fn(function()
        if internal.is_on_throttle then
            return
        end

        internal.is_on_throttle = true
        vim.defer_fn(function()
            internal.is_on_throttle = false
        end, config.throttle)

        trigger(bufnr)
    end, config.debounce)
end

local action = {}

action.next = function()
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf())
        return
    end

    advance(1, ctx)
end

action.prev = function()
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf())
        return
    end

    advance(-1, ctx)
end

function action.accept(accept_line)
    local ctx = get_ctx()

    local suggestion = get_current_suggestion(ctx)
    if not suggestion or vim.fn.empty(suggestion) == 1 then
        return
    end

    local suggestions = vim.split(suggestion, '\n')

    if accept_line then
        suggestions = { suggestions[1] }
    end

    reset_ctx(ctx)

    clear_preview()

    local cursor = api.nvim_win_get_cursor(0)
    local line, col = cursor[1] - 1, cursor[2]

    vim.schedule_wrap(function()
        api.nvim_buf_set_text(0, line, col, line, col, suggestions)
        if #suggestions == 1 then
            -- move to eol. \15 is Ctrl-o
            api.nvim_feedkeys('\15$', 'n', false)
        else
            vim.cmd('normal! ' .. #suggestions - 1 .. 'j')
            api.nvim_feedkeys('\15$', 'n', false)
        end
    end)()
end

function action.accept_line()
    action.accept(true)
end

function action.dismiss()
    local ctx = get_ctx()
    cleanup(ctx)
end

function action.is_visible()
    return not not api.nvim_buf_get_extmark_by_id(0, internal.ns_id, internal.extmark_id, { details = false })[1]
end

function action.toggle_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = not should_auto_trigger()
    vim.notify(
        'Minuet Virtual Text will ' .. (should_auto_trigger() and 'auto' or 'not auto') .. ' trigger',
        vim.log.levels.INFO
    )
end

M.action = action

local autocmd = {}

function autocmd.on_insert_leave()
    cleanup()
end

function autocmd.on_buf_leave()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_leave()
    end
end

function autocmd.on_insert_enter()
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_buf_enter()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_enter()
    end
end

function autocmd.on_cursor_moved_i()
    local ctx = get_ctx()
    -- we don't cleanup immediately if the completion has arrived but not
    -- display yet.
    if ctx.shown_choices and next(ctx.shown_choices) then
        cleanup(ctx)
    end
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_cursor_hold_i()
    update_preview()
end

function autocmd.on_text_changed_p()
    action.on_cursor_moved_i()
end

function autocmd.on_complete_changed()
    cleanup()
end

---@param info { buf: integer }
function autocmd.on_buf_unload(info)
    internal.context[info.buf] = nil
end

local function create_autocmds()
    api.nvim_create_autocmd('InsertLeave', {
        group = internal.augroup,
        callback = autocmd.on_insert_leave,
        desc = '[minuet.virtualtext] insert leave',
    })

    api.nvim_create_autocmd('BufLeave', {
        group = internal.augroup,
        callback = autocmd.on_buf_leave,
        desc = '[minuet.virtualtext] buf leave',
    })

    api.nvim_create_autocmd('InsertEnter', {
        group = internal.augroup,
        callback = autocmd.on_insert_enter,
        desc = '[minuet.virtualtext] insert enter',
    })

    api.nvim_create_autocmd('BufEnter', {
        group = internal.augroup,
        callback = autocmd.on_buf_enter,
        desc = '[minuet.virtualtext] buf enter',
    })

    api.nvim_create_autocmd('CursorMovedI', {
        group = internal.augroup,
        callback = autocmd.on_cursor_moved_i,
        desc = '[minuet.virtualtext] cursor moved insert',
    })

    api.nvim_create_autocmd('TextChangedP', {
        group = internal.augroup,
        callback = autocmd.on_text_changed_p,
        desc = '[minuet.virtualtext] text changed pum',
    })

    api.nvim_create_autocmd('CompleteChanged', {
        group = internal.augroup,
        callback = autocmd.on_complete_changed,
        desc = '[minuet.virtualtext] complete changed',
    })

    api.nvim_create_autocmd('BufUnload', {
        group = internal.augroup,
        callback = autocmd.on_buf_unload,
        desc = '[minuet.virtualtext] buf unload',
    })
end

local function set_keymaps(keymap)
    if keymap.accept then
        vim.keymap.set('i', keymap.accept, action.accept, {
            desc = '[minuet.virtualtext] accept suggestion',
            silent = true,
        })
    end

    if keymap.accept_line then
        vim.keymap.set('i', keymap.accept_line, action.accept_line, {
            desc = '[minuet.virtualtext] accept suggestion (line)',
            silent = true,
        })
    end

    if keymap.next then
        vim.keymap.set('i', keymap.next, action.next, {
            desc = '[minuet.virtualtext] next suggestion',
            silent = true,
        })
    end

    if keymap.prev then
        vim.keymap.set('i', keymap.prev, action.prev, {
            desc = '[minuet.virtualtext] prev suggestion',
            silent = true,
        })
    end

    if keymap.dismiss then
        vim.keymap.set('i', keymap.dismiss, action.dismiss, {
            desc = '[minuet.virtualtext] dismiss suggestion',
            silent = true,
        })
    end
end

api.nvim_create_user_command('MinuetToggleVirtualText', function()
    M.action.toggle_auto_trigger()
end, { desc = '[minuet.virtualtext] toggle virtual text' })

function M.setup()
    local config = require('minuet').config

    if #config.virtualtext.auto_trigger_ft > 0 then
        api.nvim_create_autocmd('FileType', {
            pattern = config.virtualtext.auto_trigger_ft,
            callback = function(args)
                vim.b[args.buf].minuet_virtual_text_auto_trigger = true
            end,
            group = M.augroup,
            desc = 'minuet virtual text filetype auto trigger',
        })
    end

    create_autocmds()
    set_keymaps(config.virtualtext.keymap)
end

return M
