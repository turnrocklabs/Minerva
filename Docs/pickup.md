# Pickup

STATE: `HITL FOLLOW-ON — cad python worker spawn fails`

Last updated 2026-05-27 — written immediately before /compact to preserve
session state. User is online and active.

---

## 0. WHAT JUST SHIPPED (don't redo any of this)

### Minerva (turnrocklabs/Minerva, branch `development`)

Autonomous loop 1-10 + handoff commit landed; full chain green:

- `0c168ad6` — PluginManager.start_plugin: unconditional `ProjectSettings.globalize_path(def.data_directory)` (fix ERR_CANT_CONNECT for marketplace installs).
- `bdbdf19e` — initialize_mcp() idempotent (no longer early-returns on existing mcp_manager).
- `0d977156` — SingletonObject._ready no longer bails on missing `user://config_file.cfg` (latent fresh-install bug).
- `b2b8728c` — initialize_plugins() runs BEFORE `await mcp_manager.initialize()` (so plugin_mcp_tools wires up even when external MCP server binaries are absent).
- `66a018ec` — pickup updated to GREEN.

NEW Minerva MCP tool exposed: `minerva_plugin_marketplace_install` (URL → MarketplaceClient.install_from_url → PluginManager).

CI green on every dev push:
- Layer A: `src/test/test_marketplace_install_start_scansort.gd` in functional-tests.
- Layer B: `tarball-smoke` job in `.github/workflows/build.yml` runs `scripts/tarball-smoke.sh` against the just-built tarball under xvfb + --headless, drives MCP HTTP :9315 install→start→state=RUNNING.

Latest release with the chain: `auto-build-20260527-092547` on turnrocklabs/Minerva. Each subsequent push to `development` creates a new auto-build release containing the same fixes.

### Plugins (imrans-lab/minerva-plugins, branch `main`)

After Minerva green, HITL surfaced: "Whitelisted script not found: 'user://plugins/scansort/ui/ScansortPanel.gd'". Cause: release tarballs only shipped manifest+binary+SHA256SUMS, no `ui/`. Fixed in:

- `3d56b02` — all 3 pack workflows now `cp -r ui $PACKDIR/` and compute SHA256SUMS over every shipped file with `find . -type f ! -name SHA256SUMS | xargs sha256sum | sed 's| \./| |'` (preserves the `<hex>  <relpath>` two-space format Minerva's MarketplaceClient._verify_sha256sums parses).
- `cf25d61` — regenerated `registry.json` via `scripts/regen_registry.py` so it points at the NEW tags (`scansort-v0.0.1`, `presentation-v0.0.1`, `cad-v0.1.0`). Confirmed via API: registry now resolves to these versions. raw.githubusercontent.com CDN may take ~5 min to refresh.

Verified iteration 11 (HITL): user installed CAD from marketplace, panel UI loads, no more "Whitelisted script not found".

---

## 1. THE OPEN BUG (where to resume)

User did HITL on CAD plugin from marketplace install. UI shows; clicking evaluate produces:

> CAD evaluation failed: tool error: bridge.Worker.Start: exec: fork/exec /usr/bin/python3: no such file or directory

Even though `/usr/bin/python3` DOES exist on the user's host (confirmed via shell: `ls /usr/bin/python3` returned the file, also at `/home/imran/anaconda3/bin/python3`).

### Why the error message is misleading

The error format `exec: fork/exec <path>: no such file or directory` is a Go runtime error from `os/exec` (the cad-plugin is Go). "no such file or directory" can mean any of:
1. The path itself doesn't exist (NOT the case here — `/usr/bin/python3` exists).
2. The path exists but is a symlink whose target is missing.
3. The path is correct but the interpreter listed in its shebang doesn't exist.
4. ENOENT from a missing **shared library** the binary needs.
5. The path is a script with `#!/usr/bin/env something-missing` shebang.
6. The Python interpreter itself fails on import (depending on how the bridge spawn-and-test interprets failure).

So "the binary is missing" is almost certainly NOT the actual story. Likeliest: cad-plugin spawns `python3 -m mcad_worker`, the mcad_worker module imports build123d/OCCT, and an .so under it is missing — Go reports that as ENOENT on the python path itself (kernel returns ENOENT from execve when a dynamic loader fails). OR `mcad_worker` package isn't installed in the resolved python's site-packages.

### Where the python path comes from (in the cad plugin)

- `~/github/plugins/cad/main.go` line ~170 calls `runtime.PythonPath(workerDir)`.
- `~/github/plugins/cad/internal/bridge/worker.go` line 156 calls `exec.CommandContext(ctx, w.pythonPath, "-m", "mcad_worker")`.
- `runtime.PythonPath` is in `~/github/plugins/cad/internal/runtime/` (didn't read yet — investigate first).
- main.go's WARNING text says: "mcad_validate will fail until python3 is on PATH or .venv exists" — so the logic is: PATH lookup first, then `<workerDir>/.venv` (probably).

The marketplace tarball **does not include `worker/`** — it only ships `cad-plugin` binary + `manifest.json` + (now) `ui/`. So even though `~/github/plugins/cad/worker/` exists with the mcad_worker Python package and its venv requirements, none of that is in the install dir at `user://plugins/cad/`.

### The user's flag (READ THIS BEFORE TOUCHING)

Quote: *"Minerva does have a way to reference python, but I'm unsure if it's OS agnostic, available in the plugin substrate, or handles virtual envs correctly."*

Translation: there's an existing Python-resolution facility somewhere in Minerva. We should NOT just hardcode a different path in the cad plugin. We should:

1. **Discover what that facility is.** Grep candidates: `python_path`, `python_interpreter`, `python_env`, `PythonResolver`, `venv`, references to `OS.execute("python3"...)` or `OS.create_process("python3"...)`. Search both Minerva src/ and the Code Generation / Autocoder / Cell paths since those likely run Python locally.

2. **Understand its OS-portability.** Minerva ships on Linux/macOS/Windows. Whatever the facility is must (or must not) work cross-platform — we need to know which.

3. **Understand the venv story.** The cad plugin's mcad_worker needs build123d + OCCT — those need a venv. The user is unsure if Minerva's facility "handles virtual envs correctly".

4. **Decide the routing.** Options to consider (do NOT pick before user input):
   - A) Expose Minerva's python-resolver via a new host capability (e.g. `host.runtime.python_path`) so plugins ask Minerva for the resolved interpreter.
   - B) Include the worker/ Python sources in the cad release tarball, and have the plugin auto-create a venv at first start (cost: 50-150 MB tarball, network at first start).
   - C) Bundle a pinned wheels archive in the tarball and pip-install offline at first start.
   - D) Add a manifest-declared `python_runtime_required: {packages: [...]}` and Minerva spins up the venv before start_plugin completes.

5. **Don't fix the symptom in cad alone.** If we hardcode `/usr/bin/python3` (or `python3` via PATH) in cad, every other future Python-needing plugin re-discovers this. Architectural fix > one-plugin patch.

### What I had already started

When the token-budget pause hit, I had just read:
- `internal/bridge/worker.go:88-90` — `func New(pythonPath, workerDir string) *Worker { pythonPath: pythonPath, ... }`
- `internal/bridge/worker.go:156` — `cmd := exec.CommandContext(ctx, w.pythonPath, "-m", "mcad_worker")`
- `main.go:170-178` — calls `runtime.PythonPath(workerDir)`, push_warning on failure, still spawns Worker with empty path so Call returns clean error.

Files NOT yet read:
- `~/github/plugins/cad/internal/runtime/*.go` (the PythonPath logic itself)
- Minerva's python-resolver (location unknown — grep before assuming)

### Useful repro: do NOT install python3 to "fix" it

The user has python3 on their machine; the error is something subtler. Resist the urge to suggest `sudo apt install python3`. Investigate first.

---

## 2. RESUMING AFTER /compact

1. Read the rest of this file.
2. Read `MEMORY.md` (auto-loaded) — particularly the latest `feedback_mcp_drives_all_minerva_tasks` (the user's stated north star: LLMs do everything via MCP, so any Python-runtime facility should probably be exposed via MCP/host-capability too).
3. Grep Minerva's src/ for python-resolver patterns:
   ```bash
   grep -rnE "python_path|python_interpreter|PythonResolver|venv|python3|python_env" /home/imran/github/Minerva/src --include="*.gd" | head -40
   grep -rnE "OS\.execute.*python|OS\.create_process.*python" /home/imran/github/Minerva/src --include="*.gd" | head -10
   ```
4. Read `~/github/plugins/cad/internal/runtime/` (PythonPath logic).
5. Reproduce by running the released Minerva from `/home/imran/Downloads/...` (or via the CAD-equivalent of the marketplace install path) and trying CAD evaluate. Capture the worker stderr.
6. **PAUSE for the user before committing any cross-cutting design** — see section 1.4 options above.

---

## 3. HARD RULES (UNCHANGED)

- Per-file `git add` only. No `-A`/`.`.
- No `--no-verify`. No `vendor/` touches.
- No force-push, no `git reset --hard`.
- Co-author trailer: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- Plugins repo `imrans-lab/minerva-plugins`: user has previously authorized direct main pushes during the marketplace push; reconfirm before any new direct push.
- Minerva `development` branch: pre-authorized for autonomous-loop pushes during prior loops; this is a NEW investigation, ask before pushing.

---

## 4. NUDGE HINTS WORTH READING

(All saved during the previous loop, still session-cached.)

- `minerva-plugin-platform/subprocess-needs-globalized-path`
- `minerva-singleton/initialize-mcp-was-not-idempotent`
- `minerva-singleton/ready-bails-on-missing-config-file`
- `minerva-singleton/init-plugins-before-external-mcp-connect`
- `minerva-ci/headless-needs-xvfb-for-cef`
- `minerva-ci/godot-stdout-buffering`
- `minerva-mcp-http/no-session-id-header`
- `minerva-plugins-release/tarball-must-include-ui-dir`

---

## 5. ITERATION LOG (from prior loop — DO NOT extend without context)

The prior 10-iteration autonomous loop log is preserved below for context.

| # | Date | Commit | Outcome |
|---|------|--------|---------|
| 0 | 2026-05-27 | 589f6ee4 | Starting state. PluginManagerPanel lifecycle UX shipped; scansort install OK but start fails ERR_CANT_CONNECT. |
| 1 | 2026-05-27 | 0c168ad6 | Layer A GREEN. PluginManager fix: unconditional globalize_path. |
| 2 | 2026-05-27 | 1f5ca135 | Layer B added — Smoke v1 (xvfb only). FAILED. |
| 3 | 2026-05-27 | 7d598edb | Smoke v2 (--headless only). FAILED. |
| 4 | 2026-05-27 | ac467c46 | Smoke v3 (xvfb + --headless). FAILED — log truncated. |
| 5 | 2026-05-27 | edb5f127 | Smoke v4 — stdbuf + --verbose + live tail. Diagnostics ready. |
| 6 | 2026-05-27 | bdbdf19e | initialize_mcp idempotency fix. Still FAILED — wrong cause. |
| 7 | 2026-05-27 | 99087bd4 | Instrumented initialize_mcp + connect_server. |
| 8 | 2026-05-27 | 9b5c628f | Instrumented _ready + get_mcp_manager. Saw lazy-create + no _ready prints. |
| 9 | 2026-05-27 | 0d977156 | REAL fix #1: _ready bailed on missing config_file. CI past that point. |
| 10 | 2026-05-27 | b2b8728c | REAL fix #2: initialize_plugins() before external-MCP-connect. **CI GREEN.** |
| HITL #1 | 2026-05-27 | 3d56b02 + cf25d61 (plugins) | Tarball missing ui/ — fixed packaging + registry regen. Scansort panel loads. |
| HITL #2 | 2026-05-27 | — | CAD evaluate fails with python3 path. Investigation paused for compaction. |
