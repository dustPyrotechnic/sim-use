<!-- SPDX-License-Identifier: Apache-2.0 -->

# 012.006 — Live target safety

> 2026-11-05 approved review correction: negative element centers need screen
> recovery advice, zero-size cache entries must not send input, and the
> in-process fixture must use an isolated cache home. The previous in-process
> test seam accidentally used the real home. Historical results below stay
> unchanged; the new decisions are recorded at the end of this file.

## Context and approval

The user approved four changes after the `a602cd6f` candidate: reject cached
aliases covered by the current keyboard, reject resolved targets outside the
screen, increase membership discovery from 1.5 to 3 seconds, and close the
six-digit color mutation gap. Red tests must run before implementation.
No phone operation, E2E, paid eval, commit, push or PR is authorized. Native
`type --target` append behavior is unchanged. Status: **等待人工验收**.

## Decisions before code

| Area | Decision | Reason |
| --- | --- | --- |
| Current layout | Read a new layout for each cached alias through `HarmonyTargetResolver.resolve`. Do not call the cache-writing `describeUI` path. | Keyboard appearance and diagnostic aliases can invalidate the safety of cached coordinates. A failed dump must stop before input. |
| Keyboard ownership | Match the cached role, label and complete frame against a visible current keyboard element. Reject ambiguous matches that also identify an App element. | The shared cache has no node ID. A point merely inside a keyboard key is not proof that the alias targets that key. Preserve the cache schema and reject uncertain covered targets. |
| Shared geometry | Reuse the renderer's painted-panel, ownership and screen rules. | Transparent wrappers, conservative fallback and system keyboard controls must have the same meaning in rendering and input validation. |
| Actual pixels | Check the exact integer coordinates that input will send: truncated cache centers and rounded selector centers. Reject points outside the screen, with a scroll/describe-ui hint. | Do not change default outline visibility for partially visible nodes. |
| Explicit coordinates | Return through the existing coordinate branch without layout validation. | The user explicitly selected that location. This is not an element-derived target. |
| Membership | Change only the discovery deadline to 3 seconds. Keep one warning and Android fallback on probe failure. | Reported cold hdc discovery takes 1.38–1.40 seconds. The former 1.5-second allowance has insufficient margin. Historical measurements and the unknown cold-script OS mechanism remain unchanged. |
| Color length | Add `#000000` to the painted-popup public rendering cases. | Six-digit RGB black is not transparent eight-digit ARGB. Removing the length guard must fail this case. |

## Red and verification plan

Use the existing binary lookup helper and child-process environments for CLI
regressions. Each test gets its own home, cache, fixture and fake hdc call log;
no global environment or routing hook is changed. Use the captured
`third-party.json` for covered App targets and current keyboard controls.

Prove that stale and unfiltered aliases, out-of-screen selectors/aliases and
dump failures emit no `uiInput`. Check tap, long-press and type through their
actual commands. Controls cover retained cached coordinates, keyboard aliases,
explicit coordinates, exact screen edges and byte-for-byte unchanged cache.
The existing membership budget assertion changes from `[1.5]` to `[3]`; runner
tests with an independently supplied 1.5-second timeout stay unchanged.

After the red gate, implement the guards, then remove each new guard separately
and retain the resulting failures. Also remove the color-length guard and
revert the membership constant to prove those tests. Restore all mutations.
Run `make build`, three full `make test` runs (at least two without
`SIM_USE_HDC`), and forty default-parallel rounds containing
`TapForwarder|PlatformRouterPhysical|Harmony`. Run an isolated fake-hdc hanging
probe through the CLI and record elapsed time, fallback, warning count and JSON.
Record each result, candidate SHA and failures in `001-action.md`.

## Costs and limits

Cached-alias input adds one layout dump/transfer before the action. It does not
refresh aliases or renumber the saved snapshot. The screen can change between
validation and input; this check is not an atomic transaction with the device.
Cached identity is structural, not a stable node ID. A moved keyboard control
requires a new describe-ui when its old point is covered and no longer matches.
Explicit coordinates intentionally bypass these checks. Real-device behavior
and human acceptance remain unverified for the new candidate.

## Red gate evidence

The focused command exited 1 before production edits: 10 tests, six failing
tests, 24 failing cases and 136 issues. Wall time was 20.589 seconds. The binary
remained `a602cd6f`. Alias coverage, failed dumps and both screen-bound paths
still emitted input. The budget was 1.5 rather than 3 seconds. Keyboard aliases,
uncovered aliases, explicit coordinates and the new six-digit color case passed.
Exact assertions and the evidence paths are in `001-action.md`.

## Implementation and mutation results

The first green run passed all 10 focused tests in 21.897 seconds. Production
changes stay in the shared Harmony resolver, existing geometry renderer and
membership constant. All three verbs use the resolver without a new override or
cache schema. Current keyboard matches use full cached geometry, role and label;
an App match makes that identity ambiguous and therefore unsafe.

Nine independent mutations failed assertions: bypass live validation, omit the
keyboard guard, omit alias bounds, omit selector bounds, continue after dump
failure, allow ambiguous ownership, overwrite the cache, revert the deadline,
and remove the color-length guard. The last mutation failed specifically on
`paint = six-digit`. No mutation remains. Restored source hashes match the
first green source hashes, and all 18 target/keyboard/budget tests passed.
The exact failures and timings are retained in the action log.

Existing assertion changes: only the approved membership budget `[1.5]` to
`[3]`. The routing timeout error sample now says `3.0 seconds`; its assertions
are unchanged. The painted-popup test adds the six-digit sample without changing
the existing cases or expected result. No assertion was removed or weakened.

## Full-run failure and harness decision

The first full run failed two existing daemon-fixture assertions after about
30 seconds: its pidfile and socket were already removed. The next two runs
passed. The new CLI tests synchronously called `Process.waitUntilExit`, which
blocks a cooperative test executor while child processes run. Change only this
new fixture to await process termination asynchronously, before another three
full runs. Keep all assertions, daemon code, old tests and time limits unchanged.
The single failure does not prove that executor blocking was its only cause;
retain the original failure and this uncertainty in the action log.

## Test seam revision before final verification

Full runs 4 and 7 also failed existing wall-clock-sensitive fixtures (release
script timeout, then physical-iOS root retries). All new Harmony cases passed.
Changing only the child wait to async did not remove this interference.
Do not modify the old fixtures or wait for a lucky full run.

Move the permanent safety assertions to the real public `performTap`,
`performLongPress` and `performType` interfaces. Reuse the existing
`HarmonyTransport` seam for an in-memory device adapter. Add an optional UI
transport to `HarmonyDeviceController` and a controller argument to these three
entrypoints, as the Android command interfaces already support. Defaults remain
the real Hdc controller. No global test override, parallelism limit or timeout
change is needed. Each test owns its fake transport and a unique cache serial.

Keep the original actual-CLI red evidence and run actual-CLI smoke separately.
All safety, coordinate, cache and error assertions stay; the new process helper's
exit-code/JSON consistency assertion moves to CLI smoke because the permanent
tests no longer launch a CLI. Recheck mutations at the final test seam.
This removes process load introduced by this task; it does not establish the
specific cause of every earlier fixture timeout.

All 18 focused tests passed at the final public-command seam (0.622 seconds of
test execution, 16.959 seconds including build). The same nine mutations again
failed assertions. Restored source hashes match the pre-mutation final seam;
all 18 tests then passed again. `make build` passed in 27.018 seconds.
The old timing failures and both mutation runs remain in `001-action.md`.

## Final evidence and acceptance boundary

- Final full `make test` runs 08/09/10 all passed; 09 and 10 had `SIM_USE_HDC`
  unset. Forty subsequent default-parallel
  `TapForwarder|PlatformRouterPhysical|Harmony` runs all passed. Per-run results,
  including earlier failures, are in `001-action.md`; raw evidence is under
  `.build/harmony-live-target-z6icqrzq/`.
- Offline CLI smoke ran separately after stress: 16 calls, 10 parseable JSON
  responses with matching exit codes, no input for the six covered-alias
  attempts, unchanged cache, and working keyboard/coordinate controls.
  A hung membership probe fell back to fake adb in 3.060 seconds with one
  warning. No real device tools were used for smoke.
- Final candidate SHA-256:
  `62439335449851622c1b4359b318f69a5242f7550c84b76f3960e913249975dd`.
  Coverage relinking explains the change from the ordinary build. All three
  final full runs, 40 stress runs and final smoke used this same binary.
- The existing six-digit-color implementation was already correct; the new
  case and the killed length-check mutation close the coverage gap.
- Still **等待人工验收**. No phone, E2E, paid eval, commit, push or PR.
  Real-device effects require a new check. Extra alias dump cost, structural
  keyboard identity and dump-to-input races remain documented limitations.
  Do not claim the prior cold-script OS mechanism or every earlier fixture
  timing failure is explained.

After CLI smoke, separately remove only the positive `keyboardMatch` condition.
The existing unfiltered-alias cases for all three verbs fail with nine issues,
including the no-input assertion. No test changes were needed. Restore the
condition: all 18 focused tests pass, and both source fingerprints and candidate
SHA match the preceding full, stress and smoke runs exactly. This is the tenth
distinct killed mutation. Temporary drivers/fake executables are retired as
non-executable `*.txt` evidence snapshots; raw result files remain intact.

## Approved review: negative centers, zero-size aliases and cache home

The dispatch reports negative centers with a connectivity hint and zero-size
diagnostic aliases that send input. Code inspection confirms both paths and the
fixture's use of `homeDirectoryForCurrentUser`. Independent five-round full
results and the working 3-second probe are supplied evidence, not new local runs.

Decisions before implementation:

- Keep `integerPoint` behavior for explicit coordinates and `scroll --center`.
  Element-derived negative centers get the same outside-screen recovery policy
  as other out-of-screen points: scroll, then refresh `describe-ui`.
- Reject cached entries whose width or height is not positive, for every verb
  using the resolver and for both `@N` and `#N@S`. Keep the diagnostic outline.
- Do not write a new cache snapshot before selector target safety passes.
  Preserve the existing cache behavior for selector matching errors; this
  correction does not introduce a general cache policy change.
- Store one cache home on `HarmonyDeviceController`, defaulting to the same user
  home as before. Alias reads and outline writes use it. The fixture supplies
  a temporary directory; no new per-verb arguments or global environment
  mutation inside tests.
- The fresh dump checks keyboard occlusion and screen bounds only. It does not
  prove that an alias still identifies its original target. A vanished keyboard
  control, a changed page or a hidden diagnostic alias may still send input at
  cached coordinates when those checks pass. Refresh `ui` after page changes.
  A general stale-alias check requires a separate user decision.

Red tests use the existing public command entrypoints and fake transport.
Cover all three verbs, negative alias/selector points, both zero-width and
zero-height entries, the real `2306` fixture node and scoped cell aliases.
Assert errors, recovery hints, no `uiInput` and unchanged cache bytes. Seed new
cache assertions with a fixed capture time to avoid second-precision timestamp
coincidence. Until the fixture seam is fixed, run the red test process with an
isolated `CFFIXED_USER_HOME`; do not write new red-test caches into the real home.

After red, implement the three fixes, then remove each new negative-center and
zero-size guard independently. Restore and compare hashes. Run `make build`,
three full `make test` rounds, forty default-parallel filtered rounds and
offline CLI smoke. Sync and compare both Skill copies. Keep failures and the
new candidate SHA in `001-action.md`. Status remains **等待人工验收**.

### Review outcome

Four red tests (25 parameter cases) failed before production changes with
163 issues: 162 target-safety issues, followed by one cache-home round-trip
failure. Negative centers already avoided input but had the wrong recovery
hint and could replace the selector cache; zero-size aliases actually sent
input. Raw assertion excerpts and both red commands are retained in
`001-action.md`, with full logs under `.build/harmony-target-review-j8qbaqoc/`.

The implementation follows the decisions above. Existing assertions and
timeouts are unchanged. The fixture now injects its own temporary home into
the controller; the default production home is unchanged. Public describe-ui
and alias input exercise the same storage location. The original isolated
red-process home was removed only after preserving its misplaced cache as
`red-misplaced-outline.json`.

All 26 focused tests pass. Independently removing the negative-center guard,
the complete size guard, only its width condition, or only its height condition
produces 75, 81, 18 and 18 issues respectively. After restoration, all 12 tracked
source hashes match the frozen originals and the same 26 tests pass again.
No serialization or timeout changes were used.

`make build`, three full `make test` runs and forty default-parallel
`TapForwarder|PlatformRouterPhysical|Harmony` rounds pass. The latter two full
runs and all stress rounds leave `SIM_USE_HDC` unset. Per-round commands,
timings and exit codes are recorded in `001-action.md` and the original JSON
results, not just the final round.

Offline CLI smoke proves 42 refusals without input or cache replacement across
the three verbs, including scoped aliases and real fixture node 2306. The first
driver then fails because it assumes an explicit-coordinate parser error has
JSON stdout; the parser actually emits its unchanged error on stderr and empty
stdout. Keep that failure and raw output. Its CLI exit code was not saved and
remains unknown. A separate continuation checks the saved parser output/input
log and completes nine remaining controls without repeating the 59 prior
recorded calls. In total, 62 business JSON responses and six help outputs are
checked. Both smoke homes are removed; temporary drivers are retained only as
non-executable evidence snapshots.

Controls confirm the three intentionally unchanged behaviors: a keyboard alias
after dismissal, an alias after page replacement, and a hidden diagnostic alias
can still send input when the cached point passes the keyboard/bounds checks.
The dump does not establish target identity or freshness. Explicit coordinates,
scroll-center conversion, selector-miss cache refresh, the 3-second membership
deadline and type-target append behavior are unchanged.

Both Skill copies compare equal. The final coverage-linked candidate SHA-256 is
`b782af0edd4048da88a9fbf94867d26d492b14e61750fcb40b8d39baabe2c9be`;
all full, stress and smoke records use this candidate. No real-device or human
acceptance evidence exists for it. The dump/input race and the historical
unknown cold-start mechanism remain; no general stale-alias policy is added.
Status remains **等待人工验收**, with no E2E, paid eval, commit, push or PR.

### Test-only follow-up: selector cache transitions

Independent review of `b782af0e…` reports five full passes, forty stress passes
and 21 of 23 killed mutations. The two surviving mutations move a successful
selector's cache write before point validation (`cachefirst`) or remove cache
refresh on selector miss (`nomisscache`). These are supplied results, not new
local runs.

Add permanent public-command tests without changing existing assertions:
for each of tap, long-press and type, a rejected lower-edge or negative-center
selector must preserve cache bytes and leave the prior alias usable. A selector
miss and a successful selector must replace an older layout; subsequent alias
input must use the new coordinates, not merely a changed capture timestamp.
Preserve the no-match error and recovery hint. Use the existing temporary-home
fixture and fake transport. Apply each requested mutation separately, retain
the real failure output, restore all production source hashes, then run the
Harmony suites and one full `make test`. No permanent production change.

Results: three new tests cover 12 parameter cases. `cachefirst` produces nine
issues in the three lower-edge cases; `nomisscache` produces six issues in the
three miss cases. Both mutations are killed by cache-content and subsequent
alias-input checks. All 237 production file hashes match the baseline after
each restoration. Existing test content is byte-identical after removing this
task's inserted block; no prior assertion or timeout changed.

The first new-test run has three failures from a new wording assertion: the
lower-edge error includes screen dimensions between `outside the` and `screen`.
Correct only that new assertion to check `outside` and `screen` separately.
Keep its failed log. The corrected three tests pass; after mutation restoration,
96 Harmony tests and one full `make test` pass (Swift Testing: 1371 / 154 / 29).
All runs use default parallel execution with `SIM_USE_HDC` unset. Commands,
timings and raw failures are in `001-action.md` and
`.build/harmony-selector-cache-shwqm685/`.

Coverage rebuilding/relinking after restoration changes the candidate from
`b782af0e…` to
`6d5074c591d3849ef05c2e5858f9217d2adbeb7d6bed9f8af3763ddef897d378`,
without a production source change. The two requested mutations, not the
independent reviewer's full 23-mutation set, were rerun. No new device or human
acceptance evidence exists; status remains **等待人工验收**.

## Review Loop P1: Harmony devices JSON envelope

The Review Loop reports that `harmony devices --json` emits a bare array in
`data`, unlike the unified, Android and physical-iOS device listings. Keep the
same `Device` rows and wrap them in a command-local Codable `ExecutionResult`
with a `devices` property. Text rows and the empty-list message must not change.

Before production changes, add an in-process contract test at the existing
command-result → `JSONEnvelopeWriter` seam, with populated and empty lists.
Compare the encoded rows with the top-level `Devices.ExecutionResult`.
The fixture can instantiate the historical array result type, but assertions
accept only `data.devices`; this lets the same test reject the bare-array
mutation without changing its assertions or global process environment.
Exercise actual command execution separately with offline fake hdc.

Retain the red output, restore the bare-array command as a mutation, then
restore and check hashes. Run `make build`, Harmony tests and one full
`make test`. README and Skill have no conflicting Harmony devices JSON shape,
so leave them unchanged. This is a Review Loop fix, not new device or human
acceptance evidence.

The red test fails for both populated and empty listings with
`Expected data.devices array`; the original candidate and all production source
hashes are unchanged at that point. The minimal wrapper makes both cases pass.
Restoring the original bare-array command makes the same unchanged test fail
again with two issues. Restoring the fix reproduces all 237 frozen production
hashes; only `HarmonyCommand.swift` differs from the pre-fix baseline.

`make build` passes, followed by 97 Harmony tests and one full `make test`
(Swift Testing: 1372 / 154 / 29; XCTest also passes). Six fake-hdc CLI calls
confirm both JSON entrypoints and unchanged namespace text for populated and
empty lists. The unified CLI smoke uses `--platform harmony` to avoid other
device discovery. No real-device command is invoked by this smoke.

README and Skill need no correction. The original test content and all its
assertions are unchanged. Raw red/mutation output, timings and fingerprints
are retained in `001-action.md` and `.build/harmony-devices-envelope-97d6a7fw/`.
The final coverage-linked candidate SHA-256 is
`d972bb8206de31f488f66a8cede04737e9b86261872c67118128128d60c0f587`.
This Review Loop P1 fix has no new device or human acceptance evidence; the
candidate remains **等待人工验收**, and the full Review Loop is not declared closed.
