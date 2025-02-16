- [Minuet AI](#minuet-ai)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Selecting a Provider or Model](#selecting-a-provider-or-model)
- [Configuration](#configuration)
- [API Keys](#api-keys)
- [Prompt](#prompt)
- [Providers](#providers)
  - [OpenAI](#openai)
  - [Claude](#claude)
  - [Codestral](#codestral)
  - [Gemini](#gemini)
    - [Experimental Configuration](#experimental-configuration)
  - [OpenAI-compatible](#openai-compatible)
  - [OpenAI-FIM-compatible](#openai-fim-compatible)
- [Commands](#commands)
  - [`Minuet change_provider`, `Minuet change_model`](#minuet-change_provider-minuet-change_model)
  - [`Minuet change_preset`](#minuet-change_preset)
  - [`Minuet blink`, `Minuet cmp`](#minuet-blink-minuet-cmp)
  - [`Minuet virtualtext`](#minuet-virtualtext)
- [API](#api)
  - [Virtual Text](#virtual-text)
- [FAQ](#faq)
  - [Customize `cmp` ui](#customize-cmp-ui)
  - [Significant Input Delay When Moving to a New Line](#significant-input-delay-when-moving-to-a-new-line)
  - [Integration with `lazyvim`](#integration-with-lazyvim)
- [Enhancement](#enhancement)
  - [RAG (Experimental)](#rag-experimental)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Acknowledgement](#acknowledgement)

# Minuet AI

Minuet AI: Dance with Intelligence in Your Code 💃.

`Minuet-ai` brings the grace and harmony of a minuet to your coding process.
Just as dancers move during a minuet.

# Features

- AI-powered code completion with dual modes:
  - Specialized prompts and various enhancements for chat-based LLMs on code completion tasks.
  - Fill-in-the-middle (FIM) completion for compatible models (DeepSeek,
    Codestral, Qwen, and others).
- Support for multiple AI providers (OpenAI, Claude, Gemini, Codestral, Ollama, and
  OpenAI-compatible services).
- Customizable configuration options.
- Streaming support to enable completion delivery even with slower LLMs.
- No proprietary binary running in the background. Just curl and your preferred LLM provider.
- Support `nvim-cmp`, `blink-cmp`, `virtual text` frontend.

**With nvim-cmp / blink-cmp frontend**:

![example-cmp](./assets/example-cmp.png)

**With virtual text frontend**:

![example-virtual-text](./assets/example-virtual-text.png)

# Requirements

- Neovim 0.10+.
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- optional: [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
- optional: [blink.cmp](https://github.com/Saghen/blink.cmp)
- An API key for at least one of the supported AI providers

# Installation

**Lazy.nvim**:

```lua
specs = {
    {
        'milanglacier/minuet-ai.nvim',
        config = function()
            require('minuet').setup {
                -- Your configuration options here
            }
        end,
    },
    { 'nvim-lua/plenary.nvim' },
    -- optional, if you are using virtual-text frontend, nvim-cmp is not
    -- required.
    { 'hrsh7th/nvim-cmp' },
    -- optional, if you are using virtual-text frontend, blink is not required.
    { 'Saghen/blink.cmp' },
}
```

**Rocks.nvim**:

`Minuet` is available on luarocks.org. Simply run `Rocks install
minuet-ai.nvim` to install it like any other luarocks package.

**Setting up with virtual text**:

```lua
require('minuet').setup {
    virtualtext = {
        auto_trigger_ft = {},
        keymap = {
            -- accept whole completion
            accept = '<A-A>',
            -- accept one line
            accept_line = '<A-a>',
            -- accept n lines (prompts for number)
            -- e.g. "A-z 2 CR" will accept 2 lines
            accept_n_lines = '<A-z>',
            -- Cycle to prev completion item, or manually invoke completion
            prev = '<A-[>',
            -- Cycle to next completion item, or manually invoke completion
            next = '<A-]>',
            dismiss = '<A-e>',
        },
    },
}
```

**Setting up with nvim-cmp**:

<details>

```lua
require('cmp').setup {
    sources = {
        {
             -- Include minuet as a source to enable autocompletion
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

</details>

**Setting up with blink-cmp**:

<details>

```lua
require('blink-cmp').setup {
    keymap = {
        -- Manually invoke minuet completion.
        ['<A-y>'] = require('minuet').make_blink_map(),
    },
    sources = {
         -- Enable minuet for autocomplete
        default = { 'lsp', 'path', 'buffer', 'snippets', 'minuet' },
        -- For manual completion only, remove 'minuet' from default
        providers = {
            minuet = {
                name = 'minuet',
                module = 'minuet.blink',
                score_offset = 8, -- Gives minuet higher priority among suggestions
            },
        },
    },
    -- Recommended to avoid unnecessary request
    completion = { trigger = { prefetch_on_insert = false } },
}
```

</details>

**LLM Provider Examples**:

**Fireworks (`Qwen-2.5-72b`)**:

<details>

```lua
require('minuet').setup {
    provider = 'openai_compatible',
    provider_options = {
        openai_compatible = {
            api_key = 'FIREWORKS_API_KEY',
            end_point = 'https://api.fireworks.ai/inference/v1/chat/completions',
            model = 'accounts/fireworks/models/qwen2p5-72b-instruct',
            name = 'Fireworks',
            optional = {
                max_tokens = 256,
                top_p = 0.9,
            },
        },
    },
}
```

</details>

**Deepseek**:

<details>

```lua
-- you can use deepseek with both openai_fim_compatible or openai_compatible provider
require('minuet').setup {
    provider = 'openai_fim_compatible',
    provider_options = {
        openai_fim_compatible = {
            api_key = 'DEEPSEEK_API_KEY',
            name = 'deepseek',
            optional = {
                max_tokens = 256,
                top_p = 0.9,
            },
        },
    },
}


-- or
require('minuet').setup {
    provider = 'openai_compatible',
    provider_options = {
        openai_compatible = {
            end_point = 'https://api.deepseek.com/v1/chat/completions',
            api_key = 'DEEPSEEK_API_KEY',
            name = 'deepseek',
            optional = {
                max_tokens = 256,
                top_p = 0.9,
            },
        },
    },
}
```

</details>

**Ollama (`qwen-2.5-coder:7b`)**:

<details>

```lua
require('minuet').setup {
    provider = 'openai_fim_compatible',
    n_completions = 1, -- recommend for local model for resource saving
    -- I recommend beginning with a small context window size and incrementally
    -- expanding it, depending on your local computing power. A context window
    -- of 512, serves as an good starting point to estimate your computing
    -- power. Once you have a reliable estimate of your local computing power,
    -- you should adjust the context window to a larger value.
    context_window = 512,
    provider_options = {
        openai_fim_compatible = {
            api_key = 'TERM',
            name = 'Ollama',
            end_point = 'http://localhost:11434/v1/completions',
            model = 'qwen2.5-coder:7b',
            optional = {
                max_tokens = 256,
                top_p = 0.9,
            },
        },
    },
}
```

</details>

# Selecting a Provider or Model

The `gemini-flash` and `codestral` models offer high-quality output with free
and fast processing. For optimal quality (albeit slower generation speed),
consider using the `deepseek-chat` model, which is compatible with both
`openai-fim-compatible` and `openai-compatible` providers. For local LLM
inference, you can deploy either `qwen-2.5-coder` or `deepseek-coder-v2` through
Ollama using the `openai-fim-compatible` provider.

As of January 28, 2025: Due to high server demand, Deepseek users may
experience significant response delays or timeout. We recommend trying
alternative providers instead.

# Configuration

Minuet AI comes with the following defaults:

```lua
default_config = {
    -- Enable or disable auto-completion. Note that you still need to add
    -- Minuet to your cmp/blink sources. This option controls whether cmp/blink
    -- will attempt to invoke minuet when minuet is included in cmp/blink
    -- sources. This setting has no effect on manual completion; Minuet will
    -- always be enabled when invoked manually. You can use the command
    -- `Minuet cmp/blink toggle` to toggle this option.
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
            accept_n_lines = nil,
            -- Cycle to next completion item, or manually invoke completion
            next = nil,
            -- Cycle to prev completion item, or manually invoke completion
            prev = nil,
            dismiss = nil,
        },
        -- Whether show virtual text suggestion when the completion menu
        -- (nvim-cmp or blink-cmp) is visible.
        show_on_completion_menu = false,
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
    -- If completion item has multiple lines, create another completion item
    -- only containing its first line. This option only has impact for cmp and
    -- blink. For virtualtext, no single line entry will be added.
    add_single_line_entry = true,
    -- The number of completion items encoded as part of the prompt for the
    -- chat LLM. For FIM model, this is the number of requests to send. It's
    -- important to note that when 'add_single_line_entry' is set to true, the
    -- actual number of returned items may exceed this value. Additionally, the
    -- LLM cannot guarantee the exact number of completion items specified, as
    -- this parameter serves only as a prompt guideline.
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
    -- see the documentation in the `Prompt` section
    default_template = {
        template = '...',
        prompt = '...',
        guidelines = '...',
        n_completion_template = '...',
    },
    default_fim_template = {
        prompt = '...',
        suffix = '...',
    },
    default_few_shots = { '...' },
    default_chat_input = { '...' },
    -- Config options for `Minuet change_preset` command
    presets = {}
}
```

# API Keys

Minuet AI requires API keys to function. Set the following environment variables:

- `OPENAI_API_KEY` for OpenAI
- `GEMINI_API_KEY` for Gemini
- `ANTHROPIC_API_KEY` for Claude
- `CODESTRAL_API_KEY` for Codestral
- Custom environment variable for OpenAI-compatible services (as specified in your configuration)

**Note:** Provide the name of the environment variable to Minuet, not the
actual value. For instance, pass `OPENAI_API_KEY` to Minuet, not the value
itself (e.g., `sk-xxxx`).

If using Ollama, you need to assign an arbitrary, non-null environment variable
as a placeholder for it to function.

Alternatively, you can provide a function that returns the API key. This
function should return the result instantly as it will be called for each
completion request.

```lua
require('mineut').setup {
    provider_options = {
        openai_compatible = {
            -- good
            api_key = 'FIREWORKS_API_KEY', -- will read the environment variable FIREWORKS_API_KEY
            -- good
            api_key = function() return 'sk-xxxx' end,
            -- bad
            api_key = 'sk-xxxx',
        }
    }
}
```

# Prompt

See [prompt](./prompt.md) for the default prompt used by `minuet` and
instructions on customization.

Note that `minuet` employs two distinct prompt systems:

1. A system designed for chat-based LLMs (OpenAI, OpenAI-Compatible, Claude,
   and Gemini)
2. A separate system designed for Codestral and OpenAI-FIM-compatible models

# Providers

## OpenAI

<details>

the following is the default configuration for OpenAI:

```lua
provider_options = {
    openai = {
        model = 'gpt-4o-mini',
        system = "see [Prompt] section for the default value",
        few_shots = "see [Prompt] section for the default value",
        chat_input = "See [Prompt Section for default value]",
        stream = true,
        api_key = 'OPENAI_API_KEY',
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

</details>

## Claude

<details>

the following is the default configuration for Claude:

```lua
provider_options = {
    claude = {
        max_tokens = 512,
        model = 'claude-3-5-haiku-20241022',
        system = "see [Prompt] section for the default value",
        few_shots = "see [Prompt] section for the default value",
        chat_input = "See [Prompt Section for default value]",
        stream = true,
        api_key = 'ANTHROPIC_API_KEY',
        optional = {
            -- pass any additional parameters you want to send to claude request,
            -- e.g.
            -- stop_sequences = nil,
        },
    },
}
```

</details>

## Codestral

<details>

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
        api_key = 'CODESTRAL_API_KEY',
        stream = true,
        template = {
            prompt = "See [Prompt Section for default value]",
            suffix = "See [Prompt Section for default value]",
        },
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

</details>

## Gemini

You should register the account and use the service from Google AI Studio
instead of Google Cloud. You can get an API key via their
[Google API page](https://makersuite.google.com/app/apikey).

<details>

The following config is the default.

```lua
provider_options = {
    gemini = {
        model = 'gemini-2.0-flash',
        system = "see [Prompt] section for the default value",
        few_shots = "see [Prompt] section for the default value",
        chat_input = "See [Prompt Section for default value]",
        stream = true,
        api_key = 'GEMINI_API_KEY',
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

### Experimental Configuration

Gemini appears to perform better with an alternative input structure, unlike
other chat-based LLMs. This observation is currently experimental and requires
further validation. For details on the experimental prompt setup currently in
use by the maintainer, please refer to the [prompt
documentation](./prompt.md#an-experimental-configuration-setup-for-gemini).

</details>

## OpenAI-compatible

Use any providers compatible with OpenAI's chat completion API.

For example, you can set the `end_point` to
`http://localhost:11434/v1/chat/completions` to use `ollama`.

<details>

Note that not all openAI compatible services has streaming support, you should
change `stream=false` to disable streaming in case your services do not support
it.

The following config is the default.

```lua
provider_options = {
    openai_compatible = {
        model = 'llama-3.3-70b-versatile',
        system = "see [Prompt] section for the default value",
        few_shots = "see [Prompt] section for the default value",
        chat_input = "See [Prompt Section for default value]",
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

</details>

## OpenAI-FIM-compatible

Use any provider compatible with OpenAI's completion API. This request uses the
text completion API, not chat completion, so system prompts and few-shot
examples are not applicable.

For example, you can set the `end_point` to
`http://localhost:11434/v1/completions` to use `ollama`.

Cmdline completion is available for models supported by these providers:
`deepseek`, `ollama`, and `siliconflow`.

<details>

Refer to the [Completions
Legacy](https://platform.openai.com/docs/api-reference/completions) section of
the OpenAI documentation for details.

Please note that not all OpenAI-compatible services support streaming. If your
service does not support streaming, you should set `stream=false` to disable
it.

Additionally, for Ollama users, it is essential to verify whether the model's
template supports FIM completion. For example, qwen2.5-coder offers FIM
support, as suggested in its
[template](https://ollama.com/library/qwen2.5-coder/blobs/e94a8ecb9327).
However it may come as a surprise to some users that, `deepseek-coder` does not
support the FIM template, and you should use `deepseek-coder-v2` instead.

```lua
provider_options = {
    openai_fim_compatible = {
        model = 'deepseek-chat',
        end_point = 'https://api.deepseek.com/beta/completions',
        api_key = 'DEEPSEEK_API_KEY',
        name = 'Deepseek',
        stream = true,
        template = {
            prompt = "See [Prompt Section for default value]",
            suffix = "See [Prompt Section for default value]",
        },
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

</details>

# Commands

## `Minuet change_provider`, `Minuet change_model`

The `change_provider` command allows you to change the provider after `Minuet`
has been setup.

Example usage: `Minuet change_provider claude`

The `change_model` command allows you to change both the provider and model in
one command. When called without arguments, it will open an interactive
selection menu using `vim.ui.select` to choose from available models. When
called with an argument, the format is `provider:model`.

Example usage:

- `Minuet change_model` - Opens interactive model selection
- `Minuet change_model gemini:gemini-1.5-pro-latest` - Directly sets the model

Note: For `openai_compatible` and `openai_fim_compatible` providers, the model
completions in cmdline are determined by the `name` field in your
configuration. For example, if you configured:

```lua
provider_options.openai_compatible.name = 'Fireworks'
```

When entering `Minuet change_model openai_compatible:` in the cmdline,
you'll see model completions specific to the Fireworks provider.

## `Minuet change_preset`

The `change_preset` command allows you to switch between config presets that
were defined during initial setup. Presets provide a convenient way to toggle
between different config sets. This is particularly useful when you need to:

- Switch between different cloud providers (such as Fireworks or Groq) for the
  `openai_compatible` provider
- Apply different throttle and debounce settings for different providers

When called, the command merges the selected preset with the current config
table to create an updated configuration.

Usage syntax: `Minuet change_preset preset_1`

Presets can be configured during the initial setup process.

<details>

```lua
require('minuet').setup {
    presets = {
        preset_1 = {
            -- Configuration for cloud-based requests with large context window
            context_window = 20000,
            request_timeout = 4,
            throttle = 3000,
            debounce = 1000,
            provider = 'openai_compatible',
            provider_options = {
                openai_compatible = {
                    model = 'llama-3.3-70b-versatile',
                    api_key = 'GROQ_API_KEY',
                    name = 'Groq'
                }
            }
        },
        preset_2 = {
            -- Configuration for local model with smaller context window
            provider = 'openai_fim_compatible',
            context_window = 2000,
            throttle = 400,
            debounce = 100,
            provider_options = {
                openai_fim_compatible = {
                    api_key = 'TERM',
                    name = 'Ollama',
                    end_point = 'http://localhost:11434/v1/completions',
                    model = 'qwen2.5-coder:7b',
                    optional = {
                        max_tokens = 256,
                        top_p = 0.9
                    }
                }
            }
        }
    }
}
```

</details>

## `Minuet blink`, `Minuet cmp`

Enable or disable autocompletion for `nvim-cmp` or `blink.cmp`. While Minuet
must be added to your cmp/blink sources, this command only controls whether
Minuet is triggered during autocompletion. The command does not affect manual
completion behavior - Minuet remains active and available when manually
invoked.

Example usage: `Minuet blink toggle`, `Minuet blink enable`, `Minuet blink disable`

## `Minuet virtualtext`

Enable or disable the automatic display of `virtual-text` completion in the
**current buffer**.

Example usage: `Minuet virtualtext toggle`, `Minuet virtualtext enable`,
`Minuet virtualtext disable`.

# API

## Virtual Text

`minuet-ai.nvim` offers the following functions to customize your key mappings:

```lua
{
    -- accept whole completion
    require('minuet.virtualtext').action.accept,
    -- accept by line
    require('minuet.virtualtext').action.accept_line,
    -- accept n lines (prompts for number)
    require('minuet.virtualtext').action.accept_n_lines,
    require('minuet.virtualtext').action.next,
    require('minuet.virtualtext').action.prev,
    require('minuet.virtualtext').action.dismiss,
    -- whether the virtual text is visible in current buffer
    require('minuet.virtualtext').action.is_visible,
}
```

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

<details>

**With nvim-cmp**:

```lua
{
    'milanglacier/minuet-ai.nvim',
    config = function()
        require('minuet').setup {
            -- Your configuration options here
        }
    end
},
{
    'nvim-cmp',
    optional = true,
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
        })
    end,
}
```

**With blink-cmp**:

```lua
-- set the following line in your config/options.lua
vim.g.lazyvim_blink_main = true

{
    'milanglacier/minuet-ai.nvim',
    config = function()
        require('minuet').setup {
            -- Your configuration options here
        }
    end,
},
{
    'saghen/blink.cmp',
    optional = true,
    opts = {
        keymap = {
            ['<A-y>'] = {
                function(cmp)
                    cmp.show { providers = { 'minuet' } }
                end,
            },
        },
        sources = {
            -- if you want to use auto-complete
            default =  { 'minuet' },
            providers = {
                minuet = {
                    name = 'minuet',
                    module = 'minuet.blink',
                    score_offset = 100,
                },
            },
        },
    },
}
```

</details>

# Enhancement

## RAG (Experimental)

You can enhance the content sent to the LLM for code completion by leveraging
RAG support through the [VectorCode](https://github.com/Davidyz/VectorCode)
package.

VectorCode contains two main components. The first is a standalone CLI program
written in Python, available for installation via PyPI. This program is
responsible for creating the vector database and processing RAG queries. The
second component is a Neovim plugin that provides utility functions to send
queries and manage buffer-related RAG information within Neovim.

For a project that has been
[indexed by VectorCode](https://github.com/Davidyz/VectorCode/blob/main/docs/cli.md),
you can add the query results to the prompt. After that, when you're working on
a buffer that has been
[registered](https://github.com/Davidyz/VectorCode/blob/main/docs/neovim.md#user-command)
with vectorcode, the automatically retrieved relevant files from the repo will
be added to the prompt and hence improve the completion results. The entire
retrieval process happens locally on your machine (but you have the option to
use a hosted embedding model or database provider).

### Chat-based Backends
For chat-based backends like [OpenAI](#openai) and [Claude](#claude), we need to
modify `chat_input` so that it contains the project context. To do this, we can
add an extra placeholder in the template:
```lua
provider_options = {
    openai = { -- or any chat-based backend
        chat_input = {
            template = '{{{language}}}\n{{{tab}}}\n{{{repo_context}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>\n<contextAfterCursor>\n{{{context_after_cursor}}}'
            repo_context = function()
                local vc_cache = require("vectorcode.cacher")
                local repo_files =
                    "Use content lead by <|repo_file|> as extra context from the code repository."

                for _, file in pairs(vc_cache.query_from_cache(0)) do
                    -- add the repo context files here
                    repo_files = repo_files
                        .. "<|repo_file|>"
                        .. file.path  -- path to the file
                        .. "\n"
                        .. file.document  -- content of the file
                end
                return repo_files
            end
        }
    }
}
```
The `repo_context` function will populate the `{{{repo_context}}}` placeholder
in the template and therefore add repo context to the prompt.

### FIM-compatible Backends
For FIM-compatible backends like [Codestral](#codestral) and
[openai_fim_compatible](#openai-fim-compatible), the actual prompt fed to the
LLM is made up of the `prompt` and `suffix` options in the minuet
configuration. The default `prompt` and `suffix` are the lines before and after
the cursor position, and the LLM server will build the actual prompt from these
2 values. Since the inference server may add extra content when building the
actual prompt, simply adding repo context to `prompt` may break the FIM
completion. To preserve the FIM functionality, we need to override this by setting
`suffix` to `false` so that the LLM server will skip the prompt construction and
just use the string in the `prompt` option as the prompt. We can then add the
repo context in the `prompt` option. In this case, the `prompt` function will
contain: repo context, prefix, suffix, cursor position and any other
instructions/context you want to feed to the LLM.

```lua
provider_options = {
    openai_fim_compatible = {  -- or codestral, etc.
        -- your other provider options
        template = {
            prompt = function(prefix, suffix)
                local prompt_message =
                    "Use content lead by <|repo_file|> as extra context from the code repository."
                local vc_cache = require("vectorcode.cacher")
                for _, file in pairs(vc_cache.query_from_cache(0)) do
                    -- add the repo context files here
                    prompt_message = prompt_message
                        .. "<|repo_file|>"
                        .. file.path  -- path to the file
                        .. "\n"
                        .. file.document  -- content of the file
                end
                return prompt_message
                    .. "<|fim_begin|>"
                    .. pref
                    .. "<|fim_hole|>"
                    .. suff
                    .. "<|fim_end|>"
            end,
            suffix = false,
        }
    }
}
```

> [!NOTE]
> Symbols like `<|repo_file|>`, `<|fim_begin|>` are control tokens to tell LLMs
> about different sections of the prompt. Some LLMs, like Qwen2.5-Coder and
> Gemini, have been trained with specific control tokens that will help them
> better understand the prompt composition. The
> [VectorCode wiki](https://github.com/Davidyz/VectorCode/wiki/Prompt-Gallery)
> provides a comprehensive list of prompt structures tailored for various LLMs
> (Qwen2.5-coder, deepseek-V3, Google Gemini, Codestral, StarCoder2, etc.).
> These structures and control tokens help the models generate more accurate
> completions.

For detailed instructions on setting up and using VectorCode, please refer to the
[official VectorCode
documentation](https://github.com/Davidyz/VectorCode/blob/main/docs/neovim.md).

# Troubleshooting

If your setup failed, there are two most likely reasons:

1. You may set the API key incorrectly. Checkout the [API Key](#api-keys)
   section to see how to correctly specify the API key.
2. You are using a model or a context window that is too large, causing
   completion items to timeout before returning any tokens. This is
   particularly common with local LLM. It is recommended to start with the
   following settings to have a better understanding of your provider's inference
   speed.
   - Begin by testing with manual completions.
   - Use a smaller context window (e.g., `config.context_window = 768`)
   - Use a smaller model
   - Set a longer request timeout (e.g., `config.request_timeout = 5`)

To diagnose issues, set `config.notify = debug` and examine the output.

# Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

# Acknowledgement

- [cmp-ai](https://github.com/tzachar/cmp-ai): Reference for the integration with `nvim-cmp`.
- [continue.dev](https://www.continue.dev): not a neovim plugin, but I find a lot LLM models from here.
- [copilot.lua](https://github.com/zbirenbaum/copilot.lua): Reference for the virtual text frontend.
