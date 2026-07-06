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
| 2 | Route-hint markers sit on their board-mm anchors while panning/zooming in the live panel (W-9 fix verification); describe_point labels ("pad:U1.3") match what's under the cursor | transform math byte-exact vs world_to_screen + round-trip tests at zoom/pan (semantics suite 33/0); rotation-correct pin positions reviewer-verified | Annotation host round (8e25f68) |
| 3 | Route Hint button appears in dock toolbar after plugin install (no stale-script tab) | headless toolbar population can't be probed; kind.author_ui() non-null asserted in smoke | Walking skeleton (W-13) |
| 4 | Panel port: visual/interaction parity with in-tree PCBEditor (selection, drag, rotate, layer switch, zoom/pan, shortcuts) | harness probes per interaction + render_overlay/vision diffs (to be built in harness round) | Panel port (pending) |
| 5 | Open the PRODUCTION goldens `minerva-plugins/pcb/worker/tests/testdata/gerber_golden/*` (both boards: 6 layers + PTH/NPTH each) in gerbv or KiCad GerbView: zero warnings, visual match, drill-to-copper alignment. REQUIRED before any real fabrication. (Spike goldens at spikes/gerber/golden/ remain as the historical reference.) | structural validator + pygerber round-trip in pytest (test_gerbers.py), byte-reproducible across processes, golden byte-compare | Gerber export round (74f1d1c) |
| 6 | Real `.minpcb` files (macOS baseline, per spike 019eb47cb448) import through pcb.deserialize without data loss | constructed legacy fixtures incl. unknown-field warn lane (go test 16/16) | YAML contract round (b0353ee) |
| 8 | Annotation workflow interactive pass: open a legacy .minpcb copy with inline annotations → migration status shows count, dock lists them, markers track zoom/pan; author a route hint via waypoint-click (click points, double-click commits, Escape cancels); repair flow: move/delete an anchored component → annotation degrades to snapshot + flags stale; reject action moves hint to resolved | migration suite 53/0, semantics 77/0 (resolvers/repair/authoring driven programmatically), conformance 21/0 | Annotation rounds (c2c22f3) |
| 7 | Panel UI interactive pass (ported editor, minerva-plugins c33217b): (a) click / shift-click / box-select; (b) component drag with grid snap on+off; (c) rotate via R key + Rotate tool; (d) trace select + Delete; (e) layer filter All/top/bottom shows correct copper; (f) zoom wheel/±/toolbar −·Fit·+ and right/middle-drag pan; (g) grid toggle (G + checkbox) and snap-during-drag; (h) Ratsnest/Labels/Traces toggles; (i) lock/unlock (L / Shift+L / context menu) + hatch overlay; (j) toolbar tool-mode pressed-state sync; (k) Export YAML → status feedback incl. payload_too_large path; (l) Escape clears selection; annotation dock still mounts | headless: load/save matrix, dirty-glyph spy, host registry symmetry (UI 22/0); reviewer fidelity diff legacy-minus-stripped | Panel port Round B (c33217b) |
