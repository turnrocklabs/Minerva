# Plugin Setup Pipeline — HITL Debt Register

Deferred human checks for DCR `019f69428fa0` (deterministic manifest-install build
pipeline), per work-cycle campaign mode (`--defer-hitl`). Rounds append; entries
are burned in ONE consolidated acceptance session at campaign end. Every entry
names the automated proxy that stood in for the human check — no proxy, no deferral.

| # | Deferred check | Automated proxy in place | Source round |
|---|---|---|---|
| 1 | Live acceptance vehicle: remove pcb plugin's built artifacts (bin/ + worker/.venv), install from manifest in live Minerva → plugin manager shows "Building… (step N/M)", build output streams to a visible surface, plugin registers and its panel opens | C5 fixture matrix F1-F2/F13 through the real installer headless; UI state-render probes (R3) | (accumulates from R2/R3) |
| 2 | Induced failure: point the go override at a fake shim path (or rename go), Rebuild → typed error with named tool + found/required + install hint; fix → Rebuild succeeds | F3-F5 fixtures assert envelopes; UI probe asserts rendered failure text | (accumulates) |
| 3 | exec-step confirmation dialog shows the literal argv before first run | dry-run golden F12 + dialog-content probe | (accumulates) |
