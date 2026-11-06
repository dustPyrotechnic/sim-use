<!-- SPDX-License-Identifier: Apache-2.0 -->

# 012.004 — Keyboard occlusion and actionable error hints

> Correction, 2026-11-05: the `c34d6dc9` device retest found that the
> `SkinBgContent` rectangle at y=1570 is transparent, not visible keyboard
> coverage. The original geometry decision and measurements below are kept
> as history, but are superseded by [005-transparent-keyboard-geometry.md](005-transparent-keyboard-geometry.md).
> That retest was performed by Claude, not human acceptance.

## Context and approved scope

The Prowl dispatch reports a confirmed keyboard-occlusion bug on a Mate 60 Pro
with candidate `d4b4a9da`: a Settings result at center (429,1920) remained in the
outline, and tapping it pressed the keyboard R key. This supersedes the earlier
“unconfirmed” status; it is user-supplied device evidence, not a new agent run.
The softKeyboard1 WMS window is full-screen and cannot provide panel geometry.

The user approved three corrections, with failing regression tests before any
implementation: keyboard occlusion, a selector-miss hint, and Harmony advice
before the original adb/daemon advice. No device operation, E2E, paid eval,
commit, push or PR is authorized. Read-only `list targets` reached by unit tests
is the sole real-hdc exception in the dispatch. Keep the 1.5-second membership
limit and the existing `type --target` append behavior unchanged.

## Existing seams and decisions

| Area | Decision | Reason |
| --- | --- | --- |
| Keyboard geometry | Derive visible, positive, screen-clipped panel rectangles from input-method layout subtrees. Descend through full-screen wrappers; do not treat them as keyboard coverage. | The real `third-party.json` has a full-screen input-method root and wrapper, but a visible `SkinBgContent` panel starts at y=1570. WMS supplies no usable panel height. Do not infer a screen-wide band from an isolated key. |
| Keyboard ownership | Inherit the layout bundle identity through descendants, using the existing inputmethod bundle convention. Keep those descendants in the outline. | Keyboard controls must remain selectable; a keyboard must not occlude itself. |
| Shared filtering | Apply the center-point exclusion in `HarmonyOutlineRenderer.render` before creating entries. | The controller publishes the same entries to JSON, text, the alias cache and live selector matching. Display-only hiding leaves unsafe targets addressable. |
| Partial coverage | Keep elements with an unoccluded target center, even when their frame intersects a panel. Continue walking children of an occluded container. | A large List can have a covered center while some cells remain usable. |
| Lists | Count and number only cells retained by the active keyboard/visibility filter; preserve the existing no-keyboard path. | No gaps or covered cells in list aliases. Do not change unrelated filtering without keyboard evidence. |
| Diagnostic output | `filterOffscreen:false` remains unfiltered, including covered entries. Both current CLI entrypoints use `--include-offscreen`; neither provides `--all`, so no new flag is added. | The approved requirement preserves the existing unfiltered mode. Aliases remain snapshot-based: use a fresh default outline before input after the keyboard or screen changes. No new alias drift-detection protocol is added. |
| Missing geometry | With no visible input-method subtree or no usable panel bounds, keep current behavior. | Do not guess keyboard size or filter app elements without evidence. |
| Selector miss | Give the no-match error an explicit describe-ui/selector recovery hint. Keep transport error defaults and other error cases unchanged. | A successfully captured layout with no match is not evidence of disconnection. |
| Disconnect hint | Prepend the existing Harmony advice in the final client decorator; retain the original hint verbatim afterward. | This reaches stale-daemon responses without new probes or wire changes. Missing hdc and explicit Android remain unchanged. |
| Pixel centers | Check both the cached integer center and the selector's rounded center. Do not change either coordinate convention. | Odd-sized frames can differ by one pixel between the existing alias and selector paths; neither actual target may land inside a keyboard panel. |
| Skill floor | Keep the existing 0.17.0 floor and development-build policy. | This updates the same unreleased Harmony feature, not behavior shipped after that floor. |

## Red-first verification contract

- Use `HarmonyOutlineRenderer.render`, `HarmonyTargetResolver.match`,
  `OutlineCache.write` and `OutlineAliasResolver.resolve` with the real
  `third-party.json` and isolated cache directories. Check covered app entries,
  keyboard controls, partial visibility, diagnostic output, list aliases and
  missing/invalid geometry. No private geometry helper is the test seam.
- Exercise an actual failing host process through `Hdc` for the unchanged
  connection hint; never invoke a device transport.
- Update the two existing original-hint-prefix assertions in
  `disconnectedHintGates` and `daemonStaleHint`: the approved priority change
  requires original-hint suffix preservation instead. Excluded paths retain
  exact equality. This changes the ordering contract, not its preservation
  guarantee; do not weaken or remove the other assertions.
- Run the three areas together and retain the actual failing test names and
  assertions before implementation. The requested combined red gate is used
  because all three public seams and approved outcomes are already known.
- Then make the smallest implementation changes and turn the same tests green.
  Run `make build`, three complete `make test` rounds (at least two without
  `SIM_USE_HDC`), and at least 40 default-parallel filtered rounds including
  TapForwarder, PlatformRouterPhysical and all Harmony suites.
- Run offline fake-transport CLI smoke for default/diagnostic UI, alias and
  selector targeting, transport failure and daemon hint order. Record each
  round, red output, final SHA and verification limits in `001-action.md`.

## Limits

The new candidate still needs real-device verification. The prior cold-script
first-execution delay and its unknown OS mechanism are separate from this fix.
State remains waiting for manual acceptance.

## Red gate evidence

Before production edits, the focused run exited 1: 6 of 8 tests failed with
18 assertion issues. It reproduced covered fixture entries, selector and
cached-alias reachability, wrong list counts/indices, selector-miss advice and
both direct/daemon advice ordering. Missing-geometry and transport-error
controls passed. The CLI remained `d4b4a9da`; exact output is in
`.build/harmony-keyboard-review-vrzc2rvs/red.log` and `001-action.md`.

The same fixture also exposes scene-board `keyboardLeftButton` and
`keyboardRightButton` controls beneath its `keyboardPanel18` WindowScene.
Keep that known keyboard-panel subtree exempt from occlusion as well, but
continue deriving coverage only from input-method panel geometry. Two
preservation assertions cover these existing controls.

## Focused green gate

The same focused command passed all 8 tests after implementation (52.436
seconds including compilation). The six red tests were not weakened.
`green.log` also includes the two added scene-board control preservation checks.

## Verification outcome

- `make build` passed. Three full `make test` runs passed; runs 2 and 3 left
  `SIM_USE_HDC` unset. No E2E flags or paid evals were enabled.
- Forty consecutive `swift test --skip-build --filter
  'TapForwarder|PlatformRouterPhysical|Harmony'` rounds passed with default
  test concurrency and `SIM_USE_HDC` unset: 90 tests/9 suites plus 7 tests/1
  suite each round. No deadline changes, suite serialization or assertion
  relaxation was used.
- Actual CLI smoke used fake transports and the captured keyboard layout.
  Covered selectors and the former unfiltered alias emitted no input;
  usable partial and keyboard aliases emitted the expected distinct points.
  Real stale-daemon responses put Harmony advice before the preserved
  original hint; explicit Android and absent-hdc controls remained unchanged.
  Ten JSON responses and both help surfaces passed. The initial smoke
  assertion's wrong nested-error assumption is recorded separately; only
  the assertion was corrected against the already saved flat JSON response.
- Final candidate SHA-256:
  `c34d6dc9912170430e06af37a77ba76c2ae980bc5b25c787706da9ccf5eb005b`.
  The coverage-enabled first full test relinked the preceding plain-build
  candidate; subsequent full runs, pressure rounds and CLI smoke kept this
  fingerprint.
- Every round, the exact red output, SHA transitions, existing build warning,
  smoke observations and cleanup are recorded in [001-action.md](001-action.md).
  Raw evidence is under `.build/harmony-keyboard-review-vrzc2rvs/`.

Status remains **等待人工验收**. No phone was operated; the new candidate has
no manual or live-device acceptance evidence. No commit, push or PR was made.
The 1.5-second deadline, native type append behavior and the unknown cold-script
OS mechanism remain unchanged. Keyboard geometry and cached-snapshot limits
above are deliberate boundaries, not claims of live input drift detection.

Final evidence aggregation also rejected a dictionary-size assumption:
unfiltered output has 320 entries but 298 distinct uniqueId values. The report
now uses the saved array count; raw CLI output and production code were not
changed, and the command was not rerun. Default output has 54 entries.
