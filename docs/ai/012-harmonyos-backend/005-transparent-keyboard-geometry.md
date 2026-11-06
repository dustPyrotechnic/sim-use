<!-- SPDX-License-Identifier: Apache-2.0 -->

# 012.005 — Transparent keyboard geometry

> 2026-11-06: The per-round results and the `.build/` evidence paths named below
> were local and are not in this repository. [001-action.md](001-action.md) now
> holds the condensed results. Status lines below show the state at that time.

> 2026-11-05: The later approved [006](006-live-target-safety.md) adds live
> cached-alias checks, actual input-point screen bounds and a 3-second membership
> limit. Those earlier exclusions below no longer describe the current candidate.
> Geometry findings and original measurements remain unchanged.

## Context and approval

The task request reports a scripted Mate 60 Pro retest of candidate
`c34d6dc9`. It is not human acceptance. Deeply covered Settings results are now blocked,
keyboard controls work, and results return when the input method disappears.
But visible results with centers near y=1647 and y=1683 were wrongly hidden.
The user approved this correction and requires red tests before implementation.
No phone operation, E2E, paid eval, commit, push or PR is authorized.

The prior 004 claim that `SkinBgContent` provides a visible keyboard panel at
y=1570 is incorrect. In `Tests/Fixtures/harmony/third-party.json`, it and the
upper `SkinBgContentStack` have `backgroundColor=#00000000` and
`backgroundImage=empty source`. The first painted main panel is `index_content`
at y=1700. These coordinates identify the evidence, not implementation constants.
The old record and its original measurements remain available with correction
notes. This amendment supersedes only the geometry decision.

## Decisions before code

| Area | Decision | Reason |
| --- | --- | --- |
| Proven transparency | Descend through a node only when its background color is a valid eight-digit ARGB value with zero alpha and its background image is explicitly `empty source`. | Missing or unrecognized attributes do not prove transparency. Existing synthetic nodes without paint metadata keep their behavior. |
| Painted coverage | Retain bounded frames with nonzero alpha, a non-empty-source background image, or unknown paint metadata. Continue through transparent wrappers. | Skinned keyboards and small spell popups can obscure content independently of the main panel. No node ID, device dimension or keyboard height is hardcoded. |
| Conservative fallback | If one input-method subtree yields no usable painted frame, run the existing first-bounded-panel rule for that subtree. Do not fall back separately for each transparent branch. | Per-branch fallback would still cover the known transparent strip. A different painted input-method subtree must not disable another subtree's fallback. |
| Geometry and ownership | Keep visibility, clipping, full-screen-wrapper exclusion, keyboard ownership and the shared center filter unchanged. | No new offscreen-center policy, alias drift probe or diagnostic-alias restriction is authorized. |
| Existing assertions | Preserve the existing four keyboard-occlusion tests. Add real fixture assertions for the transparent strip and its retained ninth List cell. | Existing assertions target centers below 1700 or above the strip; none explicitly requires hiding these newly reported visible targets. The old `partial` synthetic cell remains a valid visible-child control, although it is no longer evidence of overlap with the corrected main panel. |
| Pixel-center mutation gap | Add odd-width and odd-height edge cases at both ends of a bounded panel. Reject a target if either existing pixel-center convention falls inside. | Truncation and rounding differ by one pixel. Removing either coverage term must fail tests independently. |

## Public test seams

Use `HarmonyOutlineRenderer.render`, `HarmonyTargetResolver.match`,
`OutlineCache.write` and `OutlineAliasResolver.resolve`, as explicitly requested.
The real fixture supplies IDs 2325, 2821, 2823 and 2832 with centers in the
transparent strip. IDs 2837 and 2851 remain covered. Check selector reachability,
cached coordinates, retained List counts and index order; keep keyboard controls.
Synthetic fixtures cover all-transparent fallback, an independent painted
input-method window, a colored popup, image paint and missing paint attributes.

Odd-size cases use a 300x300 synthetic screen and a panel from (100,100) to
(200,200). A center at 99.5 is outside for the cached integer target but inside
for the rounded selector; a center at 199.5 is inside only for the cached
integer target. Test both axes through the public seams, not private helpers.

## Verification sequence

1. Add tests only. Run `swift test --enable-code-coverage --filter
   HarmonyKeyboardOcclusion`, save and publish exact failures before code edits.
2. Make the minimal geometry correction and run the same suite green.
3. Temporarily remove each center-coverage term separately, run the odd-size
   tests, and retain both red outputs. Restore the full predicate before any
   candidate build. No mutation is retained in the deliverable.
4. Run `make build`, three full `make test` rounds (at least two without
   `SIM_USE_HDC`), and forty default-parallel rounds with
   `TapForwarder|PlatformRouterPhysical|Harmony`.
5. Exercise the built CLI with the captured layout and fake transport. Record
   actual counts from arrays, not unique-ID lookup dictionaries. Preserve raw
   output, each run result, candidate SHA and the existing unrelated warnings.

## Limits and status

Status remains **waiting for manual acceptance**. A new candidate needs another real-device
check. Do not change the 1.5-second membership limit or native type append
behavior. Out-of-screen centers, aliases cached before keyboard appearance and
aliases from `--include-offscreen` are outside this correction. The prior
cold-script OS mechanism remains unknown.

## Red gate

Before production edits, the focused command exited 1 in 14.938 seconds.
Three of nine tests failed: nine failing cases with thirteen issues. All four
real strip targets were absent; the ninth cell could not match; painted-island
cases also hid the neighboring target. Fallback and odd-center controls passed.
The binary remained `c34d6dc9`. Exact output and source hashes are in
`.build/harmony-transparency-_eg69gjo/red.log` and `red.json`, with excerpts in
`001-action.md`. No existing assertion was changed.

## Green and mutation evidence

The unchanged focused suite passed all nine tests in 16.133 seconds including
compilation. Existing assertion changes: none.

Both requested mutations then compiled and failed `oddPixelCenters`:
- Removing cached-center coverage failed the right/bottom cases at 199.5
  (16.112 seconds, two failing cases, six issues).
- Removing selector-center coverage failed the left/top cases at 99.5
  (9.991 seconds, two failing cases, six issues).

Each mutation exposed the target through outline, selector and cached alias.
The complete predicate was restored and all nine tests passed again (9.811
seconds). Its renderer SHA matches the pre-mutation green source exactly:
`0ad4f079acd884a0570f31ef7171b558ba3bbb908b8f7d29ccbe24519e8293f8`.
See the raw mutation logs and `mutation-restoration.json` in the evidence folder.

`make build` and three full `make test` runs then passed. Full runs 2 and 3
left `SIM_USE_HDC` unset. User and agent guidance, both help surfaces and the
bundled Skill copy are synchronized; the Skill copies compare equal.

## Delivery evidence

Forty default-parallel pressure rounds passed, each with 95 tests/9 suites and
7 tests/1 suite. All rounds left `SIM_USE_HDC` unset. Source hashes stayed fixed.
The complete round table and warnings are in `001-action.md`.

Actual CLI replay now has 58 default entries and 320 unfiltered entries.
The four real strip targets are retained, the ninth List cell and its alias
resolve, deeper covered targets emit no input, and keyboard controls still work.
Twelve valid CLI checks passed, including ten parseable JSON responses and both
help surfaces. One invalid harness command combined mutually exclusive `--id`
and `--label`; its exit 64 and empty stdout are preserved. The separate label-only
check uses a task-local copy with only target 2832's text/description made unique.
No product behavior was changed to accommodate the invalid command.

Final binary SHA-256:
`a602cd6f4d8d44c540fde6506eeae586b2b7080ec2224ccffd7d493bd64ce3d2`.
Three full runs, forty pressure rounds and all CLI calls used this coverage-build
candidate after the ordinary build's relink. The Hdc and native type source
hashes match the red gate. No existing assertion was changed.

Status remains **waiting for manual acceptance**. The new candidate has no human or live-device
acceptance evidence. Real skinned keyboards and spell popups still need device
checks; only the approved fixture and synthetic cases were exercised here.
