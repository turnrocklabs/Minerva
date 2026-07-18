# Pickup

LATEST **2026-07-18** (PCB routing DCR — **Band A COMPLETE**; hermetic-CAM epic shaped + approved). **HEAD-OF-LINE.**

## ⚠️ UNPUSHED — review + push manually (owner instruction 2026-07-18)

Both repos have local commits that are **NOT pushed**. Review the diffs, then `git push` yourself.

- **minerva-plugins** `main` (local) → `0c3e856`, **1 ahead of origin** (`origin/main` @ `8ac60a6`, which IS pushed = Bug 1).
  - `0c3e856` = T2.3 shadow parity bridge (un-pushed) — the round to review.
  - `8ac60a6` = Bug 1 pad-token fix (already pushed).
  - Push: `cd ~/github/minerva-plugins && git push origin main`
- **Minerva** `development` → local commit with `Docs/pickup.md` + `Docs/minerva.dct` (docket state). Un-pushed.
  - Push: `cd ~/github/Minerva && git push origin development`

Standing policy: Minerva → `development`, minerva-plugins → `main`.

## What was done this session

- **Bug 1 `019f75c24bd2` (RESOLVED, pushed @ 8ac60a6):** load_board THT pads rendered as solid discs — `_pads_from_canonical_pins` emitted pad type `"tht"` but the canvas gates the drill hole on `["thru_hole","np_thru_hole"]`. Fixed the token + added `pcb/tests/gd/test_pad_synthesis.gd` (8/0). **Still needs in-app VISUAL confirm** after an app restart (the running session had pre-fix gd) — left docket at `resolved`, not `verified`.
- **T2.3 `019f70f382b6` (DONE, local @ 0c3e856):** shadow parity bridge — one normalized route record → BOTH annotation + candidate (fixes T2's two independent parses); bidirectional candidate↔annotation correlation persisted in the routing sidecar; bridged accept/reject/add-via route through workspace commands (never mutate both stores); new `pcb_routing_cutover.gd` per-surface authority latch (mechanism only, nothing flipped); commit yields stable canonical trace/via IDs (`via_N`/`trace_N` survive `to_board_dict`). Opus impl → cold Opus review `approve_with_notes` → **Layer-1 376/0** (parity_bridge 84 incl. 3-pad 2-disconnected-path + undo-after-commit fixtures; ingest 54, model 91, persistence 57, check 30, layer_stack 52, pad_synthesis 8).
- **Strategy (docket):** shaped + got Codex to approve the **hermetic-CAM DCR `019f761ead82`** (YAML source-of-truth → fabricated + pre-assembled board + 3D model → enclosure). Scope-update #571 (assembly P1, cutouts, 3D export, per-house DFM matrix JLC/OSHPark/PCBWay, RF primitives) **awaits Codex ratification**.

## NEXT WORK (in order)

1. **Push both repos** (after your review) — see UNPUSHED section.
2. **Routing DCR `019f7095c395`:** Band A done. **NEXT = T3 (S3.1) `019f70eaf0cb`** candidate rendering + identity hit-test — this is the **FIRST VISUAL HITL (Band B), NOT autonomous**. Before diving in: **re-evaluate Band B/C (T3–T7 UI) + T8 teardown against the hermetic-CAM endgame** (DCR `019f761e`) — some routing UI is reworked onto the ResolvedBoard IR in that DCR's consumer-migration stage, so doing full UI polish now risks double-work. GATE `019f70f76c2f` (4 via invariants) still blocks the routing DCR from shipping.
3. **Hermetic-CAM DCR `019f761e`:** once Codex ratifies scope-update #571, the reliability-optimized path (comment #571 §6): routing → verification backbone (KiCad-CLI oracle + Gerbonara + golden geometry-diff) → fabrication-complete FootprintDefinition + lock + ResolvedBoard IR → YAML v2 → bare-board coupon (JLC) → serial consumer migration → CAM + per-house DFM → assembled + 3D coupons → **smart-remote as a real object** → Publish/Bake. Bug 2 `019f75c2848a` (footprint-body geometry) closes via that IR migration, NOT a pin-box patch — leave it.
4. **Bug 1 visual confirm** after next app restart (holes render on a load_board board).

## Environment / deploy / harness (don't relearn)

- **NEVER** `godot --headless --path ~/github/Minerva` — that's the LIVE session. Run pcb gd tests via the scaffold: `cd ~/github/minerva-worktrees/via-scaffold && godot --headless --path src --script res://../../minerva-plugins/pcb/tests/gd/<test>.gd` (host reads the plugin at `~/github/minerva-worktrees/minerva-plugins`). Expect unrelated `SQLite` parse errors from the scaffold host — ignore. Durable: docket hint `pcb-plugin/test.gd_harness_run`.
- Deploy matrix: manifest→REINSTALL; worker.py→plugin restart; Go broker→rebuild+reinstall; panel/core .gd→**APP RESTART** (plugin_reload does NOT reload GDScript); after reinstall `/mcp` reconnect for new tools.
- T2.3 worktree left at `~/github/minerva-worktrees/minerva-plugins` on `wc/t2.3-parity-bridge` (== local main content). `pcb/worker/.venv` is an untracked build artifact — do not commit; should be gitignored.

## Key docket IDs
Routing DCR `019f7095c395` (Band A done, next T3) · via GATE `019f70f76c2f` · hermetic-CAM DCR `019f761ead82` (approved; ratify #571) + items `019f761fcfc3`/`fe518`/`fda74`/`ffa46`/`fefae`/`762004dc` + 3D `019f763ca706` + assembly `019f763cdf5b` + RF `019f7644892a` · YAML source-of-truth WI-1 `019f75a454ff` / WI-2 `019f75a4a4e0` under serialization DCR `019eb47d`. Memory files: `project_pcb_hermetic_cam_dcr.md`, `project_pcb_routing_workspace_dcr.md`, `project_pcb_yaml_source_of_truth.md`.
