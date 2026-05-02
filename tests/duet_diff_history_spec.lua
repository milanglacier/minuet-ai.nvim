local helpers = require 'tests.helpers'

return {
    {
        name = 'duet.diff_history.build returns empty string when no undo history',
        run = function()
            helpers.setup_root_config {
                duet = {
                    diff_history = {
                        max_entries = 5,
                        max_chars = 2000,
                        time_gap = 30,
                    },
                },
            }

            local diff_history = helpers.reload 'minuet.duet.diff_history'
            local bufnr = helpers.create_buffer({ 'hello', 'world' }, { 1, 0 })

            local result = diff_history.build(bufnr, require('minuet').config.duet)

            helpers.expect_equal(result, '')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.diff_history.build returns a diff after buffer modifications',
        run = function()
            helpers.setup_root_config {
                duet = {
                    diff_history = {
                        max_entries = 5,
                        max_chars = 2000,
                        -- Use time_gap=0 so all undo entries are treated as separate groups
                        time_gap = 0,
                    },
                },
            }

            local diff_history = helpers.reload 'minuet.duet.diff_history'
            local bufnr = helpers.create_buffer({ 'line one', 'line two', 'line three' }, { 2, 0 })

            -- Make an edit to create undo history
            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'line TWO' })

            local result = diff_history.build(bufnr, require('minuet').config.duet)

            helpers.expect_truthy(result ~= '', 'expected non-empty diff')
            helpers.expect_match(result, 'Recent edits')
            helpers.expect_match(result, 'line two')
            helpers.expect_match(result, 'line TWO')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.diff_history.build restores buffer to original state after undo walk',
        run = function()
            helpers.setup_root_config {
                duet = {
                    diff_history = {
                        max_entries = 5,
                        max_chars = 2000,
                        time_gap = 0,
                    },
                },
            }

            local diff_history = helpers.reload 'minuet.duet.diff_history'
            local bufnr = helpers.create_buffer({ 'original' }, { 1, 0 })

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'modified' })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'final state' })

            diff_history.build(bufnr, require('minuet').config.duet)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            helpers.expect_equal(lines, { 'final state' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.diff_history.build respects max_chars truncation',
        run = function()
            helpers.setup_root_config {
                duet = {
                    diff_history = {
                        max_entries = 5,
                        max_chars = 50,
                        time_gap = 0,
                    },
                },
            }

            local diff_history = helpers.reload 'minuet.duet.diff_history'
            local bufnr = helpers.create_buffer({ 'a', 'b', 'c', 'd', 'e' }, { 1, 0 })

            -- Make a large edit to generate a long diff
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                'alpha_long_line_one',
                'bravo_long_line_two',
                'charlie_long_line_three',
                'delta_long_line_four',
                'echo_long_line_five',
            })

            local result = diff_history.build(bufnr, require('minuet').config.duet)

            -- The prefix "Recent edits (oldest first):\n" is added, but the diff portion should be truncated
            local diff_portion = result:sub(#'Recent edits (oldest first):\n' + 1)
            helpers.expect_truthy(#diff_portion <= 50, 'diff should be truncated to max_chars')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.diff_history.build groups edits by time gap',
        run = function()
            helpers.setup_root_config {
                duet = {
                    diff_history = {
                        max_entries = 5,
                        max_chars = 4000,
                        -- Large time gap so all edits within the test are in the same group
                        time_gap = 9999,
                    },
                },
            }

            local diff_history = helpers.reload 'minuet.duet.diff_history'
            local bufnr = helpers.create_buffer({ 'start' }, { 1, 0 })

            -- Multiple rapid edits (same time gap group)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'step1' })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'step2' })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'step3' })

            local result = diff_history.build(bufnr, require('minuet').config.duet)

            -- With a large time_gap, all entries are in one group.
            -- The diff should show a single transition from 'start' to 'step3'
            helpers.expect_truthy(result ~= '', 'expected non-empty diff')
            helpers.expect_match(result, 'start')
            helpers.expect_match(result, 'step3')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.diff_history.build caps boundaries at max_entries',
        run = function()
            helpers.setup_root_config {
                duet = {
                    diff_history = {
                        max_entries = 2,
                        max_chars = 4000,
                        time_gap = 0,
                    },
                },
            }

            local diff_history = helpers.reload 'minuet.duet.diff_history'
            local bufnr = helpers.create_buffer({ 'v0' }, { 1, 0 })

            -- Create many undo entries
            for i = 1, 10 do
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'v' .. i })
            end

            local result = diff_history.build(bufnr, require('minuet').config.duet)

            -- With max_entries=2 and time_gap=0, we get at most 2 boundary snapshots
            -- resulting in at most 3 diff segments (2 boundaries + current = 3 snapshots, 2 diffs)
            -- Count the number of @@ hunk headers as a proxy for diff segments
            local hunk_count = 0
            for _ in result:gmatch('@@ ') do
                hunk_count = hunk_count + 1
            end

            -- At most 3 hunks (2 boundaries + current state = up to 3 diffs between pairs)
            helpers.expect_truthy(hunk_count <= 3, 'expected at most 3 diff hunks with max_entries=2')

            helpers.delete_buffer(bufnr)
        end,
    },
}
