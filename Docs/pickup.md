# Pickup — W0 path A (widened): scansort panel-as-view-of-plugin-state

STATE: PHASE_2_CODE_WRITTEN_UNVERIFIED

Last updated: 2026-05-17 evening

Work item: `019e38d4635970f5b28c940c193350f3` (parent DCR `019e33a2ab2e7581bf0bdcbf5ddf0aeb`)

---

## STATE marker (READ THIS FIRST)

| State | Meaning |
|---|---|
| `PHASE_1_DONE` | Instrumentation + autonomous loop established. Plugin emit → broker → panel signal proven end-to-end via `/tmp/scansort-debug.log`. |
| `PHASE_2_CODE_WRITTEN_UNVERIFIED` | (current) No-vault render gates removed. `_bootstrap_panel_state_if_needed()` added. NOT yet screenshot-verified — restart Minerva and confirm panel renders source + destinations without opening a vault. |
| `PHASE_2_VERIFIED` | Phase 2 visually confirmed. Ready for Phase 3. |
| `PHASE_3_IN_PROGRESS` | Wiring MCP-drivable active vault via session state. |
| `PHASE_4_IN_PROGRESS` | Multi-panel sanity (open 2 panels, fire MCP, both refresh). |
| `PHASE_5_IN_PROGRESS` | Re-verify live status during Process All (per-file status bar). |
| `READY_FOR_HITL` | All phases code-complete + autonomously verified. Hand off for visual sign-off. |
| `SHIPPED` | Commits squashed/landed; PR merged; work_item transitioned to done. |

Update this marker at every phase boundary in the same commit that advances the work.

---

## Cold-start procedure

1. `git -C ~/github/plugins/scansort fetch` and `git checkout work-item/W0-path-a-live-status`
2. `git -C ~/github/Minerva fetch` and `git checkout work-item/W0-path-a-live-status`
3. Read this file in full.
4. Read the work_item + comments: `docket_get id=019e38d4635970f5b28c940c193350f3` then `docket_comment action=list item_id=019e38d4`.
5. Resume from the current STATE.

---

## Scope (as widened by user this session)

Original W0 was "live per-file status during Process All." Two scope widenings during HITL:

1. **MCP→panel push refresh.** MCP-driven mutations (set_source_dir, destination_add, …) must update an open panel in real time. (Discovered when MCP setup didn't appear in the visible panel.)
2. **MCP-drivable vault open + panel-as-view-of-plugin-state.** Even before any vault is opened, panel must reflect whatever state the plugin has. With 1+ scansort tabs open, MCP calls must drive all of them. (User's framing: "open the scansort panel UI, make MCP calls, and update the panel state accordingly.")

**Design choice:** Option A — all open panels share the same plugin state (session-scoped). Option B (per-panel vault + panel_id targeting) explicitly deferred.

---

## Phases

| Phase | What | Status |
|---|---|---|
| 1 | Instrumentation: `notify_state_changed` (plugin) + `_on_plugin_event` (panel), file log `/tmp/scansort-debug.log`, MCP `minerva_plugin_open_panel`, MCPServerConnection async-drain fix | ✅ DONE — emit → recv proven 16ms latency |
| 2 | Remove no-vault render gates so source + destination panes render whatever plugin state exists | 🟡 CODE WRITTEN, untested visually |
| 3 | MCP-drivable active vault via session state. New tool e.g. `minerva_scansort_session_set_active_vault`. Panel listens for `state_changed kind=vault`, pulls current from session_state, sets `_active_vault_path`, runs post-open refresh. Panel's UI vault-open button routes through the same MCP tool (single code path). | ⬜ |
| 4 | Multi-panel sanity. Open 2 panels via curl; fire one MCP call; verify both `[panel:<id>] recv` markers in log AND both screenshots reflect the change. | ⬜ |
| 5 | Re-verify per-file live status during Process All against `~/temp/scansort-vision-docs` (3 PDFs). | ⬜ |

---

## Autonomous loop (use this — no HITL until phase 5 or final)

```bash
# kill any prior run, reset logs
pkill -9 -f "godot.*--path.*Minerva" 2>/dev/null; sleep 2
: > /tmp/minerva.log && : > /tmp/scansort-debug.log

# start Minerva (visible window, off-corner to keep your screen usable)
nohup godot --path ~/github/Minerva/src --position 50,50 >>/tmp/minerva.log 2>&1 &
MINERVA_PID=$!
until grep -q "HTTP server started on port 9315" /tmp/minerva.log 2>/dev/null; do sleep 1; done

# start plugin + open panel (panel auto-bootstraps from plugin state in Phase 2+)
# Use claude's mcp__minerva__minerva_plugin_start id=scansort
# Then: curl -s -X POST http://localhost:9315/mcp -H 'Content-Type: application/json' \
#   -d '{"jsonrpc":"2.0","id":"x","method":"tools/call","params":{"name":"minerva_plugin_open_panel","arguments":{"plugin_id":"scansort"}}}'

# fire test MCP calls (e.g. set_source_dir, destination_add)
# tail /tmp/scansort-debug.log for emit + recv markers

# find Minerva window via Quartz
python3 -c "
from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionAll, kCGNullWindowID
for w in CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID):
    if w.get('kCGWindowOwnerPID') == $MINERVA_PID and w.get('kCGWindowBounds', {}).get('Width', 0) > 500:
        print(w.get('kCGWindowNumber')); break
"
# screencapture -l <id> -x /tmp/minerva-step.png ; then Read it

# cleanup
kill -9 $MINERVA_PID
```

Gotchas observed:
- Standalone-launched godot owner string is `'godot'` (lowercase). Editor-launched is `'Godot'`. Filter on PID, not owner name.
- Plugin reload doesn't re-parse GDScript classes. Restart Minerva after any GDScript change.
- After the user's editor runtime is killed, only `minerva_create_plugin_editor` (for `editor_items[]`) or my new `minerva_plugin_open_panel` (for `ui.panels[]`) can spawn tabs via MCP.

---

## Files changed this session (WIP committed)

| Repo | File | Why |
|---|---|---|
| scansort | `manifest.json` | Declare `state_changed` event (silences PluginEventBroker warning) |
| scansort | `src/main.rs` | `notify_state_changed`, tool→kind mapping, post-dispatch emission, debug file log |
| scansort | `ui/ScansortPanel.gd` | Live per-file status, per-rule tally, `_subscribe_plugin_events`, `_on_plugin_event`, `receive()` override, `_bootstrap_panel_state_if_needed`, no-vault refresh |
| Minerva | `src/Scripts/Services/MCP/MCPServerConnection.gd` | Connect `output_ready` signal; explicit `_drain_pending_async()` at end of `_stdio_request` (fixes notification-arrives-mid-request race) |
| Minerva | `src/Scripts/Services/Plugins/PluginMCPTools.gd` | New `minerva_plugin_open_panel` MCP tool |

---

## Hard rules (per `feedback_no_fcib`, `feedback_code_rubric`, work_item)

- Per-file `git add` only. No `git add -A` / `git add .`.
- No `--no-verify`. Hooks always run.
- No `--no-gpg-sign` or `-c commit.gpgsign=false`.
- No `vendor/` touches. (`vendor/EIRTeam.FFmpeg`, `vendor/godot_cef` show modified — leave them.)
- No `git reset --hard`, no destructive ops without explicit user authorization.
- No force-push. Ever.
- Rubric (in priority order): reliability → durability → cost (small ≤100 LoC) → readability → DRY → well-factored.

---

## Library rule set (for manual verification)

`tax, utility, sailboat, dog, pizza, boat` (per `minerva_scansort_library_list_rules` at session end yesterday). Photos rules have empty `copy_to`; doc rules (`tax`, `utility`) have `copy_to=["test"]`. Keep this set.

Test corpora:
- `~/temp/scansort-vision-sweep` — 3 photos (dog, pizza, sailboat)
- `~/temp/scansort-vision-docs` — 3 doc forms (boat, tax, utility)
- `~/temp/hitl_test.ssort` — test vault (from previous HITL)
- `~/temp/scansort-vision-out*` — output dirs (out, out2, out3, out4 — registered as destinations `test`, `test2`, `test3`, `test4`)

---

## Pickup question for next session

Before doing anything else, run the autonomous loop and confirm: with no vault opened, does the panel display the **destinations registry** entries (`test`, `test2`, `test3`, `test4`) and the **current source dir** files? Two screenshots — one immediately after `plugin_open_panel`, one after `set_source_dir` with a different path — should differ.

If yes → Phase 2 visually verified → transition STATE to `PHASE_2_VERIFIED` → start Phase 3.
If no → diagnose via `/tmp/scansort-debug.log` (is `recv state_changed` firing? is `_bootstrap_panel_state_if_needed` being called? does `_refresh_all_dest_trees` return without populating?). Add print() instrumentation as needed.
