# 012.002 — Gate G1: keyboard-state probe

## Context

[000-plan.md](000-plan.md) makes `keyboard-state` for Harmony conditional on
gate G1: a probe that separates a shown soft keyboard from a hidden one, in the
system UI and in one third-party app. The spike had shown that no layout node
has `focused == "true"` while the keyboard is open.

Number `001` is kept free for the action log.

## Environment

macOS host, `hdc` 3.2.0f, ALN-AL00 over USB, HarmonyOS 6.1.0.135, API 24,
`uitest` 6.0.2.3, system input method `com.huawei.hmos.inputmethod`.
Date 2026-11-04. Device unlocked. A first attempt ran while the device was
locked (`SCBScreenLock13` visible); those samples were discarded.

## Procedure

For each state, three captures:

```bash
hdc -t <sn> shell "hidumper -s WindowManagerService -a '-a'"        # candidate A
hdc -t <sn> shell uitest dumpLayout -i -p /data/local/tmp/g1.json   # candidate B
hdc -t <sn> shell uitest screenCap -p /data/local/tmp/g1.png        # ground truth
```

| Scene | Hidden | Shown | Hidden again |
| --- | --- | --- | --- |
| System UI | Home screen | Global search (swipe down on home) | `keyEvent Back`: search page stays open, keyboard closes |
| Third-party (`com.baidu.baiduapp`) | App home | Tap the search box | `keyEvent Back`: search page stays open, keyboard closes |

The "hidden again" rows are the important ones: an input page is still in
front, but the keyboard is closed. Screenshots confirmed the state of each
row. No text was typed.

## Results

Candidate A: `ZOrd` column of the window rows in the WindowManagerService
dump. `-1` means the window exists but is not shown.

| Sample | `SCBKeyboardPanel` | `softKeyboard1` | Screenshot |
| --- | --- | --- | --- |
| System, hidden | -1 | -1 | no keyboard |
| System, shown | 97 | 98 | keyboard |
| System, after Back | -1 | -1 | search page, no keyboard |
| Baidu, hidden | -1 | -1 | no keyboard |
| Baidu, shown | 103 | 104 | keyboard |
| Baidu, after Back | -1 | -1 | search page, no keyboard |

Candidate B: window roots in `dumpLayout -i` output (a JSON array).

| Sample | Window roots (`bundleName`) |
| --- | --- |
| System, hidden / after Back | `com.ohos.sceneboard` ×2 |
| System, shown | adds `com.huawei.hmos.inputmethod` (46 nodes) |
| Baidu, hidden / after Back | `com.baidu.baiduapp`, `com.ohos.sceneboard` |
| Baidu, shown | adds `com.huawei.hmos.inputmethod` |

Cost of candidate A: 0.12 s, 0.11 s, 0.10 s (three runs, `time -p`).
Candidate B costs a full dump plus fetch (~1.2 s in the spike).

## Decision

G1 passes. `keyboard-state` stays in phase 1.

- Probe: candidate A. Read the WindowManagerService dump; the keyboard is
  shown when `SCBKeyboardPanel` has `ZOrd >= 0`. `SCBKeyboardPanel` belongs
  to the system scene board, so it does not depend on the input method's own
  window name (`softKeyboard1`).
- Probe failure (non-zero exit, no `soft` / `hidden`): `hdc` error or
  timeout, no window table in the output, no `SCBKeyboardPanel` row, or a
  `ZOrd` value that is not an integer.
- Candidate B stays available as a cross-check for tests; it is ten times
  slower and is not used for the verb.

## Open questions

- Third-party input methods: only the system input method was tested.
- Landscape, split screen and floating keyboard modes were not tested.
- The dump format is not a documented API; a system update can change it.
  The parser must fail closed (probe failure), never report `hidden`.
