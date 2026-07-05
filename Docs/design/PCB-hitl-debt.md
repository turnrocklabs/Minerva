# PCB Migration — HITL Debt Register

Deferred human-in-the-loop checks for DCR `019dc140` (Migrate PCBEditor from
in-tree to plugin), per the back-loaded-HITL autonomy plan (DCR comment,
2026-07-05). Every work-cycle round that would have ended in a 3a/3b human stop
appends its manual test steps here instead; the register is burned in ONE
consolidated acceptance session before the cutover round.

Rules:
- Rounds append; nothing is removed except by a human verdict in the
  acceptance session (or a superseding entry that explicitly replaces it).
- Every entry names the automated proxy that stood in for the human check, so
  the acceptance session focuses on what the proxy could NOT see.
- The cutover round (`019eb47f11e7`) is NOT deferrable and is not on this list.

| # | Deferred check | Automated proxy in place | Source round |
|---|---|---|---|
| 1 | Live sidecar write: open `.pcbskel`, author hint via dock, Ctrl+S → `<file>.annotations.json` appears; close/reopen → hint restores with clean glyph | `_test_panel_save_flow` (panel-hook drive, smoke 43/0); W-14 restore-gate logic | Walking skeleton (W-15 fix) |
| 2 | Route-hint marker lands where the mouse clicked once board/overlay transforms unify | none yet — transforms not unified (W-9); add render_overlay vision check in panel-port round | Walking skeleton (W-9) |
| 3 | Route Hint button appears in dock toolbar after plugin install (no stale-script tab) | headless toolbar population can't be probed; kind.author_ui() non-null asserted in smoke | Walking skeleton (W-13) |
| 4 | Panel port: visual/interaction parity with in-tree PCBEditor (selection, drag, rotate, layer switch, zoom/pan, shortcuts) | harness probes per interaction + render_overlay/vision diffs (to be built in harness round) | Panel port (pending) |
| 5 | Gerber output opens correctly in a real gerber viewer / fab preflight | golden-file diffs vs gerber-writer reference (spike) | Gerber spike (pending) |
| 6 | Real `.minpcb` files (macOS baseline, per spike 019eb47cb448) import through pcb.deserialize without data loss | constructed legacy fixtures incl. unknown-field warn lane (go test 16/16) | YAML contract round (b0353ee) |
