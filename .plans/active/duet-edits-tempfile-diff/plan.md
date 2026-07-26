# Redesign duet edit recorder: temp-file snapshots + async external `diff`

## Context

This ports the design from `minuet-ai.el`'s `duet-history-tempfile-diff` plan (reviewed merge-ready there) to the Lua recorder in `lua/minuet/duet/edits.lua`. Today each tracked buffer retains a full-text `baseline` Lua string (up to `max_buffer_size` = 1 MB each — the benchmark shows ~1 MB retained heap per near-cap buffer), and `M.flush` runs `nvim_buf_get_lines` + `table.concat` + `vim.diff` synchronously on the main thread. The redesign eliminates retained Lua-heap snapshots: baselines become temp files written with `vim.fn.writefile` (line list, no concatenated string), and diffs are computed by an external `diff -U<n>` spawned asynchronously via `vim.system`. The predict path keeps its effective synchronous semantics through a **bounded wait** on in-flight diffs, so the freshest burst is still captured in practice while a wedged diff can never hang prediction.

Decisions settled:
- **No `vim.diff` fallback** (user-confirmed): external diff availability is checked once in `M.setup` via `vim.fn.executable`; if missing, notify once and leave the recorder off. Windows users install diffutils or set `recent_edits.diff_program`.
- Temp files live in Neovim's private temp dir (`vim.fn.tempname()`, 0700 dir, auto-removed at exit) — so the Emacs plan's global registry / kill-hook cleanup machinery is **not needed** here. Files are still deleted eagerly when a buffer's tracking state is dropped.
- Event format, `truncate_to_hunks`, `push_event` eviction, `render`, `get_events` are unchanged.
- Privacy trade-off (buffer content on disk) is accepted and documented in the README, same class as swap/undo files.

## Files

- `lua/minuet/duet/edits.lua` — rewrite of the snapshot/flush core
- `lua/minuet/duet/config.lua` — two new `recent_edits` fields + annotations
- `lua/minuet/duet/init.lua` — predict's flush call passes `{ wait = true }` (line 49)
- `tests/duet_edits_spec.lua` — rewrite flush tests to async, add new coverage
- `tests/scripts/` — two fixture scripts (`slow_diff.sh`, `diff_exit_2.sh`; precedent: `mock_openai_stream.sh`)
- `tests/duet_edits_bench.lua` — measure the new costs
- `README.md` — Recent Edits section (~1488–1521) + Default Config block (~1547–1555)

## 1. Config (`config.lua`)

Add to `minuet.DuetRecentEdits` class + defaults + README config block:
- `diff_program` (string, default `'diff'`): invoked as `PROG -U<n> OLD NEW`; must emit unified diffs with exit codes 0 (identical) / 1 (differences) / ≥2 (error).
- `flush_timeout` (integer ms, default `200`): max time the predict-path flush blocks waiting for in-flight diffs before proceeding with slightly-stale history.

Update the `diff_context_lines` comment (becomes the `-U` argument; diff merges touching hunks itself).

## 2. edits.lua

### State

`minuet.DuetEditBufferState` becomes:
- `snapshot_file: string` / `pending_file: string` — two-file ping-pong allocated once at track time (`vim.fn.tempname()`); rotation is a variable swap, no per-flush create/delete.
- `changedtick: integer` — tick captured when `snapshot_file` was written (as today).
- `timer: uv.uv_timer_t?` — unchanged debounce timer.
- `process: vim.SystemObj?` — in-flight diff, or nil.

Delete the `baseline` field and `get_buffer_text` (its trailing-newline convention is preserved by `writefile`'s default mode, which terminates every line with `\n`).

### Snapshot / lifecycle

- `write_snapshot(bufnr, path)`: `vim.fn.writefile(api.nvim_buf_get_lines(bufnr, 0, -1, false), path)`; returns the `changedtick` read just before the write. Used by `M.track` (into `snapshot_file`) and by the pending write in the flush.
- `M.track`: unchanged guards; allocate both tempnames, write the snapshot, record the tick.
- `drop_buffer_state`: cancel protocol first — **nil `state.process`, then `:kill(15)`** the stashed object if any (the nil-first order defeats the late on_exit via its equality guard); stop/close the timer; `vim.uv.fs_unlink` both files (ignore errors); clear the table entry. `BufReadPost`/`BufUnload`/`BufWipeout` handlers and `M.reset` all flow through this, so a reload or wipeout mid-diff cancels cleanly.

### Flush layer

- `start_flush(bufnr)` (internal): guards — trackable (else `drop_buffer_state`), state exists (else `M.track` + return), **no in-flight `state.process`**, tick dirty, config present. Write `pending_file`, capture the pending tick. Spawn with `pcall(vim.system, { config.diff_program, '-U' .. config.diff_context_lines, state.snapshot_file, state.pending_file }, { text = true, env = { LC_ALL = 'C' } }, on_exit)`. On spawn failure (program vanished after setup): notify once at error level and set an internal `disabled` flag so it doesn't retry-and-log forever (mirrors the Emacs review's finding 2). Store the object in `state.process`.
- `on_exit(result)` — runs off-main; body wrapped in `vim.schedule`. Guard: `internal.buffers[bufnr] == state and state.process == obj`, else return (cancelled / re-tracked — vim.system disposes its own pipes). Then `state.process = nil` and:
  - signal / `code >= 2` → notify at verbose level (include stderr); **no rotate**, tick untouched → the next flush retries the burst.
  - `code == 0` → rotate only (reverted burst, no event).
  - `code == 1` → strip the two file-header lines (`^%-%-%-[^\n]*\n%+%+%+[^\n]*\n` — they leak temp paths) and the trailing newline from `result.stdout`; if what remains doesn't start with `@@`, treat as garbled/binary: notify verbose, rotate, no event; else `push_event(bufnr, stripped)` (existing truncation/eviction machinery unchanged), then rotate.
  - rotate = swap `snapshot_file`/`pending_file`, `state.changedtick = pending_tick`.
  - After a successful rotate, if the buffer's current changedtick is already dirty again, re-arm the debounce timer (never respawn directly — the failure path doesn't re-arm, so a persistently failing diff cannot loop).
- `M.flush(bufnr, opts?)` — public. Always: stop the debounce timer, run `start_flush`. When `opts.wait` is truthy, additionally do a bounded wait: `deadline = now + config.flush_timeout`; loop `vim.wait(remaining, cond, 5)` where cond is "no in-flight `process` in **any** tracked buffer"; within the deadline, if this buffer's tick went dirty again and it has no in-flight process, start a follow-up flush, capped at **2 starts total** per call (prevents a respawn loop on persistent failure). Waiting on all buffers — not just `bufnr` — preserves cross-buffer chronology for the BufLeave-flush-then-predict-in-another-buffer sequence (`vim.wait` processes the scheduled on_exit callbacks, so this works without nesting event loops).
- Autocmd/timer call sites keep calling `M.flush(bufnr)` (fire-and-forget); only `predict()` in `init.lua:49` passes `{ wait = true }`.

### Setup

At the top of `M.setup`: if `vim.fn.executable(config.diff_program) ~= 1`, `utils.notify(...)` once at warn level and return without registering any autocmds. (Only when `recent_edits.enabled`; when disabled the recorder should stay silent.)

## 3. Tests (`tests/duet_edits_spec.lua`)

Infrastructure:
- Local helper `flush_sync(bufnr)`: bump `config.duet.recent_edits.flush_timeout` to ~5000 for the test and call `edits.flush(bufnr, { wait = true })` — flush-behavior tests stay synchronous-looking.
- Fixture scripts `tests/scripts/slow_diff.sh` (sleep then exec real diff) and `tests/scripts/diff_exit_2.sh` (exit 2); tests using them (and any that need `diff` itself) skip when `vim.fn.executable('diff') ~= 1` / `sh` unavailable, following the suite's skip conventions.

Mechanical rewrites (`edits.flush(bufnr)` → `flush_sync(bufnr)`): records-a-burst, untracked-establishes-baseline, BufReadPost re-baseline, bunload re-track, empty-diff-skip, cross-buffer chronology, home-relative naming, max_events / max_total_chars eviction, truncation tests, size-guard, non-file-buffer, render-while-disabled. The InsertLeave test now asserts via `helpers.wait_until` (the autocmd flush is async). The debounce and wipeout tests already wait / assert synchronously via BufLeave — the wipeout test's BufLeave flush is now async, so its first assertion also moves behind `wait_until`. Caution: assertions match `^@@`, which still holds after header stripping; keep regex (not exact-string) matching since GNU diff omits `,1` counts.

New tests:
- Header stripping: recorded event contains no `---`/`+++` lines and no temp path (grep the event text for the tempname prefix).
- Missing program: set `diff_program = 'minuet-no-such-diff'`, run `duet.setup()` → no error, edits never produce events.
- Exit-2 retry: `diff_program = diff_exit_2.sh` → flush yields no event and the tick stays dirty; restore the real program → the same burst flushes successfully.
- Bounded wait: `diff_program = slow_diff.sh`, small `flush_timeout` → `flush({wait=true})` returns promptly with no event; the event arrives later (`wait_until`).
- In-flight skip: with the slow fixture, a second flush during flight spawns no second process and the burst is still recorded exactly once afterwards.
- Cancellation: start a slow flush, then `nvim_buf_delete` (and, in a second test, fire `BufReadPost`) mid-flight → no event ever recorded, `vim.v.errmsg` clean, temp files gone (`fs_stat` nil) for the delete case.
- Non-ASCII round-trip: buffer with `héllo` / `世界` produces an intact diff through the file round-trip.
- File cleanup: after `drop_buffer_state` via wipeout, both snapshot paths no longer exist.

## 4. Benchmark (`tests/duet_edits_bench.lua`)

- Replace the in-memory `snapshot`+`vim.diff` latency section with: `writefile` snapshot latency per size, and end-to-end async flush wall time (start flush, `vim.wait` until the event lands).
- `benchmark_baseline_memory` now demonstrates retained Lua heap ≈ 0 after tracking the 20 × 1 MB buffers (report the delta as before).
- Keep the change-callback section unchanged; raise/bind `flush_timeout` where relevant so measurements aren't truncated by the 200 ms cap.
- Update the header comment describing what is measured.

## 5. Docs (`README.md`)

- Recent Edits section (~1488–1521): rewrite the "recorder is lightweight" paragraph — snapshots are files in Neovim's private temp directory (0700, removed when Neovim exits), diffs run in an external `diff` process off the main thread; prediction waits at most `flush_timeout` ms and proceeds with slightly-stale history past the deadline. One sentence on the disk-privacy trade-off (same class as swap/undo files; disable the recorder for sensitive buffers). Note the `diff_program` requirement with a Windows pointer.
- Default Config block: add `diff_program` and `flush_timeout` with one-line comments.

## Amendment (as implemented)

Cancelling the in-flight diff on `BufUnload`/`BufWipeout` (as originally
planned above) would lose the final burst that the BufLeave flush had just
started, regressing the guarantee from commit d9dc8b2 ("flush recent edits on
buffer leave") that the wipeout test asserts. As implemented,
`drop_buffer_state` takes a `finalize` flag: the unload/wipeout path leaves an
in-flight diff running as an *orphan* — its completion callback records the
event (using a filename captured at spawn time, since the buffer no longer
exists) and then deletes both snapshot files itself. `BufReadPost`, `reset`,
and guard failures still hard-cancel with the nil-first protocol. The
cancellation tests changed accordingly: the mid-flight wipeout test asserts
the event IS recorded exactly once, while the mid-flight `BufReadPost` test
asserts cancellation.

## Verification

1. `make test` — full suite headless.
2. `nvim --headless -u NONE -i NONE --cmd "set noswapfile" +"luafile tests/duet_edits_bench.lua" +"qa!"` — confirm retained baseline heap drops to ~0 (currently ~1 MB/buffer) and flush latency stays in the low-ms range.
3. `make format-check`.
4. Manual smoke: open a real file, type a burst, pause past the debounce, `:Minuet duet predict` (or inspect `require('minuet.duet.edits').render()`) — clean entries with no temp paths; confirm exactly two `tempname` files per tracked buffer while tracked, gone after `:bwipeout`.
