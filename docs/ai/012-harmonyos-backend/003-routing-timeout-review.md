<!-- SPDX-License-Identifier: Apache-2.0 -->

# 012.003 — Android fallback and short-deadline investigation

> 2026-11-06: The per-round results and the `.build/` evidence paths named below
> were local and are not in this repository. [001-action.md](001-action.md) now
> holds the condensed results. Status lines below show the state at that time.

> 2026-11-05: [006](006-live-target-safety.md) records a later explicit approval
> to increase membership discovery from 1.5 to 3 seconds. The measurements,
> independent runner-test limits and unknown cold-script OS mechanism below
> remain historical evidence, not a claim that the production runner was fixed.

## Context

The user approved three follow-up corrections on candidate `9d21fc26`: preserve Android routing when optional hdc discovery fails, add a Harmony hint to top-level adb device-not-found errors, and investigate intermittent timeouts of immediate-output fake hdc processes. The previous fail-closed decision came from an ambiguous review requirement and violates the original Android compatibility goal. The previous suite serialization is not a root-cause finding.

## Approved change

- Failed discovery falls back to existing Android shape routing and emits one stderr warning per invocation. Include the failure reason and the explicit `sim-use harmony <verb>` alternative. Keep JSON stdout valid and never cache discovery failures as membership results.
- A top-level Android device-not-found error gets an additional Harmony hint only when the hdc hook is installed. Preserve explicit namespaces, missing-hdc hosts and implicit selection. Cover daemon stale shutdown without another discovery request.
- Keep the 1.5-second membership deadline and business timeouts. Distinguish delayed process launch, delayed termination notification, fixture contention and blocking executor/cache-lock effects using a pressure loop with phase evidence. Remove serialization as a supposed fix; make any final test restructuring follow the evidence.

## Verification and limits

No phone commands, commits, pushes, PRs, E2E or paid eval. The task instructions permitted read-only real `hdc list targets` during developer-environment testing; no separate explicit statement of that permission from the user is recorded. Run the full build and at least five consecutive full unit-test runs, with at least three runs leaving `SIM_USE_HDC` unset. Record each result, pre/post pressure failures, and fake-transport CLI/daemon cases in `001-action.md`. Keep the final state at waiting for manual acceptance; disclose an unknown root cause if evidence remains inconclusive.

## Investigation hypotheses

1. Fresh fixture exec/host load delays actual child entry: a timeout has no child-entry marker, while completion notification follows termination normally.
2. Foundation Process termination notification is delayed behind blocked executor work: child exit is recorded before the deadline but the semaphore is not signalled in time.
3. Cache-lock waiting adds another probe's time to an elapsed assertion: per-call lock-wait evidence distinguishes it from subprocess deadline enforcement.

These were the initial hypotheses. The measured evidence and bounded conclusion follow.

## Phase evidence and decision

The standalone harness extracts the actual before/after Hdc implementation and
adds timestamps at process launch, wait, notification and cache-lock boundaries.
The script uses shell builtins to write entry/exit markers. These observations
locate a delay before the first successful marker write; they do not name the
underlying OS component.

| Condition | Before requests / failures | After requests / failures |
| --- | --- | --- |
| Fresh executable script, serial | 100 / 0 | 100 / 0 |
| Fresh executable script, batch width 32 | 512 / 494 | 512 / 499 |
| Fresh script, TaskGroup batch width 32 | 256 / 239 | Not repeated |
| Installed `/usr/bin/printf`, batch width 32 | 1024 / 0 | 1024 / 0 |
| Cache policy through listing seam, Dispatch | Not available | 1024 / 0 |
| Cache policy through listing seam, TaskGroup | Not available | 1024 / 0 |

Batch width is not observed concurrency: the cold runs reached at most 12
simultaneous runner calls. All 494 before and 499 after cold failures lacked
an entry marker and still had a running process at timeout. Before the change,
`Process.run` took at most 6.660 ms and the termination callback followed timeout
within 1.705 ms. No failed request recorded a child exit before the deadline.
Switching from Dispatch to TaskGroup did not remove the cold-script failure.

A separate cache experiment had up to 2.080 seconds of lock waiting, but no
transport timeout. The old outer elapsed assertion mixed that wait with the
subprocess deadline. Cache locking remains unchanged: this finding does not
authorize a new production concurrency contract.

Keep `Hdc.run`, the 1.5-second deadline and the original timing bounds. Test
membership cache decisions through an internal listing boundary rather than a
fresh executable under a real short deadline. Test native process completion
and timeout separately. Remove the previous suite serialization. The seam
pressure runs exercise failure propagation, successful retry and positive and
negative cache hits; they are not simulated successful process runs.

Prewarming is not a repair: one after-run warmup itself timed out and exited
with signal status -5 before collecting requests. A separate 0.05-second TERM
diagnostic met the original bounded-timeout contract in 128/128 cases, but only
127/128 reached its extra trap-readiness marker. That additional readiness
condition was not made a permanent test assertion.

**Unresolved:** the specific OS mechanism behind first-execution script delay.
Cold-script pressure still fails; no claim is made that cold execution or
production `Hdc.run` was repaired. The Android fallback independently handles
a real discovery timeout as the user requested.

Raw before/after snapshots, harnesses, per-request timestamps, exact commands
and failures are retained under `.build/harmony-transport-phases-20261105/`;
`outcome.txt` and `phase-summary.json` define the measurement limits. Full
repository verification and CLI results are recorded in `001-action.md`.

## Follow-up: global probe counter race (2026-11-05)

Independent retesting of candidate `d4b4a9da` found 19 failing runs out of 40
with `swift test --skip-build --filter 'TapForwarder|HarmonyRouting|HarmonyGesture|PlatformRouterPhysical|HarmonyTransport'`.
Removing TapForwarder and PlatformRouterPhysical produced 0 failures in 40
runs. These are the reviewer's reported results, not a new local baseline run.

The parser gate protects probe installation but does not exclude unrelated
parallel calls to the global `PlatformRouter.resolve(udid:)`. Android-shaped
identifiers from TapForwarderTests and PlatformRouterPhysicalDeviceTests
therefore entered the counter closures in `topLevelDeltaRejection` and
`failingProbeForwarding`, incrementing captured mutable state from other
threads. Full-suite passes did not exclude this different interleaving.

Both probes now compare the argument with their own `Self.serial` before
reading or writing captured state. Foreign serials return false; the owned
serial retains the original increment and success/error behavior. The two nil
installations and the existing stateless serial predicate in the other helper
call sites need no change. Both `probes == 1` assertions and normal parallelism
remain intact. No Sources file, timeout, production behavior, or cold-script
conclusion changes in this follow-up.

### Follow-up verification

The test-only repair passed 40 consecutive runs of the same `--skip-build`
filter, with 0 failures. Every run left `SIM_USE_HDC` unset, used normal
parallelism, and logged both repaired tests passing. Swift Testing reported
49 and 7 tests passing in each round. An initial coverage-enabled filtered
build/run also passed; it compiled the test edits before the 40 measured runs.

Three subsequent `make test` runs all passed: 48.865 seconds with a nonexistent
hdc override, then 42.623 and 40.915 seconds with `SIM_USE_HDC` unset. Each run
reported XCTest counts of 48 / 52 / 231 and Swift Testing counts of
1345 / 154 / 29, all passing. E2E opt-in variables were removed throughout.

The CLI SHA-256 stayed
`d4b4a9dad762c970a3e2d155abd1affc720ebc1beafe33920cd6ef01af5362e7`
before and after every run and at the final independent checksum. There is
no new CLI candidate. Per-round results are in [001-action.md](001-action.md);
raw logs, exact commands, environment and checksums are retained under
`.build/harmony-probe-race-rkqry023/`.

This correction fixes the foreign-serial counter access, not the separate
cold-script execution delay. Its specific OS mechanism remains unknown.
The state remains waiting for manual acceptance.
