# Pickup — Annotation v2 Substrate

Last updated: 2026-04-30 (post Round 5b — text-editor consumer green for break detection, broken indicator, Repair UX, healthy-anchor render)

## Where I left off

**Substrate is complete and consumer-side flesh is built out:**

- **Rounds 1–4 done.** v2 envelope, anchor registry, resolve_anchor, broken UX policy, resolve cache, kind/anchor compat, chat context, MCP query/update_status, v1 migration, plugin trust boundary — all shipped, tests green.
- **Round 5a done.** TextEditorAnnotationHost + add_comment + sidecar persistence + MCP entry point.
- **Round 5b done** (this session). Break detection, broken indicator render, sidebar with Repair button, retarget mode, healthy-anchor underline render. Six commits in `baa483a1 → c9d5808d`, push at `02da553e`. HITL verified end-to-end against /tmp/annot_smoke.txt via the MCP-driven test pattern.

The text-editor view of the annotation substrate now does the full break-and-repair lifecycle without any Sonnet sub-agent. Process detail: 5b was run orchestrator-direct (no implementer sub-agent) per the lesson from 5a's reject-and-retry. Worked well — every bug was caught either at parse time, Layer-1, or HITL, and HITL surface caught real UX gaps the tests couldn't (sidebar showing only broken entries, underline y-offset twice).

## What to do next

Two open children of the parent plan:

```
/work-cycle 019ddccf60a27c95   # Round 5b.iii — add-comment UX affordance
/work-cycle 019ddc27b59b7a57   # Round 5c — MCP query/update_status round-trip
```

5b.iii is small and isolated: sidebar "+" button + keyboard shortcut. Probably one orchestrator-direct round, ~100 lines, one HITL.

5c is the bigger remaining substrate value piece: end-to-end LLM round-trip via MCP query/update_status. Pair the round-trip with a live provider so the apply-tool boundary gets exercised in production conditions.

Either order is valid. 5b.iii completes the human-author surface; 5c completes the AI-author surface. 5b.iii first if you want to dogfood the text-editor experience without an LLM in the loop. 5c first if you want to validate the substrate's apply-tool boundary before more UX polish.

## Plan map

Project: `minerva` (always pass `project="minerva"` to docket tools).

- DCR root: `019ddb704374` — First-class editor annotations: base substrate + plugin semantic anchors
- Plan: `019ddb70ca45` — Annotation v2 substrate (base annotations + semantic anchors)
- Discussion: `0bd63d76bb70` — Annotation substrate refactor (resolved into the DCR)

### Children of the plan

Status legend: ✅ done · ⏳ open/backlog

| Status | ID | Title |
|--------|----|-------|
| ✅ | `019ddb7593467eef` | Annotation v2 envelope: typed anchor, payload, lifecycle, author, summary |
| ✅ | `019ddb75ffad7dd8` | Plugin-scoped anchor registry (validate / summary / repair) |
| ✅ | `019ddb767fe871ba` | Base AnnotationHost.resolve_anchor + anchor_screen_rect contract |
| ✅ | `019ddb76ed897520` | Broken / stale anchor UX (canvas, sidebar, MCP, chat) — substrate policy |
| ✅ | `019ddb77576b7b56` | Resolve cache + perf budget |
| ✅ | `019ddb77c4b37516` | Built-in anchors carry generic kinds; plugin anchors carry plugin kinds |
| ✅ | `019ddb7843b4742d` | Capability-aware to_chat_context (structured_json IS the action contract) |
| ✅ | `019ddb78c40c74bc` | MCP query / update_status surface + apply-tool hook |
| ✅ | `019ddb796041719a` | v1 → v2 migration + coexistence hooks |
| ✅ | `019ddb7a0f407621` | Contract tests + smoke consumer (text editor) — Round 1 RED scaffolding |
| ✅ | `019ddb7aaf247033` | Plugin trust boundary + fail-containment (render / resolver / apply-tool) |
| ✅ | `019ddbcfeef774bb` | Fix stale libterminal stubs + harden contract tests with behavior |
| ✅ | `019ddc26ac2b7f04` | Round 5a: TextEditorAnnotationHost + add_comment + sidecar persistence |
| ✅ | `019ddc271a857ca0` | Round 5b: Break detection + broken indicator + repair UX in text editor |
| ⏳ | `019ddccf60a27c95` | Round 5b.iii: Add-comment UX affordance (sidebar button + keyboard shortcut) |
| ⏳ | `019ddc27b59b7a57` | Round 5c: MCP query / update_status round-trip from text editor |

## State of the trees at handoff

Minerva (`user/imran/experiments/swarm`, HEAD = `02da553e`):

- Synced with origin — last push landed `4cfc39e6..02da553e`.
- v1 substrate suite: `146 passed, 0 failed`.
- v2 substrate suite: `500 passed, 10 failed`. Remaining failures decompose to:
  - 7 × `Editor instantiable` — pre-existing; Editor.gd's body references `SingletonObject` which is not loaded under `godot --headless --script`. Test infrastructure issue, not 5b's responsibility.
  - 3 × `MCPAnnotationTools` query / update_status method probes — 5c scope (those methods don't exist yet).
- Working tree clean for code; only untracked `.gd.uid` companions Godot regenerated for already-tracked scripts. Submodule working-tree mods in `vendor/godot_cef` and `vendor/EIRTeam.FFmpeg` are local build patches per CLAUDE.md — not committed, not blocking.

## Files added or substantially modified by 5b

All in repo:

- New: `src/Scripts/UI/Controls/TextEditorAnnotationCanvas.gd` (was renamed from the original 5a `AnnotationCanvas.gd` to avoid basename collision with substrate's `class_name AnnotationCanvas`). Paints orange gutter strip + line tint for stale anchors; soft-blue underline along the actual character range for healthy anchors using `CodeEdit.get_pos_at_line_column`.
- New: `src/Scripts/UI/Controls/TextEditorAnnotationSidebar.gd`. VBoxContainer-derived Control wrapping the substrate's `AnnotationSidebarModel`. Renders "Annotations (N total, M broken)" header, broken rows with Repair button, healthy rows below, "Show broken only" filter pill. Decorates host annotations with current resolved-stale state on every refresh.
- Modified: `src/Scripts/Services/Annotations/TextEditorAnnotationHost.gd` — `_resolve_text_range` now does snapshot-text equality check (range matches but content diverged → stale=true). New `retarget_annotation(id, start, end)` re-anchors a stale annotation, refreshes snapshot, sets lifecycle back to `open`, bumps revision. `repair_annotation` alias preserves smoke-test contract.
- Modified: `src/Scripts/UI/Controls/Editor.gd` — `_on_editor_changed` bumps host revision + queues canvas redraw + refreshes sidebar. Sidebar mounted as last child of VBoxContainer in `create()` for Type.TEXT. Retarget mode (`_retarget_in_progress`) on the editor: enter on sidebar's `repair_requested` signal; mouse-up over a non-empty selection commits via `host.retarget_annotation`; Esc cancels. Public `retarget_annotation` / `repair_annotation` methods for smoke contract + future MCP. Sidebar refresh hooks added to `add_comment` and `_load_annotations_sidecar`.
- Modified: `src/Scripts/Services/MCP/Modules/MCPEditorTools.gd` — `_update_editor` now calls `code_edit.text_changed.emit()` after assignment so revision bump and content_changed fire. Without this, MCP-driven text changes would not invalidate the resolve cache and the broken indicator would only appear after an unrelated layout reflow.
- Modified: `src/Scenes/Editor.tscn` — `AnnotationCanvas` node carries the renamed script via ExtResource.
- Modified: `src/test/annotations_v2/test_text_editor_annotation_smoke.gd` — `ClassDB.class_exists()` probes for `CoreAnchors` and `MCPAnnotationTools` replaced with `preload(...).new()` (ClassDB does not see GDScript class_name classes). Expected MCP method probe names corrected (`MCPAnnotationsTools` → `MCPAnnotationTools`).

## Constraints to carry forward

These are all real, all bit me at least once:

- Always pass `project="minerva"` to docket MCP tools when working with substrate IDs (saved as docket hint `docket/minerva-project-flag`).
- Off-tree plugin scripts must use `preload()`, not `class_name` (memory: `project_off_tree_plugin_class_names.md`).
- Plugin annotation code never crosses into another plugin's data — only via MCP, per the substrate's trust boundary task (`019ddb7aaf247033`).
- 2D ortho panes in CAD are intentionally edge-only x-ray, NOT 3D renders.
- **Reverting C++ source under `src/gdextension/terminal/` does NOT evict the compiled binary.** Always rebuild via `scripts/build-extensions.sh <platform>` after any reversion.
- **`ClassDB.class_exists()` does NOT see GDScript `class_name` classes** — it only resolves native C++ class registrations. Use `preload(path).new()` for GDScript class probing.
- **Static `preload()` of a `.tscn` triggers compilation of every ext_resource script at class-load time.** In headless `--script` mode, autoloads (SingletonObject, MediaGen, etc.) are not loaded, so dependent scripts cascade-fail. Use lazy `load()` getters or skip the static preload entirely for classes that need to be loadable in headless tests.
- **GDScript `id` field validation on v2 envelopes**: `AnnotationV2Schema.validate()` rejects empty-string `id`. Generators must assign the id BEFORE calling validate.
- **`JSON.parse_string` returns `Variant::FLOAT` for all numerics.** Any GDScript code that does `is int` checks against deserialised JSON will fail. Either coerce on load (TextEditorAnnotationHost's `_coerce_envelope_ints` is the canonical example) or relax the type check.
- **`var x := obj.method()` cannot infer when `obj` is RefCounted-typed.** RefCounted method calls resolve as Variant. Use `var x: SomeType = obj.method()` for typed return values.
- **`CodeEdit.get_pos_at_line_column(line, col)` returns the position at the baseline, not the top of the line.** Don't add `line_height` for an underline — just use the returned y directly with the canvas-local offset.
- **Setting `code_edit.text = …` does NOT emit `text_changed`.** Any code path that sets text directly (MCP `update_editor`, programmatic test setup, etc.) must call `code_edit.text_changed.emit()` afterward, or downstream signal listeners (annotation revision bump, content_changed, save-state tracking) will not fire.
- **The substrate–editor boundary held cleanly through 5b.** Round 5b changed zero substrate files: `AnnotationHost`, `AnnotationAnchorRegistry`, `AnnotationSidebarModel`, `AnnotationResolveCache`, `BuiltinKinds`, `CoreAnchors` are all untouched. The pattern that makes this work: editors decorate annotations with current resolved-stale state on every refresh, then hand the decorated list to the substrate's sidebar model. If a future round needs a substrate change, that's a smell — the protocol probably has a gap.

## Cold pickup checklist

1. `git pull` on `~/github/Minerva` (branch `user/imran/experiments/swarm`).
2. Read `Docs/pickup.md` (this file).
3. `git status` — expect submodule drift, untracked `.gd.uid` files, no uncommitted `.gd` changes.
4. `git log --oneline -5` — HEAD should be `02da553e`.
5. Run the verification probes:
   - `bash src/test/annotations_v2/run_all.sh | tail -3` → expect `500 passed, 10 failed`.
   - `godot --headless --path src --script test/test_annotation_substrate.gd | grep "=== Results"` → expect `146 passed, 0 failed`.
6. Pick a next ticket:
   - `mcp__docket__docket_get id="019ddccf60a27c95"` for 5b.iii (add-comment UX), or
   - `mcp__docket__docket_get id="019ddc27b59b7a57"` for 5c (MCP round-trip).
7. `/work-cycle <ticket id>`.

## Lessons from 5b (process retrospective)

5b ran clean orchestrator-direct (no Sonnet sub-agent). The 5a reject-and-retry made the right call: when the deliverable is mechanical wiring against a known substrate, an orchestrator that can hold the plan + the test + the file context in one head outperforms a sub-agent that has to be re-briefed every hop.

Three findings worth carrying forward:

1. **HITL caught what tests couldn't** — three real bugs surfaced only at HITL: sidebar showing broken-only entries (made healthy annotations invisible), underline y-offset (rendered above editor), underline y-overshoot (rendered below text). Layer-1 tests are correct as written but they exist-check the API; only an HITL run exercises the visual coordinate math. The tests serve as a compile gate, not a UX gate. Plan around that — don't expect tests to catch coordinate bugs.

2. **Decompose into HITL-sized rounds** — 5b naturally split into three sub-rounds (5b.i revision-bump + canvas, 5b.ii sidebar + repair, 5b.iii add-comment). Each was small enough that an HITL-discovered bug fit into a single follow-up commit on the same branch without needing to roll back the round. The discipline of "one HITL per sub-round" kept blast radius small.

3. **Substrate-first design pays off** — the round-3 broken-anchor UX policy + AnnotationSidebarModel were already ergonomic enough that 5b.ii consumed them without any substrate change. That's a reusable design pattern: when shipping a substrate, also ship the sample-consumer-shaped data structure (sidebar model, render context) so the consumer round becomes pure wiring.

The "tighter scope contract / behavioral test scaffolding / smaller rounds" rules from the 5a retrospective stay valid but didn't fire in 5b — orchestrator-direct + sub-rounds + HITL caught everything that mattered.
