local helpers = require 'tests.helpers'

-- The auto trigger only fires in normal file buffers; helpers.create_buffer
-- makes scratch buffers, so clear the buftype.
local function create_normal_buffer(lines, cursor)
    local bufnr = helpers.create_buffer(lines, cursor)
    vim.bo[bufnr].buftype = ''
    return bufnr
end

return {
    {
        name = 'duet auto trigger fires a single prediction after the debounce gap',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    auto_trigger = {
                        debounce = 20,
                    },
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local complete_count = 0

            package.loaded['minuet.duet.backends.test'] = {
                complete = function()
                    complete_count = complete_count + 1
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 8 })
            duet.action.enable_auto_trigger()

            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            vim.wait(5, function()
                return false
            end, 5)
            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })

            helpers.wait_until(function()
                return complete_count > 0
            end, 1000, 'auto trigger did not fire a prediction')

            -- The two text changes are within one debounce gap, so they must
            -- collapse into a single request.
            vim.wait(60, function()
                return false
            end, 10)
            helpers.expect_equal(complete_count, 1, 'debounced text changes should produce one request')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto trigger stays quiet when disabled or gated by enable_predicates',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    auto_trigger = {
                        debounce = 20,
                    },
                },
            }

            local complete_count = 0

            package.loaded['minuet.duet.backends.test'] = {
                complete = function()
                    complete_count = complete_count + 1
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 8 })

            -- The buffer variable was never enabled, so nothing may fire.
            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            vim.wait(100, function()
                return false
            end, 10)
            helpers.expect_equal(complete_count, 0, 'auto trigger fired in a buffer where it is disabled')

            -- With the buffer enabled but a failing predicate, it must stay
            -- quiet as well.
            require('minuet').config.enable_predicates = {
                function()
                    return false
                end,
            }
            duet.action.enable_auto_trigger()

            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })
            vim.wait(100, function()
                return false
            end, 10)
            helpers.expect_equal(complete_count, 0, 'auto trigger fired despite a failing enable predicate')

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto trigger flushes recent edits with its shorter timeout while manual predict keeps the default',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    auto_trigger = {
                        debounce = 20,
                        flush_timeout = 50,
                    },
                },
            }

            local captured_flush_opts

            -- Stub the edits module before minuet.duet is (re)loaded: it is
            -- required at module top level, and context.build calls
            -- edits.render() while building the prompt.
            package.loaded['minuet.duet.edits'] = {
                setup = function() end,
                ensure_setup = function() end,
                render = function()
                    return ''
                end,
                flush = function(_, opts)
                    captured_flush_opts = opts
                end,
            }

            package.loaded['minuet.duet.backends.test'] = {
                complete = function() end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = create_normal_buffer({ 'return 1' }, { 1, 8 })
            duet.action.enable_auto_trigger()

            vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr, modeline = false })

            helpers.wait_until(function()
                return captured_flush_opts ~= nil
            end, 1000, 'auto trigger did not flush recent edits')

            helpers.expect_equal(captured_flush_opts, { wait = true, timeout = 50 })

            captured_flush_opts = nil
            duet.action.predict()

            helpers.expect_equal(
                captured_flush_opts,
                { wait = true },
                'manual predict should keep the default flush timeout'
            )

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet auto_trigger_ft enables the buffer variable per filetype and honors the ignore list',
        run = function()
            helpers.setup_root_config {
                duet = {
                    auto_trigger = {
                        auto_trigger_ft = { 'lua' },
                    },
                },
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local lua_bufnr = create_normal_buffer { 'return 1' }
            vim.bo[lua_bufnr].filetype = 'lua'
            helpers.expect_truthy(
                vim.b[lua_bufnr].minuet_duet_auto_trigger,
                'lua buffer should have auto trigger enabled'
            )

            local text_bufnr = create_normal_buffer { 'hello' }
            vim.bo[text_bufnr].filetype = 'text'
            helpers.expect_falsy(
                vim.b[text_bufnr].minuet_duet_auto_trigger,
                'text buffer should not have auto trigger enabled'
            )

            helpers.delete_buffer(lua_bufnr)
            helpers.delete_buffer(text_bufnr)

            helpers.setup_root_config {
                duet = {
                    auto_trigger = {
                        auto_trigger_ft = { '*' },
                        auto_trigger_ignore_ft = { 'text' },
                    },
                },
            }

            duet = helpers.reload 'minuet.duet'
            duet.setup()

            local ignored_bufnr = create_normal_buffer { 'hello' }
            vim.bo[ignored_bufnr].filetype = 'text'
            helpers.expect_falsy(
                vim.b[ignored_bufnr].minuet_duet_auto_trigger,
                'ignored filetype should not have auto trigger enabled'
            )

            local enabled_bufnr = create_normal_buffer { 'return 1' }
            vim.bo[enabled_bufnr].filetype = 'lua'
            helpers.expect_truthy(
                vim.b[enabled_bufnr].minuet_duet_auto_trigger,
                'wildcard filetype should enable auto trigger'
            )

            helpers.delete_buffer(ignored_bufnr)
            helpers.delete_buffer(enabled_bufnr)
        end,
    },
}
