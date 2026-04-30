# Pickup — Annotation v2 Substrate

Last updated: 2026-04-30 (post Round 5a HITL — substrate text-editor consumer green for add/save/reload)

## Where I left off

**Rounds 1, 1.5, 2, 3, 4 done** (Codex on `user/imran/experiments/swarm`). Full v2 envelope, anchor registry, resolve_anchor, broken-anchor UX policy, resolve cache, kind/anchor compat, chat context, MCP query/update_status, v1 migration, plugin trust boundary — all shipped, tests green.

**Round 5a done** (this session). Text editor smoke consumer wires the v2 substrate into `Editor.Type.TEXT`. Six commits `ddac6c87 → 378271f4`.

- New: `src/Scripts/Services/Annotations/TextEditorAnnotationHost.gd` — owns annotation list + kind registry + `core/text.range` resolver + snapshot/restore + sidecar path. `add_comment_at(start, end, text)` is the canonical entry point.
- Modified: `src/Scripts/UI/Controls/Editor.gd` — for `Type.TEXT` instantiates a host in `_ready` BEFORE `_load_text_file`, registers it under `tab_title` with `AnnotationHostRegistry`, deregisters on `_exit_tree`. Adds `add_comment(text)`, `set_selection(start, end)`, `initialize_as_text_editor()`, `save_annotations(path)`. Sidecar load in `_load_text_file`; save in `save_file_to_disc` Type.TEXT branch. The three `static var X = preload(.tscn)` declarations are now lazy `load()` getters because the static preload was triggering compilation of every ext_resource script in headless mode (cascade-failed Editor.gd's compilation).
- Modified: `src/Scenes/Editor.tscn` — placeholder `AnnotationCanvas` Control overlay (anchors_preset=15, mouse_filter=IGNORE). No rendering yet.
- Modified: `src/Scripts/Services/MCP/Modules/MCPAnnotationTools.gd` — adds `minerva_text_editor_add_comment(editor_name, start, end, text)` MCP tool. v2-aware fix: `_annotations_list` preserves stored `summary` when `schema_version >= 2` instead of synthesising `"<kind> (N primitives)"`.
- Modified: `src/test/annotations_v2/test_text_editor_annotation_smoke.gd` — switched from `ClassDB.class_exists()` (which doesn't see GDScript `class_name` classes) to `preload()` guards, matching the v2 envelope test pattern.

**Round 5a HITL surfaced six bugs**, all fixed in the same commit chain. The behavioral coverage in the existing smoke test is existence-only; round-trip bugs (validation order, init order, id collisions, JSON float coercion) only fired at HITL. See review-process improvements discussion below.

## What to do next

```
/work-cycle 019ddc271a857ca0
```

That's **Round 5b: Break detection + broken indicator + repair UX**. Read the ticket body for full scope, then comment #271 ("START HERE — 5b cold-pickup briefing") for the post-5a state and recommended sub-round split.

CAD UX work remains paused (working CAD editor exists elsewhere; not blocker).

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
| ⏳ | `019ddc271a857ca0` | **Round 5b: Break detection + broken indicator + repair UX** *(NEXT)* |
| ⏳ | `019ddc27b59b7a57` | Round 5c: MCP query / update_status round-trip from text editor |

## Recommended round order (within the work-cycle)

1. ✅ **Rounds 1–4 done.** v2 substrate complete: 484/0 base + 22 RED smoke = 484/22 at end of round 4.
2. ✅ **Round 5a done.** Text editor host + add_comment + sidecar. v2 suite 497/13 (smoke 13/13 passing for host-only contract; 13 still RED — break/repair/MCP tests for 5b/5c plus 7 "Editor instantiable" cases that require live scene tree).
3. ⏳ **Round 5b NEXT.** Break detection, broken indicator render, repair UX. See comment #271 on `019ddc271a857ca0` for sub-round suggestion (5b.i revision-bump+canvas, 5b.ii sidebar+repair, 5b.iii UX affordance for add_comment).
4. ⏳ **Round 5c.** MCP query/update_status round-trip end-to-end with a live LLM provider.

## State of the trees at handoff

Minerva (`user/imran/experiments/swarm`, HEAD = `378271f4`):
- 18 commits ahead of origin. Push at some point — local-only as of this writing.
- Full v2 suite: 497 passed, 13 failed (all in `test_text_editor_annotation_smoke.gd`; failures are 5b/5c scope or headless-Editor-infra).
- v1 substrate: 146 passed, 0 failed.
- Working tree is clean for code; only untracked `.gd.uid` companions Godot regenerated for already-tracked scripts. Not 5a's responsibility — leave for housekeeping later.
- Submodule working-tree mods in `vendor/godot_cef` and `vendor/EIRTeam.FFmpeg` are local build patches (per CLAUDE.md) — not committed, not blocking.

`~/github/plugins` (`main`):
- 19 commits ahead of origin (per pre-5a state). Working tree clean.
- Round 2b-α click-to-add edge-number tool is on disk at `cad/ui/tools/cad_edge_number_tool.gd` but not wired — will be rebuilt on the v2 `AnnotationAuthorTool` contract once substrate ships.

## Constraints to carry forward

- Always pass `project="minerva"` to docket MCP tools when working with substrate IDs (saved as docket hint `docket/minerva-project-flag`).
- Off-tree plugin scripts must use `preload()`, not `class_name` (memory: `project_off_tree_plugin_class_names.md`).
- Plugin annotation code never crosses into another plugin's data — only via MCP, per the substrate's trust boundary task (`019ddb7aaf247033`).
- 2D ortho panes in CAD are intentionally edge-only x-ray, NOT 3D renders.
- **Reverting C++ source under `src/gdextension/terminal/` does NOT evict the compiled binary.** Always rebuild via `scripts/build-extensions.sh <platform>` after any reversion (lesson from `019ddbcfeef774bb`).
- **`ClassDB.class_exists()` does NOT see GDScript `class_name` classes** — it only resolves native C++ class registrations. Use `preload(path).new()` or `is SomeClass` checks for GDScript class probing. The v2 envelope tests already follow this pattern; 5a fixed the smoke test to match.
- **Static `preload()` of a `.tscn` triggers compilation of every ext_resource script at class-load time.** In headless `--script` mode, autoloads (SingletonObject, MediaGen, etc.) are not loaded, so dependent scripts cascade-fail. If a class is meant to be loadable in headless tests, defer scene loads via lazy `load()` getters or skip the static preload entirely.
- **GDScript `id` field validation on v2 envelopes**: `AnnotationV2Schema.validate()` rejects empty-string `id`. Generators must assign the id BEFORE calling validate (Round 5a fix `90547ee5`).
- **`JSON.parse_string` returns `Variant::FLOAT` for all numerics.** Any GDScript code that does `is int` checks against deserialised JSON will fail. Either coerce on load (5a's `_coerce_envelope_ints` is one example) or relax the type check.

## To pick up cold

1. `git pull` on both `~/github/Minerva` (branch `user/imran/experiments/swarm`) and `~/github/plugins` (branch `main`).
2. Read `Docs/pickup.md` (this file).
3. `git status` — expect submodule drift, untracked `.gd.uid` files, no uncommitted `.gd` changes.
4. `git log --oneline -8` — HEAD should be `378271f4`.
5. Run the verification probes:
   - `bash src/test/annotations_v2/run_all.sh | tail -3` → expect `497 passed, 13 failed`.
   - `godot --headless --path src --script test/test_annotation_substrate.gd | grep "=== Results"` → expect `146 passed, 0 failed`.
6. `mcp__docket__docket_get id="019ddc271a857ca0"` — Round 5b ticket body.
7. `mcp__docket__docket_comment action="list" item_id="019ddc271a857ca0"` — read comments #266–271 for inherited-follow-up context and the START HERE briefing.
8. `/work-cycle 019ddc271a857ca0`.

## Lessons from 5a (open question — user is sitting with this)

5a shipped clean but the path was rocky:
- Sonnet implementer over-corrected on a real headless-test parse error (correct fix: lazy preload; what it did: lazy preload + 20+ unrelated SingletonObject access rewrites). Caught at orchestrator-diff-read before reviewer spawn.
- Five post-review fix commits surfaced at HITL (validation-order, init-order, registry, id-collision, JSON-float coercion, summary projection). Existence-only Layer-1 tests didn't exercise the round-trip, so reviewer reading code couldn't catch them.

Three improvements floated:
1. Tighter scope contract in implementer brief: explicit "files NOT to modify" list; implementer report justifies every modified file.
2. Behavioral test scaffolding written by orchestrator BEFORE implementer runs (or explicit "this round is HITL-only" acknowledgement).
3. Smaller rounds when deliverable is mechanical wiring; rule of thumb: split if >2 already-shipped files OR >150 net lines.

Decision deferred. Round 5b will be run by the orchestrator directly (no Sonnet sub-agent) per user direction.
