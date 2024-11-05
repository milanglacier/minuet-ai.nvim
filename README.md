- [Minuet AI](#minuet-ai)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [API Keys](#api-keys)
- [System Prompt](#system-prompt)
- [Providers](#providers)
  - [OpenAI](#openai)
  - [Claude](#claude)
  - [Codestral](#codestral)
  - [Gemini](#gemini)
  - [OpenAI-compatible](#openai-compatible)
  - [OpenAI-FIM-compatible](#openai-fim-compatible)
  - [Huggingface](#huggingface)
- [Commands](#commands)
  - [MinuetChangeProvider](#minuetchangeprovider)
  - [MinuetToggle](#minuettoggle)
- [FAQ](#faq)
  - [Customize `cmp` ui](#customize-cmp-ui)
  - [Significant Input Delay When Moving to a New Line](#significant-input-delay-when-moving-to-a-new-line)
  - [Integration with `lazyvim`](#integration-with-lazyvim)
- [TODO](#todo)
- [Contributing](#contributing)
- [Acknowledgement](#acknowledgement)

# Minuet AI

Minuet AI: Dance with Intelligence in Your Code 💃.

`Minuet-ai` integrates with `nvim-cmp`, brings the grace and harmony of a
minuet to your coding process. Just as dancers move during a minuet.

# Features

- AI-powered code completion
- Support for multiple AI providers (OpenAI, Claude, Gemini, Codestral,
  Huggingface, and OpenAI-compatible services)
- Customizable configuration options
- Streaming support to enable completion delivery even with slower LLMs

![example](./assets/example.png)

# Requirements

- Neovim 0.10+.
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
- An API key for at least one of the supported AI providers

# Installation

Lazy

```lua
specs = {
    {
        'milanglacier/minuet-ai.nvim',
        config = function()
            require('minuet').setup {
                -- Your configuration options here
            }
        end
    },
    { 'nvim-lua/plenary.nvim' },
    { 'hrsh7th/nvim-cmp' },
}


-- If you wish to invoke completion manually,
-- The following configuration binds `A-y` key
-- to invoke the configuration manually.
require('cmp').setup {
    mapping = {
        ["<A-y>"] = require('minuet').make_cmp_map()
        -- and your other keymappings
    },
}
```

Given the response speed and rate limits of LLM services, we recommend you
either invoke `minuet` completion manually or use a cost-effective model for
auto-completion. The author recommends `gemini-1.5-flash` for auto-completion.
You need to add `minuet` into source of `nvim-cmp` for auto completion to work.

```lua
require('cmp').setup {
    sources = {
        {
            { name = 'minuet' },
            -- and your other sources
        }
    },
    performance = {
        -- It is recommended to increase the timeout duration due to
        -- the typically slower response speed of LLMs compared to
        -- other completion sources. This is not needed when you only
        -- need manual completion.
        fetching_timeout = 2000,
    },
}
```

If you are using a distribution like `lazyvim`, see the FAQ section to see how
to configure `minuet` with `lazyvim`, note that the author does not use
`lazyvim`, the FAQ section does not guarantee to work. PRs are welcome to fix
the problem if it exists.

# Configuration

Minuet AI comes with the following defaults:

```lua
default_config = {
    -- Enable or disable auto-completion. Note that you still need to add
    -- Minuet to your cmp sources. This option controls whether cmp will
    -- attempt to invoke minuet when minuet is included in cmp sources. This
    -- setting has no effect on manual completion; Minuet will always be
    -- enabled when invoked manually.
    enabled = true,
    provider = 'codestral',
    -- the maximum total characters of the context before and after the cursor
    -- 12,800 characters typically equate to approximately 4,000 tokens for
    -- LLMs.
    context_window = 12800,
    -- when the total characters exceed the context window, the ratio of
    -- context before cursor and after cursor, the larger the ratio the more
    -- context before cursor will be used. This option should be between 0 and
    -- 1, context_ratio = 0.75 means the ratio will be 3:1.
    context_ratio = 0.75,
    throttle = 1000, -- only send the request every x milliseconds, use 0 to disable throttle.
    -- debounce the request in x milliseconds, set to 0 to disable debounce
    debounce = 400,
    -- show notification when request is sent or request fails. options:
    -- false to disable notification. Note that you should use false, not "false".
    -- "verbose" for all notifications.
    -- "warn" for warnings and above.
    -- "error" just errors.
    notify = 'verbose',
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
    -- proxy port to use
    proxy = nil,
    provider_options = {
        -- see the documentation in each provider in the following part.
    },
    -- see the documentation in the `System Prompt` section
    default_template = {
        template = '...',
        prompt = '...',
        guidelines = '...',
        n_completion_template = '...',
    },
    default_few_shots = { '...' },
}
```

# API Keys

Minuet AI requires API keys to function. Set the following environment variables:

- `OPENAI_API_KEY` for OpenAI
- `GEMINI_API_KEY` for Gemini
- `ANTHROPIC_API_KEY` for Claude
- `CODESTRAL_API_KEY` for Codestral
- `HF_API_KEY` for Huggingface
- Custom environment variable for OpenAI-compatible services (as specified in your configuration)

# System Prompt

See [prompt](./prompt.md) for the default system prompt used by `minuet`.

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

# Providers

## OpenAI

the following is the default configuration for OpenAI:

```lua
provider_options = {
    openai = {
        model = 'gpt-4o-mini',
        system = default_system,
        few_shots = default_few_shots,
        stream = true,
        optional = {
            -- pass any additional parameters you want to send to OpenAI request,
            -- e.g.
            -- stop = { 'end' },
            -- max_tokens = 256,
            -- top_p = 0.9,
        },
    },
}
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lua
provider_options = {
    openai = {
        optional = {
            max_tokens = 256,
        },
    },
}
```

## Claude

the following is the default configuration for Claude:

```lua
provider_options = {
    claude = {
        max_tokens = 512,
        model = 'claude-3-5-haiku-20241022',
        system = default_system,
        few_shots = default_few_shots,
        stream = true,
        optional = {
            -- pass any additional parameters you want to send to claude request,
            -- e.g.
            -- stop_sequences = nil,
        },
    },
}
```

## Codestral

Codestral is a text completion model, not a chat model, so the system prompt
and few shot examples does not apply. Note that you should use the
`CODESTRAL_API_KEY`, not the `MISTRAL_API_KEY`, as they are using different
endpoint. To use the Mistral endpoint, simply modify the `end_point` and
`api_key` parameters in the configuration.

the following is the default configuration for Codestral:

```lua
provider_options = {
    codestral = {
        model = 'codestral-latest',
        end_point = 'https://codestral.mistral.ai/v1/fim/completions',
        api_key = 'CODESTRA_API_KEY',
        stream = true,
        optional = {
            stop = nil, -- the identifier to stop the completion generation
            max_tokens = nil,
        },
    },
}
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lua
provider_options = {
    codestral = {
        optional = {
            max_tokens = 256,
            stop = { '\n\n' },
        },
    },
}
```

## Gemini

The following config is the default.

```lua
provider_options = {
    gemini = {
        model = 'gemini-1.5-flash-latest',
        system = default_system,
        few_shots = default_few_shots,
        stream = true,
        optional = {},
    },
}
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens. You can also adjust the safety
settings following the example:

```lua
provider_options = {
    gemini = {
        optional = {
            generationConfig = {
                maxOutputTokens = 256,
            },
            safetySettings = {
                {
                    -- HARM_CATEGORY_HATE_SPEECH,
                    -- HARM_CATEGORY_HARASSMENT
                    -- HARM_CATEGORY_SEXUALLY_EXPLICIT
                    category = 'HARM_CATEGORY_DANGEROUS_CONTENT',
                    -- BLOCK_NONE
                    threshold = 'BLOCK_ONLY_HIGH',
                },
            },
        },
    },
}
```

## OpenAI-compatible

Use any providers compatible with OpenAI's chat completion API.

For example, you can set the `end_point` to
`http://localhost:11434/v1/chat/completions` to use `ollama`.

Note that not all openAI compatible services has streaming support, you should
change `stream=false` to disable streaming in case your services do not support
it.

The following config is the default.

```lua
provider_options = {
    openai_compatible = {
        model = 'llama-3.1-70b-versatile',
        system = default_system,
        few_shots = default_few_shots,
        end_point = 'https://api.groq.com/openai/v1/chat/completions',
        api_key = 'GROQ_API_KEY',
        name = 'Groq',
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
    }
}
```

## OpenAI-FIM-compatible

Use any provider compatible with OpenAI's completion API. This request uses the
text completion API, not chat completion, so system prompts and few-shot
examples are not applicable.

For example, you can set the `end_point` to
`http://localhost:11434/v1/completions` to use `ollama`.

Refer to the [Completions
Legacy](https://platform.openai.com/docs/api-reference/completions) section of
the OpenAI documentation for details.

Note that not all openAI compatible services has streaming support, you should
change `stream=false` to disable streaming in case your services do not support
it.

```lua
provider_options = {
    openai_fim_compatible = {
        model = 'deepseek-coder',
        end_point = 'https://api.deepseek.com/beta/completions',
        api_key = 'DEEPSEEK_API_KEY',
        name = 'Deepseek',
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
    }
}
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lua
provider_options = {
    openai_fim_compatible = {
        optional = {
            max_tokens = 256,
            stop = { '\n\n' },
        },
    },
}
```

## Huggingface

Currently only text completion model in huggingface is supported, so the system
prompt and few shot examples does not apply.

```lua
provider_options = {
    huggingface = {
        end_point = 'https://api-inference.huggingface.co/models/bigcode/starcoder2-3b',
        type = 'completion',
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
```

# Commands

## MinuetChangeProvider

This command allows you to change the provider after `Minuet` has been setup.

## MinuetToggle

Enable or disable auto-completion. Note that you still need to add Minuet to
your cmp sources. This command controls whether cmp will attempt to invoke
minuet when minuet is included in cmp sources. This command has no effect on
manual completion; Minuet will always be enabled when invoked manually.

# FAQ

## Customize `cmp` ui

You can configure the icons of `minuet` by using the following snippet
(referenced from [cmp's
wiki](https://github.com/hrsh7th/nvim-cmp/wiki/Menu-Appearance#basic-customisations)):

```lua
local cmp = require('cmp')
cmp.setup {
  formatting = {
    format = function(entry, vim_item)
      -- Kind icons
      vim_item.kind = string.format('%s %s', kind_icons[vim_item.kind], vim_item.kind) -- This concatenates the icons with the name of the item kind
      -- Source
      vim_item.menu = ({
        minuet = "󱗻"
      })[entry.source.name]
      return vim_item
    end
  },
}
```

## Significant Input Delay When Moving to a New Line

When using Minuet with auto-complete enabled, you may occasionally experience a
noticeable delay when pressing `<CR>` to move to the next line. This occurs
because Minuet triggers autocompletion at the start of a new line, while cmp
blocks the `<CR>` key, awaiting Minuet's response.

To address this issue, consider the following solutions:

1. Unbind the `<CR>` key from your cmp keymap.
2. Utilize cmp's internal API to avoid blocking calls, though be aware that
   this API may change without prior notice.

Here's an example of the second approach using Lua:

```lua
local cmp = require 'cmp'
opts.mapping = {
    ['<CR>'] = cmp.mapping(function(fallback)
        -- use the internal non-blocking call to check if cmp is visible
        if cmp.core.view:visible() then
            cmp.confirm { select = true }
        else
            fallback()
        end
    end),
}
```

## Integration with `lazyvim`

```lua
{
    'milanglacier/minuet-ai.nvim',
    config = function()
        require('minuet').setup {
            -- Your configuration options here
        }
    end
},
{ 'nvim-lua/plenary.nvim' },
{
    'nvim-cmp',
    opts = function(_, opts)
        -- if you wish to use autocomplete
        table.insert(opts.sources, 1, {
            name = 'minuet',
            group_index = 1,
            priority = 100,
        })

        opts.performance = {
            -- It is recommended to increase the timeout duration due to
            -- the typically slower response speed of LLMs compared to
            -- other completion sources. This is not needed when you only
            -- need manual completion.
            fetching_timeout = 2000,
        }

        opts.mapping = vim.tbl_deep_extend('force', opts.mapping or {}, {
            -- if you wish to use manual complete
            ['<A-y>'] = require('minuet').make_cmp_map(),
            -- You don't need to worry about <CR> delay because lazyvim handles this situation for you.
            ['<CR>'] = nil,
        })
    end,
}
```

# TODO

1. Implement `RAG` on the codebase and encode the codebase information into the request to LLM.
2. Virtual text UI support.

# Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

# Acknowledgement

- [cmp-ai](https://github.com/tzachar/cmp-ai): A large piece of the codebase are based on this plugin.
- [continue.dev](https://www.continue.dev): not a neovim plugin, but I find a lot LLM models from here.
