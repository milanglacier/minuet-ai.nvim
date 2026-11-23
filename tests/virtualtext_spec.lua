local helpers = require 'tests.helpers'

---@param suggestions string[]
---@param keys string
---@param open_popup? boolean
local function accept_with_keys(suggestions, keys, open_popup)
    helpers.setup_root_config {
        provider = 'test',
        virtualtext = {
            keymap = {
                next = '<F5>',
                accept_word = '<F6>',
                accept_line = '<F7>',
                accept = '<F8>',
            },
        },
    }
    package.loaded['minuet.backends.test'] = {
        complete = function(_, callback)
            callback(suggestions)
        end,
    }
    local virtualtext = require 'minuet.virtualtext'
    virtualtext.setup()
    local bufnr = helpers.create_buffer { '' }

    local completeopt = vim.o.completeopt
    local popup_opened = false
    if open_popup then
        vim.o.completeopt = 'menuone,noselect'
        vim.keymap.set('i', '<F10>', function()
            vim.fn.complete(1, { 'other', 'over' })
            popup_opened = vim.fn.pumvisible() == 1
        end)
    end

    local result
    vim.keymap.set('i', '<F9>', function()
        vim.schedule(function()
            result = {
                lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                cursor = vim.api.nvim_win_get_cursor(0),
                visible = virtualtext.action.is_visible(),
                popup_visible = vim.fn.pumvisible() == 1,
            }
            vim.api.nvim_feedkeys(vim.keycode '<Esc>', 'in', false)
        end)
    end)

    local start = open_popup and 'i<F5><F10>' or 'i<F5>'
    vim.api.nvim_feedkeys(vim.keycode(start .. keys .. '<F9>'), 'mxt!', false)

    vim.api.nvim_clear_autocmds { group = virtualtext.augroup }
    if open_popup then
        vim.keymap.del('i', '<F10>')
        vim.o.completeopt = completeopt
    end
    for _, key in ipairs { '<F5>', '<F6>', '<F7>', '<F8>', '<F9>' } do
        vim.keymap.del('i', key)
    end
    helpers.delete_buffer(bufnr)
    assert(result, 'failed to capture the buffer in Insert mode')
    assert(not open_popup or popup_opened, 'native completion menu did not open')
    return result
end

return {
    {
        name = 'virtual text accepts the next two words when both keys are queued',
        run = function()
            local result = accept_with_keys({ 'one two three' }, '<F6><F6>')
            helpers.expect_equal(result.lines, { 'one two ' })
            helpers.expect_equal(result.cursor, { 1, 8 })
            helpers.expect_truthy(result.visible)
        end,
    },
    {
        name = 'virtual text accepts the next two lines when both keys are queued',
        run = function()
            local result = accept_with_keys({ 'one\n  two\n  three' }, '<F7><F7>')
            helpers.expect_equal(result.lines, { 'one', '  two' })
            helpers.expect_equal(result.cursor, { 2, 5 })
            helpers.expect_truthy(result.visible)
        end,
    },
    {
        name = 'virtual text can accept a word and then the rest of the suggestion',
        run = function()
            local result = accept_with_keys({ 'one two\n  three' }, '<F6><F8>')
            helpers.expect_equal(result.lines, { 'one two', '  three' })
            helpers.expect_equal(result.cursor, { 2, 7 })
            helpers.expect_falsy(result.visible)
        end,
    },
    {
        name = 'virtual text closes the native completion menu before accepting queued words',
        run = function()
            local result = accept_with_keys({ 'one two three' }, '<F6><F6>', true)
            helpers.expect_equal(result.lines, { 'one two ' })
            helpers.expect_falsy(result.popup_visible)
        end,
    },
}
