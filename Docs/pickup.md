# Pickup

STATE: `AUTONOMOUS LOOP · MARKETPLACE SCANSORT INSTALL→START GREEN GATE`

Last updated 2026-05-27 02:00 UTC, just before compaction.

You are resuming inside an autonomous loop. The user is offline. Your
budget is bounded — read sections 0–2 fully before any action.

---

## 0. THE GOAL

The downloaded `Minerva-Linux.tar.gz` release artifact (from a
development-branch push to `turnrocklabs/Minerva`) must install scansort
from the marketplace and **successfully start it** — plugin state ==
`RUNNING`, MCP probe round-trip works.

Right now the **install succeeds** but `start_plugin` fails with
`ERR_CANT_CONNECT` ("Subprocess failed to start: Can't connect").
That's the bug to find and fix.

Critical asymmetry: scansort worked when side-loaded from the editor
(per memory `project_active_scansort_*`). So the bug is **specific to
the marketplace install path**, not to scansort or to start_plugin in
general.

---

## 1. STOP CONDITIONS (loop ends on any)

Loop terminates and reports to the user when ANY of these fires:

### Success
- **A green**: Layer-A test (headless install+start+probe) passes
  cleanly
- **B green**: Layer-B test (tarball roundtrip — xvfb-run the released
  `.tar.gz`, drive over HTTP MCP) passes

When BOTH A and B are green, exit loop with success report. The user
can then re-do HITL with confidence.

### Budget
- **Iteration cap**: 6 autonomous CI cycles. Each push to `development`
  that triggers a Build Project run counts as 1 iteration. Track in
  pickup.md edits per iteration.
- **Wall-clock cap**: 4 hours from loop start.
- **Stuck-on-judgment**: any architectural question worth the user's
  input. Examples that MUST pause:
  - "Should `_chmod_executable` move from MarketplaceClient into
    PluginDB.install?"
  - "Should we change the data_directory semantics?"
  - "Should marketplace tarballs include a `.permissions` manifest?"
  - Anything that touches more than one component or changes a
    cross-plugin contract.

Trivial fixes (typos, single-file edits within MarketplaceClient/
PluginManager that match an existing pattern, test additions) do NOT
pause.

Whichever cap fires first, write findings to a new
`Docs/pickup-loop-N.md`, transition this pickup back to
"AWAITING HITL", and report.

---

## 2. ORDER DISCIPLINE — A BEFORE B

**Do Layer A first.** It's the diagnostic loop and the highest-value
addition either way.

### Layer A — Headless install+start+probe test

Extend `src/test/test_marketplace_install_from_url.gd` (or add a new
sibling test) so the test also calls `plugin_manager.start_plugin()`
and `plugin_manager.stop_plugin()` after install, and asserts:
- install returned ok
- state == S_RUNNING after start
- `host.echo` probe round-trip works (proves MCP handshake completes)
- state == S_STOPPED after stop, no errors

Run via `scripts/run-functional-tests.sh` and `functional-tests` CI job
on every dev push. The test should REPRODUCE the current
`ERR_CANT_CONNECT` failure when run against the live scansort tarball.

Note: a scansort tarball needs to be reachable. The simplest fixture
path is to download the live scansort tarball from
`https://github.com/imrans-lab/minerva-plugins/releases/download/scansort-v0.0.0-pre/scansort-0.0.1-linux-x86_64.tar.gz`
at test setup time and serve it from a localhost http.server (same
pattern the existing test uses). Don't hardcode the binary content
into the test.

When Layer A is RED with the current failure → diagnose → fix → push.
When Layer A is GREEN → proceed to Layer B.

### Layer B — Tarball roundtrip

Add a new CI job (or workflow) that:
1. Resolves the latest `auto-build-*` release tag from
   `turnrocklabs/Minerva/releases/latest`
2. Downloads `Minerva-Linux.tar.gz`
3. Extracts to a tmp dir
4. `xvfb-run -a ./Minerva.x86_64 &` (background, with timeout)
5. Polls `http://127.0.0.1:9315/` until Minerva's MCP HTTP responds
6. Sends MCP tool calls to:
   - Install scansort via the marketplace flow
   - Start scansort
   - Read plugin status — assert RUNNING
   - Send `minerva_scansort_probe` — assert ok
7. Cleanup, kill the background process, report

Known risks for B:
- CEF init in headless / virtual display — may need `--disable-gpu`
  or other flags. Check what flags are accepted.
- Auth on MCP HTTP — may need a token. Check first.
- `xvfb-run` is usually preinstalled on `ubuntu-latest`, confirm.
- Test job needs `needs: create-release` so the release exists.

### Existing test (Layer A predecessor)

`src/test/test_marketplace_install_from_url.gd` exists with 3 tests
(happy path / 404 / sha mismatch). It stops at install — never starts
the plugin. Extending it is the natural place for Layer A.

---

## 3. KNOWN BUG STATE

### Symptom
After marketplace-installing scansort, clicking Reload (or Start) in
PluginManagerPanel shows ErrorDisplay popup: "Subprocess failed to
start: Can't connect". Source: `PluginManager.gd:566` →
`error_string(ERR_CANT_CONNECT)`.

### What we know
- Binary `/tmp/scansort-inspect/scansort-plugin` from the tarball
  runs fine standalone — exits 0, prints "scansort 0.0.1 starting".
- Tarball preserves `+x` (verified: `tar -tzvf` shows
  `-rwxr-xr-x`).
- `MarketplaceClient._chmod_executable()` at line 365 SHOULD chmod
  the entrypoint after install. May be silently failing — unverified.
- The install validation now passes thanks to `host.notify` cap
  added in commit `6fca1bb4`.
- The same scansort plugin works when side-loaded from the editor
  (memory `project_active_scansort_*`).

### Hypotheses ranked
1. **Working directory mismatch** — SubProcess might inherit a cwd
   that breaks the binary's data-directory expectations
2. **Path resolution** — `data_directory` from manifest path may not
   be globalized correctly in the user:// case
3. **chmod silently failed** — `OS.execute("chmod"...)` may be a
   no-op on Linux in some path
4. **SubProcess can't read the binary** — perms restored on extract
   but lost on `DirAccess.rename_absolute`
5. **MCP stdio handshake timeout** — the binary spawns but doesn't
   respond to initialize within timeout

### First diagnostic step on resume

Run Layer A test against scansort to REPRODUCE the failure in a
headless context with full debug output. The PluginManager
`push_error` lines + MCPServerConnection debug logs will surface the
actual failure mode. Don't fix anything until you have that signal.

---

## 4. WHERE EVERYTHING LIVES

```
~/github/Minerva/                                  (you are here)
  branch: development
  remote: origin → https://github.com/turnrocklabs/Minerva
  HEAD: 589f6ee4
  Recent:
    589f6ee4 PluginManagerPanel: surface lifecycle errors via ErrorDisplay/toast
    b1aca740 CI: re-enable auto-release on every development push
    c50fc1b3 CI: every development push builds; releases gated to workflow_dispatch
    6fca1bb4 Add host.notify capability — plugin → toast bridge
    653d5c8e DCR3: marketplace dialog — reuse existing ErrorDisplay/toast surfaces
```

Every push to `development` triggers Build Project. Every successful
build creates an `auto-build-<timestamp>` release with the Linux/Mac/
Windows tarballs.

Plugins repo: `imrans-lab/minerva-plugins` main branch.
- `registry.json` — manifest of manifests
- scansort release: `scansort-v0.0.0-pre` tag, tarball
  `scansort-0.0.1-linux-x86_64.tar.gz`

---

## 5. FILES TO TOUCH (likely)

For Layer A:
- `src/test/test_marketplace_install_from_url.gd` (extend or add
  sibling)
- `scripts/run-functional-tests.sh` (may need to register the test if
  it's a new file)
- Possibly `src/Scripts/Services/Plugins/MarketplaceClient.gd` (if
  diagnosis points here)
- Possibly `src/Scripts/Services/Plugins/PluginManager.gd` (if
  diagnosis points to start_plugin)

For Layer B:
- `.github/workflows/build.yml` — new job `tarball-smoke` that runs
  after `create-release`
- May need a new script `scripts/tarball-smoke.sh` if the inline
  shell gets too gnarly

---

## 6. HARD RULES (UNCHANGED — DO NOT VIOLATE)

- Per-file `git add` only — never `-A` or `.`.
- No `--no-verify`.
- No `vendor/` touches (vendor/godot_cef, vendor/godot_wry submodules
  are off-limits).
- No force-push, no `git reset --hard`, no push without explicit user
  consent — **EXCEPTION**: during this autonomous loop, you have
  pre-authorized consent to push commits to `development` as part of
  the iteration cycle. Do NOT push to `main`.
- Never `cp` over a mapped binary — use `install -m 755` (atomic).
- pkill target is `godot`, not `Minerva`.
- Co-author trailer on every commit:
  `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- Use MCP for state probes when possible, not filesystem reads.
  EXCEPTION: filesystem reads of `/home/imran/github/` and `/tmp/`
  are fine. Reads of `~/.local/share/godot/app_userdata/` would
  reveal the user's HITL state — generally avoid. The user has
  closed Minerva so the user-data dir is at-rest anyway.

---

## 7. PER-ITERATION CHECKLIST

Each iteration must:
1. State at start of iteration: "Iteration N of 6 — goal: <one
   sentence>"
2. Pre-flight: verify branch == `development`, working tree clean
   (except `Docs/minerva.dct` and `vendor/*` submodule pointers
   which are user state, leave alone)
3. Make minimal code change
4. Headless verify locally if possible (`scripts/run-functional-tests.sh`)
5. Per-file `git add` only
6. Commit with co-author trailer + concise message naming the
   iteration N
7. Push to `development`
8. Schedule wakeup OR poll the CI run
9. Read results — update this pickup.md with a one-line
   "Iteration N: <outcome>"
10. Decide: continue / stop on success / stop on budget

---

## 8. ITERATION LOG

(Each iteration appends a one-line summary here.)

| # | Date | Commit | Outcome |
|---|------|--------|---------|
| 0 | 2026-05-27 | 589f6ee4 | Starting state. PluginManagerPanel lifecycle UX shipped; scansort install OK but start fails ERR_CANT_CONNECT. |
| 1 | 2026-05-27 | 0c168ad6 | **Layer A GREEN.** New `test_marketplace_install_start_scansort.gd` reproduced the bug, fix identified + applied. Root cause: PluginManager.gd:498 only globalized `data_directory` when prefix=`res://`, leaving `user://plugins/<id>` virtual-path strings to be passed to SubProcess (fork+exec) — `FileAccess.file_exists` understood the scheme, kernel did not. Fix: unconditional `ProjectSettings.globalize_path()`. Functional suite 7/0 (`--all`), Layer A passes install+start+stop in <5s. CI: success. |
| 2 | 2026-05-27 | (this commit) | **Layer B added (untested-in-CI yet).** New MCP tool `minerva_plugin_marketplace_install` wraps `MarketplaceClient.install_from_url`. New CI job `tarball-smoke` in build.yml `needs: build-godot`, downloads Minerva-Linux-Build artifact, runs `scripts/tarball-smoke.sh` which xvfb-runs the released binary and drives marketplace install→start of scansort end-to-end via MCP HTTP on :9315. User-driven judgment call resolved: MCP tool was the right call ("Minerva's goal is to enable LLMs to do all tasks Minerva can do"). Saved as feedback memory `feedback_mcp_drives_all_minerva_tasks`. Layer A still 7/0. CI result pending. |

---

## 9. KEY MEMORY LANDMARKS

- `MEMORY.md` — first Active Work entry now points to DCR3 on
  `development` HEAD `c50fc1b3` (slightly behind real HEAD; OK)
- `project_active_marketplace_dcr3.md` — updated 2026-05-26 with
  full commit chain
- Nudge hints in `nudge` (component `github-actions`,
  `minerva-ui`, `git`, `mcp-spec`) from this session — read via
  `nudge_query` if scoping suggests they're relevant
- `feedback_test_at_integration_boundary.md` — Phase 1B 330 unit
  tests missed 6 wiring bugs; this whole loop is repaying that
  debt for the marketplace install path. Keep this principle in
  mind when designing Layer A — boot real Singleton, real broker,
  real subprocess.

---

## 10. WHEN THE LOOP TERMINATES

On success (both A and B green):
1. Update this file's STATE header to `MARKETPLACE END-TO-END GREEN`
2. Transition memory `project_active_marketplace_dcr3.md` status to
   `shipped`
3. Report to user: which iterations were used, what was the root
   cause, what tests now exist
4. Suggest the next user-driven step (HITL re-test, then promote
   `development → main` once user is satisfied)

On budget exhaustion (6 iter / 4h / judgment):
1. Update this file's STATE header to `AWAITING HITL — <reason>`
2. Write a `Docs/pickup-loop-stopped-<date>.md` with the iteration
   log + the specific decision that needs human input
3. Schedule the user-asking prompt
