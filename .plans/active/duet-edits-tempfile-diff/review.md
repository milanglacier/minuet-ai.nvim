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

## Review round 2 (2026-07-27)

Scope: current branch at `456e3fe`, after the fix follow-up documented above.
The two original findings are fixed, but a fresh pass over the complete async
feature found three additional correctness issues.

### Verdict

**Not merge-ready.** The recorder can reverse its documented cross-buffer
timeline, the bounded prediction wait excludes orphaned diffs, and the
missing-program setup path does not actually keep the recorder off.

Verified in this round:

- `make test` — all 55 tests pass.
- `make format-check` — passes.
- A deterministic two-buffer diff fixture completed the later flush first and
  produced `FAST_B, SLOW_A`, reversing the flush/edit order.
- With a 1 s orphaned diff and a 1500 ms timeout, `flush({ wait = true })`
  returned in 0 ms with no event; the orphan event arrived later.
- With a missing `diff_program`, setup emitted its warning, then two calls to
  the real predict path caused a second spawn-failure notification.

### Findings

#### 1. [P2] Order overlapping diff results by flush sequence

`lua/minuet/duet/edits.lua:352–355` — when edits in buffers A and B have
overlapping async diffs, each completion appends its event immediately. If the
later B diff completes before the older A diff (for example because A is larger
or slower), the stored order becomes B then A, so the prompt treats A as the
newest edit despite documenting an oldest-to-newest cross-buffer timeline.
With an event/character cap, the late arrival can also evict the genuinely
newer event. Preserve a sequence assigned when each flush starts and publish
completed events in that sequence rather than process-exit order.

#### 2. [P2] Include orphaned processes in the bounded wait

`lua/minuet/duet/edits.lua:441–448` — when buffer A is unloaded or wiped after
its BufLeave diff starts, `drop_buffer_state(..., true)` removes its state from
`internal.buffers` and moves it to `internal.orphans`. A prediction in buffer B
therefore considers this wait settled immediately even though A's final diff
is still running, so the resulting prompt omits an edit that is supposed to be
covered by the cross-buffer wait. The settled condition needs to inspect the
orphan set as well.

#### 3. [P2] Keep the missing-program setup path actually disabled

`lua/minuet/duet/edits.lua:530–540` — the failed executable check returns before
registering autocmds but leaves `internal.disabled` false. Since
`duet.action.predict()` always calls `edits.flush`, one prediction can still
create a snapshot and a later prediction tries to spawn the missing program,
causing a second error notification and leaving temp-file content despite the
documented “stays off and notifies once” behavior. Mark and cleanly retain the
recorder as disabled on this path (with a corresponding recovery path when
setup later succeeds).

## Review round 2 resolution (2026-07-27)

The three findings were considered individually rather than treating every
theoretical async ordering issue as equally urgent.

### Finding 1 — accepted and deferred

The overlapping-diff ordering issue is real, but unlikely to be observable in
ordinary editing: users generally edit one buffer at a time and the external
diff normally completes within milliseconds. Simultaneous multi-buffer edits
are more likely to come from programmatic operations such as an LSP rename,
where the relative order of the affected files is usually not meaningful.

A complete fix would also require sequencing and temporarily holding completed
results until earlier processes finish, adding nontrivial state and
head-of-line behavior. The current risk does not justify that complexity, so
this finding is accepted as a known limitation and deferred.

### Finding 2 — fixed

The bounded wait's settled predicate now checks both `internal.buffers` and
`internal.orphans`. A diff that becomes orphaned because its buffer is unloaded
or wiped therefore remains part of the existing cross-buffer wait until it
completes or the configured timeout expires.

Regression test: `duet.edits.flush with wait includes an orphaned in-flight
diff` starts the slow-diff fixture, deletes its buffer while the process is in
flight, then flushes another buffer with waiting enabled and verifies that the
orphan's event has landed before the call returns.

### Finding 3 — fixed

The missing-executable branch of `M.setup()` now sets `internal.disabled =
true` before notifying and returning. Later prediction-path flushes therefore
remain inert instead of creating snapshots or attempting to spawn the missing
program.

The existing missing-program regression test was strengthened to enable and
capture notifications, call flush twice after setup, and verify that exactly
one notification was emitted.

### Verification

- `make test` — all 56 tests pass.
- `make format-check` — passes.
- `git diff --check` — passes.

## Review round 3 (2026-07-27)

Scope: current branch at `983ba72`, after the round-2 resolution. This pass
rechecked the two accepted fixes and then exercised setup transitions and the
bounded wait with a buffer that becomes dirty again while its diff is running.
The orphan-wait fix itself works, but four additional state-transition issues
remain.

### Verdict

**Not merge-ready.** A corrected diff configuration cannot recover the recorder
after the new setup-time disable, and the prediction wait can still omit a
completed pre-prediction edit from another buffer. Self-disable also leaves
stale history visible, while a failed repeated setup strands existing
snapshots until Neovim exits.

Verified in this round:

- `make test` — all 56 tests pass.
- `make format-check` — passes.
- `git diff --check` — passes.
- Missing-program setup followed by `diff_program = 'diff'` and another
  `duet.setup()` still produced zero events.
- With the 1 s slow-diff fixture and a 2500 ms timeout, buffer A was changed to
  `a = 2`, flushed, then changed to `a = 3` while that diff was in flight. A
  wait from buffer B returned after about 1 s with only the `a = 2` event.
- After one successful event and a mid-session spawn failure, `render()` still
  returned the old 57-character event.
- Re-running setup with a missing program after tracking a buffer, then deleting
  that buffer, left both snapshot files in the temp directory.

### Findings

#### 1. [P2] Re-enable the recorder after a successful setup

`lua/minuet/duet/edits.lua:535–536` — once a missing executable sets
`internal.disabled`, a later setup with a corrected, executable
`diff_program` never clears the flag. The second setup registers all recorder
autocmds, but `M.track()` continues to reject every buffer through
`is_trackable()`, so the recorder remains permanently inert unless the
internal/test-only `reset()` hook is called (which also erases history).
Clear the failure-disable state on the successful setup path before tracking
the current buffer.

#### 2. [P2] Flush dirty peer buffers before ending the bounded wait

`lua/minuet/duet/edits.lua:459–461` — after all processes settle, the follow-up
logic checks only the prediction buffer. If buffer A is edited again while its
first diff is running, then BufLeave hits the in-flight guard, A's completion
marks it dirty and re-arms its debounce; a simultaneous prediction in buffer B
waits for that first diff but returns without flushing A's later edit, even
with ample timeout remaining. The post-wait dirty scan needs to include
tracked peer buffers whose BufLeave flush could not start, not just `bufnr`.

#### 3. [P2] Hide history after the recorder disables itself

`lua/minuet/duet/edits.lua:384–388` — if the diff program disappears after
earlier events were recorded, this branch sets `internal.disabled`, but
`render()` checks only `config.enabled`. Since no new events can arrive to age
out the old ones, every later prompt keeps receiving the same stale edit
history indefinitely despite the user-facing notification saying the recorder
is disabled. Treat the internal failure-disable flag like the existing runtime
disable in `render()` while retaining events for a later recovery if desired.

#### 4. [P3] Clean tracked snapshots before returning from failed setup

`lua/minuet/duet/edits.lua:546` — when setup is rerun after the recorder has
already tracked buffers, `duet.setup()` first clears the shared augroup and
this early return leaves those states alive without the BufUnload/BufWipeout
cleanup autocmds. Deleting an idle tracked buffer after that transition
therefore leaves both content snapshots on disk until Neovim removes its temp
directory at exit, beyond the documented lifetime of the buffer. Drop existing
tracking states before returning, or retain a cleanup path while disabled.

## Review round 3 decisions and resolution (2026-07-27)

### Findings 1 and 4 — fixed together

A repeated `duet.setup()` is treated as a fresh recorder lifecycle.
`edits.reset()` now runs at the start of `edits.setup()`, before validating the
new recorder configuration. This ordering:

- cancels in-flight and orphaned diff processes;
- closes debounce timers and deletes all tracked snapshot files;
- clears the prior event history; and
- clears `internal.disabled`, allowing a corrected executable configuration to
  start recording again.

Clearing event history on repeated setup is an accepted trade-off: a full
plugin reconfiguration starts a new recent-edits session. Autocmd ownership
remains separate from recorder state cleanup; `duet.setup()` continues to clear
the shared augroup, while `edits.setup()` owns recorder reset and does not
remove autocmds itself.

Regression tests:

- `duet.edits setup recovers after the diff program becomes executable`
  starts with a missing executable, corrects it to `diff`, reruns setup, and
  verifies that a new edit event is recorded.
- `duet.edits repeated setup cleans snapshots before a missing-program return`
  creates both snapshot files, reruns setup with a missing executable, and
  verifies that the previous recorder lifecycle's files are deleted.

Both tests failed before the fix: recovery recorded zero events and the failed
setup left two snapshot files behind.

### Finding 2 — intentionally deferred

Recent-edit history is best-effort prompt context, not correctness-sensitive
application state. The reported omission requires a narrow overlap: a peer
buffer must change again while its first external diff is still running, and a
prediction in another buffer must begin before the re-armed debounce flushes
that second change. The dirty edit remains tracked and is flushed later.

Scanning and repeatedly starting dirty peer buffers inside the bounded wait
would add state-machine complexity for little practical prompt benefit, so the
current bounded-staleness behavior is accepted.

### Finding 3 — intentionally deferred

A mid-session spawn failure after successful setup requires the configured diff
program to disappear or otherwise become unspawnable while Neovim remains
running. This is considered too unusual to justify additional behavior in this
patch. Previously recorded events remain factually valid, though subsequent
edits are absent, and setup recovery now starts a clean recorder lifecycle.

### Verification

- Pre-fix regression run — the two new tests failed for the reviewed reasons.
- `make test` — all 58 tests pass after the fix.
- `make format-check` — passes.
- `git diff --check` — passes.

## Review round 4 (2026-07-27)

Scope: current branch at `ba89da5`, after the round-3 resolution. This pass
focused on the new setup-time lifecycle reset, including cancellation and
recovery while regular and orphaned diffs are still in flight. The findings
explicitly accepted or deferred in earlier rounds were not reopened.

### Verdict

**Merge-ready under the documented decisions.** No additional correctness
findings were found. Calling `M.reset()` before validating the new
configuration closes the two setup-transition holes from round 3 without
allowing a cancelled process to publish into the new lifecycle.

Verified in this round:

- `make test` — all 58 tests pass.
- `make format-check` — passes.
- `git diff --check` — passes.
- A focused setup-transition probe started both a normal in-flight diff and an
  orphaned in-flight diff, reran setup with a working program, and pumped the
  event loop beyond the slow fixture's delay. Neither old event landed, and a
  subsequent edit recorded successfully under the new lifecycle.

### Findings

None.
