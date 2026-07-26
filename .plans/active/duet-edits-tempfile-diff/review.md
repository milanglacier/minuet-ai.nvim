# Review: temp-file snapshots + async external diff (feat/recent-edit-history-V2)

Scope: `feat/recent-edit-history...feat/recent-edit-history-V2` — a single commit
(`c74d237 refactor: record edit history via temp-file snapshots and async diff`)
that rewrites the recorder core in `lua/minuet/duet/edits.lua`, plus config,
predict-path, tests, fixtures, benchmark, and README updates.

## Verdict

**Merge-ready.** No correctness bugs found that would block merging. The async
state machine (in-flight guard, cancel protocol, orphan finalization, bounded
wait) is carefully designed and each transition is covered by a test. The two
findings below are low-severity edge cases worth a follow-up decision, not
blockers.

Verified locally on this branch:

- `make test` — all tests pass.
- Benchmark — retained Lua heap drops from ~1 MB/buffer (old baseline strings)
  to **0.32 KB/buffer**; snapshot write is 4–8 ms and end-to-end sparse flush
  5–12 ms for 105 KB–1 MB buffers, with the diff itself off the main thread.

## Overview

The old design kept a full-text baseline string per tracked buffer on the Lua
heap and ran `vim.diff` synchronously on flush. The new design:

- Baselines live in two temp files per buffer (ping-pong pair from
  `vim.fn.tempname()`, in Neovim's private 0700 temp dir, auto-removed at
  exit), allocated once at track time; rotation is a variable swap.
- Diffs run in an external `diff -U<n>` via `vim.system`, asynchronously; the
  `on_exit` callback (scheduled to the main thread) records the event and
  rotates the snapshot.
- `predict()` calls `edits.flush(bufnr, { wait = true })`, which blocks at most
  `flush_timeout` (200 ms default) for in-flight diffs across **all** buffers
  (preserving cross-buffer chronology), then proceeds with slightly stale
  history. A wedged diff can never hang prediction.
- Two new config fields: `diff_program` (default `'diff'`) and `flush_timeout`.
- Setup checks `executable(diff_program)` once and disables the recorder with a
  single warning if missing; a mid-session vanish is caught by `pcall` around
  `vim.system` and sets an internal `disabled` flag (fail once, not per burst).

## What's particularly well done

- **Cancellation protocol** (`drop_buffer_state`, edits.lua:76–83): nil
  `state.process` *before* `:kill(15)`, and `on_exit` compares its captured
  process object against `state.process` — a cancelled or superseded diff
  provably reduces to a no-op, including across re-track (the closure captures
  the old state object, so a new state for the same bufnr can never be
  confused with it).
- **The orphan amendment** (`finalize` flag): the naive plan would have
  cancelled the BufLeave flush's in-flight diff on wipeout, silently regressing
  the d9dc8b2 guarantee. Leaving it running as an orphan that records its event
  (with a filename captured at spawn time) and then deletes its own files is
  the right call, and the plan documents the reasoning.
- **Failure taxonomy in `on_exit`**: exit ≥ 2 / signal → no rotation, tick stays
  dirty, next flush retries; exit 1 with unparseable output (binary) → rotate
  but skip, explicitly to avoid an infinite retry loop; success with new dirty
  tick → re-arm the debounce (never respawn directly, so a persistently failing
  diff cannot loop). Each branch has a comment stating the invariant it
  protects.
- **Prompt hygiene**: the `---`/`+++` header strip keeps temp paths out of the
  prompt, the `^@@` check validates what remains, and a dedicated test greps
  the event text for the tempdir path.
- **Security posture**: `vim.system` with an argv list (no shell, no injection
  through `diff_program`/paths), `LC_ALL = 'C'` for stable output, snapshots
  confined to the 0700 private temp dir, and the disk-exposure trade-off is
  documented in the README in the right terms (same class as swap/undo files).
- **Test coverage** maps essentially 1:1 onto the new state machine: header
  stripping, missing program, mid-session spawn failure (the missing-program
  test exercises the `internal.disabled` path too, since `track` succeeds and
  the spawn fails), exit-2 retry-then-recover, bounded-wait timeout, in-flight
  dedup, BufReadPost cancellation, wipeout orphan, temp-file cleanup, and
  non-ASCII round-trip. The `slow_diff.sh` / `diff_exit_2.sh` fixtures follow
  the existing `tests/scripts/` precedent and skip cleanly without `sh`/`diff`.
- The bounded-wait loop correctly waits on *all* buffers (cross-buffer
  chronology for the BufLeave-then-predict sequence) and caps follow-up spawns
  at 2 per call.

## Findings

### 1. Orphaned diffs survive `M.reset()` (low)

`edits.lua:479–486` — `reset` cancels in-flight diffs by iterating
`internal.buffers`, but an orphaned diff (buffer already unloaded/wiped) is no
longer in that table and cannot be cancelled. If `reset` runs while an orphan
is in flight, the orphan's `on_exit` later calls `push_event` into the
freshly-emptied history, resurrecting a pre-reset event.

Impact is small — `reset` is an internal/test hook, the window is one diff's
runtime, and the resurrected event is at least real history — but it can
produce cross-test leakage in the suite (a wipeout test's orphan landing during
the next test's run). A cheap fix: keep orphans in a small
`internal.orphans[process] = state` set that `reset` walks and hard-cancels;
or have the orphan's `on_exit` check a generation counter bumped by `reset`.

### 2. `write_snapshot` only catches thrown failures (low)

`edits.lua:94–98` — `vim.fn.writefile` signals failure both by raising (E482,
caught by the `pcall`) and by returning `-1`. In current Neovim the raise
covers the realistic failure modes (unwritable dir, ENOSPC at open), so this
works, but checking the return value too is one token of belt-and-braces:

```lua
local ok, ret = pcall(vim.fn.writefile, api.nvim_buf_get_lines(bufnr, 0, -1, false), path)
return (ok and ret == 0) and changedtick or nil
```

A silently-bad snapshot would produce a wrong diff rather than a skipped one,
which is the worse failure mode for a prompt-context feature.

## Nits (no action required)

- `tests/duet_edits_spec.lua` `flush_sync` restores `flush_timeout` after the
  flush but not on error; and the temp-file-cleanup test asserts an exact
  `readdir` count of the shared tempdir, which is brittle if anything else in
  the process creates a temp file during the 2 s wait. Both fine today given
  the harness aborts on failure and tests run serially.
- `event.bufnr` is stale for orphan-recorded events (the buffer is gone).
  Verified nothing outside `edits.lua` consumes the field, so this is
  documentation-only; the `filename`-captured-at-spawn comment already covers
  the user-visible half.
- The predict path now spends up to `write_snapshot` time (~5–8 ms at the 1 MB
  cap) plus the bounded wait on the main thread. That is the documented
  trade-off and strictly better than the old synchronous diff; noting it only
  because `flush_timeout` interacts with perceived prediction latency and 200 ms
  is the right conservative default.
- `SystemObj:kill` on a process that exited between the real exit and the
  scheduled `on_exit` is safe (luv's `process:kill` returns `nil, err` rather
  than raising) — checked, no change needed.

## Conventions & docs

- Matches the project style rules: no gratuitous micro-helpers (`arm_debounce`,
  `write_snapshot`, `extract_hunks` each isolate genuinely nontrivial or reused
  behavior), and full LuaCATS annotations on new/changed state, parameters, and
  returns, including the two new config fields.
- README and the config-block comments accurately describe the new behavior,
  the exit-code contract, the Windows story, and the privacy trade-off; the
  plan's Amendment section documents the orphan design divergence from the
  original plan, which is exactly the kind of record that keeps future readers
  sane.
- Benchmark rewrite measures the right new quantities (snapshot write latency,
  end-to-end flush wall time, retained tracking heap) and its output confirms
  the design goal.

## Fix follow-up (2026-07-26)

Both findings above were fixed on this branch after the review; `make test`
and `make format-check` pass.

### Finding 1 — orphaned diffs now cancelled by `M.reset()`

`edits.lua`: added an `internal.orphans` set (`table<state, true>`). The
`finalize` path of `drop_buffer_state` registers the orphaned state there; the
orphan's `on_exit` deregisters itself on normal completion; `M.reset` walks the
set and hard-cancels each entry. Since the nil-first cancel protocol was now
needed in two places (drop and reset), it moved into a `cancel_state(state)`
helper — nil `state.process`, `kill(15)`, unlink both snapshot files — used by
both, with the no-late-event invariant documented on the helper.

Regression test: `duet.edits.reset cancels an orphaned in-flight diff so no
event lands after the reset` — starts a `slow_diff.sh` flush, wipes the buffer
mid-flight (creating the orphan), calls `reset`, then pumps the loop past the
fixture's sleep and asserts the history stays empty, nothing raises, and no
snapshot files remain. The file assertion is a set difference rather than a
count, because `reset` legitimately also unlinks snapshots of other tracked
buffers (e.g. the buffer `setup` tracks at registration), shrinking the total.

### Finding 2 — `write_snapshot` checks `writefile`'s return value

`edits.lua`: the `pcall` result now also requires `writefile`'s return value to
be `0`, covering the documented `-1` soft-failure convention in addition to the
raised-error path. A failed write keeps returning `nil`, so the flush is
skipped and the dirty changedtick retries the burst later — the same semantics
as before, now airtight against a silently-bad snapshot producing a wrong diff.
No practical way to unit-test a non-raising `-1` return, so this one ships on
inspection.
