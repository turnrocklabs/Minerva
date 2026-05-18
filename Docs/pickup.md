# Pickup — W0 path A (re-scoped): scansort foreground-mode visibility of MCP config

STATE: FOREGROUND_VISIBILITY_VERIFIED — REGRESSION_TESTS_NEXT

Last updated: 2026-05-18 (mission hit)

Work item: `019e38d4635970f5b28c940c193350f3` (parent DCR `019e33a2ab2e7581bf0bdcbf5ddf0aeb`)

## Status snapshot

**Mission achieved.** Panel reflects MCP-driven config for all three primitives — source pane, vaults pane, directories pane — verified visually in `/tmp/iter9-mission.png`. Zero STDIO timeouts under stress (3 back-to-back MCP mutations with cascading panel refreshes).

**Six bugs filed and resolved today (all under this work item):**

| ID | Title | Fix location |
|---|---|---|
| `019e3c18f602` | STDIO reentrancy race | Minerva `fcdeda02` (MCPServerConnection.gd) |
| `019e3c18d018` | Vaults pane gates on _open_vault_path | plugins `9e4dc6b` (scan_tree_area_provider.gd) |
| `019e3c18da01` | Panel ignores kind=vault | plugins `bf8f007` (ScansortPanel.gd) |
| `019e3c18e677` | session_open_* not bridged to dest_registry | plugins `4ab4382` + `2b02a84` (main.rs) |
| `019e3c1906e4` | session_open_directory empty input_schema | plugins `5abe2dd` (manifest.json) |
| `019e3c18ffef` | plugins.json cache stale (was: manifest doesn't declare) | DEFERRED — Minerva-side cleanup |

**What's deferred / next:**
- Regression test scaffolding (Layer 1+2+3 from the test plan discussed in chat). NOT written this session — manual iteration loop served as the verification harness. Next session priority.
- `019e3c18ffef` plugins.json cache staleness — Minerva-side fix, not blocking, cosmetic warning.
- Larger A2 cleanup (panel reads session_state directly, retire the bridges in main.rs that currently write to both stores).

**Cycle mission (in user's words):** "be able to see the input dir(s), output vault(s), and output dir(s) when asked to run in the foreground/visibly."

No design changes. Same MCP calls, same backend, same Option-A session-scoped state. The only deliverable is: when the panel is open and an LLM configures a run over MCP, the panel must reflect what got configured — input dir(s), active vault, output dir(s) — without the user touching anything.

"Background mode" = MCP calls with no panel open (today's behavior, unchanged).
"Foreground mode" = MCP calls with panel open → panel mirrors session state live.

Multi-panel "both update" is nice-to-have if time permits, not part of the success bar.

---

## STATE marker (READ THIS FIRST)

| State | Meaning |
|---|---|
| `READY_FOR_TEST_ITERATION` | Phase 1 instrumentation + Phase 2 no-vault rendering code already written and committed. Nothing has been visually verified yet. |
| `PHASE_2_VERIFIED` | Screenshot proven: with no vault active, panel renders source dir + destinations registry. |
| `PHASE_3_BUILDING` | Writing the MCP-drivable active-vault tool + panel listener. |
| `PHASE_3_VERIFIED` | Screenshot proven: `set_active_vault` over MCP visibly switches the panel's active-vault display. |
| `FOREGROUND_VISIBILITY_VERIFIED` | All three primitives (input dir, active vault, output dirs) verified end-to-end via MCP-driven screenshots. Cycle mission satisfied. |
| `FOREGROUND_VISIBILITY_VERIFIED — REGRESSION_TESTS_NEXT` | (current) Mission hit and committed; regression test scaffolding pending. |
| `REGRESSION_GUARDED` | Layer 1+2+3 regression tests landed and green; the mission cannot silently regress. |
| `READY_FOR_HITL` | Autonomous verification complete, ready for user visual sign-off. |
| `SHIPPED` | Commits landed on `user/imran/experiments/swarm` (Minerva) + `main` (plugins); work_item transitioned to done. |

Update this marker at every phase boundary in the same commit that advances the work.

---

## Cold-start procedure

1. `git -C ~/github/plugins/scansort fetch` and `git checkout work-item/W0-path-a-live-status`
2. `git -C ~/github/Minerva fetch` and `git checkout work-item/W0-path-a-live-status`
3. Read this file in full.
4. Read the work_item + comments: `docket_get id=019e38d4635970f5b28c940c193350f3` then `docket_comment action=list item_id=019e38d4`.
5. Resume from the current STATE.

---

## Scope (re-scoped 2026-05-18)

**In scope:** main pane only. Three MCP-driven primitives must be visible in an open panel:

1. **Input dir** — `set_source_dir` reflects in the source pane
2. **Active vault** — `set_active_vault` (new tool, Phase 3) reflects in the vault display
3. **Output dirs** — `destination_add`/`destination_remove` reflects in the destinations registry

**Out of scope this cycle (explicitly deferred):**
- Live per-file status during Process All (original W0 scope)
- Multi-panel sanity / "both update" verification — nice-to-have if time permits, not gating
- Option B (per-panel vault + `panel_id` targeting) — Option A confirmed: one session, all panels are views

**Design unchanged.** Same MCP tools, same backend, same session-scoped state. This cycle only adds the user's ability to *see* it happen.

---

## Phases (current cycle only)

| Phase | What | Status |
|---|---|---|
| 1 | Instrumentation: `notify_state_changed` (plugin) + `_on_plugin_event` (panel), file log `/tmp/scansort-debug.log`, MCP `minerva_plugin_open_panel`, MCPServerConnection async-drain fix | ✅ Code committed, broker→panel emit→recv proven 16ms in prior session |
| 2 | Remove no-vault render gates so source + destination panes render whatever plugin state exists | 🟡 Code committed, **not yet screenshot-verified** — gating step for `PHASE_2_VERIFIED` |
| 3 | MCP-drivable active vault via session state. New tool e.g. `minerva_scansort_session_set_active_vault`. Panel listens for `state_changed kind=vault`, pulls current from session_state, sets `_active_vault_path`, runs post-open refresh. Panel's UI vault-open button routes through the same MCP tool (single code path). | ⬜ To build after Phase 2 verifies |

**Out-of-scope phases (former plan, parked):**
- ~~Phase 4 — multi-panel sanity~~ → nice-to-have only
- ~~Phase 5 — per-file live status during Process All~~ → next cycle

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

# find Minerva window by PID (Linux/X11)
WID=$(xdotool search --pid $MINERVA_PID --onlyvisible --name . | head -1)
# capture (ffmpeg x11grab — scrot/ImageMagick/grim not present on this box)
ffmpeg -y -loglevel error -f x11grab -window_id $WID -frames:v 1 /tmp/minerva-step.png
# then Read /tmp/minerva-step.png

# cleanup
kill -9 $MINERVA_PID
```

Gotchas observed:
- Plugin reload doesn't re-parse GDScript classes. Restart Minerva after any GDScript change.
- After the user's editor runtime is killed, only `minerva_create_plugin_editor` (for `editor_items[]`) or my new `minerva_plugin_open_panel` (for `ui.panels[]`) can spawn tabs via MCP.
- Linux desktop has no scrot/ImageMagick/grim/gnome-screenshot/wmctrl. Use `xdotool search --pid` + `ffmpeg -f x11grab -window_id`. macOS Quartz/`screencapture` block from prior version preserved in git history if you switch hosts.

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

## Single test iteration (run BEFORE any `/goal`)

One manual pass through the autonomous-loop block. Goal is to validate the loop mechanics + Phase 2 code with eyes-on, then stop and chat with the user about what to automate.

### Validated desktop paths (use these verbatim)

| What | Path | Notes |
|---|---|---|
| Source corpus | `/home/imran/temp/scansort-staging/` | 7 PDFs, incl. `GrandmaLizzy_modelsheet.pdf` (vision-only). Use for `session_open_source`. |
| Iteration vault | `/home/imran/temp/iter_W0.ssort` | **Stable name across all iterations of this cycle.** Created on first Phase 3 iteration; deleted at end of every iteration that touched it (see Cleanup). |
| Destination dirs | `/home/imran/temp/scansort-test-dest/{boat,tax,utility}/` | Pre-existing, already contain classified output from May 17 HITL. Do not delete contents. |
| Window ID lookup | Godot PID (capture from launch); then `xdotool search --pid $PID --onlyvisible --name .` | Returns Minerva window ID for `xwd -id`. |

### Steps (execute once, then stop)

1. Run the autonomous-loop block above to launch Minerva headlessly + start the scansort plugin via MCP.
2. Open a panel via `minerva_plugin_open_panel { plugin_id: "scansort" }`.
3. Capture screenshot A → `/tmp/iter-A-fresh-panel.png`. Expected: source pane + destinations registry both render even though no vault is active.
4. Fire `minerva_scansort_session_open_source { label: "iter_W0_src", path: "/home/imran/temp/scansort-staging" }`.
5. Capture screenshot B → `/tmp/iter-B-after-source.png`. Expected: source pane lists the 7 PDFs in `scansort-staging`.
6. `cat /tmp/scansort-debug.log` for emit/recv markers — confirm `state_changed kind=source` round-trip.
7. Stop. Report findings (with screenshot paths) and chat with user about Phase 2 verification status, Phase 3 plan, and whether to wrap into a `/goal`.

### Cleanup (run only if iteration touched the iteration vault)

```bash
# Only if Phase 3+ ran the classifier or created the vault:
rm -f /home/imran/temp/iter_W0.ssort

# Always safe (idempotent):
pkill -9 -f "godot --path /home/imran/github/Minerva/src" 2>/dev/null
```

**Do NOT** touch `~/temp/hitl_test.ssort` (separate fixture from May 17 HITL) or `~/temp/scansort-test-dest/` contents (prior HITL classification output is reference material).

**Do not** advance the STATE marker on this iteration. The whole point is to learn what's actually broken or working before committing to an autonomous loop.

---

## `/goal` text (for future autonomous use, DO NOT INVOKE THIS CYCLE)

Once the single test iteration validates the mechanics, the user may choose to wrap the rest of the cycle in `/goal`. Draft text:

```
/goal Drive the scansort foreground-mode visibility cycle in /home/imran/github/Minerva/Docs/pickup.md to completion. Goal satisfied when the file contains a line exactly matching "STATE: FOREGROUND_VISIBILITY_VERIFIED" and no line matching "STATE: PHASE_" or "STATE: READY_FOR_TEST_ITERATION". Verification requires three screenshot artifacts at /tmp/iter-{source,vault,dest}.png each showing the panel reflecting the respective MCP-driven state change without HITL action. All hard rules in §"Hard rules" must hold for every commit. Stop after 80 total turns regardless of completion. Surface immediately on any condition in §"Stop conditions".
```

---

## Stop conditions (surface to user mid-cycle)

1. Single test iteration shows Phase 2 code is not working as written → fix-attempts cap at 3 then surface.
2. Any test fails after 3 fix attempts on the same test.
3. Cannot meet a phase's acceptance criterion without scope creep.
4. Plugin start / `plugin_open_panel` MCP call fails repeatedly — likely cache invalidation (see §"Carry-forward constraints" in earlier pickup; restart Minerva).
5. Screenshot capture fails for tooling reasons (no `xdotool`/`ffmpeg`) — surface and ask.
6. Plugin or broker emits an event the panel doesn't recognize → log it and surface.
7. Anything that would require touching `vendor/` to fix.
