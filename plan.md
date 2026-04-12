# Add `duet` Manual NES Preview/Apply Flow

## Summary
Introduce a new music-themed module `duet` under `lua/minuet/duet/` as a separate next-edit-prediction feature alongside FIM. `duet` is configured via `require('minuet').setup { duet = { ... } }`, has its own provider selection and provider options, is manual-command-only in v1, and predicts a rewrite of a configurable editable region around the cursor.

`duet` is chat-provider-only, single-suggestion-only, and does not include edit-history/diff-sequence prompting in v1. It sends the full buffer plus editable-region markers to the model, previews the returned rewrite as a non-destructive diff, and applies it only on explicit user action.

The implementation is intentionally isolated from FIM. All duet-specific utilities stay under `lua/minuet/duet/`, and all duet backend code stays under `lua/minuet/duet/backends/`. Existing FIM modules should not be refactored for this feature.

## Public Interfaces
- Add top-level config key `duet` to `require('minuet').setup`.
- Add commands under the existing command tree:
  - `:Minuet duet predict`
  - `:Minuet duet apply`
  - `:Minuet duet dismiss`
- Expose Lua actions:
  - `require('minuet.duet').action.predict()`
  - `require('minuet.duet').action.apply()`
  - `require('minuet.duet').action.dismiss()`
  - `require('minuet.duet').action.is_visible()`
- Add new config shape:
  ```lua
  duet = {
      provider = 'openai',
      request_timeout = 15,
      editable_region = {
          lines_before = 8,
          lines_after = 8,
      },
      preview = {
          enabled = true,
      },
      provider_options = {
          openai = {
              system = ...,
              few_shots = ...,
              chat_input = {
                  template = ...,
              },
              ...
          },
          claude = { ... },
          gemini = { ... },
          openai_compatible = { ... },
      },
  }
  ```
- `duet` shares only these root settings with FIM:
  - `curl_cmd`
  - `curl_extra_args`
  - `proxy`
  - `notify`
- `duet` does not share FIM’s `provider`, `provider_options`, `throttle`, `debounce`, `context_window`, `context_ratio`, `n_completions`, filtering settings, or `request_timeout`.

## Template And Prompt Model
- Make NES input templating configurable via a plain string template.
- Add a dedicated duet template type:
  ```lua
  ---@class minuet.DuetChatInput
  ---@field template string
  ```
- Precompute a structured duet context before rendering the template:
  - `non_editable_region_before`
  - `editable_region_before_cursor`
  - `editable_region_after_cursor`
  - `non_editable_region_after`
- Support placeholders in `duet.provider_options.<provider>.chat_input.template` for those four dynamic parts only.
- Default template should be:
  ```text
  {{{non_editable_region_before}}}
  <editable_region_start>
  {{{editable_region_before_cursor}}}<cursor_position>{{{editable_region_after_cursor}}}
  <editable_region_end>
  {{{non_editable_region_after}}}
  ```
- `duet.provider_options.<provider>.chat_input` becomes the configurable prompt-body formatter.
- `duet.provider_options.<provider>.system` and `few_shots` remain configurable separately, same pattern as current chat providers.
- Implement duet-only prompt rendering inside `lua/minuet/duet/utils.lua` or equivalent duet-local helper module. Do not extend the current FIM prompt helpers in `lua/minuet/utils.lua`.
- The output contract stays fixed in v1:
  - exactly one `<editable_region_start>...<editable_region_end>` block
  - exactly one `<cursor_position>` inside that block

## Implementation Changes
- Add a self-contained duet module tree, for example:
  - `lua/minuet/duet/init.lua`
  - `lua/minuet/duet/config.lua`
  - `lua/minuet/duet/utils.lua`
  - `lua/minuet/duet/context.lua`
  - `lua/minuet/duet/preview.lua`
  - `lua/minuet/duet/backends/common.lua`
  - `lua/minuet/duet/backends/openai.lua`
  - `lua/minuet/duet/backends/openai_compatible.lua`
  - `lua/minuet/duet/backends/claude.lua`
  - `lua/minuet/duet/backends/gemini.lua`
- Keep all duet helpers, parsing, request assembly, preview logic, timeout handling, and provider-specific code inside that tree.
- Reuse existing FIM code only through minimal, stable seams where no feature refactor is needed:
  - root config entry in `lua/minuet/config.lua`
  - setup/command registration in `lua/minuet/init.lua`
  - no changes to FIM backends, FIM utils, cmp, blink, virtualtext, or lsp logic except what is strictly required to register `duet`

- Build duet context from the current buffer as:
  - Entire document is represented through the four template components above.
  - Editable region spans from `max(0, cursor_line - lines_before)` through `min(last_line, cursor_line + lines_after)`.
  - Cursor splits the editable region into `editable_region_before_cursor` and `editable_region_after_cursor`.
- Support v1 providers only for chat-style backends:
  - `openai`
  - `claude`
  - `gemini`
  - `openai_compatible`
- Do not support `codestral` or `openai_fim_compatible` in `duet` v1.

- `duet` transport policy:
  - streaming only
  - buffer streamed chunks until completion
  - validate only the final accumulated text
  - do not preview partial output
  - any timeout or malformed/incomplete response is a hard failure
  - use `duet.request_timeout` instead of the root timeout
- Implement duet-specific curl/request helpers under `lua/minuet/duet/` so timeout and transport behavior do not alter FIM behavior.

- Parse the model response strictly:
  - require one `<editable_region_start>...<editable_region_end>` block
  - require one `<cursor_position>` inside that block
  - remove the cursor marker to obtain replacement text
  - compute resulting cursor row/column from the marker location
  - on malformed output, notify and do not preview/apply anything

- Render preview as a unified diff-style virtual preview anchored after the editable region:
  - use extmarks and `virt_lines`
  - show removed lines with `DiffDelete`
  - show added lines with `DiffAdd`
  - omit unchanged lines
  - keep preview non-destructive until `apply`
- Store preview state per buffer:
  - original range
  - original lines
  - proposed lines
  - proposed cursor position
  - buffer `changedtick`
  - extmark ids
- `apply` replaces the full editable region with the proposed lines and restores the predicted cursor position.
- If buffer `changedtick` changed after `predict`, reject apply as stale, clear preview, and require a new `predict`.
- `dismiss` clears preview state and extmarks.

- Add distinct duet events:
  - `MinuetDuetRequestStartedPre`
  - `MinuetDuetRequestStarted`
  - `MinuetDuetRequestFinished`
- Do not add lualine integration or automatic triggering in v1.
- Do not implement edit-history/diff-sequence prompt context in v1.

## Test Plan
Manual validation is the primary test path for v1 since the repo currently has no test harness.

Validate these scenarios:
- `:Minuet duet predict` with cursor in the middle of a line produces a preview and preserves a cursor marker in the returned replacement.
- Region extraction near file start and file end respects available lines and does not error.
- `editable_region.lines_before` and `lines_after` override defaults correctly.
- Overriding `duet.provider_options.<provider>.chat_input.template` changes the serialized prompt shape correctly.
- The default template renders the four dynamic regions in the expected positions.
- `apply` replaces only the editable region, leaves the rest of the document untouched, and restores the predicted cursor position.
- `dismiss` clears the preview without changing buffer text.
- A second `predict` replaces the previous preview cleanly.
- Editing the buffer after `predict` makes the preview stale and causes `apply` to fail safely.
- Timeout produces no preview and no partial rewrite state.
- Malformed model output, including missing markers or missing cursor marker, is rejected safely.
- Each supported chat provider can send a streaming request, buffer the full response, and preview only after full validation.
- Existing FIM features and commands still work unchanged.

## Assumptions And Defaults
- Module name is `duet`.
- `duet` is manual-command-only in v1.
- `duet` returns one suggestion only.
- Preview is diff-based virtual lines, not inline text replacement and not a floating window.
- `duet` config is intentionally independent from FIM config except for shared root transport/runtime keys listed above.
- `duet.request_timeout` defaults to `15` seconds.
- `duet` supports streaming transport only; there is no duet-specific non-streaming option in v1.
- No `language` or `tab` fields are part of the duet template API.
- No `:Minuet duet change_provider` or `change_model` commands in v1; provider selection is config-driven.
- No edit-history/diff-sequence prompt context in v1.
- Existing FIM code should be touched only to register config and commands, not to host duet helpers or shared abstractions.
