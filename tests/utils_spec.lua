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
    {
        name = 'utils.make_system_prompt expands placeholders and drops unresolved ones',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'

            local system_prompt = utils.make_system_prompt({
                template = '{{{prompt}}} | {{{guidelines}}} | {{{n_completion_template}}} | {{{x}}} mid {{{y}}} end',
                prompt = 'the prompt',
                guidelines = function()
                    return 'the guidelines'
                end,
                n_completion_template = 'give %d completions',
            }, 3)

            helpers.expect_equal(
                system_prompt,
                'the prompt | the guidelines | give 3 completions |  mid  end',
                'text between two unresolved placeholders must survive'
            )
        end,
    },
    {
        name = 'utils.make_system_prompt drops n_completion_template when n_completion is nil',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'

            local system_prompt = utils.make_system_prompt({
                template = '{{{prompt}}}{{{n_completion_template}}}',
                prompt = 'p',
                n_completion_template = 'give %d completions',
            }, nil)

            helpers.expect_equal(system_prompt, 'p')
        end,
    },
    {
        name = 'utils.make_chat_llm_shot renders each template with context-aware values',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'

            local shots = utils.make_chat_llm_shot({
                lines_before = 'above',
                lines_after = 'below',
                opts = { language = 'lua' },
            }, {
                template = { '{{{before}}}<cursor>{{{after}}}{{{missing}}}', 'lang: {{{language}}}' },
                before = function(before, _, _)
                    return before
                end,
                after = function(_, after, _)
                    return after
                end,
                language = function(_, _, opts)
                    return opts.language
                end,
            })

            helpers.expect_equal(shots, { 'above<cursor>below', 'lang: lua' })
        end,
    },
    {
        name = 'utils.make_chat_llm_shot accepts plain string values',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'

            local shots = utils.make_chat_llm_shot({}, {
                template = '{{{static}}}',
                static = 'fixed text',
            })

            helpers.expect_equal(shots, { 'fixed text' })
        end,
    },
    {
        name = 'utils.expand_template keeps substituted values literal',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'

            local rendered = utils.expand_template('{{{a}}}', {
                a = '{{{b}}}',
                b = 'must not appear',
            }, utils.get_or_eval_value)

            helpers.expect_equal(rendered, '{{{b}}}', 'inserted values must not be rescanned or stripped')
        end,
    },
}
