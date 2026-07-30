# Lazy activation for the duet recent-edits recorder

Status: implemented (including two review-round revisions: the lazy starter is
`ensure_setup`, and the recorder owns a dedicated augroup).

## Context

The recent-edits recorder (`lua/minuet/duet/edits.lua`) used to register its
autocmds unconditionally at plugin setup (`edits.setup()` called from
`duet.setup()`). Users who only use inline completion — and never invoke duet —
still paid for `TextChanged*` debounce timers, buffer snapshots to temp files,
and spawned external `diff` processes, feeding a history only `duet.predict()`
ever consumes.

Decision (confirmed with user): `duet.recent_edits.enabled` becomes a
tri-state:

- `'lazy'` (**new default**) — recorder autocmds register on the first
  `duet.action.predict()` call. Inline-only users pay exactly zero; duet users
  need no config change. Trade-off: edits made before the first prediction of
  a session are never recorded, so the first prediction has an empty history
  (eager mode would contain everything since setup); history accumulates from
  the first prediction onward.
- `true` — eager: register at plugin setup, the previous behavior — for users
  who want the first prediction to already carry the session's edit history.
- `false` — fully off.

No `warn_on_*` notification option is added.

## Changes

### 1. `lua/minuet/duet/config.lua` — tri-state default

- `recent_edits.enabled` default changed from `true` to `'lazy'`.
- `minuet.DuetRecentEdits` annotation updated to
  `---@field enabled boolean|'lazy'` with a doc comment explaining the three
  values.

### 2. `lua/minuet/duet/edits.lua` — split setup vs. ensure_setup

- The recorder owns a dedicated `MinuetDuetEdits` augroup (module-local
  `augroup_name`), created inside edits.lua instead of sharing minuet.duet's
  `MinuetDuet` augroup. This lets the recorder clear its own registrations
  without touching duet's autocmds, and removes the augroup parameter
  threading from `duet/init.lua`.
- `internal.started` tracks whether the autocmds are registered in the
  current lifecycle.
- The existing truthiness checks (`not config.enabled` in `is_trackable`,
  `arm_debounce`, `render`) already treat `'lazy'` as enabled — unchanged.
- **`M.setup()`** (no arguments) is the config-lifecycle hook:
  - calls `M.reset()` (tears down snapshots/processes, clears the
    failure-`disabled` flag),
  - recreates the `MinuetDuetEdits` augroup with `{ clear = true }` to drop
    the previous lifecycle's autocmds, sets `internal.started = false`,
  - when `config.enabled == true` (eager), calls `M.ensure_setup()`
    immediately; otherwise registers nothing.
- **`M.ensure_setup()`** — idempotent starter, shared by the eager path and
  the lazy trigger:
  - returns immediately when `internal.started`, `internal.disabled`, config
    missing, or `not config.enabled`;
  - holds the diff-program pre-flight (moved out of setup): when
    `vim.fn.executable(config.diff_program) ~= 1`, sets
    `internal.disabled = true` and notifies once ('warn'). `started` stays
    false on this path so a reset + reinstall can still recover; under
    `'lazy'` only actual duet users ever see the warning;
  - otherwise sets `internal.started = true`, recreates the augroup with
    `{ clear = true }` (a registration can never stack on a previous one),
    registers the five autocmd blocks (BufEnter / BufReadPost /
    TextChanged* / BufLeave / BufUnload+BufWipeout), and calls
    `M.track(api.nvim_get_current_buf())` to baseline the buffer whose
    BufEnter already fired. Current buffer only — other open buffers are
    baselined by BufEnter when next visited.
- `flush()` / `render()` / `track()` were already safe before the recorder is
  set up (guards via `is_trackable` / `config.enabled`); unchanged.

### 3. `lua/minuet/duet/init.lua` — trigger on first predict

- `predict()` calls `edits.ensure_setup()` right before
  `edits.flush(bufnr, { wait = true })`. `predict` is the only entrypoint
  that consumes the history; `apply`/`dismiss`/`is_visible` don't need it.
- `M.setup()` calls `edits.setup()` (no augroup argument anymore).

### 4. Tests (`tests/duet_edits_spec.lua`, `tests/duet_edits_bench.lua`)

- Autocmd-dependent tests that call `duet.setup()` and rely on registered
  autocmds (TextChanged debounce, InsertLeave coalescing, buffer switch,
  BufReadPost, :bunload, wipeout, orphaned-diff, and diff-program pre-flight
  tests) pass `recent_edits = { enabled = true }` so they exercise the eager
  path with the previous semantics.
- 'duet.action.predict flushes the pending burst into context.recent_edits'
  runs under the `'lazy'` default and covers predict-triggers-ensure_setup
  end-to-end.
- `duet_edits_bench.lua` uses `enabled = true` with `edits.setup()` and
  cleans up via `nvim_del_augroup_by_name 'MinuetDuetEdits'`.
- The `count_recorder_autocmds()` helper counts autocmds in the
  `MinuetDuetEdits` group (owned exclusively by the recorder).
- New test cases:
  - default (`'lazy'`): after `duet.setup()`, no recorder autocmds exist and
    a TextChanged burst records no event;
  - `edits.ensure_setup()` registers the autocmds, is idempotent (second
    call doesn't change the count), and baselines the current buffer;
  - `enabled = true`: autocmds exist immediately after `duet.setup()`;
  - `enabled = false`: `ensure_setup()` is a no-op;
  - `duet.action.predict` starts the lazy recorder on first use (autocmd
    count goes from zero to registered).

### 5. Docs (`README.md`)

- "Recent Edits" section documents the tri-state, including the lazy
  trade-off (edits made before the first prediction are not recorded, so the
  first prediction of a session has an empty history).
- Default-config block shows `enabled = 'lazy'` with a comment listing the
  three values.

## Verification

- `make test` (runs `nvim --headless -u NONE -i NONE -n +"lua
  require('tests.run').run()"`) — full suite passes, including the new
  tri-state cases. `make format-check` (stylua) is clean.
- Manual smoke: `nvim` with the plugin, confirm
  `:lua vim.print(vim.api.nvim_get_autocmds{group='MinuetDuetEdits'})` is
  empty before the first `:Minuet duet` predict and populated after; with
  `enabled = true`, populated immediately after setup; second predict
  includes edit history.
