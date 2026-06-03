# Pickup

STATE: `P1.4 visualizer panel — RENDERS REAL DATA in-app on Linux (rich-panel, 133 symbols). Render substrate PROVEN. Awaiting owner click-through of L1/L2 (boundary grid → graph → click-to-jump → filter) to transition 019e7b871b → done. Two follow-up items filed (responsive + real entry-point UX).`

Last updated 2026-06-03 (Linux desktop session).

> **RESUME HERE (Linux, 2026-06-03 session done).** The panel now renders the REAL rich-panel graph in-app (133 symbols). What got it there this session:
> - Pulled minerva-plugins `main` → `261c6a7`; Minerva `development` already current.
> - Rebuilt bundle + binary for `linux-x86_64`; smoke tools=11; indexed rich-panel → 133 symbols / 114 edges.
> - **Fixed `get_graph` to surface `project_name`** in stats (panel splash was titled "Project"); worker 38/0; committed + **pushed** minerva-plugins `main` `b24f0a9`.
> - **DB-PATH BUG (the real "0 symbols" cause):** the pickup's old step-5 path was WRONG for an in-place install. `install-from-manifest` sets `def.data_directory = manifest base dir = the PLUGIN SOURCE DIR`, so the panel reads `~/github/minerva-plugins/codetools/code_visualizer.db` — NOT `app_userdata/...`. SQLite silently CREATES an empty DB there → "0 files · 0 symbols · 0 edges". Fix: stage the indexed DB at `~/github/minerva-plugins/codetools/code_visualizer.db`. Hint `019e8edf`. (That staged `.db` is untracked in the plugins source dir — do NOT commit it; consider gitignoring.)
> - **Two follow-ups filed under DCR `019e7b6609`:** responsive panel `019e8f2282` (adopt `ResponsiveContainer`; panel breaks at 1-pane width); real entry-point UX `019e8f2489` (LLM-driven visualize + Open saved graph + index-on-demand; kill the implicit data_directory path convention — P2 of the design discussion).
>
> **REMAINING for P1.4 sign-off:** owner clicks the splash → confirms L1 boundary grid (ui/core/mcp/test) + L2 graph w/ edges + click-to-jump + filter. Then transition `019e7b871b` → done (cite `0739a7b`/`5678d9e`/`261c6a7`/`b24f0a9` + Minerva `ae778bc1`; worker 38/0, Gate-A 13/0, regression 38/0). The responsiveness gap is a SEPARATE item, not a gate blocker.
>
> **Merge note (2026-06-02):** the `pdf-print-substrate` branch (W5–W11) was merged into `development` earlier; additive, doesn't change the codetools track.

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

## 0. What to do next — finish the P1.4 HITL gate on Linux

Docket item `019e7b871b` (in_progress). Everything is built/reviewed/committed; the ONLY remaining work is: rebuild for Linux, open the panel, confirm it renders, transition to done.

### Where it stands (done this session)
- **R1** `0739a7b` — vendored the code-visualizer into `codetools/ui/code_graph/` (Level 1+2; class_name-free, relative preloads, `viz_mcp_server.gd` dropped, `load_from_dict` added) + **`minerva_codetools_get_graph`** adapter (`code_visualizer.py` + pure-stdlib `_layout.py`) returning the `code_graph` artifact `{nodes,edges,files,analysis,stats}` with x/y. Worker 79 ok (20 tree-sitter-free `get_graph` tests).
- **R2** `5678d9e` (pushed) — `code_graph_panel.gd` (extends `MinervaPluginPanel`) + manifest `ui` block (`ipc_messages` + `panels[godot_scene]` w/ full 7-script whitelist, `save_mode "none"`, `editor_items`).
- **R3** `ae778bc1` (Minerva) — Gate-A functional `test_codetools_panel_gate.gd`: real install→register→mount via `PluginScenePanelHost`; 13/0, regression `test_plugin_scene_panel_host` 38/0; registered in `run-functional-tests.sh`.
- **HITL fixes** `261c6a7` (NOT pushed) — two bugs the in-app check caught: (a) panel `_ready` reparent crash (label move_child before add); (b) **runtime cache version-keyed only** → stale worker answered `unknown method: get_graph` despite a fresh bundle. Durable fix: `extract.go` stamps the embedded bundle sha and re-extracts on mismatch. Verified by direct call (133 nodes); go vet/test clean. Hint `019e8b3a` — cad/presentation/nametag likely share this latent bug.

### Linux resume recipe
1. **Pull** minerva-plugins `main` + Minerva `development` (owner pushed `261c6a7` + the Minerva R3/docket commits).
2. **Build for linux-x86_64** (macOS artifacts don't cross; all gitignored):
   ```
   cd ~/github/minerva-plugins && bash scripts/build-python-runtime-bundle.sh codetools linux-x86_64
   cd codetools && go build -o codetools-plugin .      # output to ROOT — entrypoint ./codetools-plugin; in-place install needs it there
   python3 scripts/smoke/mcp_smoke.py "$PWD/codetools-plugin"   # expect tools=11
   ```
3. **Index a real DB offline** (the gate's test data; no LLM needed):
   - venv: `python3.12 -m venv /tmp/ctv && /tmp/ctv/bin/pip install "tree-sitter~=0.22" ~/github/minerva-plugins/codetools/worker/vendored/code_visualizer/vendor/tree-sitter-gdscript` (builds parser.c; resolves tree-sitter 0.25.2).
   - index: `cd ~/github/minerva-plugins/codetools/worker && PYTHONPATH=/tmp/ctv/lib/python3.12/site-packages /tmp/ctv/bin/python -m vendored.code_visualizer.analyzer.index ~/gitlab/ccsandbox/experiments/rich-panel --db /tmp/cg.db --project rich-panel` → 133 symbols / 114 edges.
   - (the mac-built SQLite is portable if you copied it — but re-indexing is clean.)
4. **Install**: launch Minerva (development) → **install-from-manifest** → `~/github/minerva-plugins/codetools/manifest.json` (registers in-place; needs the root binary + class_name-clean panel scripts — both done). **Start** the plugin (`autostart` is false).
5. **Stage the DB at the panel's resolved path.** For an **in-place `install-from-manifest`** (what we use), `def.data_directory = the manifest's folder = the PLUGIN SOURCE DIR` (PluginDefinition.gd:265-266), so the panel reads `~/github/minerva-plugins/codetools/code_visualizer.db`. Stage there: `cp /tmp/cg.db ~/github/minerva-plugins/codetools/code_visualizer.db`. (The OLD `app_userdata/Minerva/plugins/data/codetools/` path only holds for a marketplace-COPIED install — staging there yields "0 symbols" because SQLite auto-creates an empty DB at the real resolved path. Hint `019e8edf`.) Worker runtime datadir is yet a third path `${XDG_DATA_HOME:-~/.local/share}/Minerva/plugins/codetools`; if the panel shows `unknown method`, `rm -rf <worker-datadir>/runtime` to force re-extract — though `261c6a7` makes this self-healing.
6. **Open** New → **Code Graph**. Confirm: L1 boundary grid (`ui / core / mcp / test` groupings), L2 spatial graph with `calls/connects/contains/emits/instances` edges, click-to-jump, basic filter.
7. **On sign-off**: transition `019e7b871b` → done (cite `0739a7b` `5678d9e` `261c6a7` + Minerva `ae778bc1`; worker 79 ok / Gate-A 13-0 / regression 38-0). No new code needed. Then P1 substrate is complete → next is P1's sibling phases (P2 `019e7b8664`) or the new platform item `019e8af5`.

### Architecture decided this session (durable — see docket)
- **File-access / no-bleed contract** (DCR `019e7b6609` comment 410): agent file *tools* live in the plugin sidecar; only the *generic platform* stays in Minerva core. Boundary test + 5 clauses + CI guard (no `minerva_codetools_*`/`minerva_file_*` in core MCP).
- **Generic schema-driven plugin-config mechanism** — new item `019e8af5` (won the code rubric: leads reliability+durability). `019e8a27` (CodeTools policy UI) re-scoped onto it (off `config_file.cfg`/AISettings). Interim: codetools policy.json in `<plugin_data_dir>`, sidecar fails safe.
- **DRY-debt** `019e7b86ab`: extract `build_codetools_fixture()` shared helper (Gate-A test duplicates the sibling's fixture build).

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
