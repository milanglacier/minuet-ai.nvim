local helpers = require 'tests.helpers'

return {
    {
        name = 'utils.make_tmp_file writes the exact JSON body in the nvim temp directory',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'
            local content = {
                message = 'hello',
                count = 2,
            }
            local expected = vim.json.encode(content)
            local data_file = utils.make_tmp_file(content)

            helpers.expect_truthy(data_file)
            helpers.expect_equal(
                vim.fs.dirname(data_file),
                vim.fs.dirname(vim.fn.tempname()),
                "request files must use Neovim's private temp directory"
            )

            local file = assert(io.open(data_file, 'rb'))
            local actual = file:read '*a'
            file:close()
            vim.uv.fs_unlink(data_file)

            helpers.expect_equal(actual, expected)
        end,
    },
    {
        name = 'utils.trim_completion_items skips whitespace-only completion items',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'

            helpers.expect_equal(utils.trim_completion_items { '  foo  ', '   ', '\n\t', ' bar' }, { 'foo', 'bar' })
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
    {
        name = 'utils.no_stream_decode ignores non-string extracted text',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'
            local data_file = vim.fn.tempname()
            vim.fn.writefile({ '{}' }, data_file)

            local result = utils.no_stream_decode(
                {
                    code = 0,
                    stdout = vim.json.encode {
                        choices = {
                            { text = { 'not a string' } },
                        },
                    },
                },
                data_file,
                'TestProvider',
                function(json)
                    return json.choices[1].text
                end
            )

            helpers.expect_falsy(result)
            helpers.expect_falsy(vim.uv.fs_stat(data_file))
        end,
    },
}
