# Pickup

STATE: `PLUGIN_SUBSTRATE_FIX (RCA 019e46b5) — BUG #2 FIXED (Option A), TEST-VERIFIED — AWAITING RE-HITL`

Last updated 2026-05-21. Bug #2 (broker→panel result-shape mismatch) is fixed
via **Option A** and verified by the functional suite. The fix is **not yet
committed** — it awaits a user HITL re-check that the CAD panel renders.

---

## 1. Status

RCA `019e46b5` — "CAD plugin renders no geometry." Still `remediating`; move to
`verified` only after the user confirms the panel renders in a live Minerva run.

W1 (connection-layer fix) shipped earlier. W7 HITL found bug #2 (W1 was
necessary but not sufficient). Bug #2 is now fixed.

## 2. What changed today — UNCOMMITTED on `user/imran/experiments/swarm`

All Minerva-side; the CAD plugin needs no change (its panel already expects the
wrapped shape — bug #2 was the broker silently dropping the wrap).

| File | Change |
|------|--------|
| `PluginErrors.gd` | + `backend_success(payload)` → `{success:true, result:payload}` — the success half of the broker→scene reply contract, paired with `backend_error()` |
| `PluginScenePanelBroker.gd` | `_dispatch_to_plugin_backend` rewritten — see §3 |
| `MCPServerConnection.gd` | W1 follow-up: `_drain_stdout` loop re-guards `is_instance_valid(_subprocess)` per iteration (fixes a shutdown null-deref) |
| `singleton_object.gd` | `create_toast_notification` no-ops when `main_scene == null` (headless-safe) |
| `test/test_cad_evaluate_render.gd` | + F3b — drives `cad.evaluate` through `PluginScenePanelBroker._dispatch_to_plugin_backend` (the path F3 bypassed) |

## 3. The fix — Option A (broker owns the reply envelope)

`_dispatch_to_plugin_backend` now, for a Dictionary `call_result`:
1. has `success` → return verbatim (tool already speaks the envelope).
2. has `ok` → `backend_success(call_result)` = `{success:true, result:<payload>}`.
   Checked **before** `error`: a worker-domain error is `{ok:false, error:{…}}`
   (both keys) and must reach the panel as a worker result so the panel sees
   `error.kind` (e.g. `cancelled`), not a transport `backend_error`.
3. has `error` only (no `ok`) → `backend_error` — a connection-layer failure.
4. neither → `backend_success`.

Why A is safe (blast-radius check, 2026-05-21): `_dispatch_to_plugin_backend`'s
return is consumed by **exactly one** call site platform-wide — `CADPanel.gd:579`
`await_reply` on `cad.evaluate`. scansort panels never use the broker scene path
(they call `conn.call_tool` directly); presentation's only `request.emit` is
`host_owned_save.response`, special-cased before `_dispatch_to_plugin_backend`.
And `CADPanel._evaluate_and_render` (lines 612-616) was already written for the
`{success:true, result:<worker_payload>}` shape — A restores the contract the
panel already speaks, so the CAD panel needs no change.

## 4. Test results (2026-05-21)

`scripts/run-functional-tests.sh --all`: F1/F2/F4 16/0, F5/F6 14/0,
CAD (F3+F3b) 21/0 with zero SCRIPT ERRORs, presentation 29/0, scansort
skip-clean (model-chat unavailable headless).

F3b is the new bug #2 regression guard — its "broker reply has success == true"
assertion fails pre-fix, passes post-fix.

Host-capability tests: channel 10/4, providers 45/0, documents 65/7. The 11
failures are pre-existing + environmental (`capability_probe` fixture won't
start) — `git stash` baseline confirmed identical counts with the fix removed,
so Option A caused zero regressions.

## 5. THE NEXT STEP — user HITL

Run Minerva, open the CAD panel, evaluate a model. Confirm geometry renders and
no `transport failure` warning. If good: commit the 5 files (per-file `git add`),
then RCA `019e46b5` → `verified`. If not: capture the new symptom.

## 6. Other open follow-ups (not blocking)

- **F7 (exported-build CI)** deferred — needs a real export env. Docket W6 c.19.
- **CI Godot version** — `build.yml` `build-godot` installs 4.5.1; project needs
  4.6; the `functional-tests` job pins 4.6.2. Reconcile.
- **Broker capability-handler robustness** — pre-existing; docket W1 comment 18.
- **`capability_probe` fixture won't start headless** — the 11 host-capability
  failures; pre-existing, unrelated to bug #2.
- The `functional-tests` CI job is unverified until a real CI run.

## 7. Hard rules

- Per-file / explicit-path `git add` only. No `-A`/`.`. No `--no-verify`.
- No `vendor/` touches. Don't commit `src/addons/sightline_probe/`,
  `src/project.godot`, or the generated `src/test/*.uid` files. In the plugins
  repo the scansort tree has the user's own uncommitted work — never sweep it up.
- No `git reset --hard`, no force-push, no push without explicit ask.
- pkill target is `godot`, not `Minerva`.
- RCA requests → 5-why with file:line proof.
