# Pickup

LATEST 2026-06-07 (session 6 — change JOURNAL + buffered file_* + bidirectional host client + side-by-side review widget + the panel→native review LOOP). **THIS IS HEAD-OF-LINE STATE.** Built autonomously on top of session 5's P1–P5. Everything is **LOCAL / NOT pushed**: Minerva `development` tip = **`1969ba78`**; plugins `main` tip = **`6e7d449`**.

**What shipped this session (all committed, machine-verified):**
- **Change JOURNAL v1** (work_item `019ea01719a2`; Minerva `b9f3871a`/`50bd3a3d`): `ChangeJournal.gd` + `TextLineDiff.gd` (Services/Documents/). Subscribes to `DocumentRegistry.buffer_created` → in-memory baseline-vs-current per path; `mark`/`changed_paths`/`diff_for`/`aligned_rows_for`; `attribute_next_edit_to("ai")` one-shot. MCP `minerva_journal_mark`/`changes`/`diff`. Captures edits through `DocumentBuffer.apply_edit` ONLY (doc_*/host.documents + the human editor) — raw `disk_write`/bash NOT captured by design. **LIVE HITL passed.** test_change_journal 14/14, test_text_line_diff 35/35.
- **Buffered file_* restored** (work_item `019ea035bb28`; Minerva `0b53321b`, plugins `51363d3`): the extraction had dropped read/write/edit. Re-added as a CORE buffered capability codetools RE-BRANDS (owner chose option A). `minerva_doc_write` gained `save`; `minerva_doc_edit` gained `replace_all`+`save`; `DiskAccess.write` mkdir -p. codetools `file_read`/`file_write`/`file_edit` are thin delegates → core `minerva_doc_*` (buffered→journaled→annotation-coherent), NOT raw disk.
- **Bidirectional Go host client** (work_item `019e8f811497` items 1–2; plugins `51363d3`+`3b33ef4`): `codetools/main.go` `hostClient.Call(capability,args)` emits `minerva/capability`, reads the correlated reply off the shared stdin scanner. **Parse the response id as float64** (Godot serializes JSON ids as `1.0` — was the "want 1 got 1.0" bug). First consumer = the file_* re-brand. REMAINING (open): wire bash → `host.terminal.exec` (items 3–5).
- **Side-by-side review widget** (work_item `019ea06a1413`; Minerva `584bb5be`→`1969ba78`): `SideBySideDiff.gd` (class_name) — Beyond-Compare two-pane diff: line tints + changed-WORD focus highlight, real per-side line numbers (string gutter), synced V+H scroll, hunk-nav toolbar "change i/N" ▲▼. Source-agnostic: `minerva_editor_review_journal(path)` (journal) OR `minerva_editor_review_content(path,before,after)` (git/generic). `EditorPane` tab handlers guarded with `is Editor`. test_side_by_side_diff 3/3.
- **The review LOOP wired + HITL-passed** (P5 `019e9fe873`; plugins `6e7d449`): code_graph HTML panel changeset → double-click file → `openNativeReview()` → `minerva_editor_review_content` → native SideBySideDiff. Owner: "the basic flow works!" Tested on the real **video-recorder-rust** bed.
- **T5 comment → Option B** (Minerva `1969ba78`): owner HITL'd the first T5 (`145b0162`) and flagged it inconsistent with the native annotation surface (bespoke dialog, no dock/gutter/list). Root cause: gap rows are inserted into the right buffer, so the right pane ≠ the real file, blocking a real host. FIX (net −8 LoC): the diff is a read-only lens; 💬 now opens/focuses the real editor tab and triggers the NATIVE add-comment flow (`Editor.begin_add_comment_at_line` → `_begin_add_comment_from_shortcut`; `EditorPane.focus_editor`) — same dock/gutter/list/C<n> as every comment. **AWAITS owner HITL of the reworked path.**

**RESUME HERE (session 7):** (1) HITL the reworked T5 — open code_graph → double-click main.gd → click an AFTER (right) line in the diff → 💬 Comment → the editor tab comes to front with the native dock add-comment input on that line → type → confirm C<n> shows in the dock + gutter and cites in chat. (2) Then: render C<n> as a clickable chat chip (P4 view-layer), P5c panel strip-down (delete dead openFileDiff/lcsDiff/composer), bash→host.terminal.exec. (3) **Push decision** — all session-5+6 commits are LOCAL on Minerva `development` and plugins `main`; owner has NOT yet approved a push.

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
