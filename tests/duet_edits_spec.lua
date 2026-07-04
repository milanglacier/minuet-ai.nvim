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
        name = 'duet.edits drops tracking state on a real :bunload and re-tracks from disk',
        run = function()
            helpers.setup_root_config {}

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local path = vim.fn.tempname() .. '.lua'
            vim.fn.writefile({ 'return 1' }, path)
            vim.cmd.edit(path)
            local bufnr = vim.api.nvim_get_current_buf()

            -- Park a scratch buffer in the window so the file buffer can be
            -- unloaded, then fire the real BufUnload via :bunload.
            local scratch = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_set_current_buf(scratch)
            vim.cmd(('bunload %d'):format(bufnr))

            -- Re-displaying the unloaded buffer reloads it from disk through
            -- the real BufReadPost/BufEnter chain, which must re-track it.
            vim.fn.writefile({ 'return 2' }, path)
            vim.api.nvim_set_current_buf(bufnr)

            edits.flush(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'the reload after unload must not be recorded as a user edit')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            edits.flush(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'the buffer should be re-tracked after the unload')
            helpers.expect_match(events[1].diff, '%-return 2', 'the baseline should be the reloaded disk content')
            helpers.expect_match(events[1].diff, '%+return 3')

            helpers.delete_buffer(bufnr)
            helpers.delete_buffer(scratch)
            vim.fn.delete(path)
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
        name = 'duet.edits keeps a chronological cross-buffer history with home-relative filenames',
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
            helpers.expect_equal(
                events[2].filename,
                vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr_b), ':~'),
                'filenames are stored home-relative'
            )
            helpers.expect_match(events[2].diff, '%+local b = 2')

            local rendered = edits.render()
            helpers.expect_match(rendered, 'local a = 2.*local b = 2', 'render should join events oldest first')
            helpers.expect_match(rendered, 'User edited ".*duet_edits_spec_named%.lua"')

            helpers.delete_buffer(bufnr_a)
            helpers.delete_buffer(bufnr_b)
        end,
    },
    {
        name = 'duet.edits names events home-relative, independent of the cwd',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            local root_a = vim.fn.tempname()
            local root_b = vim.fn.tempname()
            vim.fn.mkdir(root_a, 'p')
            vim.fn.mkdir(root_b, 'p')
            vim.fn.writefile({ 'return 1' }, root_a .. '/init.lua')
            vim.fn.writefile({ 'return 1' }, root_b .. '/init.lua')

            local original_cwd = vim.fn.getcwd()

            -- Same relative filename in two project roots, each flushed under
            -- a different cwd (a project.nvim-style chdir between edits).
            vim.cmd.cd(root_a)
            vim.cmd.edit(root_a .. '/init.lua')
            local bufnr_a = vim.api.nvim_get_current_buf()
            edits.track(bufnr_a)
            vim.api.nvim_buf_set_lines(bufnr_a, 0, -1, false, { 'return 2' })
            edits.flush(bufnr_a)

            vim.cmd.cd(root_b)
            vim.cmd.edit(root_b .. '/init.lua')
            local bufnr_b = vim.api.nvim_get_current_buf()
            edits.track(bufnr_b)
            vim.api.nvim_buf_set_lines(bufnr_b, 0, -1, false, { 'return 3' })
            edits.flush(bufnr_b)
            vim.cmd.cd(original_cwd)

            local function count_name(rendered, name)
                local _, count = rendered:gsub(vim.pesc('User edited "' .. name .. '"'), '')
                return count
            end

            -- The cwd at flush (or render) time is irrelevant: each file
            -- keeps its full home-relative name, so the two init.lua never
            -- collide and the same file can never appear under two names.
            local rendered = edits.render()
            helpers.expect_equal(count_name(rendered, vim.fn.fnamemodify(root_a, ':~') .. '/init.lua'), 1)
            helpers.expect_equal(count_name(rendered, vim.fn.fnamemodify(root_b, ':~') .. '/init.lua'), 1)

            helpers.delete_buffer(bufnr_a)
            helpers.delete_buffer(bufnr_b)
            vim.fn.delete(root_a, 'rf')
            vim.fn.delete(root_b, 'rf')
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
        name = 'duet.edits truncates an oversized burst to the leading hunks that fit',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        max_event_chars = 90,
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            local lines = {}
            for i = 1, 20 do
                lines[i] = 'line ' .. i
            end
            local bufnr = create_normal_buffer(lines)
            edits.track(bufnr)

            -- Two edits far apart produce two hunks; the budget fits only the
            -- first one.
            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'changed 1' })
            vim.api.nvim_buf_set_lines(bufnr, 19, 20, false, { 'changed 20' })
            edits.flush(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'an oversized multi-hunk burst should be kept, truncated')
            helpers.expect_truthy(#events[1].diff <= 90, 'the truncated diff must fit max_event_chars')
            helpers.expect_match(events[1].diff, '%+changed 1')
            helpers.expect_falsy(events[1].diff:match '%+changed 20', 'the hunk beyond the budget should be cut')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits drops a burst whose first hunk already exceeds max_event_chars',
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

            helpers.expect_equal(
                #edits.get_events(),
                0,
                'truncating mid-hunk would be invalid, so the burst is dropped'
            )

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits.render returns an empty string while disabled at runtime',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            edits.flush(bufnr)
            helpers.expect_match(edits.render(), '%+return 2')

            require('minuet').config.duet.recent_edits.enabled = false
            helpers.expect_equal(edits.render(), '', 'disabling must hide recorded history from prompts')

            require('minuet').config.duet.recent_edits.enabled = true
            helpers.expect_match(edits.render(), '%+return 2', 're-enabling should restore the recorded history')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits truncates a burst that alone would exceed max_total_chars instead of self-evicting',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        max_total_chars = 120,
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            local lines = {}
            for i = 1, 20 do
                lines[i] = 'line ' .. i
            end
            local bufnr = create_normal_buffer(lines)
            edits.track(bufnr)

            -- Two hunks whose formatted event exceeds max_total_chars even
            -- though the diff fits max_event_chars: the event must be
            -- truncated to fit rather than evicting itself from the history.
            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'changed 1' })
            vim.api.nvim_buf_set_lines(bufnr, 19, 20, false, { 'changed 20' })
            edits.flush(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'the event must not evict itself from the history')
            helpers.expect_truthy(#events[1].text <= 120, 'the formatted event must fit max_total_chars')
            helpers.expect_match(events[1].diff, '%+changed 1')
            helpers.expect_falsy(events[1].diff:match '%+changed 20', 'the diff should be truncated to fit the budget')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits never tracks buffers larger than max_buffer_size',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        max_buffer_size = 16,
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'this line alone is well beyond sixteen bytes' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'still far too large for the size guard' })
            edits.flush(bufnr)

            helpers.expect_equal(#edits.get_events(), 0, 'oversized buffers should never produce edit events')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits cancels the pending debounce when the buffer is wiped out',
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

            -- Real wipeout while the debounce timer armed above is pending.
            vim.v.errmsg = ''
            vim.api.nvim_buf_delete(bufnr, { force = true })

            -- Pump the loop well past the debounce: the closed timer must not
            -- fire, and nothing may error.
            vim.wait(100, function()
                return false
            end, 10)
            helpers.expect_equal(#edits.get_events(), 0, 'the pending flush must not fire after wipeout')
            helpers.expect_equal(vim.v.errmsg, '', 'wipeout with a pending debounce must not raise')
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
