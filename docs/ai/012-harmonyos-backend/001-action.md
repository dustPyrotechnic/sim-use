<!-- SPDX-License-Identifier: Apache-2.0 -->

# 012 — HarmonyOS backend: Action log

This log gives the final results. The decisions and their measurements are in
[000-plan.md](000-plan.md) and the numbered amendments.

## Timeline

| Date | Change | Ref |
| --- | --- | --- |
| 2026-11-04 | Plan approved. Gate G1 selected the `SCBKeyboardPanel` row for `keyboard-state`. | [000](000-plan.md), [002](002-g1-keyboard-probe.md) |
| 2026-11-04 | Backend and verbs implemented on `feat/harmonyos-backend`. | This log |
| 2026-11-05 | hdc probe failures now warn and keep Android routing. Fixed a probe capture race. | [003](003-routing-timeout-review.md) |
| 2026-11-05 | Outlines exclude App elements covered by the keyboard. Selector and disconnect hints corrected. | [004](004-keyboard-occlusion-and-hints.md) |
| 2026-11-05 | A device retest found that transparent wrappers hid visible targets. Geometry corrected. | [005](005-transparent-keyboard-geometry.md) |
| 2026-11-05 | Cached aliases check the current keyboard and screen. Discovery deadline is now 3 seconds. | [006](006-live-target-safety.md) |
| 2026-11-06 | Review fix: `harmony devices --json` uses `data.devices`. | [006](006-live-target-safety.md) |

## Outcome (as of 2026-11-06)

sim-use controls HarmonyOS NEXT phones from macOS through `hdc` and `uitest`.
No helper app is installed.

| Area | Files |
| --- | --- |
| Transport and discovery | `Sources/HarmonyBackend/Hdc/Hdc.swift` |
| `uitest` client | `Sources/HarmonyBackend/UITest/UITestClient.swift` |
| Layout, outline, keyboard geometry | `Sources/HarmonyBackend/Normalizer/HarmonyLayout.swift` |
| Target resolution, tap, long-press | `Sources/HarmonyBackend/Verbs/HarmonyTapCommand.swift` |
| Other verbs | `Sources/HarmonyBackend/Verbs/HarmonyCommand.swift`, `HarmonyStateCommands.swift`, `HarmonySwipeCommand.swift`, `HarmonyScreenshotCommand.swift` |
| Routing | `Sources/SimUseCore/PlatformRouter.swift` |
| Daemon platform pin | `Sources/SimUseCore/DaemonPaths.swift`, `Sources/SimUseCore/Daemon/` |
| Top-level forwarders | `Sources/SimUse/Commands/` |

Supported verbs: `devices`, `ui` / `describe-ui`, `tap`, `long-press`, `swipe`,
`scroll`, `type`, `button`, `screenshot`, `app-state`, `keyboard-state`.

The skill compatibility floor is 0.17.0. A release must ship this version.

## Verification

Manual acceptance: the user confirmed it on 2026-11-06. The scenarios were not
recorded. Agent-run checks below are not manual acceptance.

Unit tests and mutations:

| Check | Result |
| --- | --- |
| `swift test`, final source | 5 of 5 rounds passed: 1372, 154 and 29 tests |
| `TapForwarder\|PlatformRouterPhysical\|Harmony`, default parallelism | 40 of 40 rounds passed, before the `devices` JSON fix |
| Independent mutations of target, keyboard and cache guards | 23 of 23 caught, after two added cache tests |
| Bare-array `devices` mutation | Caught |

Mate 60 Pro (ALN-AL00), 1260x2720, before the `devices` JSON fix. A read-only
`harmony devices --json` was run on the final code.

| Scenario | Result |
| --- | --- |
| Stale `@N` and `#N` under the keyboard: tap, long-press, `type --target` | 6 of 6 rejected. Cache bytes unchanged. Layout unchanged, except the clock. |
| Covered App element from `--include-offscreen` | Rejected, also through the top-level command and the daemon |
| Keyboard control alias | Worked. The keyboard closed. |
| Elements at y=2848, y=2831 and y=-718 | Rejected with a scroll hint |
| Partly visible row with an off-screen center, `--id` | Rejected. Cache unchanged. |
| Zero-size element | Rejected. No input sent. |
| Alias tap with a current cache | 8 of 8 reached the expected page |

Tap time, median of 8: coordinates 0.50 s, selector 1.82 s, cached alias 1.98 s.
A rejected alias takes about 1.4 s. With a fake `hdc` that hangs, discovery took
3.06 s, gave one warning and kept Android routing. Discovery on the device took
about 0.2 s.

End-to-end, final code:

| Suite | Result |
| --- | --- |
| `scripts/test-runner.sh`, iPhone 18 Pro, iOS 27.0 | 28 of 29 suites passed. `TypeTests` failed. |
| `scripts/test-runner-android.sh`, read-only headless emulator, API 35 | 9 of 10 suites passed. `AndroidStreamVideoTests` failed. |
| Agent evals, `quick` tag, through `e2e/agent-evals/run.py` | iOS 2 of 2, Android 1 of 1 |

Failures that are not attributed to this branch, but have no known cause:

- `TypeTests` failed in 2 of 9 rounds because leading characters were lost
  (`"nitial text"`, `"lo World"`). The next 7 rounds passed. Five alternating
  rounds each on this branch and on `c02295e` all passed. This branch does not
  change the iOS typing path. Five baseline rounds cannot exclude a difference.
- `AndroidStreamVideoTests` failed once with
  `Android device emulator-5554 not found`, soon after a bridge reinstall. Three
  alternating rounds each on this branch and on `c02295e` all passed.
- `StdoutStreamSinkTests` failed in 1 of 18 full-suite rounds. This branch does
  not change that test.
- Before the safety tests moved in-process, 3 of 7 full-suite rounds failed in
  existing daemon, release-script and physical-iOS fixtures. These failures did
  not occur again, but no single cause was proved.

## Deviations from plan

- Screenshots skip the daemon, so a relative `--output` path uses the caller's
  directory.
- A Harmony crash monitor was tried and removed. It caused an unrelated system
  process-exit prompt on the device. Only explicit `app-state` remains.
- `long-press` uses the native fixed duration. `type --clear` and custom
  durations are rejected.
- Safety tests use the public `perform*` entry points with `HarmonyTransport`
  instead of CLI subprocesses. CLI behavior was checked separately.
- `scripts/eval.sh` stops on macOS bash 3.2 with
  `PASSTHROUGH[@]: unbound variable` when no extra arguments are given. This
  branch does not change the script. The evals used `run.py` directly.

## Open questions

- A cached alias still taps its old coordinates after the page changes. The
  check covers only keyboard coverage and screen bounds. This was reproduced on
  the device. A general freshness check was not added.
- Validation and input are not atomic.
- The Linux build was not run locally. Inspection found no Harmony dependency
  in the Linux targets.
- Not tested: third-party input methods, keyboard skins, spell-check popups,
  landscape, foldable devices, `button power`, and quoted text through real
  `hdc` beyond the recorded cases.
- The OS mechanism behind the delayed cold scripts is unknown. See
  [003](003-routing-timeout-review.md).
- Physical iOS and Android devices were not used for the end-to-end suites. The
  evals ran the `quick` tag only.
