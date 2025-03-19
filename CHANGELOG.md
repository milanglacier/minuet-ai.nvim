# Version 0.4.0 (2025-03-18)

## Features

- Introduced in-process LSP support for built-in completion.
- For `blink-cmp`, the completion item's `kind_name` now reflects the LLM provider name.
- Improve error handling for both stream and non-stream JSON decoding, providing more informative messages.

# Version 0.3.3 (2025-02-18)

## Documentation

- Added recipes for llama.cpp
- Added recipes for integration with VectorCode

# Version 0.3.2 (2025-02-10)

- Add luarocks release

# Version 0.3.1 (2025-02-10)

## Features

- `Minuet change_model` now supports `vim.ui.select`

# Version 0.3 (2025-02-09)

## Breaking Changes

- Remove Hugging Face provider
- Remove deprecated commands (`MinuetToggle*`, `MinuetChange*`)

## Features

- Add option to show suggestion when completion menu is visible
- Support api_key as a function

# Version 0.2 (2025-02-05)

## Breaking Changes

- Update default gemini model to gemini-2.0-flash

## Features

- Add command `Minuet change_preset`
- Add option to show suggestion when completion menu is visible

## Documentation

- Add RAG experimental feature doc with vectorcode

# Version 0.1 (2025-02-02)

- Initial release
