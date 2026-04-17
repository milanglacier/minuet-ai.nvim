local helpers = require 'tests.helpers'

return {
    {
        name = 'duet.action.predict works through the openai-compatible streaming transport',
        run = function()
            local original_api_key = vim.env.OPENROUTER_API_KEY
            local bufnr

            local ok, err = xpcall(function()
                local mock = vim.fn.getcwd() .. '/tests/scripts/mock_openai_stream.sh'

                vim.env.OPENROUTER_API_KEY = 'test-key'

                helpers.setup_root_config {
                    curl_cmd = mock,
                    duet = {
                        provider = 'openai_compatible',
                        request_timeout = 2,
                        editable_region = {
                            lines_before = 0,
                            lines_after = 0,
                        },
                        provider_options = {
                            openai_compatible = {
                                end_point = [[<editable_region>
return 42<cursor_position/>
</editable_region>]],
                                model = 'fixture-model',
                                name = 'Fixture',
                            },
                        },
                    },
                }

                local duet = helpers.reload 'minuet.duet'
                duet.setup()

                bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

                duet.action.predict()

                helpers.wait_until(function()
                    return duet.action.is_visible()
                end, 3000, 'duet preview did not become visible through the transport test')

                duet.action.apply()

                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 42' })
                helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 8 })
                helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after apply')
            end, debug.traceback)

            vim.env.OPENROUTER_API_KEY = original_api_key
            helpers.delete_buffer(bufnr)

            if not ok then
                error(err)
            end
        end,
    },
}
