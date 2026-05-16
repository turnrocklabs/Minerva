# Pickup — Path-free agent surface DCR HITL: GREEN. Next up: B8 (doc_type normalization)

Last updated: 2026-05-16 (end of session, HITL validated end-to-end across 3 models)

## TL;DR for cold pickup

- **DCR `019e2cc988ec` HITL is GREEN.** Process pipeline runs end-to-end with the path-free agent surface: session_open_vault + session_open_source + library rule + `process(model_spec={kind:'core_action', service_client_id:'model-chat', action_name:'<model>'})`. Documents land in vault with correct classification, confidence, issuer, date, AND renamed display_name from the rule's rename_pattern.
- **Six broker/plugin bugs surfaced and fixed during HITL** (see "Bugs resolved this session" below). Each was small, scoped, and validated by re-running the unchanged scenario.
- **Next pickup: bug `019e2ff19967` (doc_type normalization)** — same rule, same docs, three different display_names across gemma4:e4b / gemma4:26b / qwen2.5vl:7b. This is the B8-class enhancement called out earlier.
- B6 (Rules Editor dialog retarget at library) is still backlog — not addressed this session.

## What ran this session — five HITL iterations with full observe→file→discuss→fix discipline

| Iter | Symptom | Root cause | Fix landed |
|---|---|---|---|
| 1 | `provider_disabled` 'turnrock' even though chat UI uses it freely | `is_provider_enabled` is a menu-filter in UI, accidentally an access gate at broker; chat UI bypasses entirely | **Option 4 minimal** — new `is_provider_allowed_for_plugins` flag in singleton_object.gd (defaults true); CapabilityBroker.gd:2275 swapped to use it |
| 2 | Server: 'GPU dispatch error: dictionary update sequence element #0 has length 1; 2 is required' | Broker called `provider.generate_content(prompt, ...)` with raw `ChatHistoryItem` objects; chat UI does `provider.Format(item)` first | **Fix A** — added Format() bridge after ChatHistoryItem construction in CapabilityBroker.gd, mirroring ChatPane.gd:442-445 |
| 3 | 'empty LLM response' from plugin | Broker output was flat `{content, ...}` but plugin (and OpenAI standard) reads `choices[0].message.content` | Broker emits OpenAI shape `{choices:[{message:{role,content},finish_reason}], usage:{prompt,completion,total_tokens}, model, provider, cost_usd, free}` |
| 4 | STILL 'empty LLM response' (model returning valid JSON server-side) | `PluginErrors.success({...})` returned `{success:true, result:payload}` — JSON-RPC then wrapped again → double `result` nesting; plugin's `chat_response.get('choices')` found nothing | **Option 3** — `PluginErrors.success()` now returns payload directly. The `success: true` field was vestigial; error envelope keeps its own shape with `success: false` |
| 5 | GREEN — gemma4:e4b correctly classified 4/4 tax + 2/2 negatives | — | — |
| 6 | After GREEN, noticed `display_name == original_filename` for all moved docs (rename_pattern wasn't applied) | placement.rs `fan_out`'s vault branch never used `resolved_rename_pattern`; only the directory branch did. Asymmetric design — vault was treated as "database of bytes," rename was treated as "disk concern" | **Option A** — extracted `resolve_display_name()` + `build_template_context()` helpers in placement.rs; vault branch now mirrors directory branch's resolve+sanitise dance; `insert_document` gained optional `display_name` parameter, threaded through INSERT SQL |
| Bonus | Replacing an existing vault via UI deleted the old file but didn't create the new one | `vault_lifecycle::create_vault` had destructive error-path cleanup that fired when `db::connect_new` opened a pre-existing file and SCHEMA_SQL conflicted | Added remove_first guard at top of create_vault (Godot's SAVE_FILE dialog already confirms user intent) |
| Bonus | Source pane in panel stayed empty when source dir was added before vault was opened | `_source_provider` was instantiated only inside `_on_vault_opened_r2`; `_do_set_source_dir` skipped refresh if `_source_provider == null` | Lazy-create `_source_provider` in `_do_set_source_dir` |

## Model behavior comparison (warm state, 6 fixture PDFs)

| Model | Accuracy | Speed | doc_type quality | doc_date quality |
|---|---|---|---|---|
| **gemma4:e4b** | 2-4/4 (non-deterministic) | ~7s | sometimes generic | inconsistent |
| **gemma4:26b** | 4/4 @ conf 1.0 | ~60s | precise (`1099-DIV`, `W-2`) | missed 2 of 4 (W-2 + Morgan Stanley) → fallback to "unknown" |
| **qwen2.5vl:7b** | 4/4 @ conf 0.9 | ~28s | generic (`tax`, `tax report`) | populated on all 4 |

See docket insight `019e2ff1d098` for full picks/rationale.

## Bugs resolved this session

| ID | Title | Resolution |
|---|---|---|
| `019e2f2ed6bf` | Plugin broker chat gate rejects TURNROCK | Option 4 minimal |
| `019e2fc65558` | TurnRock model-chat Python dict error | Was broker bug (Format() missing) — fixed there |
| `019e2fd3ea42` | host.providers.chat flat response shape | Broker emits OpenAI shape |
| `019e2fd697207c9b` | PluginErrors.success double-wraps | Option 3 — drop the wrap |
| `019e2fe054e5` | process() places docs with original filenames | Option A |
| `019e2d82ca72` (pickup-doc reference) | process() can't pin model | handle_process accepts model + model_spec |

## Bugs filed this session, NOT fixed (queued)

| ID | Pri/Sev | Title |
|---|---|---|
| `019e2ff19967` | P3/Sev3 | doc_type token in rename_pattern not normalized (next pickup — B8) |
| (pickup-doc reference) `019e2d8018` | P3 | minerva_list_models omits core provider |

## Insights filed

- `019e2ff1d098` — Model selection tradeoffs (gemma vs qwen). Operational guidance for rule authors.

## Hints filed (session-scoped, durable to next conversation via memory)

- `nudge` scansort: error_envelope_chain_proven_useful
- `nudge` scansort: handler.extract_arguments_envelope
- `nudge` scansort: create_vault.destructive_cleanup_on_existing_path
- `nudge` minerva-broker: missing_provider_format_before_generate_content
- `nudge` minerva-broker: response_shape_mismatch_with_plugin_expectations
- `nudge` minerva-broker: success_envelope_double_result_wrapping
- `nudge` minerva-broker: provider_disabled.false_positive_for_turnrock
- `nudge` turnrock-model-chat: cold_start_2min_penalty
- `nudge` claude-code-env: bash.pkill_silently_fails
- `docket-hint` minerva-broker: chat_ui_bypasses_broker_enabled_check
- `docket-hint` minerva-broker: success_envelope_double_result_wrapping (also nudge)

## Files changed (uncommitted at session end — see WIP commits)

**Minerva (`user/imran/experiments/swarm`):**
- `src/Scripts/Models/singleton_object.gd` — new `_plugin_allowed_providers` dict + `is_provider_allowed_for_plugins` + `set_provider_allowed_for_plugins`
- `src/Scripts/Services/Plugins/CapabilityBroker.gd` — gate B keyless-provider exemption, null-service CoreProvider guard, Format() bridge before generate_content, OpenAI-shape response envelope, swap to `is_provider_allowed_for_plugins`
- `src/Scripts/Services/Plugins/PluginErrors.gd` — `success()` returns payload directly (drop `{success, result}` wrap)
- `src/test/test_host_capability_channel.gd` — updated assertions for new envelope shape
- `src/test/fixtures/capability_probe/capability_probe.py` — one-level less unwrap

**Plugins (`main`):**
- `scansort/manifest.json` — process tool description updated to mention model + model_spec args
- `scansort/src/main.rs` — handle_process accepts model + model_spec args; handle_insert_document accepts display_name; inputSchema for process + insert_document updated
- `scansort/src/process.rs` — model_spec forwarded to chat_args; error envelope detection for `{success:false, error_message, detail}`
- `scansort/src/documents.rs` — `insert_document` gained `display_name` parameter, INSERT SQL writes the column
- `scansort/src/reprocess.rs` — test caller updated for new signature
- `scansort/src/vault_lifecycle.rs` — `create_vault` now replaces existing file at target path
- `scansort/src/placement.rs` — extracted `resolve_display_name()` + `build_template_context()` helpers; vault branch of fan_out resolves rename_pattern and threads to insert_document
- `scansort/ui/ScansortPanel.gd` — lazy-create `_source_provider` in `_do_set_source_dir`

## Test baselines at session end

- Rust `cargo test --release` in `~/github/plugins/scansort`: **250/0**
- Panel smoke `godot --headless --path src --script test/test_scansort_panel_smoke.gd`: **433/0**
- (Minerva-side test for capability channel + scene panel broker may need re-running after the PluginErrors.success refactor — DCR follow-up)

## Cold-pickup checklist for next session

1. `git -C ~/github/Minerva fetch && git checkout user/imran/experiments/swarm && git pull --ff-only`
2. `git -C ~/github/plugins fetch && git checkout main && git pull --ff-only`
3. Verify plugin binary fresh:
   ```
   cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin
   ```
4. Smoke-check Layer-1:
   ```
   cd ~/github/Minerva && godot --headless --path src --script test/test_scansort_panel_smoke.gd   # expect 433/0
   cd ~/github/plugins/scansort && cargo test --release                                            # expect 250/0
   ```
5. Verify Claude Code tool catalogue (per `project_mcp_plugin_reload_doesnt_refresh_tools.md`):
   ```
   ToolSearch query="select:mcp__minerva__minerva_scansort_process" max_results=1
   ```
   Should return the process tool with model + model_spec args. If empty: full Minerva restart, then `/mcp` in CC.

6. Decide next step:
   - **B8 enhancement** (recommended): `019e2ff19967` — doc_type normalization for stable cross-model rename_pattern output. Three approaches listed in the bug. (c) "doc_type enum in rule schema + prompt constraint" is the most reliable but largest. (b) "post-resolution canonicalisation pass" is smallest. Use rubric.
   - **B6 (UI retarget)**: HITL phase for the Rules Editor dialog — move rules_editor_dialog.gd from path-driven CRUD to library_* calls. Now that the path-free flow is GREEN, the panel UI is the last surface still pointing at the legacy sidecar path.
   - **B3/B4 quality follow-up** (`019e2cfced`): clear test theater + by_rule counting fix + dead variant cleanup. Small work-cycle.

## Settled design decisions (do NOT re-litigate)

1. Session is multi-cardinality, label-addressed. LLM never sees paths.
2. Rules live in a global library at `<OS-app-data>/Minerva/Scansort/library.rules.json`.
3. `copy_to` carries user-chosen destination labels, not opaque IDs or paths.
4. Sidecar `<vault-stem>.rules.json` is portable export-only. Classifier reads only the library.
5. Unmatched files mark in `<source-dir>/.scansort-state.json`. Re-runs skip cleanly.
6. No rules ship — library starts empty.
7. Hot-reload via poll-on-use stat. No watcher thread.
8. No per-vault rule overrides in v1.
9. `{description}` capped at 60 chars via `chars().take(60)` (multi-byte safe).
10. Empty token values fall back to literal `"unknown"` (uniform across all 7 tokens).
11. process() accepts model + model_spec args (use model_spec={kind:'core_action', service_client_id:'model-chat', action_name:<model>} for explicit Core service routing).
12. Plugin chat access is gated by `is_provider_allowed_for_plugins` (defaults true), distinct from the menu-filter `is_provider_enabled`.
13. Broker emits OpenAI-shape chat responses; PluginErrors.success returns payload directly (no wrap).
14. Rename_pattern applies symmetrically to vault and directory destinations via `placement::resolve_display_name`.

## Build / test / operate commands (quick ref)

- Rust build: `cd ~/github/plugins/scansort && cargo build --release`
- Install binary: `install -m 0755 target/release/scansort-plugin scansort-plugin` (NEVER `cp` — ETXTBSY hazard for mmap'd .so even if not for ELF)
- Rust tests: `cargo test --release` (250/0)
- Panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (433/0)
- Launch Minerva (from CC): `godot --path /home/imran/github/Minerva/src` via Bash run_in_background=true
- Plugin reinstall (after manifest tool-schema change only):
  ```
  minerva_plugin_remove id=scansort
  minerva_plugin_install manifest_path=/home/imran/github/plugins/scansort/manifest.json
  minerva_plugin_start id=scansort
  ```
- For binary-only changes: `minerva_plugin_reload id=scansort` is enough.
- After GDScript or schema changes: full Minerva restart needed (no hot-reload).
- `pkill -f godot...` from CC silently fails (sandbox restriction) — ask user to close Minerva manually.

## Constraints to carry forward

- All testing goes through MCP tools or the panel UI — do not hand-write rules/vault files.
- Off-tree plugin GDScript: no `class_name`, use `preload()` + base-class typing.
- Plugin MCP tool names must be `minerva_<plugin_id>_*`.
- GDScript JSON round-trip turns ints into floats — coerce with `int(...)`.
- Plugin binary rebuild while Minerva runs: `install -m 0755`, not `cp`.
- **Any new MCP tool added to `main.rs` MUST also be added to `manifest.json` `tools` array.**
- model-chat has ~2 minute cold-start penalty per model when idle; first call may MCP-timeout while plugin keeps working (poll `.scansort-state.json` for progress).

## Paused / orthogonal workstreams

- Filing-engine DCR `019e2787` W12 (docs + cleanup) — still applicable; HITL no longer blocks.
- Presentation plugin v2 MCP iteration — plan `019df419ce567de0b7699b3be7b6c8b5`.
- CAD Phase B2 — blocked; `~/github/plugins/cad/` has uncommitted CAD changes — left as-is.
