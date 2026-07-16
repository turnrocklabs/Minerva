# Plugin Setup Pipeline — HITL Debt Register

Deferred human checks for DCR `019f69428fa0` (deterministic manifest-install build
pipeline), per work-cycle campaign mode (`--defer-hitl`). Rounds append; entries
are burned in ONE consolidated acceptance session at campaign end. Every entry
names the automated proxy that stood in for the human check — no proxy, no deferral.

| # | Deferred check | Automated proxy in place | Source round |
|---|---|---|---|
| 1 | Live acceptance vehicle: remove pcb plugin's built artifacts (bin/ + worker/.venv), add a `setup` stanza to its manifest (go_build + python_venv + requires go/python), install from manifest in live Minerva → plugin manager shows "Building… (step N/M)", per-step output appears in "Activity: Plugin Builds", plugin registers and its panel opens | F1/F2/F13 through the real install_plugin() path (test_setup_matrix 30/0, test_plugin_setup_pipeline 82/0); Building…-row + detail-pane population probes (test_plugin_build_ui 74/0) | R2 (pipeline) + R3 (UI/matrix) |
| 2 | Induced failure: set the go user-override to a fake/shim path (or too-old fake), Rebuild → S_NEEDS_BINARY listing the tool with found/required + install hint in the panel; clear override → Rebuild succeeds | F3/F4/F5 envelopes through the full install path (matrix); S_NEEDS_BINARY lists-every-failure + Rebuild-recovers probes (build-ui suite) | R2 + R3 |
| 3 | exec-step confirmation dialog shows the literal argv before first run; Cancel lands "You declined"; a headless/MCP install of the same manifest fails closed (exec_denied_headless) | dialog-content + deny-path probes, teardown-releases-worker, headless fail-closed timing test (build-ui section I); dry-run golden F12 | R3 |
