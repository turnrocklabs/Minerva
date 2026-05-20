# Pickup

STATE: `PLUGIN_SUBSTRATE_FIX — IMPLEMENTATION COMPLETE, AWAITING W7 HITL`

Last updated 2026-05-20. The CAD render-regression remediation (RCA
`019e46b5`) is fully implemented, tested, cold-reviewed, and committed. The
only remaining work is **W7 — human-in-the-loop verification** with the real
app and real data.

---

## 1. What this was

The CAD plugin rendered no geometry. RCA-traced to Minerva's MCP-over-stdio
connection layer — commit `fcdeda02`'s serialization gate — NOT the CAD plugin.
Tracked as remediation on RCA `019e46b5` (now `remediating`; W7 HITL moves it
to `verified` → `closed`).

## 2. What shipped — all committed on `user/imran/experiments/swarm`

| Commit | What |
|--------|------|
| `faf0d38d` | Test fixtures (pre-existing) |
| `1d84fbea` | W4+W5 — the functional test suite (5 test files) |
| `6bd32f2b` | W1 — the connection-layer fix in `MCPServerConnection.gd` |
| `0c4e6cf8` | W8 (Minerva) — faithful plugin-error propagation in the broker |
| `b9761185` | W6 — functional test runner + CI job |
| `2e1bcbe` (plugins repo) | W8 (cad) — `CADPanel` error banner |

- **W1** — replaced the `fcdeda02` gate + poll loop with a single always-live
  stdout reader (`_drain_stdout`) + a per-id pending-request map. `call_tool`
  gained a caller-set `timeout_sec`. The 30s hard cap that starved slow CAD
  evaluations is gone. Connection errors are human-readable strings.
- **W4** — F1/F2/F4 (`test_mcp_stdio_concurrency.gd`), F5/F6
  (`test_mcp_stdio_request_budget.gd`). F2 is the fail-first repro.
- **W5** — F3 CAD geometry guard, presentation deck test, scansort filing e2e.
- **W8** — `CADPanel` shows a red banner on a failed evaluate (was a silent
  empty render — the regression's symptom); `PluginErrors.backend_error` + a
  broker re-shape carry the human-readable reason faithfully to the panel.
- **W6** — `scripts/run-functional-tests.sh` + a `functional-tests` CI job.

## 3. Verification done (autonomous)

- F2 fail-first repro: confirmed RED on pre-W1 code (8349ms starvation),
  GREEN post-W1.
- Post-W1 suite: F1/F2/F4 16/0, F5/F6 14/0, F3 12/0, presentation 29/0,
  scansort skip-clean (model-chat unavailable headless).
- No regressions: the three host-capability tests' failures are pre-existing
  (confirmed identical on a pre-W1 `git stash` baseline).
- W1 diff independently cold-reviewed — no blockers.
- `scripts/run-functional-tests.sh` verified locally.

## 4. W7 — HITL verification (the remaining work — YOU)

Run Minerva and verify:
1. **CAD regression fixed** — open the CAD plugin panel, evaluate a model.
   Geometry must RENDER (the bug was a blank panel). The headline check.
2. **CAD error banner (W8)** — force a failure (invalid DSL, or kill the
   worker) → a red banner must appear over the views stating the reason.
3. **scansort still functional** — run a real filing pass; docs classify+file.
4. **presentation still functional** — open/edit a deck.
5. Optional — run the scansort e2e test where model-chat is reachable:
   `godot --headless --path src --script test/test_scansort_filing_e2e.gd`
   (it skipped headless here; with model-chat up it does the real classify).

When satisfied, transition RCA `019e46b5` → `verified` → `closed`.

## 5. Open follow-ups (NOT blocking W7 — surfaced for a decision)

- **F7 (exported-build CI)** — deferred. Running the suite against an exported
  Minerva binary needs a real export environment + answers to open questions
  (is `res://test/` inside the release `.pck`?). Docket W6, comment 19.
- **CI Godot version** — `build.yml`'s `build-godot` installs Godot 4.5.1 but
  the project requires 4.6. The new `functional-tests` job pins 4.6.2;
  `build-godot` should be reconciled.
- **Broker capability-handler robustness** — pre-existing (not a W1
  regression): a broker capability-handler that hard-fails mid-dispatch can
  leave a plugin awaiting its reply until the 120s timeout. Cold review flagged
  it. Candidate future bug. Docket W1, comment 18.
- The `functional-tests` CI job is unverified until a real CI run — it reports
  status but does not gate the release yet.

## 6. How to run the tests

```
scripts/run-functional-tests.sh          # hermetic F1-F6 (fast, no network)
scripts/run-functional-tests.sh --all    # + per-plugin (CAD/presentation/scansort)
```

## 7. Hard rules (carry-forward)

- Per-file / explicit-path `git add` only. No `git add -A` / `.`.
- No `--no-verify`, no `--no-gpg-sign`.
- No `vendor/` touches. Don't commit `src/addons/sightline_probe/` or
  `src/project.godot` while that addon is enabled. In the plugins repo, the
  scansort tree has the user's own uncommitted work — never sweep it up.
- No `git reset --hard`, no force-push, no push without explicit ask.
- pkill target is `godot`, not `Minerva`.
- PII/HBI: never commit real documents / `.ssort` vaults / audit logs.
- RCA requests → 5-why chain with file:line source proof.
