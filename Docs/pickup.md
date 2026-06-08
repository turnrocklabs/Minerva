# Pickup

LATEST 2026-06-07 (session 9 — codetools 3-skill RECUT built into the manifest + annotation word-wrap bugs fixed; **WIP, UNCOMMITTED, awaiting owner docket-close then commit/push**). **HEAD-OF-LINE.**

**CODETOOLS SKILLS RECUT — BUILT (uncommitted in plugins repo, `codetools/manifest.json`).** Reframed around **ephemeral vs durable** (owner's skill-1 note: basic = tiny throwaway scripts, not repo work). Three skills, all rewritten + reviewed-by-annotation across several rounds:
- **`minerva_codetools_basic_coding`** (4 tools) — tiny scripts: write→run→read→deliver. No repo/index/exploration. Tools: file_write/edit/read + bash.
- **`minerva_codetools_advanced_coding`** (38 tools) — durable-engineering METHODOLOGY: frame(docket+DoD)→survey(re-use map+file pre-factor)→pseudo-code→build→verify→commit-WIP(**user pushes**); risk discipline; rubric (durability>DRY>reliability>well-factored>readability>cost); proportionality; note-vs-docket-vs-project decision rules; notes are working memory (create/update/**get/list_note(_tab)**, survive compaction, capture AS YOU GO); absorbed repo-nav+debug+research+visualize. Sub-agents deferred to v1.
- **`minerva_codetools_plugin_authoring`** (16 tools) — **SELF-CONTAINED, carries the FULL plugin API inline** (~11.5KB system_prompt) because user-machine LLMs lack Minerva/plugins source + may be policy-blocked: manifest schema, stdio JSON-RPC transport+envelopes, the complete **host.\*** capability catalog (args+returns), html (window.minerva) + godot_scene panels, the annotation substrate recipe+signatures, lifecycle, traps, + a minimal Go sample. Layers on a coding skill. (manifest reformatted whole-file by a json.dump rewrite — valid.)

**NEW DOCKET PROJECT `plugins`** (prefix **PLG**, DB `~/github/minerva-plugins/Docs/plugins.dct`). Owner decision: all plugin work shares ONE docket distinguished by `component` (codetools, …). The `.dct` is **COMMITTED to the plugins repo** (NOT gitignored) — docket serializes to **JSONL** so it's merge-safe; only `*.dct.cache*` (SQLite working layer) is gitignored. **GOTCHA: docket serializes on load/unload → UNLOAD the project before committing the .dct, else you commit a stale file and lose the session's items** (unload→commit→re-add). `cad`-fold into plugins deferred (149 items). Project name registered as `plugins.dct` (docket_project_add includes the extension — cosmetic, owner said live with it).
- **discussion `019ea4fcc687`** (plugins, active) — the shaping record (ephemeral/durable axis, methodology, decision rules). Has owner review comments incl. "plugin skill needs full API/guide/samples" (addressed by the self-contained rewrite).
- **DCR `019ea523295` (plugins, proposed, follow_up of the discussion)** — "Plugins seed knowledge (kb/hint) alongside skills, referenced by stable key." The clean long-term home for the plugin-API depth (ship as updatable kbs vs an 11.5KB prompt); seeding apparatus (PluginManager._seed_plugin_skills/PluginSkillRecord) generalizes.

**ANNOTATION WORD-WRAP BUGS — FIXED in Minerva core (UNCOMMITTED):**
- **Anchoring `019ea4b62012`** (RCA `019ea4c055ad`): gutter-click below a soft-wrapped paragraph anchored to the wrong logical line. `Editor._line_at_code_edit_position` (Editor.gd:2745) used `first_visible + floor(y/line_height)` (visual rows ≠ logical lines) and shadowed the wrap-aware API. FIX: `get_line_column_at_pos` is now primary, reading **`.y` (line)** — the dead path read `.x` (column). Floor math is fallback only.
- **Underline render `019ea4d3c94d`**: a highlight spanning a wrap boundary truncated at the first row. `TextEditorAnnotationCanvas._draw_healthy` drew one `draw_line` per LOGICAL line at `p_a.y`. FIX: new `_wrap_segments()` splits the range per visual row via `get_line_wrap_count`/`get_line_wrapped_text`; one underline per row.
- Test `test_annotation_wrap_segments.gd` (6/6, + the earlier `test_buffer_sync_undo_caret.gd` 11/11 for the glyph fix).
- **STILL OPEN (deferred):** empty-line annotation **wedge** `019ea5335f03` (gutter-click a blank line → error → annotation dead for the session; partial trace says graceful at Editor.gd:2711-2714, so suspect the annotation **sidebar** add-comment-flow state isn't reset — needs sidebar read); redo-caret-to-bottom nit `019ea49c6c66` (pri4); move/re-parent-annotation UI gap `019ea4ba7818`.

**UNCOMMITTED WIP (commit AFTER owner closes docket, then push):**
- Minerva `development`: `src/Scripts/UI/Controls/Editor.gd`, `src/Scripts/UI/Controls/TextEditorAnnotationCanvas.gd`, `src/test/test_annotation_wrap_segments.gd`(+`.uid`), `Docs/pickup.md`. (Earlier this session: glyph fix `88dcfe50` + pickup `0ecef252` already pushed.)
- plugins `main`: `codetools/manifest.json`, `.gitignore` (added `*.dct.cache*`), `docs/plugins.dct` (commit via unload→commit→re-add).
- Leave modified: `Docs/minerva.dct`, `vendor/*` (expected dirt).

**NEXT SESSION:** (1) **reinstall codetools** (`minerva_plugin_remove codetools` → `minerva_plugin_install ~/github/minerva-plugins/codetools/manifest.json`) to re-seed the 3 recut skills — NOT done this session (would re-seed into the docket being closed). (2) HITL the 3 skills in focused chats. (3) fix the empty-line wedge `019ea5335f03`. (4) decide inline-vs-seeded-kb for the plugin-API depth (DCR `019ea523295`). (5) PCB→plugin migration: build on the annotation substrate (recipe is in the plugin-authoring skill; supported-now vs gaps assessed). (6) flesh out skill content further per ongoing annotation review.

---

LATEST 2026-06-07 (session 8 — layered-undo DCR **HITL-PASSED → SHIPPED**; one glyph bug found+fixed during HITL). **HEAD-OF-LINE.** DCR `019ea404ffcd` transitioned reviewing→**shipped**. Full HITL run in the live app on a scratch fixture (`/tmp/minerva_undo_hitl.gd` + `…2.gd`): P1 caret/scroll hold + Undo (1 step, history survives) ✅; P2 path-revert/closed-file/`{source:"ai"}`/whole-turn `{}` all live ✅; P3 already MCP-verified prior session.

**BUG FOUND + FIXED DURING HITL (Minerva `88dcfe50`):** agent/MCP/journal edits via `Editor._set_code_edit_text_from_buffer` (`code_edit.text = X`) did NOT refresh the tab dirty/note glyph — Godot 4 does NOT emit `text_changed` on a programmatic `text =` (only `text_set`), so `_on_editor_changed`→`content_changed`→`EditorPane` glyph never fired. The load path already worked around this (`_load_text_file` manually emits, "the signal is not emitted for some reason" Editor.gd:875); the buffer-sync path forgot. FIX = emit `code_edit.text_changed` inside the `_applying_buffer_text` guard (glyph + note + annotation revision refresh; guard still suppresses echo-back). `get_saved_state()` was already live-correct, only the visual refresh was missing. work_item `019ea49c63e5` (done). Test `test_buffer_sync_undo_caret.gd` 11/11 (+`test_bare_assign_is_silent_but_sync_emits_text_changed`). Minor deferred: redo (Ctrl+Y) scrolls caret to bottom — native `CodeEdit.redo()` bypasses the caret-restore (bug `019ea49c6c66`, pri4).

**Repos:** Minerva `development` carries `88dcfe50` (glyph fix+test) on top of the already-pushed P1-P3. plugins `main` @ `562bd24` — skills recut **already committed+pushed** (`562bd24 feat(codetools): recut seeded skills`). DCR-tree docket reconciled (P1/P2/P3 done, north-star `019ea406da3f` parked/proposed). **NEXT:** review the 3 recut codetools skills' content (loaded as Minerva editor tabs), flesh them out, improve `PLUGIN_DEVELOPER_GUIDE.md` (D2), then HITL the skills in focused chats. Do NOT reinstall codetools yet (owner wants to review skills first).

LATEST 2026-06-07 (session 7 — codetools 3-skill redesign PLANNING + layered-undo DCR **P1+P2+P3 BUILT & COMMITTED, awaiting final HITL**). **HEAD-OF-LINE.** Committed straight to `development` (owner-authorized go-forward). DCR `019ea404ffcd` status=reviewing. Minerva commits: P1 `191c2ab4`, P2 `abbb4546`, P3 `85b1abe2`; plugins commit P3.T3.2 `42ec462`. NOT pushed. Headless green: P1 9/9, journal 30/30, P3 14/14, hermetic suite 4/4. codetools smoke=21.

**WHAT SHIPPED (all phases done in docket):**
- **P1 caret/scroll preservation** (`191c2ab4`) — PROOF-FIRST overturned the premise: on Godot 4.6.1 `code_edit.text = X` is ALREADY one undoable step preserving history (it does NOT wipe undo — see nudge `minerva-undo/codeedit-text-assign-is-undoable`). So the only real defect was caret/scroll reset; `Editor._set_code_edit_text_from_buffer` now saves+restores caret(line,col)+scroll(v,h) clamped. T1.2 (complex-operation) closed OBSOLETE. Test `test_buffer_sync_undo_caret.gd` 9/9 locks the undoable-`text=` contract + caret clamp.
- **P2 journal revert** (`abbb4546`) — `ChangeJournal.revert(path,save)` + `revert_changeset(save,source_filter)` write the baseline back through `apply_edit` (re-entrancy guarded via `_reverting`) → propagates to open editor + is itself one undoable step (composes w/ P1); `save=true` flushes to disk. MCP `minerva_journal_revert` (path | changeset | source). Works on CLOSED files. test_change_journal 30/30 (+16).
- **P3 concurrency rail** (`85b1abe2` / plugins `42ec462`) — `doc_write`/`doc_edit` accept `if_match_version`; rejected on mismatch with `{code:"version_mismatch", error w/ want+got}`. Logic in new dependency-free `DocVersionGuard` (preloaded, unit-testable headless — MCPDocTools can't instantiate under `--script`). codetools `file_write`/`file_edit` forward the param. Gotcha (nudge `minerva-plugins/mcp-proxy-forwards-only-error-field`): `CapabilityBroker._handle_mcp_proxy` forwards only `result.error` to plugins → want/got folded into the error string. test_doc_version_guard 14/14. **P3 MCP-VERIFIED LIVE 2026-06-07** in the restarted app: doc_write→v1, doc_edit(no ver)→v2, doc_edit{if_match_version:1}→rejected `version_mismatch (want 1, got 2)` (file untouched), doc_edit{if_match_version:2}→ok v3. P1 caret/Undo-button + P2 revert still need the human visual HITL (runbook below).

**CODETOOLS 3-SKILL RECUT (WIP, uncommitted in plugins repo, manifest only):** `codetools/manifest.json` skills[] REPLACED the old 3 (understand_code/navigate_edit/inspect_runtime) with the recut **minerva_codetools_coding / _advanced_coding / _plugin_authoring** (owner: "have the skills" + D1 lean=replace). These are **v1 SCAFFOLDS** seeded from the planning notes — Coding absorbs understand+navigate, Advanced absorbs inspect_runtime + research/visualize, Plugin authoring is a scaffold that self-flags its docs are pending the PLUGIN_DEVELOPER_GUIDE expansion (D2 self-contained-docs deferred per owner "modify skills later"). Valid JSON, prefix-correct, tool_deps reference real tools (cobrowser_* will resolve unsatisfied-but-not-fatal). **No binary/bundle rebuild needed** (skills live in the manifest, seeded at install). To activate on a machine: reinstall codetools (`minerva_plugin_remove codetools` then `minerva_plugin_install <dev manifest>`) so the new skills re-seed into the docket. Refine content later.

### HITL RUNBOOK — layered undo (the large end-of-initiative test)
Launch Minerva (F5 so the new scripts + a regenerated class cache load); `/mcp` reconnect.
1. **P1 caret/scroll:** open a `.gd`, put the caret mid-file + scroll down; from chat have the agent `minerva_doc_edit` that file. Caret + scroll should STAY put (not jump to top). Then press the **Undo button** (or Ctrl+Z) → the agent's edit reverts as one step; press again → your earlier edits revert (history intact).
2. **P2 revert:** edit a file via the agent; `minerva_journal_changes` shows it; `minerva_journal_revert {path}` → file returns to baseline (visible live in the open editor, and undoable). Try with the file CLOSED, and `minerva_journal_revert {}` (whole turn), and `{source:"ai"}`.
3. **P3 concurrency:** `minerva_doc_read` a file (note `version`); type a char in the editor (bumps version); agent `minerva_doc_edit {if_match_version:<old>}` → rejected `version_mismatch (want/got)`; agent re-reads + retries with the new version → succeeds. Also exercise codetools `file_edit if_match_version`.

**Repos (pulled & current):** Minerva `development` @ `bf250d6f`; plugins `main` @ `6e7d449`. codetools REBUILT this session (PBS bundle 63M + Go binary; smoke = **21 tools** [18 + the re-branded file_read/file_write/file_edit], `go test` + 286 worker tests green).

**Docket reconciled:** journal v1 `019ea01719a2` → **done**; buffered file_* `019ea035bb28` → **in_progress** (core re-brand shipped; remaining sub-tasks 4 activity-log file-change verification + 5 skill/docs prefer-file_*-over-bash).

**Codetools 3-skill redesign (SHAPING, not built):** re-cut codetools' seeded skills → **Coding / Advanced coding / Plugin authoring**. Captured as 3 Minerva note tabs (`Skill: Coding`/`Skill: Advanced Coding`/`Skill: Plugin Authoring`, 10 notes each: what/why/how/deploy/human-scenarios/LLM-scenarios/boundaries-seam/success-HITL/deps/open-risks) + mirrored to nudge (components `skill-coding`, `skill-advanced-coding`, `skill-plugin-authoring`, keys `01-what`..`10-open-questions-risks`). **Locked:** D2 plugin skill DUPLICATES docs inline (self-contained, no repo dep) — improve `PLUGIN_DEVELOPER_GUIDE.md` FIRST; D3 plugin-authoring stays in codetools. **Open:** D1 replace-3-vs-add (leaning replace→3 total); D4 printing/PDF capability UNCONFIRMED (maybe nametag-maker-local — check pdf-print-substrate branch). Verified: DOCX/XLSX import EXISTS in core (`OOXMLReader`/`ExcelHandler`/`MCPDocumentTools`), undocumented for plugin authors. Memory `project_codetools_skills_redesign`.

**Layered-undo DCR `019ea404ffcd` (status=implementing) — the Coding skill's undo backbone.** Settled UX: autonomous agent + human-asks-undo + compile-now (edits hit disk). Code findings: undo = a per-editor-type dispatcher `Editor.undo_action()` (Editor.gd:1943) — TEXT→`code_edit.undo()` native stack; SPREADSHEET→`SpreadsheetHistory`; PCB→`PCBData.undo()`; GRAPHICS→command pattern; driven by the toolbar button `vboxEditor._on_undo_button_pressed()` (vboxEditor.gd:904). `Undo.gd`/`undoMain` = unrelated 3-min closed-tab restore. **LATENT BUG:** the shared-buffer→editor sync does `code_edit.text = new_text` (Editor.gd:1010 in `_set_code_edit_text_from_buffer`), which WIPES Godot's native undo → ANY agent/MCP edit to an open text file destroys the user's undo stack. Rubric-REJECTED "pin all undo to the journal" (the journal is TEXT + COARSE: `_baselines` vs `_current`, two-snapshot, no keystrokes; can't represent spreadsheet/PCB/graphics actions). Chosen = **LAYERED, composing:**
- **P1 `019ea4055a21`** undo-aware TEXT apply-path (`begin/end_complex_operation` + minimal range patch → existing button undoes agent edits, caret preserved, codetools inherits FREE). Tasks T1.1 `019ea40626a7` / T1.2 `019ea4062f7a` / T1.3 `019ea406385c`.
- **P2 `019ea4056313`** journal_revert (coarse/attributed/closed-file/cross-file/MCP; applies baseline via `apply_edit` so the revert is itself ONE native undo step → composes with P1). Tasks T2.1 `019ea4064 14e` / T2.2 `019ea4064a63` / T2.3 `019ea4065347`(pri3) / T2.4 `019ea4065c29`.
- **P3 `019ea40573c7`** `if_match_version` concurrency rail (doc_edit/doc_write version-checked at `apply_edit` + codetools file_edit forwards). Tasks T3.1 `019ea40664f9` / T3.2 `019ea4066de4` / T3.3 `019ea40676d2`.
- **North-star DCR `019ea406da3f`** (proposed, follow_up of A): journal as a GENERIC attributed-changeset interface that per-type histories REPORT INTO (review + coarse-undo everywhere incl. plugins; duck-typed undo dispatch; optional per-.minproj persistence). Cost L; do NOT start before A ships+HITL.

**Methodology = DIRECT (Opus), sequenced P1→P2→P3** — phases are S, coupled, share reuse seams (DRY-sensitive) and HITL-heavy → direct per `feedback_scansort_direct_mode` (work-cycle is for larger autonomous batches). **Proof-FIRST on P1:** throwaway headless test that Godot `begin/end_complex_operation` actually records an undo step BEFORE rewriting the sync. **HITL gate after P1** (running app: human types → agent edits via MCP → press the Undo button).

**Risk controls (owner-flagged):** (1) *wrong commit start* → feature branch `dcr/layered-undo` off `development`; verify HEAD = origin tips before any commit (done: bf250d6f / 6e7d449); per-file `git add` only, co-author trailer. (2) *scope creep* → the DCR firewalls A-now vs C-northstar; NON-GOALS = no spreadsheet/PCB/graphics undo changes, no journal persistence, no duck-typed dispatcher refactor, no turn-batching beyond T1.2; per-task DoD is the contract, anything else = new backlog item. (3) *poor DRY* → reuse `TextLineDiff` (P1 patch), `DocumentBuffer.version` (P3), `ChangeJournal` baselines (P2), the single `apply_edit` choke point; one shared version-check helper for doc_edit+doc_write; Opus dup-check pass before each commit.

**RESUME (session 8) / LAPTOP:** pull both repos AFTER the desktop pushes (push is pending owner closing docket). Minerva `development` carries P1-P3 (4 commits ahead of `bf250d6f`) + pickup; plugins `main` carries P3.T3.2 (`42ec462`) + the **WIP manifest skills recut (commit pending)**. On the laptop: (1) no codetools rebuild needed for skills, but if you touched Go/worker, rebuild per §1; (2) **reinstall codetools** to re-seed the 3 new skills (`minerva_plugin_remove codetools` → `minerva_plugin_install <dev manifest>`); (3) run the undo HITL runbook above (P3 already MCP-verified; do P1 caret/Undo-button + P2 revert). If undo HITL green → transition DCR `019ea404ffcd` reviewing→shipped. North-star DCR `019ea406da3f` parked. NEXT after this: flesh out the 3 skills' content + improve PLUGIN_DEVELOPER_GUIDE.md (D2), then HITL the skills in focused chats.

**THIS SESSION'S COMMIT/PUSH PLAN (owner-directed):** owner is closing docket now; AFTER that → commit the WIPs (Minerva: pickup.md; plugins: codetools/manifest.json skills) then push BOTH repos. Do NOT push before the owner closes docket.

---

LATEST 2026-06-07 (session 6 — change JOURNAL + buffered file_* + bidirectional host client + side-by-side review widget + the panel→native review LOOP, **HITL-PASSED + PUSHED**). **THIS IS HEAD-OF-LINE STATE.** Built on top of session 5's P1–P5. **PUSHED** (owner authorized end of session 6): Minerva `development` ≈ **`9e00f71e`** + UID/pickup commits; plugins `main` = **`6e7d449`**.

**What shipped this session (all committed, machine-verified):**
- **Change JOURNAL v1** (work_item `019ea01719a2`; Minerva `b9f3871a`/`50bd3a3d`): `ChangeJournal.gd` + `TextLineDiff.gd` (Services/Documents/). Subscribes to `DocumentRegistry.buffer_created` → in-memory baseline-vs-current per path; `mark`/`changed_paths`/`diff_for`/`aligned_rows_for`; `attribute_next_edit_to("ai")` one-shot. MCP `minerva_journal_mark`/`changes`/`diff`. Captures edits through `DocumentBuffer.apply_edit` ONLY (doc_*/host.documents + the human editor) — raw `disk_write`/bash NOT captured by design. **LIVE HITL passed.** test_change_journal 14/14, test_text_line_diff 35/35.
- **Buffered file_* restored** (work_item `019ea035bb28`; Minerva `0b53321b`, plugins `51363d3`): the extraction had dropped read/write/edit. Re-added as a CORE buffered capability codetools RE-BRANDS (owner chose option A). `minerva_doc_write` gained `save`; `minerva_doc_edit` gained `replace_all`+`save`; `DiskAccess.write` mkdir -p. codetools `file_read`/`file_write`/`file_edit` are thin delegates → core `minerva_doc_*` (buffered→journaled→annotation-coherent), NOT raw disk.
- **Bidirectional Go host client** (work_item `019e8f811497` items 1–2; plugins `51363d3`+`3b33ef4`): `codetools/main.go` `hostClient.Call(capability,args)` emits `minerva/capability`, reads the correlated reply off the shared stdin scanner. **Parse the response id as float64** (Godot serializes JSON ids as `1.0` — was the "want 1 got 1.0" bug). First consumer = the file_* re-brand. REMAINING (open): wire bash → `host.terminal.exec` (items 3–5).
- **Side-by-side review widget** (work_item `019ea06a1413`; Minerva `584bb5be`→`1969ba78`): `SideBySideDiff.gd` (class_name) — Beyond-Compare two-pane diff: line tints + changed-WORD focus highlight, real per-side line numbers (string gutter), synced V+H scroll, hunk-nav toolbar "change i/N" ▲▼. Source-agnostic: `minerva_editor_review_journal(path)` (journal) OR `minerva_editor_review_content(path,before,after)` (git/generic). `EditorPane` tab handlers guarded with `is Editor`. test_side_by_side_diff 3/3.
- **The review LOOP wired + HITL-passed** (P5 `019e9fe873`; plugins `6e7d449`): code_graph HTML panel changeset → double-click file → `openNativeReview()` → `minerva_editor_review_content` → native SideBySideDiff. Owner: "the basic flow works!" Tested on the real **video-recorder-rust** bed.
- **T5 comment → Option B → HITL-PASSED** (Minerva `1969ba78`; crash fix `9e00f71e`): owner HITL'd the first T5 (`145b0162`) and flagged it inconsistent with the native annotation surface (bespoke dialog, no dock/gutter/list). Root cause: gap rows are inserted into the right buffer, so the right pane ≠ the real file, blocking a real host. FIX (net −8 LoC): the diff is a read-only lens; 💬 now opens/focuses the real editor tab and triggers the NATIVE add-comment flow (`Editor.begin_add_comment_at_line` → `_begin_add_comment_from_shortcut`; `EditorPane.focus_editor`) — same dock/gutter/list/C<n> as every comment. HITL surfaced a latent crash: `EditorPane` assumed every tab is an `Editor` (4 sites) and threw on the `SideBySideDiff` tab → hardened with `is Editor` narrowing (`9e00f71e`). **HITL-PASSED 2026-06-07 night** — owner: "we create the real editor and comment. A bit clunky, but good enough for tonight." Widget item `019ea06a1413` = **done**.

**RESUME HERE (session 7) — all deferred, owner "pickup later", tracked in follow-up `019ea0fff0d4`:** (1) **annotation/review polish** — in-diff commenting is clunky (delegates to a separate editor tab); decide Option A (right pane = real host-backed editor with the dock/gutter/list IN the diff; needs phantom gap-row rendering) vs a smoother B. (2) render C<n> as a clickable chat **chip** + dock/panel **badge** (P4 view-layer; data present). (3) **P5c panel strip-down** — delete dead in-panel openFileDiff/lcsDiff/composer JS (plugins `ui/code_graph.src.html` + rebuild). (4) **code-graph usability** (legibility/entry/responsive/splash — older items `019e8f2489`/`29a2`/`2282`/`8e4a26`). (5) **bash→host.terminal.exec** (host-client tail, `019e8f811497` items 3–5).

**CACHE NOTE:** new class_names (`ProjectIdentity`, `AnnotationRef`, `AnnotationRefResolver`, `TextLineDiff`, `ChangeJournal`, `SideBySideDiff`) were added MANUALLY to the gitignored `src/.godot/global_script_class_cache.cfg` for headless `--script` tests; they regenerate on the next editor open. Headless `--script` tests that load scripts referencing `SingletonObject` must defer to `process_frame` (autoload unresolved in `_init`).

---

LATEST 2026-06-06 (session 5 — DCR 019e9f602391 citeable annotation refs C<n>: P1–P4 + HTML-panel-open bug DONE, P5 Minerva-side prep DONE). **Superseded as head-of-line by session 6 above; still current for the DCR P1–P4 detail.** Built autonomously (owner approved hybrid methodology + autonomous run). Minerva `development` was **2afcaced → +6 commits → `25ceef39`** at the time (session 6 has since extended it to `1969ba78`).

**What shipped (all machine-verified, committed to development):**
- **P1 core project identity** (`93c246bf`): new `ProjectIdentity` (Models/, class_name, DI'd + hermetically testable) = `project_id` (UUID, reuses generate_UUID) + `annotation_ref_seq`. Minted for the implicit project at startup (singleton `_ready`); persisted to a minimal `user://` config scratch (section `ImplicitProject`) for unsaved sessions; promoted into `.minproj` on save (`serialize_project`/`deserialize_project` in ProjectMenuActions.gd); reconcile-on-load floor. `test_project_identity` 23/23.
- **P2 ref allocator + envelope** (`158d2ec2`): new `AnnotationRef` util (format/parse/sidecar+list scan). `ProjectIdentity.vend_ref()` (monotonic, never-reused), `stamp()` (idempotent), `is_implicit`/`mark_explicit()`, static `current()` w/ `_override` test seam. Stamp at BOTH create paths: `TextEditorAnnotationHost.add_annotation_v2` (UI+live-host) AND `MCPAnnotationTools._annotations_add` closed-file branch (codetools path). Reconcile-on-load in host `load_annotations` + closed-file add. Query `ref`/`ref_project` filters; new `minerva_annotations_resolve_ref`. test_project_identity 49/49; MCP wired tests pass.
- **P3 surface ref** (`454b1b02`): creation echo (`{id,ref,ref_project,echo:"Created C7 — main.gd:331 …"}`); new `minerva_annotations_index` (C1..Cn w/ location+summary+status, sorted, scans sidecar/editor/all-hosts, `ref_project` scope); dock model carries ref. test_mcp_annotation_tools 226/227 (1 pre-existing headless draw_string fail).
- **P4 chat bridge** (`1f8307d6`): new `AnnotationRefResolver` (Services/Annotations/) — `parse_refs` (word-bounded C<n>) + `resolve_for_chat(text, project_id)` → plain-text reference notes (current re-anchored code + intent + lifecycle/staleness). Wired into `ChatPane.create_prompt` via `InjectedNotes` (**STRINGS**, not ContextBlock dicts — providers fold string InjectedNotes into "Reference Information"; dicts are silently dropped). `test_annotation_ref_resolver` 12/12; full app boot clean.
- **Bug 019e9e351353 FIXED** (`2eaa294d`, docket→resolved): `minerva_plugin_open_panel` now opens `kind=html` (CEF) panels via `_open_plugin_panel_for_editor_item` (the File→New path); default-panel resolution kind-agnostic. So an agent CAN open the codetools code_graph panel via MCP now.
- **P5 Minerva-side prep DONE** (`25ceef39`): `EditorCodeEdit.preview_review_diff()/exit_review_diff()` (read-only colored diff; preview_diff untouched — autocoder dep) + MCP `minerva_editor_review_diff`/`_exit_review_diff`. DCR open question answered: preview_diff suffices, only read-only wrapper was missing.

**Docket:** DCR `019e9f602391` status=`implementing`. Child work_items: P1 `019e9f8bc4` done, P2 `019e9f9c7b` done, P3 `019e9fd4f9` done, P4 `019e9fe1ac` done, P5 `019e9fe873` in_progress (HITL pending). Bug `019e9e351353` resolved.

**CACHE/UID NOTE:** 3 new class_names (`ProjectIdentity`, `AnnotationRef`, `AnnotationRefResolver`) were registered MANUALLY in the gitignored `src/.godot/global_script_class_cache.cfg` for headless `--script` testing (a fresh `--script` run doesn't rescan; `--import`/`--editor --quit` didn't rewrite the cache). On the owner's next real editor open the cache + `.uid` files regenerate cleanly — no action needed, but if a headless run reports "Identifier ... not declared" for these, re-open the editor once.

### HITL RUNBOOK — verify the citeable-ref scenario end-to-end
Prereqs: launch Minerva (F5 in editor, so the regenerated cache/.uid are picked up); MCP reconnect; codetools installed (it's the v0.2.0 html panel — `minerva_plugin_remove codetools` then `minerva_plugin_install <dev manifest>` if needed, per session-4 notes).
1. **Open the html panel via MCP** (proves the bug fix): `minerva_plugin_open_panel {plugin_id:"codetools", panel_name:"code_graph"}` → code_graph tab opens (no more "not godot_scene" error).
2. **Core ref loop without the panel** (proves P1–P4): open a `.gd` file (`minerva_open_file`); add a comment via the native dock OR `minerva_annotations_add`/`minerva_text_editor_add_comment` → response carries `ref:"C1"` + `echo:"Created C1 — …"`. Run `minerva_annotations_index` → see C1 w/ location+summary+status. In **chat**, type a message citing `C1` ("let's rethink C1") → the LLM's context should include a "Reference Information" block with C1's current code + intent (P4). Edit the file, cite C1 again → block shows the NEW code (+ STALE flag if the anchor moved).
3. **Review-diff handoff** (proves P5): with a file open, `minerva_editor_review_diff {editor_name, diff:<unified diff>}` → colored read-only diff; `minerva_editor_exit_review_diff` restores editing.
4. **What to watch / likely HITL follow-ups (P5 visual + plugins repo):** (a) codetools panel `ui/code_graph.src.html` double-click should call `minerva_open_file` + `minerva_editor_review_diff` instead of the in-panel HTML diff (NOT yet wired — plugins repo); (b) render C<n> as a clickable chip in chat (MessageMarkdown BBCode `[meta]`) + the C<n> badge in AnnotationDockPane/panel (data present, rendering not done); (c) review-diff visual appearance; (d) demote the synthetic-changeset-doc discussion path to chat.

**NOT pushed** — owner said commit/run autonomously; awaiting go to push `development` (+6) → origin. The HiDPI/ffmpeg fixes (session 4, `5b606199`/`2afcaced`) are also still unpushed ahead of origin.

---

LATEST 2026-06-06 (session 4 — macOS laptop bring-up + CEF HiDPI fix + ffmpeg clean-launch fix + new design DCR). **Superseded as head-of-line by session 5 above; still current for the HiDPI/ffmpeg/laptop context.** On the macOS laptop:
- **Pulled**: plugins `main` -> `c3b23b6` (+ tag `codetools-v0.2.0`); Minerva `development` was at `44d3175b`, now **+2 commits -> `2afcaced`** (committed locally, NOT pushed).
- **Laptop is fully set up & at parity with the Linux desktop** (the old "LAPTOP RESUME" steps are DONE — don't redo). Rebuilt the gitignored codetools artifacts: PBS runtime bundle `macos-arm64` (21M), Go binary (smoke = 18 tools), html panels via `codetools/scripts/build-ui-panels.py` (`ui/code_graph.html` 313KB). Fixture: working-tree edit to `~/gitlab/ccsandbox/experiments/video-recorder-rust/scripts/main.gd` (added `_save_snapshot_png`) -> indexed `/tmp/vrr.db` (113 sym / 58 edges; venv = py3.11 + tree-sitter-gdscript) -> deployed to `codetools/code_visualizer.db`.
- **Plugin-reload gotcha**: `minerva_plugin_reload` reuses the CACHED manifest snapshot (was stale v0.1.0 godot_scene panel). To pick up the v0.2.0 `kind=html` panel you must `minerva_plugin_remove` then `minerva_plugin_install <dev manifest>`, then start. Open via **File -> New -> Code Graph** (html still can't open via MCP — bug `019e9e351353`).
- **CEF HiDPI FIX (committed, Minerva `5b606199`)**: html panels were soft/oversized at 1.88x UI scale. Fix = `patches/godot_cef/0002-hidpi-oversampling-scale.patch` (OSR buffer scale = pixel_scale x `viewport.get_oversampling()`; view_rect/screen_info use host-computed device scale; input device-scale = pixel-scale) + `CefWebViewEditor.gd` sets SubViewport oversampling = `content_scale_factor x display_scale` (reapplied on resize). Built macOS godot_cef via `scripts/build-godot-cef.sh`; HITL-verified crisp at parity. **Linux/Windows: rerun `scripts/build-godot-cef.sh` on those machines** (binding is cfg-aware; patch applies cross-platform). Memory `feedback_cef_panels_magnified_by_ui_scale`.
- **ffmpeg CLEAN-LAUNCH FIX (committed, Minerva `2afcaced`)**: Minerva errored at launch on a HOLLOW `libgdffmpeg` framework. RCA: `build-ffmpeg.sh` `needs_build()` globbed `-name 'libgdffmpeg*'` which matched the `.framework` DIRECTORY name, so a binary-less build read as "built". Fixed detection (check the real Mach-O binary + a dylib). Rebuilt ffmpeg — macOS source build is FAST (libs are vendored prebuilt in `thirdparty/`, only the wrapper compiles). macOS has NO prebuilt in the EIRTeam release (linux64/win64 only) so source build is required; Linux/Win get binaries via `build-extensions.sh` download. Memory `project_ffmpeg_macos_build`.
- **Shared-annotation store VERIFIED** (bug `019e9e5f8fb2` confirmed, comment 435): MCP-wrote a `text_comment` to a CLOSED file's sidecar (`ann_bb0984`) -> opened that file in the NATIVE editor -> same annotation loaded. The codetools panel composer + native code editor share one sidecar store.
- **NEW DESIGN DCR `019e9f6023917d4b89150cf6b8c9c4b0`** "Citeable annotation references (C<n>): core, project-scoped, chat-resolvable" — **design only, NO code**. Reframe (long owner dialogue): discussion lives in CHAT; comments are durable, anchored, **citeable knowledge tokens** (`C7`) the user cites in chat and the LLM resolves to current code + intent. Decisions: CORE feature (not codetools-private; reusable), namespace = per-Minerva-project keyed on a NEW `project_id` UUID, reuse the `text_comment` substrate unchanged. Implicit->explicit project handling is the crux (mint project_id at startup -> autosave to user:// scratch -> promote into .minproj on save -> reconcile-on-load). 5-phase plan; **P1 = core project identity** is the entry point. follow_up of `019e9e34d475`; blocks/reshapes `019e9e4930d8` (now its consumer); interaction-model decision in `019e9e34d475` comment 433. Memory `project_citeable_annotation_refs`.
- **The old 12-item codetools UX/functionality batch (in the "NEXT WORK" section far below) is largely SUBSUMED** by DCRs `019e9e34d475` (HTML/D3 UI) + `019e9f602391` (citeable refs). Treat it as historical context, not the active queue. **Active NEXT WORK = DCR `019e9f602391` P1.**
- **Submodules** `vendor/EIRTeam.FFmpeg` + `vendor/godot_cef` carry local patch/build dirt (gitignored binaries + applied patches) — expected; DO NOT commit `vendor/`. `Docs/minerva.dct` (minerva docket DB) also shows modified — leave it.

---

STATE: `DCR 019e7b6609 SHIPPED 2026-06-04 — Code Tools extraction COMPLETE. codetools-v0.2.0 published to the marketplace (all 3 targets: linux-x86_64/macos-universal/windows-x86_64; registry.json advertises it, URLs 302, registry-check green). Minerva core = notes/chat app (253 tools, no glob/grep/bash/cwd, no-bleed CI guard); becomes a coding agent only when codetools installed (18 tools + 3 install-seeded skills + code-visualizer panel + code-probe). P0-P4 all done incl. owner sign-off + Option C probe HITL. Repos: Minerva development; plugins main @ a77966e (codetools-v0.2.0 tag @ 314b3b6). NEXT WORK = the owner-confirmed codetools UX/functionality follow-up batch — **3 of 12 DONE** (`019e8e4317`, `019e93d8f1`, `019e93c4c4`), 9 remaining (UX cluster next: Code-Graph 019e8f2489/29a2/2282/8e4a26 + plugin-config 019e8af511->019e8a2709), listed in the "NEXT WORK" section below.

LATEST 2026-06-06 (session 3 — Code Graph panel rebuilt as HTML/D3 + comments-as-annotations) — **WIP, mid-HITL.** Owner pivoted the Code-Graph UX cluster from the GDScript panel to a self-contained **HTML/D3 (CEF) panel** (the GDScript port was a workaround for "no HTML render"; that's obsolete). Governing **DCR `019e9e34d475`** (codetools UI → HTML/D3, narrow-first). DONE + committed this session (plugins main + Minerva development — see commits below):
- **`ui/code_graph.html`** (built by `scripts/build-ui-panels.py` from `ui/code_graph.src.html` + inlined `ui/vendor/d3.v7.min.js` — CEF loads a file:// temp with no base URI so d3 MUST be inlined; ~313KB). Ported from code-magic `viz/graph.html`.
- Bridge: `window.minerva.call` (HTTP MCP, no size cap) for get_graph/get_diff/annotations_*; `window.__MINERVA_PANEL` (injected by core change) gives the panel its data_directory→db_path.
- **NARROW-FIRST** (owner: "3-pane = vertical phone"): ☰ hamburger → outline drawer; Graph/Diff toggle; inspector = slide-in detail; ResizeObserver on panel width. Graph legibility: forceCollide (no overlap) + seeded settle + freeze + labels.
- **Changeset overview** (AI-era, owner-approved "looks good"): files + ±LoC sorted by churn → drill to file diff; **breadcrumbs** (project › Changes › file); **hunk nav** (▲▼ change i/n) in the file diff; unchanged-context collapse.
- **Comments-as-annotations** (owner: comments must be referenceable as "C7" in chat, LLM-resolvable): codetools comments = core **`text_comment` annotations on the real source files** (document_path sidecars) + a synthetic changeset doc (`<data_dir>/.codetools/<project>.changeset`). Panel = display/edit (💬 composer, 💬C# badges, comments list). Shows in codetools diff + Minerva's native code-editor annotation pane (shared sidecar) + MCP. Round-trip MCP-verified (ann created on a closed file, persisted to sidecar, listable).
- **CORE Minerva changes (committed to development):** `CefWebViewEditor.gd`+`WebViewEditor.gd` inject `window.__MINERVA_PANEL`; `MCPAnnotationTools._get_registry` now also registers `AnnotationTextComment` so MCP/sidecar writes accept `text_comment` on files that aren't open (bug `019e9e5f8fb2`).
- **Worker:** `repo_path` added to `get_diff` artifact (panel builds abs source paths). **Packaging:** `codetools.yml` now `cp -r ui` (so html ships on marketplace installs — was binary-only).
- **VERIFIED (HITL):** graph renders/legible, changeset overview, diff-focus, breadcrumbs, hunk nav. **MCP-verified:** annotation round-trip. **NOT yet HITL'd:** the in-panel comment composer/badges + native-editor cross-check (owner left mid-test); graph SCOPING still whole-project.
- **OPEN (tasks/docket):** comments panel HITL (#27, work_item `019e9e4930d8`); **graph scope+breadcrumbs+labels** rock (`019e9e49245c`, deferred); remove dead `ui/code_graph/` GDScript (#23); update `test_codetools_panel_gate` → kind=html (#24); runtime_diagnostics panel (#21, work_item TBD); **no-MCP-path-to-open-html-panel** gap (bug `019e9e351353`, #26 — html panels only open via UI File→New). Earlier-shipped this initiative: get_diff/stale `019e9aa059`/`019e9aa093` (d51bea2); design DCRs `019e9aa0f8` edge-model, `019e9ab8422d` cache-coherence.
- **Nudges (session 3):** codetools/{cef-panel-substrate, minerva-annotation-substrate-for-plugins, text-comment-annotation-envelope, html-panel-no-mcp-open, panel-ui-deploy-and-ipc-allowlist}.

**LAPTOP RESUME (local-only state does NOT transfer — do these):**
1. Pull plugins `main` + Minerva `development`.
2. Rebuild (binary+bundle are gitignored): `cd ~/github/minerva-plugins && bash scripts/build-python-runtime-bundle.sh codetools linux-x86_64 && cd codetools && go build -o codetools-plugin .`; rebuild html: `python3 scripts/build-ui-panels.py`.
3. Fixture (`video-recorder-rust` working-tree edits are LOCAL to the desktop): on the laptop, make ANY working-tree edits to its `scripts/*.gd` to produce a changeset, then index → `python -m vendored.code_visualizer.analyzer.index <video-recorder-rust> --db /tmp/vrr.db --project video-recorder-rust` (needs a venv w/ tree-sitter-gdscript, cf §1). Point the panel at it: `cp /tmp/vrr.db ~/github/minerva-plugins/codetools/code_visualizer.db` (gitignored; rich-panel db backed up at `code_visualizer.db.richpanel-bak` on the DESKTOP only).
4. In Minerva: `minerva_plugin_remove codetools` then `minerva_plugin_install <dev manifest>` (def→html), start; (core changes are in the pulled source, so a normal launch loads them).
5. Open **File → New → Code Graph** (html panels can't open via MCP — bug 019e9e351353); HITL the comments.

LATEST 2026-06-05 (session 2 — diff-viz scenario + index coherence) — Began the UX cluster by standing up a REAL in-place test fixture: `~/gitlab/ccsandbox/experiments/video-recorder-rust` (a GDScript subdir of the ccsandbox repo; the code_visualizer indexer is GDScript-ONLY). Added a snapshot-to-PNG feature to its main.gd (uncommitted working-tree diff = standing fixture; baseline /tmp/vrr.db 111 sym/55 edges → 114/59). Diff-viz validation surfaced + FIXED two functionality bugs, committed+pushed plugins main `d51bea2`: **019e9aa059** get_diff was unscoped for a subdir project (whole-repo bleed + repo-root paths) → `git diff --relative` from repo_path; **019e9aa093** stale_check blind to uncommitted edits (last-commit hash) → `git hash-object` content hash on both index + check. Both RESOLVED (awaiting panel HITL → verified). 8 new integration tests (test_code_visualizer_git_scope.py), full worker suite 286 green. Two scenarios analysed (project topology: whole-repo/subdir/vendor/complete/incomplete; and a SOLID GOD-file-breaking LLM workflow) → exposed deeper design gaps now filed as DCRs: **019e9aa0f8** edge model (open-world + scoped resolution + data-coupling + decomposition analysis) and **019e9ab8422d** index cache coherence (no-prune reindex W1, reindex wipes descriptions W2, tags orphan W3, unstable line-encoded IDs W4, FTS divergence, new-file blindness). Nudges saved: codetools/{code-graph-ux-gaps, indexer-is-gdscript-only, get_diff-subdir-repo-bug, get_diff-relative-fix, index-cache-coherence-weak}. STILL the visual UX items (panel diff-wiring + splash/legibility/responsive) for the live HITL. Repos: plugins main `d51bea2`; Minerva development unchanged.

LATEST 2026-06-05 — codetools probe made FULLY AUTONOMOUS + live-verified ON MINERVA (plugins main a77966e). It now turns 'a warning somewhere' into 'res://File.gd:NNN, user_fixable' with NO human clicking. Shipped this session: dual-mode op=run (headless/editor-assist) + op=stop + editor-aware remove-probe (019e93d8f1 VERIFIED); rename .sightline->.codetools + codetools_probe addon (019e93c4c4 DONE); editor-assist no-DISPLAY/dead-editor fix (019e987e1d VERIFIED); parser catches unprefixed Godot diagnostics (019e988adc59); symbol-grep + file-grep resolution (named func / bare X.gd -> res://); DEBUGGER ERROR-TREE detail-row capture (file:line lives in <GDScript Source>File.gd:line child rows); on-demand open-scripts sweep (scan_open_scripts, frame state-machine, restores focus). Live HITL on Minerva auto-captured the await->MCPEditorTools.gd:344 + autocoder->AutocoderAdapter.gd:422; FIXED 2 real Minerva warnings root-cause (Minerva dev 36bf9a98): ce_size->_ce_size, removed redundant await. Probe then REMOVED from Minerva/src (repo clean). 241 worker tests. Durable findings in nudge (codetools/* editor-probe, debugger-tree, redeploy recipe). MINOR BUG: remove-probe eats a trailing blank line in project.godot for multi-plugin lists (cosmetic).

LATEST 2026-06-04 — dual-mode Godot diagnostics shipped (bug `019e93d8f1` → resolved, plugins main `1aebef4`): the codetools probe is no longer HITL-only. RCA found the "stale [editor_plugins] line" was NOT a parser bug — a live Godot editor rewrites project.godot back. Built: `inspect op=run` (mode=headless autonomous via `godot --headless`+stderr-parse → normalized `godot_diagnostics`; mode=editor-assist human-driven via probe scrape → same shape), `op=stop` (cross-platform editor detection + SIGTERM/SIGKILL), editor-aware `remove-probe` (`stop_editor` consent gate). **sightline DE-VENDORED** (first-party/editable; VENDORING.md carve-out — edit `vendored/sightline/` in place). 37 new worker tests (219 total green) + smoke + live `op=run` on voice-capture. Follow-ups filed under `019e93d8f1`: `019e9454a10d` docs/skill dual-mode revision, `019e9454a999` relocate sightline out of vendored/, `019e9454b22d` editor-assist live HITL (verified→ gate), `019e945618` mode=windowed/Xvfb. Reusable facts in nudge (`codetools/probe.*`).

Last updated 2026-06-04 (Linux desktop session) — dual-mode probe shipped; 2/12 batch done.

---

## NEXT WORK — codetools UX/functionality follow-up batch (owner-confirmed 2026-06-04)

The codetools initiative is DONE/shipped. Next: investigate + triage this batch of
12 follow-ups (filed during the codetools work) in the **minerva** docket. Owner
confirmed this exact set. Status NOT yet verified per item — first step is a
`docket_get` on each to confirm open/closed + priority, then plan.

**Docket-query gotchas (cost me two wrong reads — DON'T repeat):**
- The bulk `docket_query` returns ONLY `id`+`title`, and its status filter did NOT
  apply (closed items came back). Use per-item `docket_get` for status/type.
- IDs are mixed: ULID `019e…` (time-sortable) AND legacy manual keys like
  `DKT-####`. The `DKT-####` items are MARCH autocoder/codegen work in the minerva
  project (NOT misfiled, NOT recent, many closed) — they only sort to the top
  because `"DKT"` > digits. Ignore them for this batch. minerva prefix = `MNR`,
  docket project prefix = `DCK`; there is no "DKT" project.
- `docket_get <id>` defaults to the PRIMARY project (`docket`/DCK) and fuzzy-
  matches — always pass `project: minerva` for these.

**UX (6):**
- `019e8f2489` — Code Graph entry-point + index-on-demand + save/open durable graph (real-usage UX)
- `019e8f29a2` — Code Graph legibility (contrast, node overlap, zoom-to-fit, L3 AST)
- `019e8f2282` — Make the Code Graph panel responsive (adopt ResponsiveContainer; narrow/1-pane)
- `019e8e4a26` — Code Graph opens at a Level-0 splash (click-to-explore) — looks "empty"
- `019e8a2709` — CodeTools policy.json undiscoverable/uneditable on a binary install (move override to user-config; ties to generic plugin-config 019e8af5)
- `019e93c4c4` — Rename user-visible `.sightline`/`sightline_probe` → codetools name (adapter copy-seam)

**Functionality (6):**
- `019e8f8114` — codetools Go shim: bidirectional host-request client + wire bash → host.terminal.exec
- `019e8f710a` — TerminalNew.execute_command runs a PTY command but can't read exit code or timeout
- ✅ `019e8e4317` — get_graph project_name — **DONE** (code+test already present; confirmed 2026-06-04)
- `019e8af511` — Generic schema-driven plugin-config mechanism (plugins own settings; host renders)
- `019e89eb89` — host capability to open a file in the OS default app (preview/print) [W11]
- ✅ `019e93d8f1` — ~~remove-probe stale line~~ → **DONE 2026-06-04** as the DUAL-MODE PROBE feature (op=run headless/editor-assist + op=stop + editor-aware remove-probe; sightline de-vendored). plugins `1aebef4`; resolved (editor-assist HITL `019e9454b22d` gates verified)

---

> **RESUME HERE.** P1 + P2 + **P3 all DONE.** P3 (code-probe `019e7b867e`) shipped all 6 grandchildren: P3.1 vendor (`d8cd08f`), P3.2 wrapper — 3 tools `minerva_codetools_{explore,inspect,validate}`, plugin now **18 tools / 201 worker tests** (`fb562cb`), P3.3 X11 gate + `prepare`/`remove-probe` (`4fa6c13`), P3.4 remove core `src/addons/sightline_probe` (Minerva `0bfa445e`), P3.5 DRY (rubric scope-reversal, see DRY-debt `019e7b86ab` comment 417), P3.6 replay harness + schema guard + Option C runbook (`e40c996`).
>
> **Live HITL done 2026-06-04:** owner reconnected MCP; validated P2+P3 end-to-end in the running app — old core `minerva_bash`/`file_glob`/`file_grep`/`cwd` confirmed GONE; the 18 `minerva_codetools_*` tools work (grep/explore/inspect/bash exercised on real code); the **Code Graph panel opened and rendered** (133 symbols). Caught + fixed a real bug live: `glob '**/*.gd'` returned 0 — P2.1's `**/` regex missed top-level files → fixed to `(?:.*/)?`, re-verified live (plugins `e5a84d4`; DCR comment 419). **Still pending:** the full **Option C** probe-capture HITL (`codetools/docs/probe_capture_runbook.md`) — release-time gate, not blocking.
>
> **P4 (unify+marketplace `019e7b8699`) — only the gated release remains.** Done 2026-06-04:
> - **P4.2** (3 install-seeded skills `understand_code`/`navigate_edit`/`inspect_runtime`) ✅ — prior session.
> - **P4.3 unify/dep-staleness `019e90b5432b`** ✅ — confirmed router/envelope already coherent; added the first platform-wide `follow_ups` convention `envelope.follow_up(tool,reason,params)` (enforced in `validate()`); staleness signals: code-visualizer reads (`query`/`get_context`/`get_graph`) get a best-effort `_staleness_aware` decorator (cheap os.stat over the indexed file set, early-exit, follow_up→`stale_check`/`analyze`, opt-out `staleness:false`), and `inspect op=status` emits a follow_up→`prepare` when the probe isn't installed. +15 worker tests. plugins `0b64ec4`+`e6f9bc5`.
> - **DRY-debt `019e7b86ab`** ✅ (GATE D satisfied) — extracted `build_codetools_fixture()`+helpers into `src/test/marketplace_test_helpers.gd` (the comment-412 in-tree test dup); the fs/search convergence (comment 417) CLOSED as rubric-justified divergence (rg binary already shared; vendored is hermetic). Minerva `a28a3ac0`. Verified vs stashed-HEAD baseline (no regression).
> - **P4.4 combined workflows `019e90b54ff9`** ✅ — `codetools/docs/workflows.md` (understand→edit→verify loop + 3 recipes) + skill loop cross-references. plugins `af1a727`.
>
> **REMAINING: P4.5 release `019e90b566a4` — OWNER + HITL GATED. DO NOT auto-cut.** Preconditions: DRY closed (✅) + Option C live-Godot probe-capture HITL (`codetools/docs/probe_capture_runbook.md`, still pending human) + owner sign-off + Gate-D functionals green. Open follow-up: `019e8f811497` (Go host-request client).
>
> **Repos current & pushed:** minerva-plugins `main` @ `1aebef4` (codetools-v0.2.0 shipped + dual-mode probe); Minerva `development` (this pickup commit). Pull both before starting. (NOTE: the P4.5 release block above is historical — codetools-v0.2.0 is SHIPPED; see STATE + LATEST at top.)

---

## TL;DR

Active initiative: **extract code-intelligence out of Minerva core into one OPTIONAL marketplace plugin, `codetools`**, that turns Minerva into a coding agent only when installed. Governing DCR: `019e7b6609` (`minerva` docket). Canonical reference: docket kb `019e7f366d99` + memory `project_active_codetools_extraction.md`.

**P1 substrate is DONE** (`019e7b8650` closed 2026-06-03):
- **P0/P1.1/P1.2/P1.3** — clean baseline; plugin skeleton (Go shim + embedded CPython, cad pattern, `codetools-v0.1.0`); unified envelope `{status,summary,artifacts,evidence_handles,follow_ups,[error]}` + router; vendored code-visualizer (`code-magic` @ `9cc9403`) behind the router with real-fixture functionals.
- **P1.4** — code-visualizer ships as a `godot_scene` panel; **HITL render gate passed on Linux** (renders the real `rich-panel` graph, 133 symbols). Envelope `data`-field question RESOLVED (DCR comment 386: typed artifacts win, no `data` field).

P1.4 surfaced three **backlog follow-ups** (under the DCR, NOT gate blockers): real entry-point UX `019e8f2489`, responsive panel `019e8f2282`, visual legibility `019e8f29a2`.

---

## 0. P2 — extract file primitives (HARD removal) — ✅ COMPLETE 2026-06-03

Parent **P2 `019e7b8664` DONE**. All three grandchildren shipped this session; the per-grandchild detail below is HISTORICAL. Result: core boots 253 tools (was 257) with NO glob/grep/bash/cwd — those live only in the codetools plugin as `minerva_codetools_*`. No-bleed contract enforced (`test_codetools_no_bleed.gd` 10/10 + `scripts/check-no-codetools-bleed.sh` wired into build.yml). Landed: P2.1 plugins `1de5643`; P2.2 Minerva `8e39e5bc` + plugins `b62ce9c`; P2.3 Minerva `ee56eaf4`. Open follow-up `019e8f811497` (Go host-request client to wire bash→host.terminal.exec).

**Rubric-decided forks (this session, for the record):** (1) ActionNormalizer/PolicyEngine `minerva_bash`/`minerva_file_*` patterns KEPT — generic normalization heuristics, not registrations (no-bleed guard targets `_register_tool` only). (2) P2.2 split: core capability + tested dormant worker seam done now; the Go bidirectional host-request client (reusable infra codetools lacks) deferred to follow-up rather than ballooning P2.2. (3) rg = pinned BurntSushi 15.1.0 musl prebuilt, bundled via shared PBS script. (4) bash policy fail-safe = baseline deny-set always on, normal commands allowed when policy.json absent.

**Next:** P3 code-probe `019e7b867e`, P4 unify+marketplace `019e7b8699`, DRY-debt `019e7b86ab`. _(Historical P2 build detail follows.)_

### P2.1 `019e8f306e` — reimplement file primitives in the worker (FIRST)
Build glob / grep(via bundled `rg`) / bash / cwd in the worker `files/` subsystem (Python), routed through the P1.2 envelope + router. Tools become `minerva_codetools_*` (NOT `minerva_file_*`/`minerva_bash` — those die with core in P2.3). Behavior parity with the core impls (reference, don't port GDScript verbatim):
- glob (cf `src/Scripts/Services/CodeTools/GlobTool.gd`): `*`/`**`/`?`, exclude `.git`/`node_modules`/…, sorted, limit/truncate.
- grep (cf `GrepTool.gd`): regex, type filters, context lines, binary detection — **implement via a bundled ripgrep shipped in the PBS runtime bundle** (add to `build-python-runtime-bundle.sh`).
- cwd (cf `CwdTool.gd`): get/set with `~` expansion + validation (worker has a real chdir).
- bash (cf `BashTool.gd`+`Policy.gd`): policy deny-patterns (interim `policy.json` in `<plugin_data_dir>`, fail-safe), 120s timeout, ~30KB cap, merged stdout/stderr. Terminal-PTY routing is P2.2; headless subprocess is the baseline here.
DoD: no-stub functionals vs the real binary (smoke tool count +4); cold-Opus; worker unittests; regression green. Model: SONNET impl / OPUS review.

### P2.2 `019e8f3098` — host capability `host.terminal.exec` (SECOND)
Add an OPTIONAL Minerva-core host capability so a plugin's bash routes through the visible UI terminal PTY (same substrate as `minerva_terminal_*`), with a headless fallback when ungranted/headless. Sibling of `host.providers.chat`/`host.files.*`/`host.dialogs.*`/`host.notify`. Wire P2.1's bash to prefer it when granted. DoD: capability gated/granted; routes through terminal when granted; clean fallback; core fine without it; cold-Opus; regression green. Model: OPUS (design-bearing host API).

### P2.3 `019e8f30d2` — HARD-remove core file primitives + no-bleed guard (LAST)
Only after P2.1+P2.2 exist. REMOVE (inventory verified 2026-06-03):
- Delete `src/Scripts/Services/CodeTools/` (8 files, ~919 ln: Glob/Grep/Bash/Cwd/Read/Write/Edit/Policy.gd).
- Delete `src/Scripts/Services/MCP/Modules/MCPCodeTools.gd` (registers `minerva_file_glob`/`minerva_file_grep`/`minerva_bash`/`minerva_cwd`).
- Remove instantiation `MCPCodeTools.new(self),` at `MinervaMCPServer.gd:~109`.
- KEEP `minerva_doc_*` (`MCPDocTools.gd`) — separate, buffer-coupled.
- Move out the 5 file-primitive tests (`test_codetools_glob`/`_read`/`_edit_grep_bash`/`_cwd_write`/`_policy`); KEEP `test_codetools_panel_gate` + `test_marketplace_install_start_codetools`.
- Re-scope the shipped "File and Code Tools" skill (`master.dct` id `019d5c…0006`): drop the 4 file tools from `tool_deps`, keep `minerva_doc_*`; invalidate baseline-docket cache (author-minerva-skill workflow).
- `PolicyEngine.gd`/`ActionNormalizer.gd` pattern-match `minerva_bash`/`minerva_file_read` by name (rule patterns, not registrations) — decide keep-generic vs clean; update `test_policy_engine`/`test_tool_search_index`.
ADD the no-bleed contract (DCR comment 410): boundary test asserting core MCP registers NO `minerva_codetools_*`/`minerva_file_*`/`minerva_bash`/`minerva_cwd` + a CI guard.
DoD: core BOOTS + full regression green WITHOUT codetools; boundary test + CI guard green; `grep` of `src/` (outside tests) shows ZERO refs to CodeTools/Glob/Grep/Bash/Cwd/Write/Edit/Policy; cold-Opus. Model: SONNET impl / OPUS review.

### Durable decisions / debt (see docket)
- **No-bleed contract** (DCR comment 410): agent file *tools* live in the sidecar; only the *generic platform* stays in core. 5 clauses + boundary test + CI guard.
- **Generic schema-driven plugin-config mechanism** `019e8af5` (won the rubric); `019e8a27` (CodeTools policy UI) re-scoped onto it. Interim: codetools `policy.json` in `<plugin_data_dir>`, fails safe.
- **DRY-debt** `019e7b86ab` (gates P4): extract `build_codetools_fixture()` shared helper.

---

## 1. How to build / test codetools

- `godot` is on PATH (4.6.x). GDScript suite runs headless: `scripts/run-functional-tests.sh [--all]` → `godot --headless --path src --script test/<t>.gd`. **Run from the Minerva repo root** (`--path src` is relative).
- Marketplace functional: `src/test/test_marketplace_install_start_codetools.gd` (in `--all`). Builds the real binary, installs via the real `MarketplaceClient`+`PluginManager`, asserts the envelope. SKIPs without the plugins checkout / `go` / a bundle.
- **Embedded-bundle gotcha:** the Go binary embeds the worker at *bundle-build* time. After ANY worker `.py` change, rebuild the bundle or Tier-1 runs stale code: `cd ~/github/minerva-plugins && bash scripts/build-python-runtime-bundle.sh codetools <triple>` (PBS cached → ~3s; triples: `linux-x86_64`, `macos-arm64`, …). `261c6a7` makes the Go runtime self-heal (stamps bundle sha, re-extracts on mismatch). For `go test`/manual, `codetools/scripts/dev-make-placeholder-bundle.sh` compiles without a full bundle (Tier-3 system `python3`).
- Worker unit tests: `cd codetools/worker && python3 -m unittest discover -t . -s tests -p 'test_*.py'` (tree-sitter tests need the deps below).
- Go: `cd codetools && go build -o codetools-plugin . && go vet ./... && go test ./...`. Smoke (expect tools=11 today): `python3 scripts/smoke/mcp_smoke.py "$PWD/codetools/codetools-plugin"` — **smoke script is at the plugins REPO ROOT `scripts/smoke/`, not `codetools/scripts`.**
- **Offline indexing for the panel** (no LLM): `python3.12 -m venv /tmp/ctv && /tmp/ctv/bin/pip install "tree-sitter~=0.22" ~/github/minerva-plugins/codetools/worker/vendored/code_visualizer/vendor/tree-sitter-gdscript`; then `cd codetools/worker && PYTHONPATH=/tmp/ctv/lib/python3.12/site-packages /tmp/ctv/bin/python -m vendored.code_visualizer.analyzer.index <repo> --db /tmp/cg.db --project <name>`. **Panel reads `~/github/minerva-plugins/codetools/code_visualizer.db`** for an in-place install (NOT app_userdata — hint `019e8edf`; that db is gitignored).
- CI: `.github/workflows/codetools.yml` (binary-size floor 20MB; worker unittests on linux). Watch: `gh run watch <id> --exit-status`.

---

## 2. Discovery anchors (survive compaction)

- **DCR `019e7b6609`** (`minerva` docket) — design + decisions. Comment 34 = execution playbook/gates; 35 = skills + test decision; 36 = workflow/repo; 37/386 = envelope `data`-field (RESOLVED: typed artifacts, no `data`); **410 = file-access no-bleed contract (read before P2)**.
- **Docket kb `019e7f366d99`** (`minerva`, active) — canonical reference. Mirrors memory `project_active_codetools_extraction.md`.
- **Item map** (all in `minerva`): P0 `019e7b862f` ✅, **P1 `019e7b8650` ✅** (P1.1 `…86e4`, P1.2 `…86f2`, P1.3 `…870f`, P1.4 `…871b` all ✅). **P2 `019e7b8664` ← next** (P2.1 `019e8f306e`, P2.2 `019e8f3098`, P2.3 `019e8f30d2`). P3 `019e7b867e`, P4 `019e7b8699`, DRY-debt `019e7b86ab`, plugin-config `019e8af5`. P1.4 follow-ups: `019e8f2489`/`019e8f2282`/`019e8f29a2`. Hints: discovery map `019e7b8804`, repo+branch workflow `019e7b9196`, plus this session's `019e8b3a`/`019e8edf`/`019e8e43`/`019e8e4a`.
- Plugin API docs: `~/github/minerva-plugins/docs/PLUGIN_DEVELOPER_GUIDE.md` + `PLUGIN_API_COVERAGE.md`.

---

## 3. Build / version state (2026-06-03)

| Component | Version / commit | Notes |
|---|---|---|
| Minerva | `development` @ `a28a3ac0` (pushed) | P2 hard removal (253 tools) + P3.4 sightline_probe addon removed + DRY-debt test-helper extraction |
| minerva-plugins | `main` @ `af1a727` (pushed) | P2+P3+P4.2/P4.3/P4.4 + glob `**/` + inspect-schema fixes |
| **codetools plugin** | **`codetools-v0.1.0`** (released, all 3 targets) | optional, not bundled. smoke **tools=18** + 3 install-seeded skills (now loop-cross-referenced); 219 worker tests; no new tag yet (P4.5 will cut it) |
| CAD plugin | `cad-v0.1.2` | unaffected |
| Presentation | `presentation-v0.0.3` | prior work |

Known: Minerva `development` CI has a pre-existing, unrelated smoke-test failure (owner-confirmed). Not a regression from this work.

---

## 4. Hard rules

- Per-file `git add` only. No `-A` / `.`. No `--no-verify`. No `vendor/` touches. No force-push, no `git reset --hard`.
- Commit co-author trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Push authorization (this initiative):** owner authorized push-as-we-go 2026-05-31 — Minerva→`development`, minerva-plugins→`main`. No feature branches; commit straight to the integration branch.

---

## 5. First actions for next session

1. Read this file + the canonical kb `019e7f366d99`. Pull both repos. Read DCR comment 410 (no-bleed contract) before touching P2.
2. Start **P2.1 `019e8f306e`** — reimplement glob/grep(bundled rg)/bash/cwd in the worker `files/`, envelope-routed, `minerva_codetools_*`. Suggested: `/work-cycle` (SONNET impl + OPUS review). Build P2.1 then P2.2 BEFORE the P2.3 core removal.
3. Keep the three P1.4 follow-ups (`019e8f2489`/`019e8f2282`/`019e8f29a2`) in mind but they're backlog, not P2 blockers.
