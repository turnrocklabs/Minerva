# Pickup — B8 doc_type normalization: `both` strategy validated; iter2 ready to re-run on laptop

Last updated: 2026-05-16 (end of desktop session, B8 winner picked, iter2 design validated by bisect)

## TL;DR for cold pickup

- **B8 (doc_type normalization) DCR `019e2ff19967`: `both` strategy chosen.** iter1 sweep (3 strategies × 6 docs × 2 reps on gemma4:26b + qwen2.5vl:7b validation) showed `both` (enum prompt + canonicalize safety net) tied `enum` on per-rep stability and beat `canonicalize` alone. Rubric tiebreaker on durability favors `both`.
- **iter2 design is GREEN by bisect:** 3 rules (tax + utility + boat with expanded subtypes ~7 each) and new rename_pattern `{year}_{issuer}_{doc_type}` produces clean, compact display_names. Instruction tweak ("prefer short common name over full legal name") produced `2024_Fidelity_1099.pdf` instead of `2024-1099-FIDELITY BROKERAGE SERVICES LLC.pdf` — much better.
- **iter2 BLOCKED by 1 unrelated bug:** the 2.7MB medical research PDF triggers a process() hang > 12 min. Bisect confirmed: drop the medical PDF → sanity runs in 125s. Per operator (load owner): model-chat cold-start ceiling is 5 min, so anything beyond that is a bug, not cold-start. Likely cause: bad UTF-8 / control chars in extracted text breaking something downstream. The same PDF returns invalid-JSON body from `extract_text` MCP call.
- **Next pickup (laptop):** pull both repos, rebuild plugin, set up `~/temp/scansort-fixtures/` with laptop PDFs (4-5 positives + 1 small clean negative), run `harness.py --sanity` → `--pilot` → `--validate both`. Auto-generated report at `report.md`.

## Cold-pickup checklist for laptop

1. `git -C ~/github/Minerva pull --ff-only`  (branch: user/imran/experiments/swarm)
2. `git -C ~/github/plugins pull --ff-only`  (branch: main)
3. Rebuild plugin:
   ```
   cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin
   cargo test --release   # expect 258/0
   ```
4. Smoke check panel:
   ```
   cd ~/github/Minerva && godot --headless --path src --script test/test_scansort_panel_smoke.gd   # expect ≥ 433/0
   ```
5. Set up fixtures (NOT in repo for PII reasons — operator provides own PDFs):
   ```
   mkdir -p ~/temp/scansort-fixtures
   # Copy 4-5 positives (tax / utility / boat docs) + 1 small clean negative
   # into ~/temp/scansort-fixtures/
   chmod -w ~/temp/scansort-fixtures/*.pdf
   ```
   **AVOID large image-only PDFs as negatives** — the iter2 medical-PDF bug indicates some PDFs cause process() to hang. Pick a simple text-based PDF (article, recipe, vehicle listing — anything small ≤ 200 KB with clean text).

6. Run the sweep (NO external dependencies — harness manages Minerva lifecycle):
   ```
   cd ~/github/plugins/scansort/experiments/b8_doc_type
   python3 harness.py --sanity              # 1 cell, ~3 min — validates fixtures
   python3 harness.py --pilot               # 2 cells gemma4:26b × both × 2 reps, ~10 min
   python3 harness.py --validate both       # 2 cells qwen2.5vl:7b × both × 2 reps, ~5 min
   python3 harness.py --report              # writes report.md
   ```
7. Review `report.md`. If results look good → mark B8 shipped, file the medical-PDF bug, and proceed to next backlog item.

## What ran this session (desktop)

### iter1 — 3-strategy comparison (gemma4:26b + qwen2.5vl:7b validation)

- 8 cells, 48 ledger rows
- **Outcome:** `both` strategy wins. Beat `canonicalize` alone (which is brittle — LLM produces novel tokens that don't match aliases). Tied `enum`. Picked `both` on durability rubric.
- ledger archived as `ledger.iter1.jsonl` (gitignored, has PII).

### iter2 — expand to 3 rules + new rename_pattern (`both` strategy only)

- Rules: `tax`, `utility`, `boat` — all under `experiments/b8_doc_type/rules/*.json`
- Each rule has 6-7 subtypes with thorough also_known_as lists
- rename_pattern: `{year}_{issuer}_{doc_type}` (was `{year}-{doc_type}-{issuer}`)
- Instruction prompts ask LLM to prefer short common name for `issuer`
- **Bisect (1 cell, 6 fixtures, no medical PDF):** completed in 125s with all 6 docs classified correctly and the new compact format working perfectly:
  ```
  1040 (Padgett)     → 2025_Padgett Business Services_1040.pdf
  1099 (Fidelity)    → 2024_Fidelity_1099.pdf                 ← short issuer
  M.Stanley          → unknown_Morgan Stanley_1099.pdf         ← short issuer
  Beneteau           → 2023_Allport Marine Survey_survey.pdf  ← boat rule fired
  PSEBill            → 2025_Puget Sound Energy_electric.pdf
  msft_w2            → unknown_Microsoft_W-2.pdf               ← short issuer
  ```
- Medical PDF (2.7MB research article on Paediatric Intestinal Pseudo-obstruction) caused process() to hang >12 min in 3 attempts; quarantined to `~/temp/scansort-fixtures-medical-quarantined.pdf` on desktop.

## Files in `experiments/b8_doc_type/`

Committed:
- `.gitignore` — covers `ledger*.jsonl`, `report*.md`, `*.log`, `__pycache__/`
- `harness.py` — main entry. MCP client + Minerva lifecycle + cell runner + report generator. ~700 LoC. Single-file by design.
- `probe.py` — tiny MCP smoke probe (left as a debugging aid)
- `probe_extract.py` — per-PDF extract_text timer (left as a debugging aid)
- `rules/tax.json`, `rules/utility.json`, `rules/boat.json` — the 3 experimental rule definitions with subtypes

Gitignored (never commit):
- `ledger.jsonl`, `ledger.iter1.jsonl` — has filenames + extracted issuers (PII)
- `*.log` — all log files have classification output with real names + firms
- `report.md` — generated from ledger (PII)
- `__pycache__/`

## Settled design decisions for B8 (do NOT re-litigate)

1. Rule has `subtypes: [{name, also_known_as: [aliases]}]` field. Hand-authored JSON for now; rule-editor UI is B6-adjacent.
2. `process()` accepts `doc_type_strategy: "none" | "enum" | "canonicalize" | "both"` (default `"none"` for back-compat).
3. **`both` is the production-recommended strategy.** Default stays `"none"` because experiment-driven, not legislated.
4. Enum strategy: prompt is augmented per-rule with `Allowed doc_type values when this rule wins: ...`.
5. Canonicalize strategy: post-LLM alias→canonical-name map applied using the winning rule's subtypes (case-insensitive, exact-string).
6. Both = enum prompt push + canonicalize safety net (catches LLM drift).
7. `{doc_type}` template token name stays internal — user-facing rename to `{subtype}` deferred to B6.
8. Fixtures NEVER checked in (PII).

## Bugs / follow-ups to file (NOT done yet)

| Suggested | Title | Notes |
|---|---|---|
| P3 / Sev 3 | `extract_text` returns invalid-JSON body for some PDFs (raw control chars at known columns) | Reproed on 2 PDFs (medical research article col 317, 1040 col 20762). Plugin must escape control chars before serializing full_text to the MCP response. |
| P2 / Sev 2 | `process()` hangs > 12 min on the medical-research PDF | Bisected from B8 iter2. May share root cause with the extract_text bug above OR be a separate classifier/LLM-prompt-size issue. Investigate by trimming the offending PDF to N pages and seeing where it falls over. |
| P3 / Sev 3 | Canonicalize safety net misses some alias matches under specific inputs | Saw `1099-DIV` not mapping to `1099` in gemma+canonicalize+M.Stanley (iter1) and qwen+both+Fidelity (iter1). Ledger doesn't capture raw pre-canonicalize doc_type — enhance harness to record it before re-investigating. |

## Plugin / Minerva commits at end of session

- **Plugins repo** (`main`): B8.1-B8.4 implementation + experiments harness landed. HEAD will be updated on commit (see commit log on push).
- **Minerva repo** (`user/imran/experiments/swarm`): only pickup.md updated. No code changes were needed Minerva-side for B8 — MCP HTTP port 9315 + plugin start path already worked.
- **Plugin binary** built on desktop at `~/github/plugins/scansort/scansort-plugin`. Rebuild on laptop with `cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin`.

## Carry-forward constraints

- **NEVER commit fixture PDFs or experiment ledger.** They contain real names, firms, and extracted text. Gitignore already covers this — preserve it.
- 5-min model-chat cold-start ceiling: timeouts beyond that = bug, not warmup. Defer investigation if not blocking.
- `process()` is a single MCP call that classifies all docs serially. HTTP timeout in harness must cover cold-start + N × per-doc inference (set to 720s cold / 360s warm in this harness).
- Plugin must be explicitly started post-MCP-initialize: `mcp.call("minerva_plugin_start", {"id": "scansort"})`. Install/load is not enough.
- After ~5 identical-args tool failures, broker BLOCKS the tool. Don't poll-retry with same args — fix root cause or change args.

## Paused / orthogonal workstreams

- Filing-engine DCR `019e2787` W12 (docs + cleanup) — still applicable; B8 doesn't block.
- Path-free DCR `019e2cc988ec` B6 (Rules Editor dialog retarget at library) — still backlog.
- `019e2cfced` — B3/B4 quality follow-up.
- `019e2d8018` — `minerva_list_models` omits core provider.

## Quick reference

- Rust build: `cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin`
- Rust tests: `cargo test --release` (expect 258/0)
- Panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (expect ≥ 433/0)
- Launch Minerva manually (only if not using harness): `godot --path /home/imran/github/Minerva/src` (background)
- MCP HTTP port: 9315 (JSON-RPC over POST `http://localhost:9315/`)
- Tool name prefix: `minerva_scansort_*`
- Plugin start tool: `minerva_plugin_start` with `{"id": "scansort"}`
