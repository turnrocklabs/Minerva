# HITL — DCR `019df57b`: Plugins ship skills (install-time skill seeding)

Walks the human-driven side of the DCR. Headless tests cover the data layer
and lifecycle logic (`test_plugin_skill_seeder.gd` 107/0,
`test_plugin_skill_record.gd` 43/0, `test_plugin_skill_seeding.gd` 36/0
round-trip). This doc covers the three UI surfaces that headless can't see:

1. **Install dialog** (T3) — `PluginSkillSeedDialog`
2. **Update prompt dialog** (T4) — `PluginSkillUpdateDialog`
3. **Picker integration** (T5) — `FocusedChatPopup` badges + filter
4. **Uninstall toast** (T6) — `PluginManagerPanel` status line

Plus an end-to-end walkthrough exercising all four.

---

## Prereqs

- A test plugin manifest with `skills[]` declared. The simplest is to take
  `~/github/plugins/test_paired_dsl/` (or any installed plugin) and add a
  `skills` array to its `manifest.json`. Example shape:

  ```json
  "skills": [
    {
      "id": "minerva_test_paired_dsl_echo_skill",
      "title": "Echo a message via test plugin",
      "summary": "Trivial test skill — echoes its input back.",
      "system_prompt": "You are an echo bot.",
      "outcome": "The user sees their message echoed.",
      "preconditions": "test_paired_dsl plugin is installed.",
      "steps": "1. Read input. 2. Echo verbatim.",
      "tool_deps": [],
      "target": "all"
    }
  ]
  ```

  (`tool_deps: []` makes the skill always-satisfied — easier baseline.)

- Restart Minerva so the install pipeline picks up the latest builds.

---

## 1. Install dialog (T3)

**Goal:** confirm the dialog appears, lists skills clearly, and accept/cancel
behave correctly.

1. Open Plugin Manager (`Plugins → Manage` or wherever it's surfaced).
2. Click **Install** and select the modified manifest.
3. Expected: a `ConfirmationDialog` titled "Install plugin skills?" appears
   listing each skill with title + summary + tool-dep count.
4. Click **Install skills**. Expected: status bar shows
   `Installed plugin '<id>'. Seeded 1 skill(s).`
5. Verify in a docket query (in the docket UI or via MCP):
   `filter: {type: skill, source: plugin:test_paired_dsl}` returns the new
   record with `customised: false`, non-empty `pristine_hash`,
   `pristine_content` containing the manifest entry verbatim.
6. Uninstall and re-install, this time clicking **Skip skills** in the
   dialog. Expected: status shows `Skills skipped (user declined)`. No
   record is created.

**What to flag:**
- Dialog text wraps badly or summaries are clipped.
- Wrong title in the listing.
- Tool-dep count looks wrong.
- Cancel button doesn't work (records get seeded anyway).

---

## 2. Picker integration (T5)

**Goal:** plugin badge renders, deprecated marker shows, unsatisfied skills
hide.

1. With the test plugin's skill seeded (from §1), open a Focused Chat:
   click "Focused Chat" in the chat pane header.
2. Available-skills list should show the new skill with `[from <plugin_id>]`
   appended after the title. Hover for tooltip — should say
   "Seeded by plugin '<plugin_id>'".
3. Edit the manifest's `skills[0].tool_deps` to add a non-existent tool
   (e.g. `"minerva_nonexistent_tool"`). Save manifest, then in Minerva run
   `minerva_plugin_install` again with `auto_confirm_skills: true` (or via
   Plugin Manager re-install) — this triggers reactivity which marks the
   skill as having unsatisfied deps.
4. Expected: skill disappears from FocusedChatPopup's available list.
5. To check the deprecated path: edit the manifest to **remove** the skill
   entry entirely, then re-install (T4 path). Expected: in the picker the
   skill now has a `[deprecated]` tag.

**What to flag:**
- Badge format awkward / hard to read.
- Tooltip doesn't appear or shows wrong text.
- Filter (unsatisfied hide) doesn't take effect immediately on the picker.
- Deprecated label confusing or missing.

---

## 3. Update prompt dialog (T4)

**Goal:** customised skills get the diff dialog on upstream change; pristine
ones update silently.

1. With the test skill seeded (clean state, customised=false), edit the
   manifest's `steps` field to a new value. Re-install through Plugin
   Manager. Expected: NO dialog (silent update). Status shows install
   succeeded; the docket record's `steps` reflects the new manifest.
2. Now edit the docket record manually (e.g. via the docket UI — add a
   custom note to `steps`). The record's `customised` should auto-flip to
   `true` (this happens through `PluginSkillRecord.apply_user_edit` if any
   UI uses it; if you're editing via raw `docket_update`, manually set
   `customised: true` first).
3. Edit the manifest's `steps` again. Re-install through Plugin Manager.
4. Expected: a dialog titled "Plugin update — review skill changes" appears
   showing your version vs upstream's new version (compact text preview).
5. Click **Keep my edits**. Expected: docket record still has your edits.
   Querying the record should show `pristine_content` updated to the new
   upstream version (so you can diff later) but `steps` unchanged.
6. Edit the manifest's `steps` once more. Re-install. Click **Apply update
   (overwrite my edits)**. Expected: docket record's `steps` matches the
   new manifest; `customised` stays `true` (your fork lineage is preserved).

**What to flag:**
- Diff preview unreadable / fields mislabeled.
- Wrong button labels (should be "Apply update" / "Keep my edits").
- Decline path overwrites edits anyway (regression).
- Accept path doesn't update.

---

## 4. Uninstall toast (T6)

**Goal:** post-uninstall status line surfaces what happened to the seeded
skills.

1. Setup: install the plugin with at least 2 skills (manifest has multiple
   `skills[]` entries). Edit one of them via docket UI so it becomes
   customised; leave the other pristine.
2. Click **Remove** in Plugin Manager.
3. Expected: status bar shows
   `Plugin removed. Removed 1 pristine skill(s), kept 1 customised skill(s).`
4. The customised skill remains in the docket as `source: user`,
   `pristine_hash: ""`, `pristine_content: {}`. Your edits are preserved.
5. Re-install the same plugin. The customised orphan is NOT auto-re-paired
   with the plugin — it stays `source: user`. The freshly-seeded record is a
   new record under `source: plugin:<id>`.

**What to flag:**
- Counts wrong.
- Toast text clipped / hard to read.
- Customised orphan got deleted (regression).
- Re-install produces duplicates.

---

## 5. End-to-end smoke

1. Install plugin v1 (1 skill, basic content).
2. Confirm install dialog → Install skills.
3. Open Focused Chat → see skill with `[from <plugin>]` badge.
4. Edit skill via docket UI (any field).
5. Bump plugin version to v2 with same skill content. Re-install.
   Expected: NO update dialog (hash matches), no churn.
6. Bump plugin version to v3 with `steps` changed. Re-install.
   Expected: update dialog appears (you're customised). Choose **Keep my edits**.
   Verify your edits are intact.
7. Bump plugin version to v4 with the skill removed. Re-install.
   Expected: skill marked deprecated; picker now shows `[deprecated]`.
8. Uninstall the plugin.
   Expected: customised skill converts to `source: user`; deprecated flag
   stays; pristine_hash cleared.
9. Open Focused Chat. The orphan should still appear; it now reads as a
   user skill (no `[from <plugin>]` badge), but `[deprecated]` may persist.

---

## Acceptance checklist (DCR criteria 1–8)

- [x] **#1** Manifest accepts `skills[]` array; validated at install time. — T1, `test_plugin_skills_manifest.gd` 35/0.
- [x] **#2** Each skill maps onto docket skill schema fields. — T2 + docket chore `019e0020200e`, `test_plugin_skill_record.gd` 43/0.
- [ ] **#3** Install dialog lists skills + asks for confirmation. — T3 dialog implemented; **HITL §1 above**.
- [ ] **#4** Seeded skills appear with "from <plugin>" badge. — T5 picker; **HITL §2 above**.
- [x] **#5** Re-install of same version is idempotent. — T3 + T4 deferral logic, `test_plugin_skill_seeder.gd::test_materialize_idempotent_on_same_hash`.
- [ ] **#6** `plugin_remove` cleans pristine, preserves forks. — T6 unseed; **HITL §4 above**.
- [x] **#7** Plugin update reconciles (silent / prompt / deprecate). — T4, `test_plugin_skill_seeder.gd::test_plan_*` + `test_apply_*`; **HITL §3 above** for the dialog.
- [x] **#8** Round-trip integration test. — `test_plugin_skill_seeding.gd` 36/0 covers all 6 phases programmatically.

Boxes marked `[ ]` are HITL gates — the headless tests cover the logic, but a
human needs to confirm the UI surface.
