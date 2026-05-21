# Pickup

STATE: `PLUGIN_SUBSTRATE_FIX (RCA 019e46b5) — W7 HITL IN PROGRESS — BUG #2 FOUND, AWAITING FIX-APPROACH DECISION`

Last updated 2026-05-21. W1/W4/W5/W6/W8 are implemented and committed. W7 HITL
then revealed the CAD render regression is **not fully fixed** — a second bug,
masked by the first. **The immediate next step is a user decision: fix
approach A vs B (section 4).** Read this whole file before acting.

---

## 1. Status

RCA `019e46b5` — "CAD plugin renders no geometry." Tracked as remediation on
that RCA (status `remediating`; do NOT move to `verified` — the regression is
not resolved).

W1 (the connection-layer fix) is **correct and necessary** — F2 RED→GREEN, the
serialization gate is gone. But W7 HITL found W1 is **not sufficient**: there
is a second, independent bug that W1 *unmasked*.

## 2. What shipped — committed on `user/imran/experiments/swarm` (NOT pushed)

| Commit | What |
|--------|------|
| `faf0d38d` | test fixtures |
| `1d84fbea` | W4+W5 — functional test suite (5 files) |
| `6bd32f2b` | W1 — connection-layer fix (`MCPServerConnection.gd`) |
| `0c4e6cf8` | W8 (Minerva) — broker error propagation (`PluginErrors.backend_error` + broker) |
| `b9761185` | W6 — `scripts/run-functional-tests.sh` + `build.yml` CI job |
| `9323abde` | pickup (superseded by this file) |
| `2e1bcbe` (plugins repo, `main`) | W8 (cad) — `CADPanel` error banner |

Post-W1 suite all green: F1/F2/F4 16/0, F5/F6 14/0, F3 12/0, presentation 29/0,
scansort skip-clean. The 3 host-capability tests fail but identically pre-W1
(pre-existing, stash-confirmed). W1 cold-reviewed, no blockers.

## 3. THE LIVE BUG — #2, broker→panel result-shape mismatch

W7 HITL: user ran the CAD panel; `cad.evaluate` now COMPLETES (W1 fixed the
timeout), but the panel still renders nothing and logs
`[CADPanel] cad.evaluate transport failure: unknown —` (empty message).

Mechanics (all confirmed):
- A successful `cad.evaluate` →  `conn.call_tool("cad.evaluate")` returns the
  cad payload `{ok:true, result:{shape_name,mesh,edges}}` — **no `success`
  key** (F3's own run printed `result keys: ["ok","result"]`).
- `PluginScenePanelBroker._dispatch_to_plugin_backend` success path does
  `return PluginErrors.success(call_result)` — and `PluginErrors.success()`
  returns its arg **verbatim** (`PluginErrors.gd:369-370`; the `{success:true,
  result:...}` wrap was removed long ago as vestigial for the MCP capability
  bridge). So the broker delivers `{ok:true, result:{...}}` to the panel.
- `CADPanel._evaluate_and_render` expects `{success:true, result:<payload>}`
  (its own comment, `CADPanel.gd:568-571`). `CADPanel.gd:550`
  `if not bool(result.get("success", false))` → no `success` key → treats a
  SUCCESSFUL eval as a transport failure → blank render; `err_code` defaults
  to `"unknown"`, `err_message` is empty.

Why masked: pre-W1 the gate timed out `cad.evaluate` before any reply reached
the panel — the panel never parsed a reply, so #2 was invisible. W1 made the
reply arrive; #2 surfaced. Why tests missed it: F3 calls `call_tool` directly,
bypassing the broker→panel path. Full record: RCA `019e46b5` comment 20.

## 4. DECISION NEEDED — fix approach (the next step)

- **A. Fix the broker (recommended).** In `_dispatch_to_plugin_backend`, the
  success path wraps a non-`success` payload: `return {"success": true,
  "result": call_result}`. Matches the panel's expectation + completes the
  reply contract W8 started for errors (`{success:false,...}`). Blast radius:
  changes the reply shape for every plugin panel whose backend tool returns an
  `{ok}`-style payload (scansort especially) — **must blast-radius-check the
  scansort panel first** (does it read wrapped or verbatim broker replies?).
- **B. Fix the CAD panel only.** Rewrite `CADPanel._evaluate_and_render`'s
  result handling to read the verbatim shape: `result` IS the worker payload
  `{ok, result}` (one fewer unwrap layer), plus the W8 error shape
  `{success:false, error_code, error_message}`. Surgical, zero cross-plugin
  risk, per-panel patch.

Recommended path: quick scansort-panel blast-radius check → A if clean, B if
not. **Either fix MUST ship with a new test that drives the real broker→panel
reply path** (F3's gap) — e.g. extend the CAD per-plugin test to go through
`PluginScenePanelBroker`, not just `call_tool`.

Awaiting the user's A-vs-B call. The user was asked; this pickup is the
compaction save while that decision is pending.

## 5. Other open follow-ups (not blocking)

- **F7 (exported-build CI)** deferred — needs a real export env. Docket W6 c.19.
- **CI Godot version** — `build.yml` `build-godot` installs 4.5.1; project
  needs 4.6; the new `functional-tests` job pins 4.6.2. Reconcile.
- **Broker capability-handler robustness** — pre-existing: a broker handler
  that hard-fails mid-dispatch wedges a plugin until the 120s timeout. Docket
  W1 comment 18.
- The `functional-tests` CI job is unverified until a real CI run.

## 6. Run the tests

```
scripts/run-functional-tests.sh          # hermetic F1-F6
scripts/run-functional-tests.sh --all    # + per-plugin (CAD/presentation/scansort)
```

## 7. Hard rules

- Per-file / explicit-path `git add` only. No `-A`/`.`. No `--no-verify`.
- No `vendor/` touches. Don't commit `src/addons/sightline_probe/` or
  `src/project.godot`. In the plugins repo, the scansort tree has the user's
  own uncommitted work — never sweep it up (per-file add only).
- No `git reset --hard`, no force-push, no push without explicit ask.
- pkill target is `godot`, not `Minerva`.
- RCA requests → 5-why with file:line proof.
