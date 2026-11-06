<!-- SPDX-License-Identifier: Apache-2.0 -->
# HarmonyOS fixtures

Captured with `hdc shell uitest dumpLayout [-i] -p <remote>` and
`hdc shell "hidumper -s WindowManagerService -a '-a'"` on an ALN-AL00,
HarmonyOS 6.1.0.135 / API 24 / uitest 6.0.2.3, 2026-11-04.
See `docs/ai/012-harmonyos-backend/002-g1-keyboard-probe.md`.

- `home.json`: system home, keyboard hidden; 214 original nodes.
- `third-party.json`: Baidu search, keyboard shown; 930 original nodes.
- `system-dialog.json`: merged layout from the initial spike, with the
  USB-mode dialog under a scene-board window; 124 original nodes.
- `system-*.wms` and `app-*.wms`: hidden, shown, and hidden again after Back.
- `processes.txt`: selected unchanged `ps -A -o PID,NAME` rows, with a
  fixture license/provenance header; includes system and third-party main
  processes plus service/renderer children. System bundle prefixes must not
  exclude a running main process.
- `system-search-input.json`: six-node Search subtree captured during
  implementation smoke on 2026-11-05. Its native `SearchField` child carries
  the typed test text and must remain selectable as `TextField`.
- `processes-whitespace.txt`: synthetic parser boundary cases, not a new
  device capture. Covers column padding, tabs, names with spaces, and
  unrelated native processes without changing the main-process policy.

JSON tree shape, geometry, identifiers and state attributes are retained.
Non-generic text, originalText, descriptions and hints are replaced with
`示例文本`; resource background image paths are removed. These are sanitized
real dumps, not synthetic layouts. The WMS captures are unchanged.
All fixture files in this directory are licensed Apache-2.0.
