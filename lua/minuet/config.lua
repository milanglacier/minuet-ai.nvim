local default_prompt = [[
You are the backend of an AI-powered code completion engine. Your task is to
provide code suggestions based on the user's input. The user's code will be
enclosed in markers:

- `<contextAfterCursor>`: Code context after the cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Code context before the cursor

Note that the user's code will be prompted in reverse order: first the code
after the cursor, then the code before the cursor.
]]

local default_guidelines = [[
Guidelines:
1. Offer completions after the `<cursorPosition>` marker.
2. Make sure you have maintained the user's existing whitespace and indentation.
   This is REALLY IMPORTANT!
3. Provide multiple completion options when possible.
4. Return completions separated by the marker <endCompletion>.
5. The returned message will be further parsed and processed. DO NOT include
   additional comments or markdown code block fences. Return the result directly.
6. Keep each completion option concise, limiting it to a single line or a few lines.
7. Create entirely new code completion that DO NOT REPEAT OR COPY any user's existing code around <cursorPosition>.]]

local default_few_shots = {
    {
        role = 'user',
        content = [[
# language: python
<contextAfterCursor>

fib(5)
<contextBeforeCursor>
def fibonacci(n):
    <cursorPosition>]],
    },
    {
        role = 'assistant',
        content = [[
    '''
    Recursive Fibonacci implementation
    '''
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)
<endCompletion>
    '''
    Iterative Fibonacci implementation
    '''
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
<endCompletion>
]],
    },
}

local n_completion_template = '8. Provide at most %d completion items.'

-- use {{{ and }}} to wrap placeholders, which will be further processesed in other function
local default_system_template = '{{{prompt}}}\n{{{guidelines}}}\n{{{n_completion_template}}}'

local default_fim_prompt = function(context_before_cursor, _)
    local utils = require 'minuet.utils'
    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()
    context_before_cursor = language .. '\n' .. tab .. '\n' .. context_before_cursor

    return context_before_cursor
end

local default_fim_suffix = function(_, context_after_cursor)
    return context_after_cursor
end

local default_chat_input = {
    template = '{{{language}}}\n{{{tab}}}\n<contextAfterCursor>\n{{{context_after_cursor}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>',
    language = function(_, _)
        local utils = require 'minuet.utils'
        return utils.add_language_comment()
    end,
    tab = function(_, _)
        local utils = require 'minuet.utils'
        return utils.add_tab_comment()
    end,
    context_before_cursor = function(context_before_cursor, _)
        return context_before_cursor
    end,
    context_after_cursor = function(_, context_after_cursor)
        return context_after_cursor
    end,
}

local M = {
    -- Enable or disable auto-completion. Note that you still need to add
    -- Minuet to your cmp/blink sources. This option controls whether cmp/blink
    -- will attempt to invoke minuet when minuet is included in cmp/blink
    -- sources. This setting has no effect on manual completion; Minuet will
    -- always be enabled when invoked manually. You can use the command
    -- `MinuetToggleCmp/Blink` to toggle this option.
    cmp = {
        enable_auto_complete = true,
    },
    blink = {
        enable_auto_complete = true,
    },
    virtualtext = {
        -- Specify the filetypes to enable automatic virtual text completion,
        -- e.g., { 'python', 'lua' }. Note that you can still invoke manual
        -- completion even if the filetype is not on your auto_trigger_ft list.
        auto_trigger_ft = {},
        -- specify file types where automatic virtual text completion should be
        -- disabled. This option is useful when auto-completion is enabled for
        -- all file types i.e., when auto_trigger_ft = { '*' }
        auto_trigger_ignore_ft = {},
        keymap = {
            accept = nil,
            accept_line = nil,
            -- accept n lines (prompts for number)
            accept_n_lines = nil,
            -- Cycle to next completion item, or manually invoke completion
            next = nil,
            -- Cycle to prev completion item, or manually invoke completion
            prev = nil,
            dismiss = nil,
        },
    },
    provider = 'codestral',
    -- the maximum total characters of the context before and after the cursor
    -- 16000 characters typically equate to approximately 4,000 tokens for
    -- LLMs.
    context_window = 16000,
    -- when the total characters exceed the context window, the ratio of
    -- context before cursor and after cursor, the larger the ratio the more
    -- context before cursor will be used. This option should be between 0 and
    -- 1, context_ratio = 0.75 means the ratio will be 3:1.
    context_ratio = 0.75,
    throttle = 1000, -- only send the request every x milliseconds, use 0 to disable throttle.
    -- debounce the request in x milliseconds, set to 0 to disable debounce
    debounce = 400,
    -- Control notification display for request status
    -- Notification options:
    -- false: Disable all notifications (use boolean false, not string "false")
    -- "debug": Display all notifications (comprehensive debugging)
    -- "verbose": Display most notifications
    -- "warn": Display warnings and errors only
    -- "error": Display errors only
    notify = 'warn',
    -- The request timeout, measured in seconds. When streaming is enabled
    -- (stream = true), setting a shorter request_timeout allows for faster
    -- retrieval of completion items, albeit potentially incomplete.
    -- Conversely, with streaming disabled (stream = false), a timeout
    -- occurring before the LLM returns results will yield no completion items.
    request_timeout = 3,
    -- if completion item has multiple lines, create another completion item only containing its first line.
    add_single_line_entry = true,
    -- The number of completion items (encoded as part of the prompt for the
    -- chat LLM) requested from the language model. It's important to note that
    -- when 'add_single_line_entry' is set to true, the actual number of
    -- returned items may exceed this value. Additionally, the LLM cannot
    -- guarantee the exact number of completion items specified, as this
    -- parameter serves only as a prompt guideline.
    n_completions = 3,
    -- Defines the length of non-whitespace context after the cursor used to
    -- filter completion text. Set to 0 to disable filtering.
    --
    -- Example: With after_cursor_filter_length = 3 and context:
    --
    -- "def fib(n):\n|\n\nfib(5)" (where | represents cursor position),
    --
    -- if the completion text contains "fib", then "fib" and subsequent text
    -- will be removed. This setting filters repeated text generated by the
    -- LLM. A large value (e.g., 15) is recommended to avoid false positives.
    after_cursor_filter_length = 15,
    proxy = nil,
}

M.default_system = {
    template = default_system_template,
    prompt = default_prompt,
    guidelines = default_guidelines,
    n_completion_template = n_completion_template,
}

M.default_chat_input = default_chat_input

M.default_few_shots = default_few_shots

M.default_fim_template = {
    default_prompt = default_fim_prompt,
    default_suffix = default_fim_suffix,
}

M.provider_options = {
    codestral = {
        model = 'codestral-latest',
        end_point = 'https://codestral.mistral.ai/v1/fim/completions',
        api_key = 'CODESTRAL_API_KEY',
        stream = true,
        template = {
            prompt = M.default_fim_template.default_prompt,
            suffix = M.default_fim_template.default_suffix,
        },
        optional = {
            stop = nil, -- the identifier to stop the completion generation
            max_tokens = nil,
        },
    },
    openai = {
        model = 'gpt-4o-mini',
        system = M.default_system,
        few_shots = M.default_few_shots,
        chat_input = M.default_chat_input,
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
    },
    claude = {
        max_tokens = 512,
        model = 'claude-3-5-haiku-20241022',
        system = M.default_system,
        chat_input = M.default_chat_input,
        few_shots = M.default_few_shots,
        stream = true,
        optional = {
            stop_sequences = nil,
        },
    },
    openai_compatible = {
        model = 'llama-3.3-70b-versatile',
        system = M.default_system,
        chat_input = M.default_chat_input,
        few_shots = M.default_few_shots,
        end_point = 'https://api.groq.com/openai/v1/chat/completions',
        api_key = 'GROQ_API_KEY',
        name = 'Groq',
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
    },
    gemini = {
        model = 'gemini-1.5-flash-latest',
        system = M.default_system,
        chat_input = M.default_chat_input,
        few_shots = M.default_few_shots,
        stream = true,
        optional = {},
    },
    openai_fim_compatible = {
        model = 'deepseek-chat',
        end_point = 'https://api.deepseek.com/beta/completions',
        api_key = 'DEEPSEEK_API_KEY',
        name = 'Deepseek',
        stream = true,
        template = {
            prompt = M.default_fim_template.default_prompt,
            suffix = M.default_fim_template.default_suffix,
        },
        optional = {
            stop = nil,
            max_tokens = nil,
        },
    },
    llamacpp = {
        endpoint = 'http://127.0.0.1:8012/infill',
        api_key = '',
        n_predict = 256,
        t_max_prompt_ms = 500,
        t_max_predict_ms = 500,
        show_info = true,
        max_line_suffix = 8,
        max_cache_keys = 250,
        ring_n_chunks = 16,
        ring_chunk_size = 64,
        ring_scope = 1024,
        ring_update_ms = 1000,
    },
    huggingface = {
        end_point = 'https://api-inference.huggingface.co/models/bigcode/starcoder2-3b',
        type = 'completion', -- chat or completion
        strategies = {
            completion = {
                markers = {
                    prefix = '<fim_prefix>',
                    suffix = '<fim_suffix>',
                    middle = '<fim_middle>',
                },
                strategy = 'PSM', -- PSM, SPM or PM
            },
        },
        optional = {
            parameters = {
                -- The parameter specifications for different LLMs may vary.
                -- Ensure you specify the parameters after reading the API
                -- documentation.
                stop = nil,
                max_tokens = nil,
                do_sample = nil,
            },
        },
    },
}

return M
