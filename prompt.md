- [FIM LLM Prompt Structure](#fim-llm-prompt-structure)
- [Chat LLM Prompt Structure](#chat-llm-prompt-structure)
  - [Default Template](#default-template)
  - [Default Prompt](#default-prompt)
  - [Default Guidelines](#default-guidelines)
  - [Default `n_completions` template](#default--n-completions--template)
  - [Default Few Shots Examples](#default-few-shots-examples)
  - [Default Chat Input Example](#default-chat-input-example)
  - [Customization](#customization)
  - [An Experimental Configuration Setup for Gemini](#an-experimental-configuration-setup-for-gemini)

# FIM LLM Prompt Structure

The prompt sent to the FIM LLM follows this structure:

```lua
provider_options = {
    openai_fim_compatible = {
        template = {
            prompt = function(context_before_cursor, context_after_cursor) end,
            suffix = function(context_before_cursor, context_after_cursor) end,
        }
    }
}
```

The template contains two main functions:

- `prompt`: the default is to return language and the indentation style,
  followed by the `context_before_cursor` verbatim.
- `suffix`: the default is to return `context_after_cursor` verbatim.

Both functions can be customized to provide additional context to the LLM. The
`suffix` function can be disabled by setting `suffix = false`, which will
result in only the `prompt` being included in the request.

Note: for Ollama users: Do not include special tokens (e.g., `<|fim_begin|>`)
within the prompt or suffix functions, as these will be automatically populated
by Ollama. If your use case requires special tokens not covered by Ollama's
default template, first set `suffix = false` and then incorporate the special
tokens within the prompt function.

# Chat LLM Prompt Structure

## Default Template

`{{{prompt}}}\n{{{guidelines}}}\n{{{n_completion_template}}}`

## Default Prompt

You are the backend of an AI-powered code completion engine. Your task is to
provide code suggestions based on the user's input. The user's code will be
enclosed in markers:

- `<contextAfterCursor>`: Code context after the cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Code context before the cursor

Note that the user's code will be prompted in reverse order: first the code
after the cursor, then the code before the cursor.

## Default Guidelines

Guidelines:

1. Offer completions after the `<cursorPosition>` marker.
2. Make sure you have maintained the user's existing whitespace and indentation.
   This is REALLY IMPORTANT!
3. Provide multiple completion options when possible.
4. Return completions separated by the marker `<endCompletion>`.
5. The returned message will be further parsed and processed. DO NOT include
   additional comments or markdown code block fences. Return the result directly.
6. Keep each completion option concise, limiting it to a single line or a few lines.
7. Create entirely new code completion that DO NOT REPEAT OR COPY any user's
   existing code around `<cursorPosition>`.

## Default `n_completions` template

8. Provide at most %d completion items.

## Default Few Shots Examples

```lua
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
```

## Default Chat Input Example

The chat input represents the final prompt delivered to the LLM for completion.
Its template follows a structured format similar to the system prompt and can
be customized as follows:

`{{{language}}}\n{{{tab}}}\n<contextAfterCursor>\n{{{context_after_cursor}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>`

Components:

- `language`: The programming language user is working on
- `tab`: The user's indentation style used by the user
- `context_before_cursor` and `context_after_cursor`: Represent the text
  content before and after the cursor position

Each subcomponent must be defined by a function that takes three parameters:

- `context_before_cursor`: The text content before the cursor
- `context_after_cursor`: The text content after the cursor
- `opts`: A table containing flags about context truncation:
  - `is_incomplete_before`: True if content before cursor was truncated
  - `is_incomplete_after`: True if content after cursor was truncated

The function should return a string value.

## Customization

You can customize the `template` by encoding placeholders within triple braces.
These placeholders will be interpolated using the corresponding key-value pairs
from the table. The value can be either a string or a function that takes no
arguments and returns a string.

Here's a simplified example for illustrative purposes (not intended for actual
configuration):

```lua
system = {
    template = '{{{assistant}}}\n{{{role}}}'
    assistant = function() return 'you are a helpful assistant' end,
    role = "you are also a code expert.",
}
```

Note that `n_completion_template` is a special placeholder as it contains one
`%d` which will be encoded with `config.n_completions`, if you want to
customize this template, make sure your prompt also contains only one `%d`.

Similarly, `few_shots` can be a table in the following form or a function that
takes no argument and returns a table in the following form:

```lua
{
    { role = "user", content = "something" },
    { role = "assistant", content = "something" }
    -- ...
    -- You can pass as many turns as you want
}
```

Below is an example to configure the prompt based on filetype:

```lua
require('minuet').setup {
    provider_options = {
        openai = {
            system = {
                prompt = function()
                    if vim.bo.ft == 'tex' then
                        return [[your prompt for completing prose.]]
                    else
                        return require('minuet.config').default_system.prompt
                    end
                end,
            },
            few_shots = function()
                if vim.bo.ft == 'tex' then
                    return {
                        -- your few shots examples for prose
                    }
                else
                    return require('minuet.config').default_few_shots
                end
            end,
        },
    },
}
```

There's no need to replicate unchanged fields. The system will automatically
merge modified fields with default values using the `tbl_deep_extend` function.

## An Experimental Configuration Setup for Gemini

Some observations suggest that Gemini might perform better with a `Prefix-Suffix`
structured input format, specifically `Before-Cursor -> Cursor-Pos -> After-Cursor`.

This contrasts with other chat-based LLMs, which may yield better results with
the inverse structure: `After-Cursor -> Before-Cursor -> Cursor-Pos`.

This finding remains experimental and requires further validation.

Below is the current configuration used by the maintainer for Gemini:

```lua
local gemini_prompt = [[
You are the backend of an AI-powered code completion engine. Your task is to
provide code suggestions based on the user's input. The user's code will be
enclosed in markers:

- `<contextAfterCursor>`: Code context after the cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Code context before the cursor
]]

local gemini_few_shots = {}

gemini_few_shots[1] = {
    role = 'user',
    content = [[
# language: python
<contextBeforeCursor>
def fibonacci(n):
    <cursorPosition>
<contextAfterCursor>

fib(5)]],
}

local gemini_chat_input_template =
    '{{{language}}}\n{{{tab}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>\n<contextAfterCursor>\n{{{context_after_cursor}}}'


gemini_few_shots[2] = require('minuet.config').default_few_shots[2]

require('minuet').setup {
    provider_options = {
        gemini = {
            system = {
                prompt = gemini_prompt,
            },
            few_shots = gemini_few_shots,
            chat_input = {
                template = gemini_chat_input_template,
            },
            optional = {
                generationConfig = {
                    maxOutputTokens = 256,
                    topP = 0.9,
                },
                safetySettings = {
                    {
                        category = 'HARM_CATEGORY_DANGEROUS_CONTENT',
                        threshold = 'BLOCK_NONE',
                    },
                    {
                        category = 'HARM_CATEGORY_HATE_SPEECH',
                        threshold = 'BLOCK_NONE',
                    },
                    {
                        category = 'HARM_CATEGORY_HARASSMENT',
                        threshold = 'BLOCK_NONE',
                    },
                    {
                        category = 'HARM_CATEGORY_SEXUALLY_EXPLICIT',
                        threshold = 'BLOCK_NONE',
                    },
                },
            },
        },
    },
}
```
