# Pickup — scansort File→Close session-reset DCR

STATE: `READY_FOR_DCR_019e3d678fb873f8ae45515ee0c3b32d`

Last updated: 2026-05-18 (post compact; multi-vault chain closed; audit logs shipped; next mission: File→Close session reset)

## Mission for next session

**Autonomous cycle on DCR `019e3d678fb873f8ae45515ee0c3b32d`** — add a "Close" menu item to the scansort panel's File menu. Closes the entire session **in-memory only** (source + vaults + dirs), leaves the source manifest (`.scansort-state.json`) on disk so re-opening preserves processing history, leaves vault `.ssort` files intact, leaves rule library intact.

The DCR has full UX + implementation breakdown. Read it first:
```
docket_get id=019e3d678fb873f8ae45515ee0c3b32d
```

No open questions — user decided 2026-05-18 to do in-memory clear only.

## Cycle policy (carry-forward)

Each iter:
1. Snapshot library → `/tmp/lib_snapshot_iter.json`
2. Wipe state: `rm ~/temp/scansort-staging/.scansort-state.json` + any test vaults
3. Implement (sub-agent with worktree isolation, 25-30 turn budget, enumerated file list)
4. `cargo test` — green before continuing
5. **CRITICAL: rebuild + cp binary to entrypoint** (`cp target/release/scansort-plugin scansort-plugin`). See durable hint `019e3ca206867194bfc3a978fc32a96b` — the entrypoint is a manual copy, NOT a symlink. Skipping this means Minerva runs the OLD binary.
6. Restart Minerva, run R1 (baseline regression), then test the new Close behavior
7. Restore library, commit pickup.md, walk DCR through implementing → reviewing → shipped
8. 30-min cap, 3 fix attempts per bug, ALL bugs in ONE commit

## Validated paths

| What | Path | Notes |
|---|---|---|
| Source corpus | `/home/imran/temp/scansort-staging` | 7 PDFs |
| Test vault | `/home/imran/temp/test.ssort` | Created via create_vault; delete at cycle end |
| Library snapshot | `/tmp/lib_snapshot_iter.json` | Write at iter start; restore at iter end |
| Minerva log | `/tmp/minerva_<tag>.log` | nohup target |
| Window ID | `xdotool search --name "Minerva"` | Returns inner WID; export `DISPLAY=:1` first |
| Plugin entrypoint | `~/github/plugins/scansort/scansort-plugin` | Must be `cp`'d from target/release after every build |

## What just shipped this session

| Commit | What |
|---|---|
| plugins `80ddc7e` | B-fallback rule engine (DCR `019e3c91`) — multi-vault tax-year routing works |
| plugins `5b4d9db` | Persona-leak cleanup (CPA/Lawyer/Citizen → behavior-named) |
| plugins `91dcfed` | MCP process audit log (DCR `019e3ce0`) — audit_enabled + audit_path params on minerva_scansort_process |
| plugins `8348787` | Audit enrichment — vault path in resolved_path, doc_id=N in detail |
| plugins `fa4065e` | Audit format — FQN source path + RFC 3339 "Z" UTC timestamps |
| Minerva `5b4b1f48` | pickup.md — multi-vault SHIPPED, B-fallback + R1+S1 passing |
| Minerva `284298d9` | pickup.md — R2 background passes; chain closed |

**Tests:** plugins 305 lib + 4 manifest. **Plugins HEAD:** `fa4065e`. **Minerva HEAD:** `284298d9`.

## Important session hints from this session (find via nudge_query)

- `scansort/build_binary_install_step` (docket `019e3ca20686...`) — **CRITICAL**: cargo build writes to target/release; manifest entrypoint is `./scansort-plugin` — must cp manually
- `scansort/panel_file_menu_location` (nudge) — get_editor_actions ~line 2982, MenuButton ids 0/1/2/3/4/5/7/11/12/13
- `scansort/session_module_layout` (nudge) — session.rs thread-local pattern; reset() helper does NOT exist yet
- `scansort/condition_node_schema` (nudge) — rule conditions JSON shape
- `scansort/phase1_scoring_does_not_extract_fields` (nudge) — historical; B-fallback now runs stages-before-conditions
- `minerva-plugin-mcp/plugin_start_arg_name` (nudge) — `{"id": "..."}` not `{"plugin_id": "..."}`
- `minerva-mcp/close_editor_takes_name` (nudge) — `{"editor_name": "..."}` not `{"index": N}`
- `scansort/session_open_vault_doesnt_create` (nudge) — must create_vault before session_open_vault

## Hard rules (carry-forward)

- Per-file `git add` only. No `git add -A` / `git add .`.
- No `--no-verify`. No `--no-gpg-sign`.
- No `vendor/` touches.
- No `git reset --hard`, no destructive ops without explicit auth.
- No force-push.
- pkill target is `godot`, not `Minerva`.
- Source is read-only — scansort copies to destinations, never alters source.
- Rubric: reliability → durability → cost (S≤100, M 101-1000, L>1000) → debuggability → discoverable (weight last two heavily).

## Cold-start procedure for next session

1. `git -C ~/github/plugins log --oneline -5` — confirm `fa4065e` at tip
2. `git -C ~/github/Minerva log --oneline -3` — confirm `284298d9` at tip
3. Read this pickup.md
4. `docket_get id=019e3d678fb873f8ae45515ee0c3b32d` — read the full DCR (no open questions)
5. Verify binary install: `md5sum ~/github/plugins/scansort/scansort-plugin ~/github/plugins/scansort/target/release/scansort-plugin` — if they differ, cp first
6. Per cycle policy: snapshot library → wipe → sub-agent dispatch → review → cp binary → R1 + Close-action verification
