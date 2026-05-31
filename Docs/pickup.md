# Pickup

STATE: `Code Tools extraction — P0 + P1.1 + P1.2 + P1.3 DONE & GREEN; P1.4 (godot_scene visualizer panel — HITL gate) is next`

Last updated 2026-05-31.

---

## TL;DR

Active initiative: **extract code-intelligence out of Minerva core into one OPTIONAL marketplace plugin, `codetools`**, that turns Minerva into a coding agent only when installed. Governing DCR: `019e7b6609` (`minerva` docket). Full design + decisions + progress: docket kb `019e7f366d99` (canonical, published) and memory `project_codetools_extraction.md`.

This session shipped the substrate, in order, each behind a cold-Opus review + CI:
- **P0** — clean baseline: pushed parked commits, fetched tags, registry drift fixed, Minerva `.gd.uid` hygiene.
- **P1.1** — the `codetools` plugin skeleton at `~/github/minerva-plugins/codetools`: Go shim + embedded CPython (cad pattern) + stdio MCP + one health tool `minerva_codetools_ping`. CI green on all 3 targets; **`codetools-v0.1.0` released**.
- **P1.2** — the unified result envelope `{status, summary, artifacts, evidence_handles, follow_ups, [error]}` + router every subsystem will dispatch through. 22 worker unit tests.
- **P1.3** — vendored code-visualizer (`code-magic` @ `9cc9403`) under `codetools/worker/vendored/code_visualizer/`; 9 envelope adapters (`query, get_context, stale_check, get_diff, analyze, set_description, describe_symbol, set_tags, undescribed`) wired into `router.ROUTES` + `internal/tools/code_visualizer.go` + `main.go initRegistry`; 22 real-fixture functional tests (real Godot fixture project, real SQLite) green; the Minerva GDScript marketplace test extended with an install→start→analyze:stats round-trip (Gate-A).

Nothing is half-done — we paused cleanly at the P1.3→P1.4 boundary.

---

## 0. What to do next session — P1.4 (HITL gate)

**Ship the code-visualizer panel as a `godot_scene`.** Docket item `019e7b871b`. This is the ONE explicit human-in-the-loop gate of the substrate phase — headless can verify registration + wiring + data flow, but not "does the graph render / is it usable."

- Source viz: `~/gitlab/ccsandbox/experiments/code-magic/viz` (and `code-magic-viz/`) at the same pinned SHA `9cc9403`. Vendor like P1.3 did the analyzer.
- Wire it as a `godot_scene` panel in `codetools/manifest.json` (cad's CAD panel + presentation deck are precedents). Panel queries the worker over MCP for graph data.
- The "looks right" gate: open the panel in a running Minerva pointed at a real indexed SQLite (the P1.3 fixture works), and confirm: nodes render, edges connect, click-to-jump, basic filter. Owner signs off.
- Model plan: SONNET for the panel scaffold + MCP wiring, OPUS for review. The human gate replaces the auto-functional-test gate for the visual layer.

### Lessons / gotchas captured in docket hints this session

- `019e7f57218e` — tree-sitter-gdscript NOT on PyPI; install from `vendored/.../vendor/tree-sitter-gdscript`.
- `019e7f737cc9` — `PYTHONNOUSERSITE=1` required on `build-python-runtime-bundle.sh` pip line or dev user-site leaks into the bundle and silently skips deps.
- `019e7f738b83` — `def.data_directory` is a Godot URI; globalize via `ProjectSettings.globalize_path()` before handing to external workers.
- `019e7f5050047` — Go-shim plugins source MCP tools from the Go `Registry`, NOT manifest `tools[]`.
- `019e7f591b8d` — code-visualizer `analyze:dead_code` never flags class members (class-contains-member edges keep them "alive"); test fixtures should assert on top-level classes.

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
| minerva-plugins | `main` @ `<P1.3 HEAD>` (push pending) | codetools P0–P1.3 |
| **codetools plugin** | **`codetools-v0.1.0`** (released, all 3 targets) | optional; not bundled. P1.3 work is on main but no new tag — P1.4 HITL ships next. |
| Minerva | `development` @ `<P1.3 HEAD>` (push pending) | codetools functional + analyze:stats round-trip |
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

1. Read this file. Envelope `data`-field question is RESOLVED (DCR comment 386 — typed artifacts win; no `data` field). Review hints listed in §0 if you'll touch tree-sitter or the bundle script.
2. Start P1.4: vendor the Godot viz from `~/gitlab/ccsandbox/experiments/code-magic/{viz,code-magic-viz}` @ `9cc9403`, scaffold the `godot_scene` panel in `manifest.json`, wire it to query the worker via MCP for graph data. Point at the P1.3 fixture's SQLite for a first render.
3. The HITL gate: owner opens the panel in a running Minerva and confirms graph renders + is usable. No headless gate substitutes for this step.
