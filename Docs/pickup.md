# Pickup — CAD plugin substrate adoption

Last updated: 2026-05-02 (after CAD Phase A R1+R2a+R2b — HITL pending)

## Where I left off

**Annotation v2 substrate is fully shipped** through T8 (plugin adoption design doc, commit `b05a28fb` on Minerva). Dock DCR `019de430afa7` substrate features (T1-T8) all done. Plugin adoption guide at `Docs/design/Annotation-substrate-plugin-adoption.md`.

**CAD plugin Phase A (substrate consumer adoption) is committed but HITL-pending.** Three WIPs in `~/github/plugins/cad/`:

```
cda0822  WIP: CAD Phase A R2b — delete custom toolbar + selection mirror
3c3afa9  WIP: CAD Phase A R2a — extract silhouette, delete edge_overlay.gd
26ec57a  WIP: CAD Phase A R1 — substrate adoption (A1 + A3)
```

Phase A net: **+272 / −1032 = −760 lines of duplicated annotation infrastructure removed.**

Substrate test suite stayed 39 PASS / 0 FAIL across all three sub-rounds.

## What to do next (in order)

### 1. HITL Phase A — verify the cad plugin in a running Minerva

Open the running Minerva, restart the CAD plugin panel, verify:

1. Platform `AnnotationDockPane` is **visible by default** (no resize trick / chevron — that was the R1-only bug, fixed by R2b removing the custom toolbar).
2. Toolbar comes from `AnnotationDockPane`. Should expose Select + the four advertised kinds (callout, 2d_arrow, 2d_text, cad_edge_number — whichever have `author_ui()` non-null).
3. **No leftover custom toolbar** in the panel.
4. Annotation controls actually work — pick a tool, place an annotation, see it.
5. Edge tree (geometry inspector) still works — Prev/Next/Clear + click-to-select highlights the right row. Tree click pushes selection to the host (visible via `minerva_cad_get_selected_edge` MCP).
6. Ortho silhouettes still render in Top/Front/Right panes (x-ray edge outlines).
7. `cad_edge_number` tool still picks edges. **Anchoring still floats on re-evaluate** — that's the Phase B problem, not a Phase A regression.
8. Iso pane shows shaded mesh + annotations as before.

If green: transition `019de9b755b07366` (A1), `019de9b78eda7a6b` (A2), `019de9b7ae707aa0` (A3) → done with resolution citing the three commit SHAs. Then start Phase B.

If broken: report what's broken; the failure mode informs whether to re-spin a single sub-round or roll back further.

### 2. Phase B — CAD edge anchors (the original problem)

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

### Phase A (in_progress, HITL pending)

| Status | ID | Title |
|---|---|---|
| ⏳ HITL | `019de9b755b07366` | A1: replace Cad_AnnotationCanvas with platform AnnotationOverlay; mount AnnotationDockPane via get_annotation_host() |
| ⏳ HITL | `019de9b78eda7a6b` | A2: delete edge_overlay.gd (5 instances) — route edge picking through substrate |
| ⏳ HITL | `019de9b7ae707aa0` | A3: Cad_AnnotationHost.get_capabilities() — advertise registered kinds |
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

- HEAD: `b05a28fb` (T8 Round 1 reframe).
- Last 5 commits: `b05a28fb`, `7c226c4a`, `a50cbb63`, `abc5ca9f`, `f0056c0e` (all T8 + T_apply Phase A from this session sequence).
- Working tree: `Docs/minerva.dct` modified (this session's docket bookkeeping — committed alongside this pickup.md update). Submodule pointers in `vendor/godot_cef`, `vendor/godot_wry` show drift but are pre-existing local build patches per CLAUDE.md.

### cad plugin (`~/github/plugins/cad/`, branch `main`)

- HEAD: `cda0822` (Phase A R2b).
- Working tree clean.
- Pushed (after pickup commit lands).

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
3. In Minerva: `git status` — expect submodule drift only. `git log --oneline -5`.
4. In cad plugin: `git status --short` — clean. `git log --oneline -3` — head should be `cda0822`.
5. Read `~/.claude/projects/-home-imran-github-Minerva/memory/project_active_cycle_plan.md` for the full active CAD cycle context.
6. Run the substrate regression suite from Minerva root:
   ```
   for t in test/annotations_v2/test_workbench_selection_sync.gd \
            test/annotations_v2/test_kind_extension_api.gd \
            test/annotations_v2/test_annotation_overlay_draw.gd; do
     timeout 90 godot --headless --path src --script "$t"
   done
   ```
   Expect 39 PASS / 0 FAIL.
7. Open Minerva, restart CAD plugin, run the HITL test plan in "What to do next §1."
8. Either transition Phase A tasks → done (if HITL passes) or report breakage.
9. Then: `/work-cycle 019de9b807e67c01` (B1) when ready to start Phase B.

## Process notes from this session

- **Two-sub-round split with no HITL between** worked well for the bigger Round 2 (delete edge_overlay + delete custom toolbar). Each sub-round had its own Sonnet implementer + Opus cold reviewer + Layer-1 gate. Single HITL at the end. Minimized HITL gates without sacrificing review safety.
- **Cold reviewer with file allowlist + OUT-of-scope list + method-level kill list** caught the verbatim-move comment-drop in R2a (cosmetic, fixed in main context). Pattern is durable — the explicit lists make the reviewer's job mechanical.
- **R1's intermediate state was not user-functional** (custom toolbar dead, platform UI layout-collapsed). The "skip-ahead" decision to bundle R2a+R2b sequentially was the right call once HITL surfaced this. Lesson: if the first round of a multi-round cleanup leaves a non-functional intermediate, don't pause for HITL — chain to the next round and HITL the end state.
