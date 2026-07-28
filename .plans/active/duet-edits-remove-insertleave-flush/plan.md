# Remove the InsertLeave flush from the duet recent-edits recorder

## Context

`lua/minuet/duet/edits.lua` flushes the pending edit burst on every
`InsertLeave`. For a mode-toggling editing style (type a phrase, `Esc`,
motion, `i`, repeat) this bypasses the `debounce = 1500` burst boundary and
fragments one logical edit into a stream of character-level events — a real
transcript showed 14 tiny diffs of a single file, which with
`max_events = 15` evicts the entire cross-buffer history and feeds the model
noisy intermediate states instead of intent.

The flush is not needed for correctness or freshness:

- `TextChangedI` already arms the debounce timer on every insert-mode change,
  and the uv timer fires regardless of mode — a burst always flushes after
  `debounce` ms of true idle.
- `duet/init.lua:50` calls `edits.flush(bufnr, { wait = true })` before every
  prompt build, so history is fresh at prediction time regardless.
- `BufLeave` still flushes on file switches.

Decision (user-confirmed): **delete the InsertLeave autocmd**. Burst
boundaries become: idle pause (`debounce`), buffer switch (`BufLeave`), or
prediction request (wait-flush). Sparseness is acceptable: history is only
consumed at predict time, and predict forces a flush; if the stream feels too
coarse in practice, `debounce` is already the user-facing granularity knob.

## Changes

### 1. `lua/minuet/duet/edits.lua`

Delete the `InsertLeave` autocmd registration in `M.setup` (lines 581–587).
No other code references it; `on_text_changed` / `arm_debounce` /
`start_flush` are untouched.

### 2. `tests/duet_edits_spec.lua`

Replace the test `'duet.edits flushes immediately on InsertLeave'` (lines
138–160) with one that pins the new behavior — rapid insert-mode bursts
punctuated by `InsertLeave` coalesce into a single debounced event:

- `setup_root_config` with a short `duet.recent_edits.debounce` (e.g. 20 ms,
  matching the existing debounce test at lines 104–137).
- Make a change, `nvim_exec_autocmds('TextChangedI', ...)`, then
  `nvim_exec_autocmds('InsertLeave', ...)`; repeat with a second change.
- `helpers.wait_until` an event appears, then assert `#events == 1` and that
  the diff spans from the original text to the final text (mirror the
  assertions of the TextChanged coalescing test: `%-return 1`,
  `%+return 3`-style matches).

This both proves InsertLeave no longer force-flushes and that the changes it
used to flush are still captured by the debounce.

### 3. `README.md`

Update the Recent Edits section (lines 1494–1497): drop "leave insert mode"
from the flush-trigger list, e.g. "When you pause typing
(`recent_edits.debounce` milliseconds), switch buffers, or trigger
`:Minuet duet predict`, ...". (Buffer switch is a real trigger today and is
currently undocumented in that sentence — mentioning it keeps the list
accurate.)

Note: `lua/minuet/virtualtext.lua:513` has its own unrelated InsertLeave
autocmd — leave it alone. `.plans/active/duet-edits-tempfile-diff/plan.md`
mentions the old InsertLeave test but is a historical planning doc — leave it
alone.

## Verification

Run the duet edits test suite with the repo's usual headless runner (check
Makefile / tests for the exact invocation). All existing tests must pass — in
particular the debounce coalescing test (lines 104–137), the
BufLeave/cross-buffer chronology test (lines 162–212), and the predict
wait-flush tests — plus the new InsertLeave-coalescing test.
