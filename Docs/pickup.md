# Pickup — CAD plugin substrate adoption

Last updated: 2026-05-02 (after CAD Phase A HITL roll-forward — A1/A2/A3 done)

## Where I left off

**Annotation v2 substrate is fully shipped** through T8 (plugin adoption design doc, commit `b05a28fb` on Minerva). Dock DCR `019de430afa7` substrate features (T1-T8) all done. Plugin adoption guide at `Docs/design/Annotation-substrate-plugin-adoption.md`.

**CAD plugin Phase A (substrate consumer adoption) is fully done.** A1/A2/A3 transitioned to `done` in docket. WIPs on `~/github/plugins/cad/` (branch `main`):

```
b483293  WIP: CAD Phase A HITL roll-forward — overlay restoration + layout fixes
cda0822  WIP: CAD Phase A R2b — delete custom toolbar + selection mirror
3c3afa9  WIP: CAD Phase A R2a — extract silhouette, delete edge_overlay.gd
26ec57a  WIP: CAD Phase A R1 — substrate adoption (A1 + A3)
```

Plus on Minerva (branch `user/imran/experiments/swarm`):
```
7a840861  WIP: substrate KEY_BACKSPACE fallback for Mac Delete
```

HITL caught and fixed in this session:
- Mac main-keyboard "Delete" key (KEY_BACKSPACE) didn't delete annotations — substrate fallback added.
- T_Beam.mcad opening crashed on `Invalid cast: could not convert value to 'Dictionary'` because the worker emits `error` as either Dict or bare String.
- Stale `cad-plugin` Go binary on the laptop (Apr 26 vs source Apr 29) caused `method not found: cad.evaluate`. Memory `project_cad_plugin_binary.md` saved.
- R2a's "verbatim move" silently dropped four functional pieces from `edge_overlay.gd`: ortho background fill, selected-edge highlight, click-to-pick, multi-edge chooser. All restored in `Cad_GeometryOverlay.gd` (now ~480 lines).
- Cad_GeometryOverlay didn't redraw on camera transform changes (silhouette froze on pan/zoom). Added `_process` transform tracking.
- Selection marker drifted from silhouette when AnnotationDockPane opened/closed (cache stale on Control resize). Added `size` tracking alongside transform.
- Iso pane drew silhouette on top of shaded mesh. Now skipped in perspective panes via `Camera3D.projection` check.
- Two orphan "Annotations" Label nodes in CADPanel.tscn (R2b leftovers) duplicated the substrate dock header.
- WideLayout content min was 1020px (2×400 viewports + 220 sidebar); collided with the substrate dock at editor widths 1024–1280. Viewport mins shrunk to 300×225 → WideLayout now fits any panel ≥ 820px.

End-to-end MCP verification: drew an arrow + "Fillet this edge" text annotation on edge 5 of T_Beam.mcad. `minerva_cad_get_selected_edge` returned full edge dict; `minerva_annotations_list` returned both annotations with payloads. Substrate is talking to MCP correctly — link from arrow→edge is *positional* (canvas.point coords); making it semantic is Phase B B2.

Substrate test suite: 39 PASS / 0 FAIL throughout.

## What to do next

### Start Phase B — CAD edge anchors (the original problem)

Backlog filed under plan `019dc0552d6a` (project=minerva):

| ID | Title | Notes |
|---|---|---|
| `019de9b807e67c01` | B1: define cad/edge anchor type schema + register resolver | Spine. Independent of Phase A. |
| `019de9b82b977e11` | B2: migrate cad_edge_number_kind + tool to consume cad/edge anchor | follow_up of B1. |
| `019de9b859d97f51` | B3: worker edge-ID stability across re-evaluation | **has open A/B/C design question — discuss before implementer round** |
| `019de9b874dc704e` | B4: MCPCadTools._cad_annotate_edges — emit cad/edge anchors | follow_up of B2. In-tree work in Minerva. |

Recommended cycle: B1 + B2 as one work-cycle (Sonnet implementer + Opus cold reviewer + Layer-1 + HITL), then a design discussion on B3 before its implementer round, then B4.

### A4 (sidebar question) — answered, archived

User chose Option C: keep custom edge tree as geometry inspector; substrate sidebar handles annotation listing. Drop `_selected_edge_id` mirror. R2b implemented this. See `019de9b7d73a70cf` for the answer.

## Plan map

Project: `minerva` (always pass `project="minerva"` to docket tools).

- DCR: `019dc054a453` — CAD plugin: port MCAD experiment as first platform consumer
- Plan: `019dc0552d6a` — Plan: CAD Plugin (v1 through exports)

### Phase A (done)

| Status | ID | Title |
|---|---|---|
| ✅ | `019de9b755b07366` | A1: replace Cad_AnnotationCanvas with platform AnnotationOverlay; mount AnnotationDockPane via get_annotation_host() |
| ✅ | `019de9b78eda7a6b` | A2: delete edge_overlay.gd (5 instances) — route edge picking through substrate |
| ✅ | `019de9b7ae707aa0` | A3: Cad_AnnotationHost.get_capabilities() — advertise registered kinds |
| ✅ | `019de9b7d73a70cf` | A4 (question): edge browser sidebar — answered, option C |

### Phase B (backlog)

| ID | Title |
|---|---|
| `019de9b807e67c01` | B1: define cad/edge anchor type schema + register resolver |
| `019de9b82b977e11` | B2: migrate cad_edge_number_kind + tool to consume cad/edge anchor |
| `019de9b859d97f51` | B3: worker edge-ID stability across re-evaluation |
| `019de9b874dc704e` | B4: MCPCadTools._cad_annotate_edges — emit cad/edge anchors |

### Other open CAD work (not blocking)

- `019dc1259c977380` — CAD panel: surface progress notifications from worker.
- `019dd020c20f76aa` — CAD adopt: route worker/validation errors through plugin toast API.
- `019dc0597b6071f8` — MCP tool: mcad_render with composable show flags.
- `019dc05988787a22` — MCP tool: mcad_export.
- `019dc0bb5f2e7655` — `.mcad.meta.json` sidecar fields.
- `019dc0bb76d87a1e` — MCP tool: mcad_deviation.
- `019dd017d9df` — CAD-specific AnnotationKind extensions (measurement, surface points). Probably waits until Phase B done.
- `019dd021189373a5` — CAD: optional DSL bottom split.
- `019dcc928a35` — Translator-stage validation feedback to mcad_validate.

## State of the trees at handoff

### Minerva (`user/imran/experiments/swarm`)

- HEAD: `7a840861` (substrate KEY_BACKSPACE fallback for Mac Delete).
- Last commits: `7a840861`, `f3433675`, `b05a28fb`, `7c226c4a`, `a50cbb63`.
- Working tree: this pickup.md update pending commit. Submodule pointers in `vendor/godot_cef`, `vendor/godot_wry` show drift but are pre-existing local build patches per CLAUDE.md.

### cad plugin (`~/github/plugins/cad/`, branch `main`)

- HEAD: `b483293` (Phase A HITL roll-forward).
- Working tree clean.
- Not yet pushed.

## Constraints to carry forward

- Always pass `project="minerva"` to docket MCP tools when working with substrate IDs.
- Off-tree plugin scripts must use `preload()`, not `class_name` for cross-script types (memory: `project_off_tree_plugin_class_names.md`).
- Plugin annotation code never crosses into another plugin's data — only via MCP, per the substrate's trust boundary.
- 2D ortho panes in CAD are intentionally edge-only x-ray, NOT 3D renders.
- When adding/removing plugin scripts, update BOTH `~/github/plugins/<id>/manifest.json` AND `~/.local/share/godot/app_userdata/Minerva/plugins/plugins.json` (cached). Skipping the cached one means Godot still loads the deleted script. (Nudge `minerva-plugin-platform/manifest_script_whitelist`.)
- `queue_redraw()` does NOT trigger `_draw()` in headless tests — call `overlay._draw()` directly to assert draw-call behavior.
- Docket state machine doesn't allow skipping states. work_item: backlog → open → in_progress → done. bug: new → triaged → active → resolved. Resolution string only on terminal hop.
- AnnotationHost capability shape is **frozen** for canvas-sync compatibility — extend, don't rename.
- `host.get_panes()` is real on `Cad_AnnotationHost` and returns panel-relative viewport rects. Don't reinvent.

## Cold pickup checklist

1. `git pull` on `~/github/Minerva` (branch `user/imran/experiments/swarm`) and `~/github/plugins/cad` (branch `main`).
2. Read `Docs/pickup.md` (this file).
3. In Minerva: `git status` — expect submodule drift only. `git log --oneline -5` — head should be `7a840861`.
4. In cad plugin: `git status --short` — clean. `git log --oneline -4` — head should be `b483293`.
5. **Rebuild the cad-plugin Go binary on this machine** if its mtime is older than `*.go` source — see `~/.claude/projects/-Users-ipeerbhai-github-Minerva/memory/project_cad_plugin_binary.md`. Symptom of skipping: opening any `.mcad` file shows `cad.evaluate worker error [unknown]: method not found: cad.evaluate`.
   ```
   cd ~/github/plugins/cad && go build -o cad-plugin .
   ```
6. Run the substrate regression suite from Minerva root:
   ```
   for t in test/annotations_v2/test_workbench_selection_sync.gd \
            test/annotations_v2/test_kind_extension_api.gd \
            test/annotations_v2/test_annotation_overlay_draw.gd; do
     godot --headless --path src --script "$t"
   done
   ```
   Expect 39 PASS / 0 FAIL. (Note: Mac doesn't ship `timeout`; just run godot directly.)
7. `/work-cycle 019de9b807e67c01` (B1) when ready to start Phase B. Discuss B3's A/B/C design question (`019de9b859d97f51`) before its implementer round.

## Process notes from this session

- **Two-sub-round split with no HITL between** worked well for the bigger Round 2 (delete edge_overlay + delete custom toolbar). Each sub-round had its own Sonnet implementer + Opus cold reviewer + Layer-1 gate. Single HITL at the end. Minimized HITL gates without sacrificing review safety.
- **Cold reviewer with file allowlist + OUT-of-scope list + method-level kill list** caught the verbatim-move *comment* drop in R2a (cosmetic, fixed in main context) but missed the *functional* drops (background fill, selected-edge highlight, click-to-pick, multi-edge chooser). The reviewer's allowlist treated the new file as a verbatim move, but the move dropped ~70% of the original by line count. **Process upgrade**: when a reviewer is told "verbatim move," it should also assert that the per-method line count delta is within ±5% — anything bigger is no longer a move, it's a refactor and needs a different review lens.
- **R1's intermediate state was not user-functional** (custom toolbar dead, platform UI layout-collapsed). The "skip-ahead" decision to bundle R2a+R2b sequentially was the right call once HITL surfaced this. Lesson: if the first round of a multi-round cleanup leaves a non-functional intermediate, don't pause for HITL — chain to the next round and HITL the end state.
- **HITL roll-forward as a separate WIP commit** (cad@b483293) preserved the R1/R2a/R2b commits as historical evidence rather than amending them. Easier to review what actually got dropped vs added.
