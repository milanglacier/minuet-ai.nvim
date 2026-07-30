local helpers = require 'tests.helpers'

-- helpers.create_buffer creates scratch buffers (buftype = 'nofile'), which
-- the recorder's trackability guard rejects. Recorder tests must turn the
-- buffer into a normal one before tracking it.
local function create_normal_buffer(lines, cursor)
    local bufnr = helpers.create_buffer(lines, cursor)
    vim.bo[bufnr].buftype = ''
    return bufnr
end

-- The flush pipeline is asynchronous (external diff process). flush_sync
-- keeps flush-behavior tests synchronous-looking by waiting generously for
-- the in-flight diff to settle.
local function flush_sync(bufnr)
    local config = require('minuet').config.duet.recent_edits
    local saved = config.flush_timeout
    config.flush_timeout = 5000
    require('minuet.duet.edits').flush(bufnr, { wait = true })
    config.flush_timeout = saved
end

local script_dir = vim.fn.getcwd() .. '/tests/scripts'

-- The fixture scripts need a POSIX sh and the real diff; without them the
-- tests using them pass vacuously.
local function has_fixture_support()
    return vim.fn.executable 'sh' == 1 and vim.fn.executable 'diff' == 1
end

-- The recorder owns the MinuetDuetEdits augroup exclusively; the autocmd
-- count tells whether (and how many times) it registered its autocmds.
local function count_recorder_autocmds()
    return #vim.api.nvim_get_autocmds { group = 'MinuetDuetEdits' }
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
            flush_sync(bufnr)

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
        name = 'duet.edits strips the diff file headers so temp paths never reach the prompt',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 42' })
            flush_sync(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1)
            helpers.expect_falsy(events[1].diff:match '%-%-%- ', 'the --- file header must be stripped')
            helpers.expect_falsy(events[1].diff:match '%+%+%+ ', 'the +++ file header must be stripped')
            -- The snapshot files live in Neovim's private temp directory; its
            -- path must not leak into the prompt text.
            local tempdir = vim.fn.fnamemodify(vim.fn.tempname(), ':h')
            helpers.expect_falsy(events[1].text:find(tempdir, 1, true), 'temp file paths must not leak into events')

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
            flush_sync(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'first flush should only capture the baseline')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            flush_sync(bufnr)

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
                        enabled = true,
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
        name = 'duet.edits coalesces bursts across InsertLeave into one debounced event',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
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
            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            vim.api.nvim_exec_autocmds('InsertLeave', { buffer = bufnr, modeline = false })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            vim.api.nvim_exec_autocmds('InsertLeave', { buffer = bufnr, modeline = false })

            helpers.wait_until(function()
                return #edits.get_events() > 0
            end, 1000, 'debounced edit burst was not flushed')

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'InsertLeave must not split the burst into separate events')
            helpers.expect_match(events[1].diff, '%-return 1')
            helpers.expect_match(events[1].diff, '%+return 3')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits flushes a buffer switch before predicting in another buffer',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    recent_edits = {
                        enabled = true,
                        debounce = 10000,
                        flush_timeout = 5000,
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

            local bufnr_a = create_normal_buffer { 'local a = 1' }
            edits.track(bufnr_a)
            local bufnr_b = create_normal_buffer { 'local b = 1' }
            edits.track(bufnr_b)

            vim.api.nvim_set_current_buf(bufnr_a)
            vim.api.nvim_buf_set_lines(bufnr_a, 0, -1, false, { 'local a = 2' })
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr_a, modeline = false })

            -- BufLeave starts an async flush of bufnr_a; the predict-path
            -- flush must wait for it (it waits on every buffer's in-flight
            -- diff), or the prompt would miss the freshest cross-buffer
            -- burst.
            vim.api.nvim_set_current_buf(bufnr_b)
            vim.api.nvim_buf_set_lines(bufnr_b, 0, -1, false, { 'local b = 2' })
            duet.action.predict()

            helpers.expect_truthy(seen_context, 'backend did not receive a request')
            helpers.expect_match(
                seen_context.recent_edits,
                'local a = 2',
                "the prompt must include the other buffer's in-flight burst"
            )
            helpers.expect_match(seen_context.recent_edits, 'local b = 2')

            helpers.delete_buffer(bufnr_a)
            helpers.delete_buffer(bufnr_b)
        end,
    },
    {
        name = 'duet.edits re-baselines on BufReadPost so a reload is not recorded as a user edit',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            -- Simulate a disk reload (:e!, autoread): the buffer content is
            -- replaced and BufReadPost fires afterwards.
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            vim.api.nvim_exec_autocmds('BufReadPost', { buffer = bufnr, modeline = false })

            flush_sync(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'a reload must not be recorded as a user edit')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            flush_sync(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1)
            helpers.expect_match(events[1].diff, '%-return 2', 'the baseline should be the reloaded content')
            helpers.expect_match(events[1].diff, '%+return 3')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits cancels an in-flight diff on BufReadPost so the pre-reload burst is discarded',
        run = function()
            if not has_fixture_support() then
                return
            end

            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
                        diff_program = script_dir .. '/slow_diff.sh',
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            vim.v.errmsg = ''
            edits.flush(bufnr)

            -- Reload while the slow diff is still in flight: the pending
            -- burst was discarded by the reload, so the diff must be
            -- cancelled and never produce an event.
            vim.api.nvim_exec_autocmds('BufReadPost', { buffer = bufnr, modeline = false })

            vim.wait(1500, function()
                return false
            end, 50)
            helpers.expect_equal(#edits.get_events(), 0, 'a cancelled diff must never record an event')
            helpers.expect_equal(vim.v.errmsg, '', 'cancelling an in-flight diff must not raise')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            flush_sync(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'the re-tracked buffer should flush against the reloaded baseline')
            helpers.expect_match(events[1].diff, '%-return 2')
            helpers.expect_match(events[1].diff, '%+return 3')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits drops tracking state on a real :bunload and re-tracks from disk',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
                    },
                },
            }

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

            flush_sync(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'the reload after unload must not be recorded as a user edit')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            flush_sync(bufnr)

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
            flush_sync(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'a change reverted to the baseline should not emit an event')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            flush_sync(bufnr)

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
            flush_sync(bufnr_a)
            vim.api.nvim_buf_set_lines(bufnr_b, 0, -1, false, { 'local b = 2' })
            flush_sync(bufnr_b)

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
            flush_sync(bufnr_a)

            vim.cmd.cd(root_b)
            vim.cmd.edit(root_b .. '/init.lua')
            local bufnr_b = vim.api.nvim_get_current_buf()
            edits.track(bufnr_b)
            vim.api.nvim_buf_set_lines(bufnr_b, 0, -1, false, { 'return 3' })
            flush_sync(bufnr_b)
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
                flush_sync(bufnr)
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
            flush_sync(bufnr)
            helpers.expect_equal(#edits.get_events(), 1)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            flush_sync(bufnr)

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
            flush_sync(bufnr)

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
            flush_sync(bufnr)

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
            flush_sync(bufnr)
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
            flush_sync(bufnr)

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
            flush_sync(bufnr)

            helpers.expect_equal(#edits.get_events(), 0, 'oversized buffers should never produce edit events')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits flushes once and cancels the debounce when the buffer is wiped out',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
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
            -- The BufLeave flush's diff is orphaned by the wipeout and must
            -- still record the final burst.
            vim.v.errmsg = ''
            vim.api.nvim_buf_delete(bufnr, { force = true })
            helpers.wait_until(function()
                return #edits.get_events() == 1
            end, 2000, 'the BufLeave flush before the wipeout must record the final burst')

            -- Pump the loop well past the debounce: the closed timer must not
            -- fire again, and nothing may error.
            vim.wait(100, function()
                return false
            end, 10)
            helpers.expect_equal(#edits.get_events(), 1, 'the pending timer must not duplicate the BufLeave flush')
            helpers.expect_equal(vim.v.errmsg, '', 'wipeout with a pending debounce must not raise')
        end,
    },
    {
        name = 'duet.edits deletes the snapshot temp files when a tracked buffer is wiped out',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local tempdir = vim.fn.fnamemodify(vim.fn.tempname(), ':h')
            local files_before = #vim.fn.readdir(tempdir)

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            flush_sync(bufnr)

            helpers.expect_equal(
                #vim.fn.readdir(tempdir) - files_before,
                2,
                'a tracked, flushed buffer keeps exactly two snapshot files'
            )

            vim.api.nvim_buf_delete(bufnr, { force = true })
            helpers.wait_until(function()
                return #vim.fn.readdir(tempdir) == files_before
            end, 2000, 'wiping out the buffer must delete its snapshot files')
            helpers.expect_equal(#edits.get_events(), 1, 'the recorded history must survive the wipeout')
        end,
    },
    {
        name = 'duet.edits.reset cancels an orphaned in-flight diff so no event lands after the reset',
        run = function()
            if not has_fixture_support() then
                return
            end

            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
                        diff_program = script_dir .. '/slow_diff.sh',
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            -- Set, not count: reset also unlinks snapshots of other tracked
            -- buffers (e.g. the one setup tracked), so the total may shrink.
            local tempdir = vim.fn.fnamemodify(vim.fn.tempname(), ':h')
            local files_before = {}
            for _, file in ipairs(vim.fn.readdir(tempdir)) do
                files_before[file] = true
            end

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })

            -- Wipe out while the slow diff is in flight: the diff becomes an
            -- orphan; the reset must cancel it instead of letting it record
            -- an event into the freshly-emptied history.
            edits.flush(bufnr)
            vim.v.errmsg = ''
            vim.api.nvim_buf_delete(bufnr, { force = true })
            edits.reset()

            vim.wait(1500, function()
                return false
            end, 50)
            helpers.expect_equal(#edits.get_events(), 0, 'a reset must cancel orphaned diffs, not record them later')
            helpers.expect_equal(vim.v.errmsg, '', 'cancelling an orphaned diff must not raise')
            for _, file in ipairs(vim.fn.readdir(tempdir)) do
                helpers.expect_truthy(
                    files_before[file],
                    'the cancelled orphan must not leave snapshot files behind: ' .. file
                )
            end
        end,
    },
    {
        name = 'duet.edits.flush with wait includes an orphaned in-flight diff',
        run = function()
            if not has_fixture_support() then
                return
            end

            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
                        diff_program = script_dir .. '/slow_diff.sh',
                        flush_timeout = 2000,
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'
            local bufnr_a = create_normal_buffer { 'local a = 1' }
            edits.track(bufnr_a)
            vim.api.nvim_buf_set_lines(bufnr_a, 0, -1, false, { 'local a = 2' })
            edits.flush(bufnr_a)
            vim.api.nvim_buf_delete(bufnr_a, { force = true })

            local bufnr_b = create_normal_buffer { 'local b = 1' }
            edits.track(bufnr_b)
            edits.flush(bufnr_b, { wait = true })

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'the bounded wait must include a diff orphaned by buffer deletion')
            helpers.expect_match(events[1].diff, '%+local a = 2')

            helpers.delete_buffer(bufnr_b)
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
            flush_sync(bufnr)

            helpers.expect_equal(#edits.get_events(), 0, 'scratch buffers should not produce edit events')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits default predicates never track dotenv buffers',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            for _, name in ipairs { '.env', '.env.local' } do
                local bufnr = create_normal_buffer { 'SECRET=1' }
                vim.api.nvim_buf_set_name(bufnr, name)
                edits.track(bufnr)

                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'SECRET=2' })
                flush_sync(bufnr)

                helpers.expect_equal(#edits.get_events(), 0, name .. ' must never produce edit events')
                helpers.delete_buffer(bufnr)
            end

            -- The guard matches only .env and .env.*; a mere .env prefix
            -- (.envrc, .environment) must stay tracked.
            local bufnr = create_normal_buffer { 'export FOO=1' }
            vim.api.nvim_buf_set_name(bufnr, '.envrc')
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'export FOO=2' })
            flush_sync(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'a .env prefix alone must not reject the buffer')
            helpers.expect_match(events[1].diff, '%+export FOO=2')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits custom enable_predicates replace the default and receive the buffer number',
        run = function()
            local seen_bufnr
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enable_predicates = {
                            function(bufnr)
                                seen_bufnr = bufnr
                                return true
                            end,
                        },
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            -- The custom predicate permits a dotenv buffer, proving that it
            -- replaces rather than supplements the default dotenv guard.
            local bufnr = create_normal_buffer { 'SECRET=1' }
            vim.api.nvim_buf_set_name(bufnr, '.env')
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'SECRET=2' })
            flush_sync(bufnr)

            helpers.expect_equal(#edits.get_events(), 1, 'custom predicates must replace the default dotenv guard')
            helpers.expect_equal(seen_bufnr, bufnr, 'predicates must receive the buffer number')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits drops state and snapshots when a predicate starts failing mid-session',
        run = function()
            local allow = true
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enable_predicates = {
                            function()
                                return allow
                            end,
                        },
                    },
                },
            }

            -- duet.setup clears the duet augroup; without it, stale autocmds
            -- from earlier tests would track this test's buffer through an
            -- old recorder instance and skew the temp-file counting below.
            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local tempdir = vim.fn.fnamemodify(vim.fn.tempname(), ':h')
            local files_before = #vim.fn.readdir(tempdir)

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            flush_sync(bufnr)
            helpers.expect_equal(#edits.get_events(), 1, 'the buffer is tracked while the predicate passes')
            helpers.expect_equal(#vim.fn.readdir(tempdir) - files_before, 2, 'a tracked buffer keeps two snapshots')

            allow = false
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 3' })
            flush_sync(bufnr)

            helpers.expect_equal(#edits.get_events(), 1, 'a burst after the predicate flips must not be recorded')
            helpers.expect_equal(
                #vim.fn.readdir(tempdir) - files_before,
                0,
                'the failing predicate must delete the snapshot files'
            )

            -- Flipping back re-tracks from the current content without
            -- recording the changes made while rejected.
            allow = true
            flush_sync(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 4' })
            flush_sync(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 2, 'a passing predicate must re-track the buffer')
            helpers.expect_match(events[2].diff, '%-return 3', 'the re-established baseline is the current content')
            helpers.expect_match(events[2].diff, '%+return 4')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits round-trips non-ASCII buffer content through the snapshot files',
        run = function()
            helpers.setup_root_config {}
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'héllo', '世界' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'monde' })
            flush_sync(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1)
            helpers.expect_match(events[1].diff, ' héllo', 'non-ASCII context lines must survive the file round-trip')
            helpers.expect_match(events[1].diff, '%-世界')
            helpers.expect_match(events[1].diff, '%+monde')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits leaves the recorder off when the diff program is not executable',
        run = function()
            helpers.setup_root_config {
                notify = 'verbose',
                duet = {
                    recent_edits = {
                        enabled = true,
                        diff_program = 'minuet-no-such-diff-program',
                    },
                },
            }

            local notifications, restore_notifications = helpers.capture_notifications()
            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            vim.v.errmsg = ''
            flush_sync(bufnr)
            flush_sync(bufnr)
            restore_notifications()

            helpers.expect_equal(#edits.get_events(), 0, 'a missing diff program must never produce events')
            helpers.expect_equal(vim.v.errmsg, '', 'a missing diff program must not raise')
            helpers.expect_equal(#notifications, 1, 'a missing diff program must notify only during setup')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits setup recovers after the diff program becomes executable',
        run = function()
            if not has_fixture_support() then
                return
            end

            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
                        diff_program = 'minuet-no-such-diff-program',
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            require('minuet').config.duet.recent_edits.diff_program = 'diff'
            duet.setup()

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            flush_sync(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'a successful repeated setup must re-enable the recorder')
            helpers.expect_match(events[1].diff, '%+return 2')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits repeated setup cleans snapshots before a missing-program return',
        run = function()
            if not has_fixture_support() then
                return
            end

            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local tempdir = vim.fn.fnamemodify(vim.fn.tempname(), ':h')
            local files_before = {}
            for _, file in ipairs(vim.fn.readdir(tempdir)) do
                files_before[file] = true
            end

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            flush_sync(bufnr)

            local snapshot_files = {}
            for _, file in ipairs(vim.fn.readdir(tempdir)) do
                if not files_before[file] then
                    table.insert(snapshot_files, tempdir .. '/' .. file)
                end
            end
            helpers.expect_equal(#snapshot_files, 2, 'a tracked, flushed buffer must own two snapshot files')

            require('minuet').config.duet.recent_edits.diff_program = 'minuet-no-such-diff-program'
            duet.setup()

            local leaked_files = {}
            for _, file in ipairs(snapshot_files) do
                if vim.uv.fs_stat(file) then
                    table.insert(leaked_files, file)
                end
            end

            -- Keep the test isolated even when the assertion fails against a
            -- regression that leaves recorder state behind.
            edits.reset()
            helpers.delete_buffer(bufnr)

            helpers.expect_equal(
                #leaked_files,
                0,
                'a failed repeated setup must clean snapshots from the previous recorder lifecycle'
            )
        end,
    },
    {
        name = 'duet.edits retries a burst after the diff program fails and recovers with a working one',
        run = function()
            if not has_fixture_support() then
                return
            end

            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        diff_program = script_dir .. '/diff_exit_2.sh',
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            flush_sync(bufnr)
            helpers.expect_equal(#edits.get_events(), 0, 'a failing diff run must not record an event')

            -- The failed run did not rotate the snapshot, so the same burst
            -- is retried once the program works again.
            require('minuet').config.duet.recent_edits.diff_program = 'diff'
            flush_sync(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1, 'the burst must be retried after the diff failure')
            helpers.expect_match(events[1].diff, '%-return 1')
            helpers.expect_match(events[1].diff, '%+return 2')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits.flush with wait returns at the timeout and records the event later',
        run = function()
            if not has_fixture_support() then
                return
            end

            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        diff_program = script_dir .. '/slow_diff.sh',
                        flush_timeout = 50,
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            edits.flush(bufnr, { wait = true })

            -- The fixture sleeps for a full second, so an empty history here
            -- proves the wait gave up at the deadline instead of blocking
            -- until completion.
            helpers.expect_equal(#edits.get_events(), 0, 'the bounded wait must not block until the diff completes')

            helpers.wait_until(function()
                return #edits.get_events() == 1
            end, 3000, 'the event must still arrive once the slow diff completes')
            helpers.expect_match(edits.get_events()[1].diff, '%+return 2')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits skips flushes while a diff is in flight and never duplicates a burst',
        run = function()
            if not has_fixture_support() then
                return
            end

            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        diff_program = script_dir .. '/slow_diff.sh',
                    },
                },
            }
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.track(bufnr)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            edits.flush(bufnr)
            edits.flush(bufnr)
            edits.flush(bufnr)

            helpers.wait_until(function()
                return #edits.get_events() > 0
            end, 3000, 'the in-flight burst was never recorded')

            -- Pump the loop long enough for any duplicate diff to have
            -- landed as a second (empty, hence skipped) or duplicated event.
            vim.wait(1500, function()
                return false
            end, 50)
            helpers.expect_equal(#edits.get_events(), 1, 'repeated flushes of one burst must record exactly one event')

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
                    recent_edits = {
                        flush_timeout = 5000,
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
        name = 'duet.edits default lazy setting registers no recorder autocmds at setup',
        run = function()
            helpers.setup_root_config {}

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            helpers.expect_equal(count_recorder_autocmds(), 0, 'the lazy default must not register autocmds at setup')

            local bufnr = create_normal_buffer { 'return 1' }
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr, modeline = false })
            helpers.expect_equal(#edits.get_events(), 0, 'edits before the recorder starts must not be recorded')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits.ensure_setup registers the recorder autocmds once and baselines the current buffer',
        run = function()
            helpers.setup_root_config {}

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local edits = require 'minuet.duet.edits'

            local bufnr = create_normal_buffer { 'return 1' }
            edits.ensure_setup()

            local registered = count_recorder_autocmds()
            helpers.expect_truthy(registered > 0, 'ensure_setup must register the recorder autocmds')

            edits.ensure_setup()
            helpers.expect_equal(
                count_recorder_autocmds(),
                registered,
                'a repeated ensure_setup must not duplicate autocmds'
            )

            -- ensure_setup baselined the current buffer, so the next burst is
            -- diffed against the text it had when the recorder was set up.
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 2' })
            flush_sync(bufnr)

            local events = edits.get_events()
            helpers.expect_equal(#events, 1)
            helpers.expect_match(events[1].diff, '%-return 1')
            helpers.expect_match(events[1].diff, '%+return 2')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.edits enabled = true starts the recorder at setup',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = true,
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            helpers.expect_truthy(count_recorder_autocmds() > 0, 'enabled = true must register the autocmds at setup')
        end,
    },
    {
        name = 'duet.edits enabled = false keeps ensure_setup a no-op',
        run = function()
            helpers.setup_root_config {
                duet = {
                    recent_edits = {
                        enabled = false,
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            require('minuet.duet.edits').ensure_setup()

            helpers.expect_equal(count_recorder_autocmds(), 0, 'enabled = false must never register the autocmds')
        end,
    },
    {
        name = 'duet.action.predict starts the lazy recorder on first use',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                },
            }

            package.loaded['minuet.duet.backends.test'] = {
                complete = function() end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            helpers.expect_equal(count_recorder_autocmds(), 0, 'the recorder must not run before the first prediction')

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 0 })
            duet.action.predict()

            helpers.expect_truthy(count_recorder_autocmds() > 0, 'the first prediction must start the recorder')

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
