# Pickup

STATE: `Presentation deck round-trip in progress; macOS pipeline + envelope contract + provider defaults all landed`

Last updated 2026-05-29.

---

## TL;DR

The macOS build saga from the previous pickup is **fully closed**. This session built on top of that with three deeper fixes (broker envelope, marketplace size cap, provider defaults), shipped CAD plugin v0.1.2, and is now in the middle of editing a presentation deck via MCP. The user has reviewed an outline doc extracted from a .mdeck file and asked for a "Quantization" slide inserted before slide 8. **Next session's job**: round-trip the outline back to the .mdeck via `minerva_presentation_*` tool calls.

---

## 0. What to do next session (resume here)

### Immediate action: add the Quantization slide

The user wants slide 8 to be a new "Quantization" slide inserted between current slide 7 ("Cost, Privacy, License") and what was slide 8 ("How Do I Know It's Lying?"). The outline at `/Users/ipeerbhai/temp/llms_overview_outline.md` already reflects the renumbered structure (slide 8 = Quantization, original 8-19 became 9-20).

Bullets the user specified for Quantization:
- Lets you run models in less VRAM
- Lowers quality the more you compress
- Modern 4-bit (aka Q4_K??) is the boundary between acceptable and high degradation

(The user wrote `Q4_K??` as their notation for "checking exact suffix" — common modern picks are `Q4_K_M` / `Q4_K_S`. Leave the `??` or ask.)

### How to do it via MCP

1. **Find the deck tab** — `minerva_presentation_list_open_decks` returns the live `tab_name`. Nudge has it cached as `minerva/deck.tab` = `llms_overview_v1.mdeck`.

2. **Insert slide at position 7** (0-indexed; "before current 8" = at index 7):
   ```
   minerva_presentation_add_slide
     tab_name: "llms_overview_v1.mdeck"
     position: 7
     title: "Quantization"
   ```

3. **Add the title-bar text tile** matching the deck's consistent template (every slide in the deck uses the same 4-tile layout — nudge has the geometry at `minerva/deck.template_pattern`):
   ```
   minerva_presentation_add_text_tile
     tab_name: "llms_overview_v1.mdeck"
     slide_index: 7
     x: 0.05, y: 0.13, w: 0.9, h: 0.1
     content: "[b][color=#1F2A2E]Quantization[/color][/b]"
     text_mode: "plain"
     auto_fit: true
   ```

4. **Add the body bullets tile**:
   ```
   minerva_presentation_add_text_tile
     tab_name: "llms_overview_v1.mdeck"
     slide_index: 7
     x: 0.05, y: 0.25, w: 0.5, h: 0.6
     content: "Lets you run models in less VRAM\nLowers quality the more you compress\nModern 4-bit (aka Q4_K??) is the boundary between acceptable and high degradation"
     text_mode: "bullet"
     auto_fit: true
   ```
   NOTE: `text_mode: bullet` requires NO leading `-` or `*` — the renderer adds the marker. Bullets are split on newlines.

5. **Verify** via `minerva_presentation_get_slide slide_index: 7` and `minerva_presentation_list_slides`.

6. The user has NOT asked to add side/banner images for the new slide. Leave those out; the user can paste them in via the panel UI later if they want visual parity.

7. **Save** via `minerva_doc_save editor_name: "llms_overview_v1.mdeck"`.

### After Quantization lands

The user may want more outline edits → round-trip again. The general pattern is: edit `/Users/ipeerbhai/temp/llms_overview_outline.md`, compute diff vs. current deck state, apply via `add_slide` / `add_text_tile` / `modify_tile` / `set_slide_title`. No mass `doc_write` on the .mdeck — every change is a typed tool call.

---

## 1. Key files and Minerva tabs

| Where | Path / tab | What |
|---|---|---|
| On disk | `/Users/ipeerbhai/temp/llms_overview_v1.mdeck` | The deck (58 MB JSON; 19 slides, will be 20 after Quantization). MIGRATED from version: "1.0" (float) + raw-base64 image src to version: 1 (int) + blob envelopes — backup at `.v1-original.bak`. |
| On disk | `/Users/ipeerbhai/temp/llms_overview_outline.md` | Markdown outline (v2 — Quantization inserted, slides renumbered). Source of truth for round-trip. |
| Minerva tab | `llms_overview_v1.mdeck` | Live deck editor. `minerva_list_editors` may show `type: "unknown"` (see Open Bug below) but `minerva_presentation_list_open_decks` confirms `kind: "plugin_scene"` and `plugin_id: "presentation"`. |
| Minerva tab | `llms outline` | Outline editor. Saved to disk in this session. |
| On disk only | `/Users/ipeerbhai/temp/presentation_skill_draft.md` | EMPTY (buffer was never path-saved before reload). The draft text is in the prior conversation transcript if needed for restoring; not blocking. |
| Skill code on disk | `~/github/minerva-plugins/presentation/manifest.json` | Has NO `skills` array. The draft we wrote is reproducible from the conversation — defer until after deck work. |

Nudge hints set (TTL: session):
- `minerva/deck.path`, `minerva/deck.tab`
- `minerva/outline.path`, `minerva/outline.tab`
- `minerva/deck.template_pattern` — full geometry of the 4-tile slide template
- `minerva/next.action` — round-trip plan

---

## 2. What got fixed this session (don't redo)

### A. macOS build pipeline — fully green

All iter 11-13.1 changes from previous pickup are landed and verified:
- `[libraries] macos` patched to `bin/.../Godot CEF.framework/libgdcef.dylib` (per CFBundleExecutable)
- `[dependencies] macos` stripped from `godot_cef.gdextension`
- Manual rsync of CEF framework + helper into `Contents/Frameworks/addons/.../`
- EIRTeam.FFmpeg built from source on macOS arm64 with `actions/cache@v4` keyed on submodule SHA
- macOS export uses ditto packaging with `--keepParent` so the .app wrapper stays intact in the zip
- `codesign --force --deep --sign -` after bundling; release-body docs `xattr -dr` instruction (BEFORE first launch)
- macOS upload step now ships `Minerva-macOS.zip` containing a single `Minerva.app` (was leaking `minerva-launch.log`)

Latest macOS build: **`auto-build-20260529-002821`** (commit `63b7baf5`). This is the build the user has installed locally.

### B. Plugin marketplace fixes

- **Size cap** — `MarketplaceClient.gd:DOWNLOAD_MAX_BODY_BYTES` raised 100 MiB → 2 GiB (CAD tarball is 309 MB); timeout 60s → 600s; registry caps split into separate constants
- **Human-readable errors** — `MarketplaceClient.format_install_error(result)` decodes HTTPRequest.RESULT_* enum + HTTP status codes into friendly cause + URL + targeted hint; `MarketplaceBrowseDialog.gd` uses it
- These fixes are in `auto-build-20260529-002821` and earlier

### C. Broker envelope contract restored — Bug 2

`PluginErrors.gd:success(result)` reverted to wrap `{success: true, result: payload}`. A previous "vestigial" comment claimed the wrap was unnecessary; that change broke three consumers silently:
- `CapabilityBroker._audit_dispatch` logged every successful dispatch as `capability_failed reason=unknown`
- `PluginToolRegistry.handle_tool_call` logged every successful capability call as `policy_deny`
- Outbound plugin `callCapability` calls received bare dict, unmarshaled into Go struct, got `Success=false` with empty error

After this fix `minerva_presentation_list_open_decks` works correctly (returns the live deck), the audit log is honest, and downstream effects clear.

### D. Provider defaults — disabled on fresh install

`singleton_object.gd:_init_enabled_providers()` now starts `_enabled_providers[provider] = false`; `is_provider_enabled` fallback default also `false`. Existing users with a saved `[EnabledProviders]` config section keep their preferences. `_plugin_allowed_providers` stays permissive (separate concern).

### E. CAD plugin v0.1.2 released

`imrans-lab/minerva-plugins:cad-v0.1.2`. Bumped `cad.evaluate` timeout 30s → 90s in `CADPanel.gd` to cover macOS ARM cold-start (Python module imports + codesign cache + dyld first-load + OCCT static-init can exceed 30s). Also dropped phantom `linux-arm64` registry URL (build was never published).

### F. Deck migration

`/Users/ipeerbhai/temp/llms_overview_v1.mdeck`:
- `version: 1.0` (float) → `1` (int) per slide_model.gd's `SCHEMA_VERSION`
- Removed top-level `file_path` key (not in schema)
- All 38 image tile `src: <bare base64>` wrapped as `{__blob__: true, content_type: <sniffed>, bytes: <base64>}`
- Backup at `~/temp/llms_overview_v1.mdeck.v1-original.bak`

Note: `slide_model.gd:validate_tile` references `scripts/migrate_mdeck_to_blob_contract.gd` but that file doesn't exist in the plugin repo. Our migration was inline Python. Worth filing a follow-up to add the canonical migration script.

---

## 3. Open issues

### Bug 1 — `minerva_list_editors` reports `type: "unknown"` for the .mdeck tab

`minerva_presentation_list_open_decks` correctly reports `kind: "plugin_scene"`. But `minerva_list_editors` shows `type: "unknown"` for the same editor. Two different code paths, two different views of the same editor. Probably a normalizer somewhere that doesn't have a case for `PLUGIN_SCENE` (the `_editor_type_to_string` function in `singleton_object.gd:1660+` does handle it as `"PLUGIN_SCENE"`, so `minerva_list_editors` must use a different mapper).

This doesn't block the deck work — every plugin tool call uses `tab_name` and reads through `host.documents` which correctly identifies the editor. But the user noticed it, and we should diagnose. Search for the implementation behind `minerva_list_editors` tool and find where it derives the `type` field; add a `PLUGIN_SCENE` case (or lowercase the existing string).

### Followups deferred from this session

- `tarball-smoke` job still failing on every CI run (Linux MCP-fatal-filter regression; pre-existing)
- Windows verify+smoke gate not yet added (DCR `019e5ce2160f76d9868f7a000c41614b` item #4)
- EIRTeam.FFmpeg upstream has no macOS .framework — we build from source; opening a PR with their autobuild flow would help everyone
- godot-cef.yml's `actions/upload-artifact` drops macOS framework binary symlinks; we bypass by building from source
- Add `scripts/migrate_mdeck_to_blob_contract.gd` to the presentation plugin so the validator's error message points at a real script
- Presentation plugin needs a `skills` array — draft was in `/Users/ipeerbhai/temp/presentation_skill_draft.md` but it was an unsaved buffer and is now empty. Reproducible from conversation if user wants it shipped as v0.0.3 after deck work concludes.

---

## 4. Build / version state

| Component | Version / commit | Notes |
|---|---|---|
| Minerva | `auto-build-20260529-002821` (commit `63b7baf5`) | User has this installed |
| CAD plugin | `cad-v0.1.2` | User installed via marketplace |
| Presentation plugin | `presentation-v0.0.1` | User installed via marketplace; no skills yet |

---

## 5. Hard rules (carried from prior session)

- Per-file `git add` only. No `-A` or `.`.
- No `--no-verify`. No `vendor/` touches.
- No force-push, no `git reset --hard`.
- Co-author trailer on commits.
- Minerva `development` push: autonomous-loop authorization carries.
- `imrans-lab/minerva-plugins` `main` push: per-instance user authorization REQUIRED. Re-ask before pushing.

---

## 6. First actions for next session

1. Read this file.
2. Confirm Minerva tab is still open: call `minerva_presentation_list_open_decks`. If empty, the user closed the deck — ask them to reopen `/Users/ipeerbhai/temp/llms_overview_v1.mdeck`.
3. Execute the Quantization-slide insertion per §0.
4. Save via `minerva_doc_save editor_name: "llms_overview_v1.mdeck"`.
5. Confirm slide order via `minerva_presentation_list_slides`; show the user the resulting titles.
6. Wait for the user's next outline edit. Pattern repeats.
