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
}
