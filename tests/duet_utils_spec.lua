local helpers = require 'tests.helpers'

return {
    {
        name = 'duet.utils renders system prompts and chat input templates',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.duet.utils'

            local system_prompt = utils.make_system_prompt {
                template = 'before {{{alpha}}} {{{beta}}} {{{missing}}}',
                alpha = 'A',
                beta = function()
                    return 'B'
                end,
            }
            local shot = utils.make_duet_llm_shot({
                before = 'left',
                after = 'right',
            }, {
                template = '{{{before}}}<cursor>{{{after}}}{{{missing}}}',
                before = function(context)
                    return context.before
                end,
                after = function(context)
                    return context.after
                end,
            })

            helpers.expect_equal(system_prompt, 'before A B ')
            helpers.expect_equal(shot, 'left<cursor>right')
        end,
    },
    {
        name = 'duet.utils parses a valid duet response',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.duet.utils'
            local parsed, err = utils.parse_duet_response [[<editable_region>
foo
ba<cursor_position/>r
</editable_region>]]

            helpers.expect_equal(err, nil)
            helpers.expect_equal(parsed, {
                lines = { 'foo', 'bar' },
                cursor = {
                    row_offset = 1,
                    col = 2,
                },
            })
        end,
    },
    {
        name = 'duet.utils preserves leading empty line when no duplicated left context is trimmed',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.duet.utils'
            local parsed, err = utils.parse_duet_response [[<editable_region>

foo
ba<cursor_position/>r
</editable_region>]]

            helpers.expect_equal(err, nil)
            helpers.expect_equal(parsed, {
                lines = { '', 'foo', 'bar' },
                cursor = {
                    row_offset = 2,
                    col = 2,
                },
            })
        end,
    },
    {
        name = 'duet.utils filters duplicated non-editable region text before parsing cursor position',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        before_region_filter_length = 3,
                        after_region_filter_length = 3,
                    },
                },
            }

            local utils = helpers.reload 'minuet.duet.utils'
            local parsed, err = utils.parse_duet_response(
                [[<editable_region>
prefix line
foo
ba<cursor_position/>r
suffix line
</editable_region>]],
                {
                    non_editable_region_before = 'prefix line',
                    non_editable_region_after = 'suffix line',
                }
            )

            helpers.expect_equal(err, nil)
            helpers.expect_equal(parsed, {
                lines = { 'foo', 'bar' },
                cursor = {
                    row_offset = 1,
                    col = 2,
                },
            })
        end,
    },
    {
        name = 'duet.utils clamps cursor to replacement end when it falls inside duplicated right context',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        before_region_filter_length = 3,
                        after_region_filter_length = 3,
                    },
                },
            }

            local utils = helpers.reload 'minuet.duet.utils'
            local parsed, err = utils.parse_duet_response(
                [[<editable_region>
prefix line
foo
bar
suffix<cursor_position/> line
</editable_region>]],
                {
                    non_editable_region_before = 'prefix line',
                    non_editable_region_after = 'suffix line',
                }
            )

            helpers.expect_equal(err, nil)
            helpers.expect_equal(parsed, {
                lines = { 'foo', 'bar' },
                cursor = {
                    row_offset = 1,
                    col = 3,
                },
            })
        end,
    },
    {
        name = 'duet.utils preserves trailing empty line after trimming duplicated left context',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        before_region_filter_length = 3,
                        after_region_filter_length = 0,
                    },
                },
            }

            local utils = helpers.reload 'minuet.duet.utils'
            local parsed, err = utils.parse_duet_response(
                [[<editable_region>
prefix line
foo
bar<cursor_position/>

</editable_region>]],
                {
                    non_editable_region_before = 'prefix line',
                }
            )

            helpers.expect_equal(err, nil)
            helpers.expect_equal(parsed, {
                lines = { 'foo', 'bar', '' },
                cursor = {
                    row_offset = 1,
                    col = 3,
                },
            })
        end,
    },
    {
        name = 'duet.utils rejects responses with an invalid marker layout',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.duet.utils'
            local parsed, err = utils.parse_duet_response [[<editable_region>
foo
</editable_region>]]

            helpers.expect_equal(parsed, nil)
            helpers.expect_match(err, 'cursor marker')
        end,
    },
}
