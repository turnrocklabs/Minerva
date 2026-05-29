# Pickup

STATE: `Deck round-trip COMPLETE; presentation v0.0.2 shipped; ready for next iteration`

Last updated 2026-05-29.

---

## TL;DR

This session: (1) found and shipped **Bug 3** — `host.documents.patch_state` field name mismatch silently broke every `tab_name`-mode write tool in the presentation plugin; (2) completed the deck round-trip — the outline at `~/temp/llms_overview_outline.md` (22 slides) is now fully applied to `~/temp/llms_overview_v1.mdeck` and saved. **All 22 slides have correct titles + bodies.** The 3 new slides (Quantization, Why Minerva?, ChatGPT as a Provider) have 2 tiles each (title-bar + body) and need side+banner images pasted in via the UI when the user wants visual parity with the other 19 slides (which kept their original 4-tile layout).

---

## 0. What to do next session

The deck round-trip task is **done** — no immediate next action is queued. When the user resumes, possible threads:

1. **Continue outline edits → deck round-trip** with the same pattern. Outline file at `~/temp/llms_overview_outline.md`; deck file at `~/temp/llms_overview_v1.mdeck`. Just edit the outline, then ask Claude to re-apply diffs to the deck. Bug 3 is fixed so this is now a clean live-editor flow.
2. **Add images to the 3 new slides** (Quantization slide 5, Why Minerva? slide 16, ChatGPT as a Provider slide 18). User said earlier they'd paste those in via the UI — leave for them unless they ask.
3. **Bug 1 still open**: `minerva_list_editors` reports `type: "unknown"` for .mdeck plugin-scene editors. See §3.
4. **Presentation skill v0.0.3**: still not drafted into the plugin. Reproducible from prior transcripts if needed.

No artifacts in this session created a future obligation with a date attached, so no `/schedule` offer is appropriate.

---

## 1. Key files and Minerva tabs

| Where | Path / tab | What |
|---|---|---|
| On disk | `/Users/ipeerbhai/temp/llms_overview_v1.mdeck` | The deck, 22 slides, saved. Migrated schema + outline edits all applied. Backup at `.v1-original.bak`. |
| On disk | `/Users/ipeerbhai/temp/llms_overview_outline.md` | Markdown outline (22 slides, sequential 1-22, post-spelling-pass). Source of truth for future round-trips. |
| Minerva tab | `llms_overview_v1.mdeck` | Live deck editor. **In sync with disk** (`minerva_doc_save` ran at end of session). |
| Minerva tab | `llms outline` | Outline editor, in sync with the .md file. |

Nudge hints (TTL: session) — **may be stale next session, nudge is non-durable.**

---

## 2. What got fixed this session (don't redo)

### A. Bug 3 — `host.documents.patch_state` field name mismatch

**Symptom:** every `tab_name`-mode write tool in the presentation plugin (`modify_tile`, `set_slide_title`, `add_slide` to live editor, `remove_slide`, `move_slide`, etc.) failed with `schema_validation_failed`. `path`-mode writes were unaffected.

**Root cause:** Host (`CapabilityBroker._handle_host_documents_patch_state` at `CapabilityBroker.gd:903`) reads `args["json_patch"]`. Plugin Go side (`PatchBuilder.Send` at `presentation/main.go:497`) was sending `args["patch"]`. PatchBuilder tests were entirely client-side (`cannedCapResponse` mock returns success without inspecting wire payload), so the contract drift was invisible. Saved memory: [`feedback_patch_state_field_name.md`](../../../.claude/projects/-Users-ipeerbhai-github-Minerva/memory/feedback_patch_state_field_name.md).

**Fix:** one line in `presentation/main.go:497` (`"patch"` → `"json_patch"`), plus a wire-shape regression test in `TestPatchBuilder_ChainedAddRemove_DispatchesOnePatch` that asserts `json_patch` appears AND `patch` does not. Shipped as `presentation-v0.0.2` (plugins commit `2b44b59`, pushed to `imrans-lab/minerva-plugins:main` with user authorization). CI built all 4 platforms green; GitHub Release published; installed locally + restarted plugin + verified `modify_tile` via `tab_name` works.

Registry updated to point at v0.0.2 release URLs.

### B. Deck round-trip end-to-end

Outline at `~/temp/llms_overview_outline.md` (post-renumber + spelling pass) is fully applied to `~/temp/llms_overview_v1.mdeck`. Tool-call breakdown:

| Phase | What | Calls |
|---|---|---|
| 1 | Front (slides 0-4): 3 title renames + 4 body updates | 7 |
| 2 | Insert Quantization at position 5 (title-bar + body tiles) | 3 |
| 3 | Middle (slides 6-14): 8 body updates + Skill Ladder title rename | 11 |
| 4 | Back (slides 15-21): 3 reworks + 2 inserts (Why Minerva?, ChatGPT) + Polls rename | 17 |
| 5 | `minerva_doc_save` | 1 |

Final state: 22 slides, sequential 0-21, all titles match outline, bodies match outline. 19 original slides kept their image tiles (side panel + banner). 3 new slides have only title-bar + body tiles.

### C. Outline pass (earlier in session)

`~/temp/llms_overview_outline.md` had been: renumbered 1-22 (sequential, was 1-20 with two unnumbered slides and missing slide 8); spelling-corrected (`wrose`→`worse`, `let's`→`lets`, `Hundred`→`Hundreds`); style-normalized (lowercase bullet starts, `3d`→`3D`, `introduction`→`Introduction`, `focused Chat`→`focused chat` since it's a feature not a product noun).

---

## 3. Open issues (carried forward)

### Bug 1 — `minerva_list_editors` reports `type: "unknown"` for .mdeck

`minerva_presentation_list_open_decks` correctly reports `kind: "plugin_scene"`. But `minerva_list_editors` shows `type: "unknown"` for the same editor. Two mapping code paths exist. `singleton_object.gd:_editor_type_to_string` does handle `PLUGIN_SCENE`, so `minerva_list_editors` must use a different mapper. Diagnose by finding the implementation behind that MCP tool and adding a `PLUGIN_SCENE` branch.

Doesn't block daily work — every plugin tool call goes through `tab_name` lookup via `host.documents`, not editor-type detection.

### Followups still deferred

- `tarball-smoke` Linux MCP-fatal-filter regression — still failing each CI run (pre-existing)
- Windows verify+smoke gate not yet added (DCR `019e5ce2160f76d9868f7a000c41614b` item #4)
- `scripts/migrate_mdeck_to_blob_contract.gd` referenced by `slide_model.gd:validate_tile` but doesn't exist — file a follow-up to add it
- Presentation plugin skill (`presentation` v0.0.3 candidate): draft was lost when an unsaved buffer was discarded earlier this session; reproducible from prior transcripts. Defer until user asks.
- godot-cef.yml's `actions/upload-artifact` drops macOS framework binary symlinks; we bypass by building from source — file upstream issue when there's time

---

## 4. Build / version state

| Component | Version / commit | Notes |
|---|---|---|
| Minerva | `auto-build-20260529-002821` (commit `63b7baf5`) | User has this installed |
| CAD plugin | `cad-v0.1.2` | User installed via marketplace |
| Presentation plugin | **`presentation-v0.0.2`** ← BUMPED THIS SESSION | Bug 3 fix; commit `2b44b59` |

---

## 5. Hard rules (carried from prior session)

- Per-file `git add` only. No `-A` or `.`.
- No `--no-verify`. No `vendor/` touches.
- No force-push, no `git reset --hard`.
- Co-author trailer on commits: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`
- Minerva `development` push: autonomous-loop authorization carries.
- `imrans-lab/minerva-plugins` `main` push: per-instance user authorization REQUIRED. Re-ask before pushing.

---

## 6. First actions for next session

1. Read this file.
2. Confirm Minerva is connected to MCP (`minerva_presentation_list_open_decks`).
3. Ask the user what they want to work on — no immediate task is queued.
4. If they want more deck edits: edit `~/temp/llms_overview_outline.md`, then re-apply via `minerva_presentation_*` tools. Bug 3 is fixed so `tab_name`-mode works cleanly.
