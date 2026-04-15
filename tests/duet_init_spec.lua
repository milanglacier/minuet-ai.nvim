local helpers = require 'tests.helpers'

return {
    {
        name = 'duet.action.predict trims duplicated non-editable region text from the duet response',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                        before_region_filter_length = 3,
                        after_region_filter_length = 3,
                    },
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local pending_callback

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'before', 'return 1', 'after' }, { 2, 8 })

            duet.action.predict()
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')

            pending_callback [[<editable_region_start>
before
return 42<cursor_position>
after
<editable_region_end>]]

            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            duet.action.apply()

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'before', 'return 42', 'after' })
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 2, 8 })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.predict followed by apply updates the buffer and cursor',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local pending_callback
            local seen_context

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(context, callback)
                    seen_context = context
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

            duet.action.predict()

            helpers.expect_equal(seen_context.original_lines, { 'return 1' })
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')

            pending_callback [[<editable_region_start>
return 42<cursor_position>
<editable_region_end>]]

            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            duet.action.apply()

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 42' })
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 8 })
            helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after apply')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.predict discards stale provider responses',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local pending_callback

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

            duet.action.predict()
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 7' })

            pending_callback [[<editable_region_start>
return 42<cursor_position>
<editable_region_end>]]

            vim.wait(50, function()
                return false
            end, 10)

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 7' })
            helpers.expect_falsy(duet.action.is_visible(), 'stale duet preview should not render')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.dismiss clears the preview without changing the buffer',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local pending_callback

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

            duet.action.predict()
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')

            pending_callback [[<editable_region_start>
return 42<cursor_position>
<editable_region_end>]]

            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            duet.action.dismiss()

            helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after dismiss')
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 1' })

            duet.action.apply()

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 1' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.apply becomes a no-op after the preview is cleared by editing',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local pending_callback

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

            duet.action.predict()
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')

            pending_callback [[<editable_region_start>
return 42<cursor_position>
<editable_region_end>]]

            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 7' })
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr, modeline = false })

            helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after editing the buffer')

            duet.action.apply()

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 7' })

            helpers.delete_buffer(bufnr)
        end,
    },
}
