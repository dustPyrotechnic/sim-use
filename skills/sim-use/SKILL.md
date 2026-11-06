---
name: sim-use
description: Drive iOS Simulator, Android emulator/device, HarmonyOS NEXT phones, and physical iPhone/iPad screens for AI agents. Use when asked to automate a simulator or emulator, drive a real iOS or HarmonyOS device, tap/swipe/type on a device, describe UI, take a screenshot, or interact with a mobile app.
---

## 0. Preflight

Before first interaction with a device, run the preflight check:

```bash
python3 scripts/preflight.py --device <UDID>
```

This verifies sim-use is installed and compatible with the skill, the device is reachable, and the daemon is healthy. If you don't have the script, do the checks manually:

1. `sim-use --version` — confirm sim-use is on PATH and supports the skill's documented commands.
2. `sim-use devices` — confirm the target device is listed and booted/connected.
3. `sim-use ui --device <UDID>` — confirm you can read the screen.

A `WARN  UI content` line still passes preflight: the read works, but the outline can miss app controls. See the *Pitfalls* index.

The skill requires sim-use 0.17.0 or a development build with these commands. `--device` is optional when only one simulator is booted or one non-Harmony daemon is running. For Android, run `sim-use android init --device <serial>` once to install the bridge APK. Physical iPhones/iPads support only `ui`, selector-based `tap` and `screenshot`; see *Physical iOS devices* below. Harmony always requires an explicit serial or `SIM_USE_DEVICE`; see *HarmonyOS NEXT* before using it. Linux remains Android-only: no Harmony/iOS verbs, video, Viewer or `init`, and every verb needs `--device <serial>`.

## 1. The observe-act loop

Every interaction follows the same cycle: **observe → act → verify**.

### Observe

```bash
sim-use ui --device <UDID>
```

Read the outline. Each element has an `@N` alias and optionally a `#<id>` identifier. List cells carry `#N` (dominant list) or `#N@M` (scoped).

Frames in the JSON output (`--json`: `entries[].frame`, `screen`) use iOS **points**, Android and Harmony **pixels**. Key off `platform` before doing coordinate math across platforms. For UI reads, pair `--json` with `--no-raw` — see *Keeping output small* below.

### Act

Pick a selector, in order of preference:

| Selector | When to use |
|---|---|
| `tap @N` | Right after `ui`. Fastest, cache-backed. |
| `tap #<id>` | Stable across minor layout changes. Paste from the outline. |
| `tap --label 'X'` | Scripted flows. Combine with `--wait-timeout` for transitions. |
| `tap --label-regex '...'` | Dynamic labels with counters/timestamps. Anchor with `^...$`. |
| `tap --label-contains 'X'` | Substring match when exact label is unknown. |
| `tap -x N -y N` / `tap --point x,y` | Last resort for elements with no AX data. Takes the numbers the outline prints, in any orientation and on any display; `--coordinate-space native` is for device-native portrait points. |

Disambiguate collisions with `--element-type` or `--frame minY=0.7r` (see `references/cheatsheet.md`).

### Verify

Always verify after acting — commands are fire-and-forget:

```bash
sim-use ui --device <UDID>       # read the new screen state
sim-use screenshot --device <UDID> --output after.png
```

### Keeping output small

Every byte of command output you read costs context. Defaults that keep the loop cheap:

- Prefer the default text outline over `--json`. The outline carries everything a tap needs (`@N` / `#<id>` aliases, roles, frames, states); reach for `--json` when you need structured fields for coordinate math (`entries[].frame`, `screen`) or full untruncated text (the outline truncates labels at 60 graphemes, `value=` at 30).
- When you do use `--json`, add `--no-raw`. `data.raw` is the raw accessibility tree — typically the bulk of the envelope's bytes, and useful only for debugging sim-use itself.
- One `ui` per action: the Verify read of step N is the Observe read of step N+1. Don't run a second `ui` in between.
- Verify with the text outline, not a screenshot. Reading a screenshot costs several times more than a typical outline; take one only when the check is genuinely visual (colors, images, layout).
- On iOS, to wait out a transition, prefer `tap --label 'X' --wait-timeout 3` (polls for the element) over re-running `ui` in a loop. Android and Harmony `tap` have no `--wait-timeout`; use `sleep` between commands instead.
- For a known multi-step sequence on iOS, use `sim-use ios batch` (see `references/batch-reference.md`) — one invocation, one output.

### Common moves

| Task | Command |
|---|---|
| Scroll down | `sim-use gesture scroll-up --device <UDID>` (scroll-up = content moves up = page down) |
| Type text | `sim-use type 'hello' --device <UDID>` |
| Paste Unicode | Focus the field, then `sim-use paste 'こんにちは 🎉' --device <UDID>`; iOS works with Simulator.app or Device Hub, in either keyboard mode |
| Hardware button | `sim-use button home --device <UDID>` |
| Android back | `sim-use button back --device <UDID>` |
| Wait for animation | `sleep 0.4` between commands, or `--pre-delay 0.5` |
| Toggle/switch | `sim-use tap @N --duration 0.05 --device <UDID>` (UISwitch needs a brief hold) |
| Swipe | `sim-use swipe --from 50,500 --to 350,500 --device <UDID>` |
| Pinch zoom in | `sim-use gesture pinch-out --device <UDID>` (two-finger spread) |
| Rotate (two-finger gesture) | `sim-use gesture rotate-cw --angle 90 --device <UDID>` |
| Rotate the device (iOS) | `sim-use ios rotate landscape-left --device <UDID>` — interface names as the `App:` header prints them; re-run `ui` after |
| Fold / unfold (iPhone Duo) | `sim-use ios fold closed\|open --device <UDID>`; `sim-use ios fold --device <UDID>` reports which display is active; re-run `ui` after |
| Record evidence GIF | `sim-use record-video --output demo.gif --device <UDID>` — stop with SIGINT/SIGTERM (never SIGKILL); transcodes after stop; auto-plays inline in PRs; add `--gif-markers` for START/END loop-boundary cards |

### Paste on iOS simulators

Prefer `paste` for Unicode and IME-safe text. The default preserves the focused field's caret and selection. `--replace` selects all first. Use `--via-menu --target-id <id>` or `--target-x/--target-y` to focus a target explicitly. Both paths use the native Paste action; no hardware-keyboard or sync-setting change is needed.

For multiline or shell-sensitive text, use `printf '%s' "$TEXT" | sim-use paste --stdin --device <UDID>` or `paste --file <path>`. The control's native rules still apply, including single-line normalization and smart-paste spaces. `--replace` fails before Paste if Select All is unavailable and the field is not confirmed empty through accessibility. Never treat that refusal as a successful replacement. Unknown or ambiguous menu provenance is also refused; do not bypass that refusal by tapping a same-label app button. Always verify the actual field. If the command reports that Paste may have been sent, check the field before retrying; it does not automatically resend Paste.

Shared clipboard sync can also overwrite the Mac and other devices. Keep one clipboard writer active. sim-use serializes its own paste operations and checks for unexpected readback, but cannot prevent external writes. Never print unrelated clipboard data or restore an old backup over newer external content.

Batch paste supports default, replacement, files and explicit menu targets; `paste --stdin` is not a batch step because stdin belongs to the batch. A failed batch is not automatically replayed after a transient boot-readiness error. Inspect the UI and completed steps before retrying, including with `--continue-on-error`.

### HarmonyOS NEXT (macOS host)

Use `hdc` on `PATH` or set `SIM_USE_HDC` to its executable; no on-device
helper or app install is needed. Always pass `--device <serial>` or set
`SIM_USE_DEVICE`. Harmony daemons are excluded from automatic device
selection. `sim-use harmony <verb>` forces Harmony; top-level commands
recognize connected hdc serials before adb-shaped identifiers.
A failed or timed-out hdc membership probe emits one stderr warning and keeps
Android identifier-shape routing; its deadline is 3 seconds, and the failed
probe is not repeated in that invocation. Missing hdc leaves Android routing
unchanged. A target absent from `hdc list targets` cannot be identified as
Harmony: if a top-level command reports an adb device-not-found error, its
Harmony connection/namespace advice comes before the original adb/daemon hint.
Check the connection or use `sim-use harmony <verb>` when the platform is known.

Phase 1 supports `devices`, `ui` / `describe-ui`, `tap` (coordinates, `@N`,
selectors), `long-press`, `swipe`, `scroll`, `type`, `button` (`home`, `back`,
`power`), `screenshot`, `app-state`, and `keyboard-state`. Inspect
`sim-use harmony <verb> --help` for supported options. Use `scroll` or
`swipe`, not gesture presets. No `paste`, multi-touch, video or Linux
Harmony support; do not infer emulator, foldable or landscape compatibility.
`harmony devices` lists connected targets only; do not pass `--online`.
Both scroll entrypoints default to down and accept `--duration` in seconds
(default `0.4`), like swipe. Example:
`sim-use scroll --direction down --duration 0.4 --device <serial>`.
Harmony rejects `swipe --delta`; omit it rather than assuming it changes
the gesture.

Default `ui` hides non-keyboard targets whose tap centers are covered by a
painted input-method panel. Known transparent wrappers are skipped; image
backgrounds and painted popups cover their own frames. Missing paint metadata
is not proof of transparency, and a subtree with no painted panel keeps its
conservative bounded-panel fallback. Keyboard controls and partially covered
targets with usable centers remain; list aliases count only retained cells.
Without valid panel bounds, do not assume the outline detects keyboard occlusion.
`ui --include-offscreen` keeps covered elements for diagnostics, not safe input.
Cached `@N`/`#N` input (also long-press and `type --target`) reads one current
layout **only to check keyboard occlusion and screen bounds**. It does not
prove the target is still in its original place. Covered App targets, unusable
cached sizes and dump failures stop without input; matching current keyboard
controls still work. Validation keeps the old coordinates and alias numbering.
This is not general stale-alias or visibility validation: an old keyboard alias
after dismissal, a changed page, or a `visible=false` diagnostic alias can still
send input at an uncovered on-screen cached point. **Always refresh default `ui`
after page changes**, and refresh after keyboard changes. The screen can still
change between validation and input.
If a selector or alias resolves outside the screen, including negative centers,
scroll then refresh `ui`; partially visible elements can have offscreen centers.
Zero-size entries remain in `--include-offscreen` diagnostics, not usable input.
Explicit `--x/--y` and `--point` bypass these checks; do not use them to evade a refusal.
On a selector miss, refresh `describe-ui` and check the selector; reserve hdc
connection troubleshooting for transport errors.

`type '你好' --device <serial>` works with CJK in the focused field.
**It replaces the device pasteboard and cannot restore it**; successful
input reports an advisory. Targeted input uses `uitest inputText`.
Verify the field after typing, and do not type secrets as test data.

`keyboard-state` returns `soft` or `hidden` (JSON `visible`) on a valid
WindowManagerService probe. A missing/malformed `SCBKeyboardPanel` row or
transport failure is an error, never evidence that the keyboard is hidden.

System-dialog warnings require inspection before input. Never select a
USB-connection-mode option during automation: it can disconnect hdc.
Use `button back` to dismiss only when authorized. Stop at a lock screen;
do not enter the password. Re-read `ui` after navigation before using `@N`.


### Physical iOS devices (experimental)

The top-level verbs route a physical UDID automatically, but only three of them: `ui`, `tap` (`#<id>` / `--id` / `--label` / `--label-contains` / `--element-type` forms) and `screenshot`. **Never assume capability parity with the simulator** — every other verb or form (coordinates, `@N`/`#N` aliases, swipe/gesture/multi-touch, type/paste, recording, `--value`/`--label-regex`/`--frame`/`--duration`/`--wait-timeout`) rejects with the reason and the nearest alternative in the `hint`; read it instead of retrying. The `sim-use ios-device` namespace is the physical-only peer of `ios`/`android` (same verbs, plus ECID addressing and tree-tuning flags).

**Hard requirement for `ui` / `tap`:** the device must be paired, trusted, unlocked and in Developer Mode, and the foreground target app must be development-signed with `get-task-allow=true`. A Release-configuration binary installed with a Development profile is supported. Distribution/Ad Hoc, TestFlight, App Store and system apps are unsupported; do not retry them or claim success. sim-use itself installs and signs no runner and needs no Developer Disk Image. `screenshot` is exempt from the signing rule — it runs over CoreDevice and captures any screen, system apps included.

```bash
# Physical-device preflight — physical rows carry kind `physical`
sim-use devices

# Observe → act → verify, same loop and verbs as the simulator
sim-use ui --device <UDID>
sim-use tap --label "Friends" --element-type Button --device <UDID>
sim-use ui --device <UDID>

# For dynamic labels
sim-use tap --label-contains "Reply" --element-type Button --device <UDID>

# By stable identifier (the #id shown in ui) — positional or --id
sim-use tap '#BackButton' --device <UDID>

# Screenshot — any screen, not limited to development-signed apps
sim-use screenshot --output shot.png --device <UDID>
```

Rules for this experimental surface:

1. **Treat hierarchy errors as capability failures.** If the command says the hierarchy is unavailable, confirm the screen is unlocked and inspect the installed app's final `get-task-allow` entitlement. Do not fall back to coordinates or focus walking.
2. **Tap by `#id` or label, not `@N`.** Element handles expire with the DTX connection, so there is no `@N` alias (nor coordinates — no geometry). Use the `#id` shown in the outline (positional `#<id>` or `--id`) — it is stable and the best choice when a label is dynamic — or `--label` / `--label-contains`, with `--element-type` to disambiguate. The navigation-bar back button appears as a normal `Button "<previous screen title>" #BackButton`; go back by tapping `#BackButton` (or the shown label) like any other element — no special "back" verb.
3. **Always verify.** Activate is fire-and-forget. Re-run `sim-use ui` and confirm the expected state before continuing.
4. **Respect the capability rejections.** A `not supported on physical iOS devices` error is a statement about the channel, not a transient failure — follow its hint (usually `ui` + `tap '#<id>' / --label`) instead of retrying or substituting a lookalike form. `--json` works on every verb with the standard `{ok, data}` envelope; physical results carry `"kind":"physical"` and omit geometry fields (`screen`, `x`/`y`).
5. **Budget seconds, not milliseconds.** A full tree takes a few seconds. `sim-use ios-device ui --fast` is quicker but omits nested elements; do not poll in a tight loop.

If `ui` succeeds with zero elements or `tap` prints success for a missing/ambiguous label, treat it as a sim-use bug; the command is expected to fail loudly instead.

## 2. Pitfalls

Quick symptom index — see `references/pitfalls.md` for detailed recipes.

| Symptom | Cause | Fix |
|---|---|---|
| `tap --label` hits wrong element | Label collision (e.g. header and tab bar share text) | Add `--frame minY=0.7r` or `--element-type` to narrow |
| `tap @N` fails after navigation | Alias cache is stale | Re-run `ui` before tapping |
| `App:` line shows wrong app | System layer (alert, share sheet) is on top | Dismiss it first, then re-run `ui` |
| `multipleMatches` error | Several elements share the selector | Use `--frame`, `--element-type`, or a more specific selector |
| Tap lands but nothing happens | Animation in progress, or element not yet interactive | Add `--pre-delay 0.3` or `--wait-timeout 3` |
| iOS: `paste` fails or text is missing | No focused field, a custom edit menu, a paste prompt, or an external clipboard writer | Focus the field, or use `paste --via-menu --target-id <id>`; inspect prompts and verify the actual field. Do not switch to `type` as a Unicode substitute |
| Android: `paste` denied | Background clipboard access blocked | Use `type` instead |
| Outline shows `U+FFFC` in label | iOS icon placeholder character | Match with `--label-regex` excluding the prefix |
| `[i] … covers ~N% of the screen` warning (text output, or `--json` top-level `advisory` key) | The selector resolved to a near-full-screen wrapper (common on Flutter/canvas UIs) and the tap hit its center, likely missing the intended control | Re-run `ui` and target the control via `@N`/`#<id>`, or pass explicit `-x/-y`/`--point` |
| `[i] Screen orientation could not be confirmed…` / `…coordinates may be stale…` advisory | Device/app is rotated (the `App:` header shows a tag like `(landscape-right)`) and orientation self-calibration couldn't verify the mapping, or the `@N` snapshot predates a rotation | Re-run `ui` and tap again; selectors handle rotation automatically once calibration succeeds. Explicit `-x/-y`/`--point` take outline (visual-space) coordinates and ride the same calibration; `--coordinate-space native` is for device-native portrait points |
| Outline is empty or misses visible app controls, or `[i] … recovered from other processes …` advisory (`--json`: `advisory.kind: remote_content_recovery`) | The app exposed an empty accessibility tree. Normal for a system picker. Otherwise, on an iOS simulator, a likely cause is that app accessibility was off when the app launched | Compare the outline with the screen. If controls are missing, see [Missing app controls](references/pitfalls.md#missing-app-controls-in-the-outline) |
| iOS: `ui` fails with `No translation object returned for simulator <UDID> for the frontmost application` on every screen, while `screenshot` and `ui --point` still work | The simulator's accessibility bridge (`CoreSimulatorBridge`) is stale | Follow the error's hint: run `xcrun simctl spawn <UDID> launchctl stop com.apple.CoreSimulator.bridge` (launchd restarts it at once), then retry `ui`. Right after a boot, wait a few seconds and retry first |
| iOS: the `ui` header ends in `inner display`, `cover display` (older builds: `display LCD-1` for inner), or `display Resizable 560x874` | The app is on the named Duo screen or an Xcode 27 Resize Mode display. An active inner screen does not prove a fully open hinge. `--json` keeps raw names; `data.display` is absent on the main/cover screen. Touch, `ui`, `ui --point`, `screenshot` and `record-video` / `stream-video` (`h264`, `bgra`) route automatically | Work as usual — selectors and `@N` land on that display; the vertical bar of an iOS 27.1 SDK app (back button, tabs) is listed last as `[Trailing …]` / `[Leading …]`. Explicit `-x/-y` take the numbers `ui` prints there; `--coordinate-space native` means that display's native points. See [iPhone Duo](references/pitfalls.md#ios-iphone-duo-multi-display-simulator) and [Resize Mode](references/pitfalls.md#ios-resize-mode-resizable-app-session) |

## 3. Crash awareness

See `references/crash-awareness.md` for the full protocol. Summary:

On iOS simulators and Android, sim-use watches for app processes disappearing between commands. Harmony phase 1 has explicit `app-state` queries only. When automatic detection reports a disappearance:

```
================ PROCESS DISAPPEARED ================
com.example.app (pid 12345) was alive at the previous command and is GONE now.
```

On Android, `ui` also detects the AOSP system crash dialog directly from the accessibility tree.

**Mandatory response:**
1. **STOP.** Do not silently relaunch or continue.
2. Report the crash to the user with the banner text.
3. Wait for instructions before proceeding.

After an intentional relaunch, call `sim-use app-state --reset` to clear the signal.

## 4. Escalation

Stop and ask the user when:
- A selector collision cannot be resolved with available disambiguators.
- Preflight fails and autofix does not recover.
- The task requires a destructive action (deleting data, uninstalling an app).
- You've retried the same action 3 times without progress.

## 5. Exit checklist

Before reporting a task as complete:
1. Run `sim-use ui` (or `screenshot`) to capture the final state.
2. Confirm the screen matches the intended outcome.
3. If the outcome is ambiguous, show the final `ui` output or screenshot to the user.
