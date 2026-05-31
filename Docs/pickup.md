# Pickup

STATE: `Code Tools extraction — P0 + P1.1 + P1.2 DONE & GREEN; P1.3 (vendor code-visualizer) is next`

Last updated 2026-05-31.

---

## TL;DR

Active initiative: **extract code-intelligence out of Minerva core into one OPTIONAL marketplace plugin, `codetools`**, that turns Minerva into a coding agent only when installed. Governing DCR: `019e7b6609` (`minerva` docket). Full design + decisions + progress: docket kb `019e7f366d99` (canonical, published) and memory `project_codetools_extraction.md`.

This session shipped the substrate, in order, each behind a cold-Opus review + CI:
- **P0** — clean baseline: pushed parked commits, fetched tags, registry drift fixed, Minerva `.gd.uid` hygiene.
- **P1.1** — the `codetools` plugin skeleton at `~/github/minerva-plugins/codetools`: Go shim + embedded CPython (cad pattern) + stdio MCP + one health tool `minerva_codetools_ping`. CI green on all 3 targets; **`codetools-v0.1.0` released**.
- **P1.2** — the unified result envelope `{status, summary, artifacts, evidence_handles, follow_ups, [error]}` + router every subsystem will dispatch through. 22 worker unit tests.

Both repos clean and pushed. Nothing is half-done — we paused cleanly at the P1.2→P1.3 boundary.

---

## 0. What to do next session — P1.3

**Vendor the code-visualizer subsystem (was "Code Magic") behind the router.** Docket item `019e7b870f`.

- Source PoC: `~/gitlab/ccsandbox/experiments/code-magic` — **pin HEAD @ `9cc9403`** at vendor time (Python + SQLite + a working 10-tool stdio MCP + a Godot viz; ships ZERO tests).
- Snapshot into `codetools/worker/vendored/` with a `VENDORING.md` recording the SHA; **no local edits** (track any patches separately).
- Re-namespace its 10 MCP tools to `minerva_codetools_*` and route them through the P1.2 envelope (register handlers in `codetools/worker/codetools_worker/router.py` `ROUTES`; each returns `envelope.ok(...)` with typed artifacts).
- Its Python deps (tree-sitter wheels etc.) go in `codetools/scripts/runtime-bundle.lock` `PIP_PKGS`; SQLite is stdlib.
- **Gate A (no stubs):** index a REAL fixture Godot project (real `.gd`/`.tscn`/`.tres`) + real SQLite; author net-new functionals (it has none); cold-Opus review; full regression green.
- Model plan: **SONNET** for the mechanical vendor + rename, **OPUS** review. Functionals are net-new.
- DRY watch: code-visualizer's own indexer fs/search temporarily duplicates the future shared `files/` — that debt is tracked by the converge-DRY item and gates P4. Don't silently leave it.

First recon step (already teed up): map code-magic's structure / 10 tools / deps before vendoring.

### The deferred HITL gate (the night's destination is P1.4, not P1.3)
Everything through P1.3 and most of P1.4 is machine-verifiable headless. The ONE thing that needs a human is **P1.4: opening the code-visualizer `godot_scene` panel in a running Minerva and confirming the graph actually renders / is usable.** Headless proves registration + wiring + data flow; it cannot prove "the visualization looks right."

---

## 1. How to build / test codetools (dev facts learned this session)

- `godot` is on PATH (Homebrew, 4.6.2). GDScript suite runs headless: `scripts/run-functional-tests.sh [--all]` → `godot --headless --path src --script test/<t>.gd`. **Run it from the Minerva repo root** (`--path src` is relative).
- The codetools marketplace functional: `src/test/test_marketplace_install_start_codetools.gd` (in the `--all` set). Builds the real binary, installs via the real `MarketplaceClient`+`PluginManager`, pings, asserts the envelope. Cross-platform; SKIPs without the plugins checkout / `go` / a bundle.
- **Embedded bundle gotcha:** the Go binary embeds the worker source at *bundle-build* time. After ANY worker `.py` change, rebuild the bundle or Tier-1 runs stale code: `cd ~/github/minerva-plugins && bash scripts/build-python-runtime-bundle.sh codetools macos-arm64` (PBS cached → ~3s). The GDScript functional clears the version-keyed `EnsureRuntime` runtime cache itself; for `go test`/manual, the placeholder path (`codetools/scripts/dev-make-placeholder-bundle.sh`) compiles without a full bundle and falls through to system `python3` (Tier-3).
- Worker unit tests (no deps): `cd codetools/worker && python3 -m unittest discover -t . -s tests -p 'test_*.py'`.
- Go: `cd codetools && go build -o build/codetools-plugin . && go vet ./... && go test ./...` ; smoke: `python3 scripts/smoke/mcp_smoke.py codetools/build/codetools-plugin`.
- CI: `.github/workflows/codetools.yml` (binary-size floor 20MB; worker unittests on linux). Watch: `gh run watch <id> --exit-status`.

---

## 2. Discovery anchors (survive compaction)

- **DCR `019e7b6609`** (`minerva` docket) — design + decisions. Comment 34 = execution playbook/gates; 35 = skills + test decision; 36 = workflow/repo decisions; **37 = open envelope-schema questions (read this — `data` field decision is yours)**.
- **Docket kb `019e7f366d99`** (`minerva`, published/active) — canonical reference: design, locked decisions, names, locations, item map, progress. Mirrors memory `project_codetools_extraction.md`.
- Docket items (ALL now in the `minerva` docket, moved out of `minerva-services` 2026-05-31): P0 `019e7b862f`, P1 `019e7b8650`; done: P1.1 `019e7b86e4`, P1.2 `019e7b86f2`; **next: P1.3 `019e7b870f`**, then P1.4 `019e7b871b`. Later phases P2 `019e7b8664`, P3 `019e7b867e`, P4 `019e7b8699`, DRY-debt `019e7b86ab`. Hints: discovery map `019e7b8804`, repo+branch workflow `019e7b9196`.
- Plugin API docs: `~/github/minerva-plugins/docs/PLUGIN_DEVELOPER_GUIDE.md` + `PLUGIN_API_COVERAGE.md`.

## 2a. Open question for the owner (non-blocking)
Envelope primary-payload home: I kept the DCR's 5-field schema and made `type` a REQUIRED discriminator on each artifact (additive `data` field still possible later, non-breaking). **Decide before P1.3 subsystems serialize a lot of output: add a dedicated `data` field, or are typed artifacts the contract?** See DCR comment 37.

---

## 3. Build / version state

| Component | Version / commit | Notes |
|---|---|---|
| minerva-plugins | `main` @ `6083486` (pushed) | codetools P0–P1.2 |
| **codetools plugin** | **`codetools-v0.1.0`** (released, all 3 targets) | optional; not bundled |
| Minerva | `development` @ `cc3729cb` (pushed) | codetools functional + runner wiring |
| CAD plugin | `cad-v0.1.2` | unaffected; verified green |
| Presentation | `presentation-v0.0.3` | prior work |

Known: Minerva `development` CI has a pre-existing, unrelated smoke-test failure (owner-confirmed). Not a regression from this work.

---

## 4. Hard rules

- Per-file `git add` only. No `-A` / `.`. No `--no-verify`. No `vendor/` touches. No force-push, no `git reset --hard`.
- Commit co-author trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Push authorization (this initiative):** owner authorized push-as-we-go 2026-05-31 — Minerva→`development`, minerva-plugins→`main`. No feature branches; commit straight to the integration branch.
- Work directly on the integration branch (no branches) per owner.

---

## 5. First actions for next session

1. Read this file + DCR comment 37 (the `data`-field question).
2. Resume P1.3: recon `~/gitlab/ccsandbox/experiments/code-magic` @9cc9403 (structure, 10 tools, deps), then vendor → re-namespace → route through envelope → real-fixture functionals. SONNET impl + OPUS review.
3. Keep the cold-Opus-review-per-item + CI-green discipline. Drive toward the P1.4 visual HITL gate.
