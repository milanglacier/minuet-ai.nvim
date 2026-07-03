local helpers = require 'tests.helpers'

-- helpers.create_buffer creates scratch buffers (buftype = 'nofile'), which
-- the recorder's trackability guard rejects. Recorder tests must turn the
-- buffer into a normal one before tracking it.
local function create_normal_buffer(lines, cursor)
    local bufnr = helpers.create_buffer(lines, cursor)
    vim.bo[bufnr].buftype = ''
    return bufnr
end

return {
    {
        name = 'duet.edits.flush records a tracked edit burst as a unified diff event',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 42' })
            edits.flush(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1)
            helpers.expect_equal(events[1].filename, '[No Name]')
            helpers.expect_match(events[1].diff, '^@@')
            helpers.expect_match(events[1].diff, '%-return 1')
            helpers.expect_match(events[1].diff, '%+return 42')
            helpers.expect_match(events[1].text, '^User edited "%[No Name%]":\n\n```diff\n')
            helpers.expect_match(events[1].text, '\n```$')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits.flush on an untracked buffer establishes the baseline without an event',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            edits.flush(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'first flush should only capture the baseline')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            edits.flush(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1)
            helpers.expect_match(events[1].diff, '%-return 2')
            helpers.expect_match(events[1].diff, '%+return 3')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits flushes a debounced burst after TextChanged and coalesces rapid changes',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        debounce = 20,
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr, modeline = false })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr, modeline = false })

            helpers.wait_until(function()
                return #edits.get_events() > 0
            end, 1000, 'debounced edit burst was not flushed')

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'rapid changes should coalesce into a single event')
            helpers.expect_match(events[1].diff, '%-return 1')
            helpers.expect_match(events[1].diff, '%+return 3')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits flushes immediately on InsertLeave',
        run = function()
            helpers.setup_root_config {}

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 42' })
            vim.api.nvim_exec_autocmds('InsertLeave', { buffer = bufnr, modeline = false })

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'InsertLeave should flush without waiting for the debounce')
            helpers.expect_match(events[1].diff, '%+return 42')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits re-baselines on BufReadPost so a reload is not recorded as a user edit',
        run = function()
            helpers.setup_root_config {}

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            -- Simulate a disk reload (:e!, autoread): the buffer content is
            -- replaced and BufReadPost fires afterwards.
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            vim.api.nvim_exec_autocmds('BufReadPost', { buffer = bufnr, modeline = false })

            edits.flush(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'a reload must not be recorded as a user edit')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            edits.flush(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1)
            helpers.expect_match(events[1].diff, '%-return 2', 'the baseline should be the reloaded content')
            helpers.expect_match(events[1].diff, '%+return 3')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits drops tracking state on BufUnload',
        run = function()
            helpers.setup_root_config {}

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_exec_autocmds('BufUnload', { buffer = bufnr, modeline = false })

            -- With the baseline dropped, the first flush only re-baselines;
            -- if the state had survived the unload this would emit an event.
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            edits.flush(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'unload should have dropped the baseline')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            edits.flush(bufnr)
            helpers.expect_equal(#edits.get_events(), 1, 'the buffer should be re-tracked after the unload')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits skips empty diffs but still resets the baseline',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 1' })
            edits.flush(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'a change reverted to the baseline should not emit an event')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            edits.flush(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1)
            helpers.expect_match(events[1].diff, '%-return 1')
            helpers.expect_match(events[1].diff, '%+return 3')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits keeps a chronological cross-buffer history with relative filenames',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            local bufnr_a = create_normal_buffer { 'local a = 1' }
            edits.track(bufnr_a)
            local bufnr_b = create_normal_buffer { 'local b = 1' }
            vim.api.nvim_buf_set_name(bufnr_b, 'duet_edits_spec_named.lua')
            edits.track(bufnr_b)

            vim.api.nvim_buf_set_lines(bufnr_a, 0, -1, false, { 'local a = 2' })
            edits.flush(bufnr_a)
            vim.api.nvim_buf_set_lines(bufnr_b, 0, -1, false, { 'local b = 2' })
            edits.flush(bufnr_b)

            local events = edits.get_events()
            helpers.expect_equal(#events, 2)
            helpers.expect_equal(events[1].filename, '[No Name]')
            helpers.expect_match(events[1].diff, '%+local a = 2')
            helpers.expect_equal(events[2].filename, 'duet_edits_spec_named.lua')
            helpers.expect_match(events[2].diff, '%+local b = 2')

            helpers.expect_match(edits.render(), 'local a = 2.*local b = 2', 'render should join events oldest first')

            helpers.delete_buffer(bufnr_a)
            helpers.delete_buffer(bufnr_b)
        end,
    },
    {
        name = 'duet.edits evicts the oldest events beyond max_events',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        max_events = 2,
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            for i = 2, 4 do
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return ' .. i })
                edits.flush(bufnr)
            end

            local events = edits.get_events()
            helpers.expect_equal(#events, 2)
            helpers.expect_match(events[1].diff, '%+return 3')
            helpers.expect_match(events[2].diff, '%+return 4')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits evicts the oldest events beyond max_total_chars',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        max_total_chars = 100,
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            edits.flush(bufnr)
            helpers.expect_equal(#edits.get_events(), 1)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            edits.flush(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'the oldest event should be evicted to fit the character budget')
            helpers.expect_match(events[1].diff, '%+return 3')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits drops a single burst larger than max_event_chars',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        max_event_chars = 10,
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 42' })
            edits.flush(bufnr)

            helpers.expect_equal(#edits.get_events(), 0, 'an oversized burst should be dropped')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits never tracks non-file buffers',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            local bufnr = helpers.create_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 42' })
            edits.flush(bufnr)

            helpers.expect_equal(#edits.get_events(), 0, 'scratch buffers should not produce edit events')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.predict flushes the pending burst into context.recent_edits',
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

            local seen_context

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(context, _)
                    seen_context = context
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 8 })
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 42' })

            duet.action.predict()

            helpers.expect_truthy(seen_context, 'backend did not receive a request')
            helpers.expect_match(seen_context.recent_edits, '%-return 1')
            helpers.expect_match(seen_context.recent_edits, '%+return 42')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet chat input template renders recent edits before the context',
        run = function()
            helpers.setup_root_config {}
            local utils = helpers.reload 'minuet.duet.utils'
            local chat_input = require('minuet').config.duet.provider_options.openai.chat_input

            local context = {
                non_editable_region_before = 'before',
                editable_region_before_cursor = 'left',
                editable_region_after_cursor = 'right',
                non_editable_region_after = 'after',
                recent_edits = '',
            }

            local rendered_without = utils.make_duet_llm_shot(context, chat_input)
            helpers.expect_match(rendered_without, '^before\n', 'empty history should leave no leading blank lines')

            context.recent_edits = 'User edited "foo.lua":\n\n```diff\n@@ -1 +1 @@\n-a\n+b\n```'
            local rendered_with = utils.make_duet_llm_shot(context, chat_input)

            helpers.expect_equal(
                rendered_with,
                context.recent_edits .. '\n\n' .. rendered_without,
                'history should be prepended, separated by a blank line'
            )
        end,
    },
}
