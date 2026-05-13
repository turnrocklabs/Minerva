# Pickup — Scansort plugin T7 R9 (HITL pending)

Last updated: 2026-05-13 (post-compact, R9 WIP committed; awaiting in-app verification)

## Where I left off

Active workstream: **Scansort plugin DCR — T7 panel UI, Round 9** (`minerva:019e1cdc9a41710ab544180f6ddbcd2a`, in_progress).
Parent DCR: `minerva:019e1cdb451076ae8c344f6e6ec605e1`.

R9 added structured `model_spec` routing to `host.providers.chat` so plugins can target Core-action models (model-chat / TurnRock services) that the old name-string compare couldn't reach. Scansort's chrome bar gained a Model OptionButton next to the File menu, populated from the chat dropdown. Tests green (Layer-1: 188/0 across 4 suites). **WIP commits pushed; in-app HITL test still pending.**

## Commits (pushed; pull on laptop)

| Repo | Branch | HEAD | Subject |
|---|---|---|---|
| `~/github/Minerva` | `user/imran/experiments/swarm` | `f35f0bb1` | WIP: T7 R9 — broker model_spec + ChatPane.get_available_models |
| `~/github/plugins` | `main` | `4cd4245` | scansort: model_spec routing for classify (T7 R9) |

## HITL test plan (do this first on the laptop)

The currently-running Minerva booted before R9, so its in-memory broker still uses the old name-string compare and the running scansort binary still sends `model_id`. **Restart Minerva first, then:**

1. Plugin Manager → start scansort → open the panel.
2. Confirm chrome bar (above panel) shows **[drawer-icon File MenuButton] [Model OptionButton]** to the left of "Save All".
3. Click the Model OptionButton → pick a **model-chat** entry such as `Model Chat (qwen2.5-vl:7b)`. This is the case that was unrouteable before R9.
4. Open a vault → File → "Add Document…" → pick a small PDF/text → confirm ingest pipeline runs end-to-end.
5. **Pass criteria**: status panel reports a classification (e.g. "Classified: <category>"). No "Classification failed: host.providers.chat error: schema_validation_failed".
6. Sanity: change the chat panel's model selection → close/reopen scansort → confirm the chrome dropdown's default mirrors the new chat selection.

If pass → add a `done` comment on T7 docket and the round wraps. If fail → paste the error text into a new round.

## Latent bug fixed in R9 (background)

Scansort's `handle_classify_document` was passing `model_id: "<string>"` to `host.providers.chat`, but `CapabilityBroker._handle_host_providers_chat` validates `args.has("model")` strictly. So **every** classify call since the broker integration landed (T1 R2) was silently returning `schema_validation_failed`. The Rust handler now reads `model` (with `model_id` as deprecated alias) and the broker accepts both `model: String` and `model_spec: Dictionary` (spec wins when both present).

The structured spec mirrors `ProviderOptionButton.get_item_provider_spec()`:
- `{kind: "core_action", service_client_id, action_name}` — Core/model-chat actions.
- `{kind: "dynamic", model_id}` — model_id ≥ `SingletonObject.DYNAMIC_MODEL_ID_BASE` (10000).
- `{kind: "builtin", model_id}` — model_id is a key in `API_MODEL_PROVIDER_SCRIPTS`.

Empty spec `{}` is detected at the call site and not forwarded; the broker would otherwise reject with "unknown kind".

## Files touched (R9)

### Minerva (`~/github/Minerva`)
- `src/Scripts/Services/Plugins/CapabilityBroker.gd` — added `_CoreProvider` preload (~line 36-44), extended `_handle_host_providers_chat` (~line 1980-2260) with spec-resolution branch before the existing string-match path.
- `src/Scripts/UI/Views/ChatPane.gd` — added `get_available_models() -> Array` (~line 3573) next to the existing `get_active_model_descriptor()`.
- `src/test/test_host_capability_chat_spec.gd` (NEW) — 7 cases × multiple assertions = 18/0.
- `src/test/test_scansort_panel_smoke.gd` — Group M (M124–M130) for chrome OptionButton + spec routing + empty-spec guard. 120/0.

### Plugins (`~/github/plugins/scansort`)
- `src/main.rs` — `handle_classify_document` reads `model` (with `model_id` alias) and forwards `model_spec` when non-empty; tool schema declares both, deprecates `model_id`.
- `ui/ScansortPanel.gd` — `_model_dropdown` member added; `get_editor_actions()` now returns `[MenuButton, OptionButton]`; `_resolve_chat_model_for_classify()` returns `{model_spec}`; classify call site builds args with `model: "default"` and conditionally adds `model_spec`.
- `scansort-plugin` binary rebuilt + installed via `install -m 0755` (NOT `cp` — see nudge `running-plugin-binary-cp-fails-text-file-busy`).

## Cold-pickup checklist (laptop)

1. `git -C ~/github/Minerva fetch && git -C ~/github/Minerva checkout user/imran/experiments/swarm && git pull --ff-only`
2. `git -C ~/github/plugins fetch && git -C ~/github/plugins checkout main && git pull --ff-only`
3. **Rebuild the scansort plugin binary** on the laptop — the binary is gitignored, only source is in the repo:
   ```
   cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin
   ```
4. Smoke-check Layer-1:
   ```
   cd ~/github/Minerva
   timeout 120 godot --headless --path src --script test/test_scansort_panel_smoke.gd
   timeout 90 godot --headless --path src --script test/test_host_capability_chat_spec.gd
   ```
   Expect 120/0 and 18/0 respectively.
5. Run the HITL test plan above.
6. If pass: comment on `019e1cdc9a41710ab544180f6ddbcd2a` confirming and proceed to the next T7 round (or wrap T7 entirely — depends on remaining R9 followups vs. the T7 success bar).

## Open work after R9 confirms

R9 followups (filed in the T7 docket comment, deferred — not blocking):
- Add an integration test that captures `classify_args` on the live wire and asserts `model_spec` is forwarded.
- Half A reviewer note: T3 (core_action happy path) auto-passes when Core autoload is absent in headless. Add a Core stub or mark the test "human-required".
- `_dynamic_provider_map` access is a private SingletonObject reach; promote to a public predicate when convenient.

T7 outstanding rounds (none queued — R9 was scope-completing for the model-routing problem). Wrap T7 once HITL passes.

## Local workspace caveats (won't transfer to laptop)

The following pre-R9 working-tree changes were NOT committed and will NOT travel — re-do or re-enable on the laptop if needed:

- `src/project.godot` — `buses/default_bus_layout="uid://ceag6rfsoj1uq"` line added; `addons/sightline_probe/plugin.cfg` enabled.
- `src/addons/sightline_probe/` — untracked editor addon directory.
- `vendor/godot_cef` and `vendor/godot_wry` — submodule working-tree dirty markers (no committed changes; safe to ignore).
- `~/github/plugins/cad/...` and `~/github/plugins/presentation/presentation` — unrelated CAD/presentation work, untouched by R9.

Plus a stack of `.uid` files in `src/test/` that Godot auto-generates from .gd files when the editor opens the project — they'll regenerate on the laptop on first run. Not committing them keeps the diff clean.

## Key nudges saved this session (durable session-scoped)

Check these via `nudge query` before re-discovering:
- `minerva-plugin-platform/scansort-T7-R9-scope-spec-based-model-routing` — original R9 brief (kept for reference)
- `minerva-plugin-platform/scansort-classify-uses-wrong-broker-key-model_id-vs-model` — the latent bug R9 fixed
- `minerva-plugin-platform/core-provider-model-name-is-synthesized-display-string` — why string-compare routing fails for Core actions
- `minerva-plugin-platform/chatpane-current-model-accessor-via-provider-option-button` — accessor pattern
- `minerva-plugin-platform/running-plugin-binary-cp-fails-text-file-busy` — use `install`, not `cp`
- `minerva-plugin-platform/godot-filedialog-default-access-is-resources` — FileDialog UX gotcha
- `minerva-plugin-platform/scansort-tool-envelopes-tool_ok-doesnt-add-ok-key` — envelope non-uniformity audit
- `minerva-plugin-platform/scansort-verify-password-ok-overloaded-bug` — earlier R7/R8 fix
- `minerva-testing/panel-menu-introspection-via-member-not-path` — headless test pattern

## Constraints to carry forward

- Off-tree plugin scripts (under `~/github/plugins/`) must use `preload()` + base-class typing for cross-script types. No `class_name` references.
- Off-tree plugin `class_name` must start with `<canonical_prefix>_` (PluginDefinition validates at install).
- Plugin MCP tool names must be `minerva_<plugin_id>_*` (validated at manifest + runtime dispatch).
- CapabilityBroker dependencies use `const _Foo := preload(...)`, NOT class_name — headless test isolation.
- GDScript JSON round-trip turns ints into floats; coerce with `int(...)` for any `model_id`-shaped field.
- Plugin binary rebuild while Minerva is running: use `install -m 0755`, NOT `cp` (ETXTBSY).
- Layer-1 testing uses targeted SceneTree scripts; `godot --check-only` hangs on Minerva.

## Paused workstreams (orthogonal, not picking up)

- **Presentation plugin v2 MCP iteration** — plan `019df419ce567de0b7699b3be7b6c8b5`. Paused at end of buffer-canonical DCR.
- **CAD Phase B2** — blocked on bug `019dec49988b7091933371908d6bbb00` (callout annotation edge-tracking).
- **HITL gizmo polish** `019def28e6be7e358a7a80e33014e526` — orthogonal to MCP/plugin work.
