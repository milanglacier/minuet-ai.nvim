local helpers = require 'tests.helpers'

return {
    {
        name = 'duet.context.build captures the editable region around the cursor',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 1,
                        lines_after = 1,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'zero', 'one', 'two', 'three' }, { 3, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'zero')
            helpers.expect_equal(built.editable_region_before_cursor, 'one\ntw')
            helpers.expect_equal(built.editable_region_after_cursor, 'o\nthree')
            helpers.expect_equal(built.non_editable_region_after, '')
            helpers.expect_equal(built.original_lines, { 'one', 'two', 'three' })
            helpers.expect_equal(built.range, {
                start_row = 1,
                end_row = 4,
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build handles an empty buffer',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 2,
                        lines_after = 2,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, '')
            helpers.expect_equal(built.editable_region_before_cursor, '')
            helpers.expect_equal(built.editable_region_after_cursor, '')
            helpers.expect_equal(built.non_editable_region_after, '')
            helpers.expect_equal(built.original_lines, { '' })
            helpers.expect_equal(built.range, {
                start_row = 0,
                end_row = 1,
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build keeps non-editable regions within the context window unchanged',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    non_editable_region = {
                        context_window = 100,
                        context_ratio = 0.75,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'alpha', 'edit', 'omega' }, { 2, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'alpha')
            helpers.expect_equal(built.editable_region_before_cursor, 'ed')
            helpers.expect_equal(built.editable_region_after_cursor, 'it')
            helpers.expect_equal(built.non_editable_region_after, 'omega')
            helpers.expect_equal(built.original_lines, { 'edit' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build truncates only the non-editable region before the editable region',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    non_editable_region = {
                        context_window = 20,
                        context_ratio = 0.75,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'before-one', 'before-two', 'before-three', 'edit', 'x' }, { 4, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'before-three')
            helpers.expect_equal(built.editable_region_before_cursor, 'ed')
            helpers.expect_equal(built.editable_region_after_cursor, 'it')
            helpers.expect_equal(built.non_editable_region_after, 'x')
            helpers.expect_equal(built.original_lines, { 'edit' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build truncates only the non-editable region after the editable region',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    non_editable_region = {
                        context_window = 20,
                        context_ratio = 0.75,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'b', 'edit', 'after-one', 'after-two', 'after-three' }, { 2, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'b')
            helpers.expect_equal(built.editable_region_before_cursor, 'ed')
            helpers.expect_equal(built.editable_region_after_cursor, 'it')
            helpers.expect_equal(built.non_editable_region_after, 'after-one')
            helpers.expect_equal(built.original_lines, { 'edit' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build truncates both non-editable regions using context ratio',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    non_editable_region = {
                        context_window = 40,
                        context_ratio = 0.75,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({
                'before-one',
                'before-two',
                'before-three',
                'edit',
                'after-one',
                'after-two',
                'after-three',
            }, { 4, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'before-two\nbefore-three')
            helpers.expect_equal(built.editable_region_before_cursor, 'ed')
            helpers.expect_equal(built.editable_region_after_cursor, 'it')
            helpers.expect_equal(built.non_editable_region_after, 'after-one')
            helpers.expect_equal(built.original_lines, { 'edit' })

            helpers.delete_buffer(bufnr)
        end,
    },
}
