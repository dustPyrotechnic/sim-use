# 012 — HarmonyOS backend: Plan

| | |
| --- | --- |
| **Status** | Implemented; manual acceptance confirmed (2026-11-06); PR pending |
| **Anchor date** | 2026-11-04 |
| **Primary PRs** | (fill in as they merge) |
| **Related** | [007-physical-ios-device-backend](../007-physical-ios-device-backend/000-design.md) (capability model, top-level routing), [008-linux-android-build](../008-linux-android-build/000-design.md) (Linux graph, connection-scoped daemon) |

> 2026-11-04: The task request explicitly approves this plan and G1 for
> implementation on `feat/harmonyos-backend`. The earlier “unapproved”
> amendment below is historical. This round stops at manual acceptance;
> no commit, push, PR, final E2E or paid eval is authorized.

> 2026-11-05 follow-up: optional hdc discovery failures must warn and retain
> Android routing, not abort it. The earlier fail-closed and suite-serialization
> conclusions are superseded by the approved [routing/timeout review](003-routing-timeout-review.md).

> 2026-11-05 device follow-up: keyboard occlusion is now confirmed by the
> user's device test. A red-first correction and two hint changes are approved;
> the prior “unconfirmed” status and original-hint-first order are superseded
> by [004-keyboard-occlusion-and-hints.md](004-keyboard-occlusion-and-hints.md).

> 2026-11-05 transparency correction: the scripted `c34d6dc9` retest is
> device evidence, not human acceptance. The y=1570 keyboard boundary in 004
> was a transparent wrapper. The approved red-first correction is in
> [005-transparent-keyboard-geometry.md](005-transparent-keyboard-geometry.md).

> 2026-11-05 live-target correction: the user approved current keyboard checks
> for cached aliases, actual-pixel screen bounds, a 3-second membership limit
> and the six-digit color test gap. The earlier exclusions are superseded by
> [006-live-target-safety.md](006-live-target-safety.md); historical evidence stays unchanged.

## Background

sim-use drives iOS Simulators, physical iOS devices and Android targets.
HarmonyOS NEXT devices do not run adb or AccessibilityService, so no current
backend can reach them. The OpenHarmony toolchain supplies `hdc` (device
transport, comparable to adb) and the on-device `uitest` tool (layout dump,
input injection, screen capture). No app install is needed for `uitest`.

### Feasibility spike (2026-11-04)

Environment: macOS host, `hdc` 3.2.0f, physical ALN-AL00 over USB,
HarmonyOS 6.1.0.135, API 24, `uitest` 6.0.2.3. Times are wall clock on the host
for one call, one sample each. Only the system home screen and global search
were tested.

| Capability | Command | Time | Result |
| --- | --- | --- | --- |
| Shell round trip | `hdc -t <sn> shell echo` | 0.14 s | Fixed cost of every call |
| Layout dump | `hdc shell uitest dumpLayout -p <file>` | 1.12 s | JSON tree, 124 nodes on the home screen |
| Fetch file | `hdc file recv <file> <local>` | 0.10 s | — |
| Screenshot | `hdc shell snapshot_display -f <file>.jpeg` | 0.40 s | 1260×2720 JPEG |
| Key | `uitest uiInput keyEvent Back` / `Home` | ~0.4 s | OK |
| Swipe | `uitest uiInput swipe x1 y1 x2 y2 v` | ~0.9 s | OK |
| Text (CJK) | `uitest uiInput text "你好abc123"` | ~1.0 s | OK, text read back from the dump |

Findings:

1. `uiInput text` delivers text through the system pasteboard. The keyboard
   showed "from pasteboard: 你好abc123" after the call, so the call replaces
   the user's pasteboard content.
2. Dump nodes have `attributes` + `children`. `bounds` is the string
   `"[x1,y1][x2,y2]"`; booleans are `"true"` or `""`. `bundleName` appears only
   on `WindowScene` nodes. No node had `focused == "true"` with the keyboard
   open, so focus cannot be the keyboard signal.
3. An Android-shaped serial (redacted here as `TESTHARMONY000001`) satisfies
   `PlatformRouter.looksLikeAndroid`. Shape-based routing sends it to adb.
4. A system "USB connection mode" dialog was on screen at the start. A
   selection in that dialog can change the USB mode and drop the hdc link.

## Goals

- Add a `harmony` platform and a `HarmonyBackend` target that drives a
  HarmonyOS device through `hdc` + `uitest`, with no on-device app.
- Phase 1 verbs, top-level and under `sim-use harmony <verb>`: `devices`,
  `describe-ui`, `tap` (coordinates, `@N`, selectors), `long-press`, `swipe`,
  `scroll`, `type`, `button` (home, back, power), `screenshot`, `app-state`,
  `keyboard-state`. `keyboard-state` is conditional on gate G1 (below).
- Correct routing for hdc serials, also when the serial looks like an adb
  serial.
- The same outline, `@N` aliases and `--json` envelope shape as other
  platforms, with `platform: "harmony"`.
- No behavior change for existing iOS and Android users, including the
  Android-only Linux build.

**Non-goals (phase 1):** `record-video`, `stream-video`, `multi-touch`,
`gesture` presets beyond swipe, `paste`, Harmony on Linux (the existing
Android-on-Linux build stays supported, see Linux below), HarmonyOS emulator
support claims (not tested), a custom on-device HAP bridge.

## Design

### Module

New SwiftPM target `Sources/HarmonyBackend/`, depends on `SimUseCore` +
ArgumentParser only (no FB*, no `SimUseVideo` in phase 1). Layout mirrors
`Sources/AndroidBackend/`:

| Folder | Content |
| --- | --- |
| `Hdc/` | `Hdc` process wrapper: binary discovery (`PATH`, `SIM_USE_HDC`, DevEco default path), `-t <serial>`, timeouts, `list targets` parser |
| `UITest/` | `UITestClient`: `dumpLayout`, `uiInput click/longClick/swipe/fling/keyEvent/text`, `snapshot_display`; temp files under `/data/local/tmp/sim-use-*` |
| `Normalizer/` | `HarmonyLayoutNode` (Codable for the dump JSON), `HarmonyClassifier` (type → `ElementType`), `HarmonyOutlineRenderer`, system-dialog detection |
| `Verbs/` | `Harmony<Verb>Command` + `HarmonyCommand` namespace |

The target is registered only in the macOS graph of `Package.swift` and in
`Sources/SimUse/main.swift`.

### Linux

The `#if os(Linux)` graph in `Package.swift` builds `SimUseCore`,
`AndroidBackend` and `SimUseLinux`. CI runs `swift build`, `swift test` and
`.build/debug/sim-use --help` on it (`.github/workflows/tests.yml`, job
`linux`). Rules for this work:

- `HarmonyBackend` is not added to the Linux graph. `SimUseLinux` does not
  register `harmony` verbs.
- `SimUseCore` must not import or reference `HarmonyBackend`. Core keeps only
  platform-neutral pieces: the `harmony` enum cases and the routing hook.
- The new enum cases make the exhaustive switches in
  `Sources/SimUseCore/Device.swift` (`init(from:)` kind default, `isUsable`)
  and `PlatformRouter` callers change. These compile on Linux too, so each
  new case gets an explicit branch there. On Linux the Harmony probe hook is
  not installed, so routing is the same as today.

### Routing

`Platform` in `Sources/SimUseCore/PlatformRouter.swift` and
`Device.Platform` in `Sources/SimUseCore/Device.swift` gain `harmony`.
Shape alone cannot tell an hdc serial from an adb serial, so resolution adds a
membership step for an **explicit** identifier:

1. `sim-use harmony <verb>` → always Harmony.
2. Top-level verbs with an explicit `--device` / `SIM_USE_DEVICE`: when the
   identifier is Android-shaped, ask `hdc list targets` (0.1 s, cached per
   process) before adb. A hit routes to Harmony. The probe is an injectable
   hook that only the macOS executable installs; with no hook or no `hdc`
   binary, routing is unchanged.

### Default device selection (no `--device`)

Current order in `DeviceResolver.resolve(explicit:)`: (1) explicit flag,
(2) `SIM_USE_DEVICE` / `SIM_USE_UDID`, (3) the single live daemon (any
platform, from `DaemonPaths.enumerateLiveDaemons`), (4) the single booted iOS
simulator from `simctl`. Today step 3 picks an Android daemon too.

Decision: keep steps 1–4 and their order for iOS and Android. A Harmony
target is never selected implicitly:

- In step 3, Harmony daemons are removed from the list before the
  `count == 1` check. The rest of the rule is unchanged.
- The daemon needs a platform tag for this, because a live-daemon entry has
  only `udid`. The Harmony daemon records its platform in its footprint
  (format to be fixed in implementation, readable by an older client as
  "unknown"). Step 3 does not run an `hdc` probe, so the Android fast path
  gets no extra cost.
- Explicit selection (steps 1–2) of a Harmony device still works.

Consequence to note: with one Android daemon and one Harmony daemon, step 3
picks the Android daemon. Today two daemons fall through to step 4. This is
the only changed case, and it needs a Harmony daemon to exist.

Acceptance scenarios (unit tests with injected daemon list and simctl
provider; live check where marked):

| Live daemons | Booted iOS sims | Expected without `--device` |
| --- | --- | --- |
| Harmony only | 0 | Error `noSimulatorBooted` (Harmony not picked) — also live |
| Harmony only | 1 | The iOS simulator |
| Android only | 1 | The Android daemon (unchanged) — also live |
| Android + Harmony | 1 | The Android daemon |
| iOS only | any | That iOS daemon (unchanged) |
| None | 1 | The iOS simulator (unchanged) |

### Daemon

Harmony verbs route through the existing per-UDID daemon. The connection
identity for `DaemonClient.connectionIdentityProvider` is the hdc server
address (`OHOS_HDC_SERVER_PORT` / default). The daemon caches the last dump
for `@N` resolution through `OutlineCache`, as for Android.

### Text input

`type` uses `uiInput text` (focused field) or `inputText x y` when a target is
given. Because it overwrites the pasteboard, `type` reports this in its
advisory output and README/skill text. Restoring the previous pasteboard is
not possible without an on-device helper; see Open questions.

### keyboard-state and gate G1

Existing contract (`Sources/SimUse/Commands/KeyboardState.swift`): text output
`soft` or `hidden`, both exit 0; non-zero exit only for a probe failure;
`--json` carries `visible`. "Cannot tell" must never be reported as `hidden`.

**Gate G1 (before phase 1 implementation of `keyboard-state`):** find a probe
that separates shown from hidden on the ALN-AL00, in the system UI and in one
third-party app, with keyboard shown and hidden in each. Candidates: the input
method window in `hidumper -s WindowManagerService -a '-a'`, or keyboard nodes
in `uitest dumpLayout` without window merge (`-i`). Record the commands and
results as an amendment.

If G1 fails, the plan owner asks the user to approve one of: move
`keyboard-state` to phase 2, or ship it with a documented error for Harmony.
The verb is not removed from scope without that approval.

Acceptance after G1:

| Case | Text stdout | `--json` | Exit |
| --- | --- | --- | --- |
| Keyboard shown | `soft` | `visible: true` | 0 |
| Keyboard hidden | `hidden` | `visible: false` | 0 |
| Probe failure (device gone, hdc error, output not parseable) | no `soft` / `hidden` | error envelope | non-zero |

### Dialog safety

`describe-ui` flags system dialogs (`com.ohos.sceneboard` dialog windows) in
the outline header, in the same way `CrashDialogSignal` is surfaced. The tool
never auto-dismisses them.

### Contract changes

- `--json`: new `platform` value `harmony`; new `kind` usage for physical
  Harmony devices.
- Daemon footprint: platform tag for Harmony daemons (see Default device
  selection).
- Skill: `skills/sim-use/SKILL.md` gains a Harmony section; bump
  `MINIMUM_SIM_USE_VERSION` in `skills/sim-use/scripts/preflight.py` and
  extend `PreflightScriptTests`.
- README and `CHANGELOG.md` `[Unreleased]`.

## Alternatives & decisions

| Decision | Options considered | Chosen because |
| --- | --- | --- |
| Device-side channel | (a) `uitest` CLI per call; (b) `uitest start-daemon` RPC; (c) own HAP bridge like Android | (a) works today with no install and covers phase 1. (b) and (c) are phase 2 options for latency and multi-touch; decide after measurement. |
| Routing for colliding serials | (a) explicit namespace only; (b) `harmony:` prefix; (c) `hdc list targets` membership probe | (c) keeps top-level verbs usable with the real serial; (a) stays available as an override. (b) invents an identifier no other tool accepts. |
| Separate target vs. extend `AndroidBackend` | — | Transport, tree format and input tools have nothing in common with adb + bridge. |
| Screenshot command | `snapshot_display` vs `uitest screenCap` | `snapshot_display` measured 0.40 s; keep `screenCap` as fallback. |
| Linux scope | (a) add Harmony to Linux; (b) macOS only, keep Android-on-Linux | (b): no Harmony need on Linux yet; Core stays free of the backend so (a) stays possible later. |
| Implicit device selection | (a) keep daemon step, Harmony can be picked; (b) make all resolution iOS-first; (c) keep order, exclude Harmony daemons | (c): (a) can send an unqualified command to a phone by surprise; (b) changes existing Android sessions. |
| Harmony exclusion signal | (a) `hdc` probe in step 3; (b) platform tag in daemon footprint | (b): no extra 0.1 s on the Android fast path. |
| Skill compatibility floor | Keep 0.16.0 vs bump to 0.17.0 | 0.16.0 has shipped without Harmony. The new skill requires 0.17.0; development stamps retain the existing preflight policy. This is not a release/version bump of the binary. |
| Preflight implicit selection | Include Harmony among connected candidates vs require explicit selection | Exclude Harmony before preflight's automatic candidate count too, so the skill cannot bypass the CLI's explicit-device safety rule. Explicit `--device` still works. |
| Fixture privacy | Commit full device content vs sanitize display text | Retain real G1 tree structure, geometry, flags and identifiers; replace non-generic text/description/hint values. Use all six original WMS keyboard captures. |
| Daemon platform tag | Change pidfile vs PID-bound sidecar | Keep the integer `<id>.pid` format. Store `{pid, platform:"harmony"}` in `<id>.platform`, trust it only for the matching PID, and remove it with that daemon's footprint. Older clients ignore it as unknown. A hidden daemon `--platform harmony` carries explicit namespace routing even if discovery later fails. |
| Input option capabilities | Ignore unsupported options vs explicit rejection | The live `uitest uiInput` help has no longClick duration or text clear option. Use native longClick; reject custom duration and `type --clear`. Convert swipe duration to distance/velocity only inside the documented 200–40000 px/s range. Never silently clamp. |
| App-state source | Foreground layout vs process list | Use the observed `ps -A -o PID,NAME` format and the existing main-process liveness model. Do not label layout visibility as process liveness or claim foreground state. |
| Screenshot output encoding | Reject `.png` vs transcode native JPEG | The device rejects a `.png` snapshot_display filename even with exit status 0. Capture native JPEG and use system ImageIO for PNG output; retain screenCap fallback. No SimUseVideo dependency is added. |
| Automatic Harmony crash monitoring | Enable the existing generic tracker vs keep to explicit app-state | Live smoke exposed an unrelated system process disappearing. Automatic crash monitoring is not a phase-1 goal and was added during implementation without a scoped app allowlist. Remove that extra hook and its wrapper; retain the approved app-state queries. This is a scope correction, not a change to iOS/Android monitoring. |
| Screenshot daemon bypass | Route every Harmony verb through the daemon vs retain screenshot exception | A live cross-directory check showed that daemon-side output resolution wrote a relative path into the daemon's directory. Keep screenshots in-process on all platforms, including both Harmony command surfaces, as the existing screenshot contract requires. Input and UI commands still use the per-device daemon. |
| System search input role | Classify only `Search` vs include its native `SearchField` child | Live smoke showed that the child carries entered text and was falling through to Button. Map both to TextField; keep the actual six-node subtree as a selector/readback regression fixture. |
| Authorized process-parser review fix (2026-11-05) | Filter system bundles vs retain all main app processes; split every token vs PID plus the remaining name | The captured fixture already contains `com.ohos.sceneboard`. System bundle prefixes do not determine process liveness. Retain them, split each row once after PID, and keep strict header/PID/name validation and existing child-process/path exclusions. That earlier authorization covered these fixes and restoring the init frontmatter test, without device operations; the later checklist decisions follow below. |
| Membership failure and latency (revised authorized review, 2026-11-05) | Abort optional discovery failures vs warn and preserve Android shape routing | The prior review wording led to fail-closed routing, which broke the original Android compatibility goal. The user explicitly requires one stderr warning per invocation and Android fallback on nonzero exit, exit-0 failure text or timeout. Do not cache failures. The later approved 006 change increases the former 1.5-second probe limit to 3 seconds because cold hdc discovery was reported at 1.38–1.40 seconds. Successful-negative fallback, namespaces, absent-hdc behavior and daemon hints remain unchanged. |
| Warning lifetime and error output | Add a JSON advisory or daemon field vs use the existing stderr/client-error surfaces | A TaskLocal invocation owns the once-only warning and suppresses repeated discovery after that invocation's failure; a later invocation can retry. The successful membership cache is unchanged. A stderr warning avoids changing the JSON envelope. Prepend the Harmony alternative only while rendering the final client error, preserving the original hint verbatim afterward and covering stale-daemon responses without a new wire field or probe. This order supersedes the earlier append decision after the authorized device review. |
| Harmony gesture parity (authorized review) | Ignore `--delta` vs reject; inconsistent scroll defaults/units vs one contract | Reject an explicitly supplied swipe `--delta` on Harmony only. Both scroll entrypoints default to down, accept seconds (default 0.4), and share success text and validation. This is an unreleased CLI correction, not a compatibility alias for millisecond input. |
| Disconnect and listing errors (authorized review) | Broad error matching vs transport-specific evidence; count unavailable backends vs exclude them | Only the hdc unknown-target transport diagnostic marks a Harmony daemon stale; ordinary uitest errors must not stop it. An unavailable optional hdc backend does not suppress the original all-listings-failed warning; a successful empty listing remains distinct from failure. |
| Connected-only listing and public examples (authorized review) | Retain no-op flags vs remove; publish serial vs redact | Remove Harmony's unused `onlineOnly` parameter and `--online` flag because hdc already lists connected targets only. Replace the captured serial in Sources/Tests/docs with Android-shaped `TESTHARMONY000001`; keep original local evidence unchanged. |
| Short-deadline investigation (historical authorized outcome; deadline later revised in 006) | Change Hdc.run or increase deadlines vs separate cache policy from cold executable timing | Pressure located failures before the fresh script's first marker, with prompt Process.run return and termination notification; installed native processes passed under the same load. That round kept Hdc.run, cache locking and 1.5 seconds, and removed suite serialization in favor of deterministic cache/routing seams and separate native process tests. Cold-script pressure still failed and its specific OS cause remains unknown. The later 3-second policy is not a claimed runner repair; original measurements and runner-test timing bounds are unchanged. |
| Confirmed keyboard occlusion and selector recovery (2026-11-05) | Use full-screen WMS windows vs actual input-method layout panels; hide only text vs filter shared entries | Use visible, clipped, non-full-screen panel bounds from input-method subtrees. Filter non-keyboard entries before outline, aliases and selectors are published, checking both existing pixel-center conventions. Preserve keyboard controls, usable partial centers, no-geometry behavior and the existing unfiltered flag. Count retained List cells only. A selector miss advises refreshing describe-ui; real hdc failures retain connection advice. Red-first evidence and geometry limits are in 004. |

## Verification plan

The checklist below was defined before implementation. Actual commands,
results and remaining coverage limits are recorded in
[001-action.md](001-action.md). Paid steps still need separate approval.

### During implementation (targeted)

- `make build`, `make test` on macOS.
- Unit tests with fixture dumps (home screen dump from the spike, plus one
  third-party app dump): node decoding, bounds parsing, classifier, outline
  rendering, `@N` resolution.
- Routing tests: an hdc-listed serial routes to Harmony; an adb-only serial
  still routes to Android; no hook or no `hdc` binary → no probe. Extend
  `PhysicalDeviceRoutingTests` or add `HarmonyRoutingTests`.
- Default selection tests for the table in Default device selection.
- `keyboard-state` tests for the three cases above.
- `PreflightScriptTests` for the new floor.
- Linux: `swift build`, `swift test`, `.build/debug/sim-use --help` in a
  `swift:6.3` container, or the CI `linux` job.

### Manual acceptance (bound to one candidate)

Candidate identity: commit SHA and `sim-use --version` of the built binary,
device ALN-AL00 with the HarmonyOS build number. Scenarios, each in the system
UI and in one third-party app:

1. `devices` lists the Harmony device with `platform: harmony`.
2. `describe-ui`, then `tap @N` and a selector tap.
3. `swipe`, `scroll`, `long-press`.
4. `type` with CJK text; the pasteboard advisory is shown.
5. `button home` / `back`.
6. `screenshot`.
7. `app-state`.
8. `keyboard-state`: shown, hidden, and device unplugged (probe failure).
9. Default selection: Harmony daemon only, no `--device` → not picked;
   Android daemon with a booted iOS sim → Android picked as today.

Agent clicks and screenshots do not count as manual acceptance.

### Final full run (after the Review Loop converges)

On the final snapshot, by one verification owner:

| Scope | Why |
| --- | --- |
| `make build`, `make test` (macOS) | Unit and contract tests |
| Linux `swift build`, `swift test`, `sim-use --help` | `SimUseCore` enum and routing changes compile there |
| `make e2e-ios` | `DeviceOptions` / `DeviceResolver` / `PlatformRouter` are on every iOS path |
| `make e2e-android` | Android-shaped identifiers now pass the Harmony probe first |
| Harmony live checklist (scenarios 1–9) | No automated Harmony E2E in phase 1 |
| Agent evals `e2e/agent-evals/` `ios` and `android` cases | `SKILL.md` changes; paid `claude -p`, needs approval at that time |

Not in scope, with reason: `make e2e-matrix` (no change to the Xcode / Device
Hub host matrix), `make e2e-ios-duo` (no display-routing change), bridge APK
tests (no bridge change).

## Open questions

- Resolved 2026-11-04: gate G1 passed; see the keyboard probe amendment.
- Resolved 2026-11-05: PID-bound `.platform` sidecar; older clients ignore
  the new file. See the decision above and implementation results.
- New Harmony agent eval cases: not in this plan; needs a separate decision.
- Latency of `uitest start-daemon` RPC; whether it supports multi-touch and
  frame capture (phase 2).
- Third-party coverage beyond the tested Baidu app; its dump, CJK input,
  selectors, gestures and keyboard states worked during implementation smoke.
- Whether the pasteboard can be read and restored from `hdc shell`.
- Coordinate model on foldables and in landscape.
- HarmonyOS emulator serial format and behavior.

## Amendments

- Updated 2026-11-04: revised before approval for review items on the Linux
  build, final verification scope, `keyboard-state` gate G1 and default device
  selection. No separate file; the plan is still unapproved.
- Updated 2026-11-04: gate G1 passed; `keyboard-state` probe uses the `SCBKeyboardPanel` row of the WindowManagerService dump — see [002-g1-keyboard-probe.md](002-g1-keyboard-probe.md)
- Updated 2026-11-04: implementation authorized by the task request. During
  execution the user separately approved `brew install xcodegen` and
  `./scripts/build.sh dev` because the checkout had no XCFrameworks.
  This does not authorize device installs or changes to system settings.
- Updated 2026-11-05: the user separately approved repair of two existing
  daemon test suites whose servers could expire while waiting for the
  shared parser gate. Server start, assertions and shutdown now run inside
  that gate. No production timeout, behavior or assertion was weakened.
- Updated 2026-11-05: user approved Android fallback with warnings, disconnected-target hints, and renewed short-timeout root-cause investigation — see [003-routing-timeout-review.md](003-routing-timeout-review.md).
- Updated 2026-11-05: user approved red-first keyboard occlusion filtering, selector recovery advice and Harmony-first disconnect hints — see [004-keyboard-occlusion-and-hints.md](004-keyboard-occlusion-and-hints.md).
- Updated 2026-11-05: correct transparent input-method geometry with conservative subtree fallback and dual-center mutation tests — see [005-transparent-keyboard-geometry.md](005-transparent-keyboard-geometry.md).
- Updated 2026-11-05: add live alias safety without cache replacement, screen bounds and a 3-second discovery deadline — see [006-live-target-safety.md](006-live-target-safety.md).
- Updated 2026-11-06: manual acceptance confirmed; the action log was condensed into the repository template — see [001-action.md](001-action.md)
