local helpers = require 'tests.helpers'

return {
    {
        name = 'utils.remove_spaces skips whitespace-only completion items',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'

            helpers.expect_equal(utils.remove_spaces { '  foo  ', '   ', '\n\t', ' bar' }, { 'foo', 'bar' })
        end,
    },
    {
        name = 'utils.filter_text keeps leading newline while matching duplicated context',
        run = function()
            helpers.setup_root_config {
                before_cursor_filter_length = 2,
                after_cursor_filter_length = 0,
            }

            local utils = helpers.reload 'minuet.utils'

            helpers.expect_equal(
                utils.filter_text('\nfoo', {
                    lines_before = 'foo',
                    lines_after = '',
                }),
                '\nfoo'
            )
        end,
    },
}
