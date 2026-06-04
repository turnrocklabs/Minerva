# Pickup

STATE: `P1 + P2 + P3 COMPLETE 2026-06-03. P3 extracted code-probe (runtime inspection, was Sightline) into the codetools plugin: 3 new MCP tools minerva_codetools_{explore,inspect,validate} (plugin now 18 tools, 201 worker tests); core src/addons/sightline_probe removed (no-bleed guard extended). ONE human step remains: Option C HITL (codetools/docs/probe_capture_runbook.md) to refresh probe fixtures from a live Godot capture at release. Next: P4 unify+marketplace (019e7b8699); DRY-debt (019e7b86ab) gates it. Open follow-up: Go host-request client 019e8f811497.`

Last updated 2026-06-03 (Linux desktop session).

> **RESUME HERE.** P1 + P2 + **P3 all DONE.** P3 (code-probe `019e7b867e`) shipped all 6 grandchildren: P3.1 vendor (`d8cd08f`), P3.2 wrapper — 3 tools `minerva_codetools_{explore,inspect,validate}`, plugin now **18 tools / 201 worker tests** (`fb562cb`), P3.3 X11 gate + `prepare`/`remove-probe` (`4fa6c13`), P3.4 remove core `src/addons/sightline_probe` (Minerva `0bfa445e`), P3.5 DRY (rubric scope-reversal, see DRY-debt `019e7b86ab` comment 417), P3.6 replay harness + schema guard + Option C runbook (`e40c996`).
>
> **ONE human step pending:** the **Option C HITL** — follow `codetools/docs/probe_capture_runbook.md` to refresh the probe fixture from a live Godot capture (`inspect {op:prepare}` → open editor → `status` loaded → copy/normalize JSON → re-test). Release-time gate; not blocking.
>
> **Next initiative work:** **P4 unify+marketplace `019e7b8699`** (gated by DRY-debt `019e7b86ab`). Open follow-up: `019e8f811497` (Go host-request client for bash→host.terminal.exec).
>
> **Repos current & pushed:** Minerva `development` @ `0bfa445e`; minerva-plugins `main` @ `e40c996`. Pull both before starting.

---

## TL;DR

Active initiative: **extract code-intelligence out of Minerva core into one OPTIONAL marketplace plugin, `codetools`**, that turns Minerva into a coding agent only when installed. Governing DCR: `019e7b6609` (`minerva` docket). Canonical reference: docket kb `019e7f366d99` + memory `project_active_codetools_extraction.md`.

**P1 substrate is DONE** (`019e7b8650` closed 2026-06-03):
- **P0/P1.1/P1.2/P1.3** — clean baseline; plugin skeleton (Go shim + embedded CPython, cad pattern, `codetools-v0.1.0`); unified envelope `{status,summary,artifacts,evidence_handles,follow_ups,[error]}` + router; vendored code-visualizer (`code-magic` @ `9cc9403`) behind the router with real-fixture functionals.
- **P1.4** — code-visualizer ships as a `godot_scene` panel; **HITL render gate passed on Linux** (renders the real `rich-panel` graph, 133 symbols). Envelope `data`-field question RESOLVED (DCR comment 386: typed artifacts win, no `data` field).

P1.4 surfaced three **backlog follow-ups** (under the DCR, NOT gate blockers): real entry-point UX `019e8f2489`, responsive panel `019e8f2282`, visual legibility `019e8f29a2`.

---

## 0. P2 — extract file primitives (HARD removal) — ✅ COMPLETE 2026-06-03

Parent **P2 `019e7b8664` DONE**. All three grandchildren shipped this session; the per-grandchild detail below is HISTORICAL. Result: core boots 253 tools (was 257) with NO glob/grep/bash/cwd — those live only in the codetools plugin as `minerva_codetools_*`. No-bleed contract enforced (`test_codetools_no_bleed.gd` 10/10 + `scripts/check-no-codetools-bleed.sh` wired into build.yml). Landed: P2.1 plugins `1de5643`; P2.2 Minerva `8e39e5bc` + plugins `b62ce9c`; P2.3 Minerva `ee56eaf4`. Open follow-up `019e8f811497` (Go host-request client to wire bash→host.terminal.exec).

**Rubric-decided forks (this session, for the record):** (1) ActionNormalizer/PolicyEngine `minerva_bash`/`minerva_file_*` patterns KEPT — generic normalization heuristics, not registrations (no-bleed guard targets `_register_tool` only). (2) P2.2 split: core capability + tested dormant worker seam done now; the Go bidirectional host-request client (reusable infra codetools lacks) deferred to follow-up rather than ballooning P2.2. (3) rg = pinned BurntSushi 15.1.0 musl prebuilt, bundled via shared PBS script. (4) bash policy fail-safe = baseline deny-set always on, normal commands allowed when policy.json absent.

**Next:** P3 code-probe `019e7b867e`, P4 unify+marketplace `019e7b8699`, DRY-debt `019e7b86ab`. _(Historical P2 build detail follows.)_

### P2.1 `019e8f306e` — reimplement file primitives in the worker (FIRST)
Build glob / grep(via bundled `rg`) / bash / cwd in the worker `files/` subsystem (Python), routed through the P1.2 envelope + router. Tools become `minerva_codetools_*` (NOT `minerva_file_*`/`minerva_bash` — those die with core in P2.3). Behavior parity with the core impls (reference, don't port GDScript verbatim):
- glob (cf `src/Scripts/Services/CodeTools/GlobTool.gd`): `*`/`**`/`?`, exclude `.git`/`node_modules`/…, sorted, limit/truncate.
- grep (cf `GrepTool.gd`): regex, type filters, context lines, binary detection — **implement via a bundled ripgrep shipped in the PBS runtime bundle** (add to `build-python-runtime-bundle.sh`).
- cwd (cf `CwdTool.gd`): get/set with `~` expansion + validation (worker has a real chdir).
- bash (cf `BashTool.gd`+`Policy.gd`): policy deny-patterns (interim `policy.json` in `<plugin_data_dir>`, fail-safe), 120s timeout, ~30KB cap, merged stdout/stderr. Terminal-PTY routing is P2.2; headless subprocess is the baseline here.
DoD: no-stub functionals vs the real binary (smoke tool count +4); cold-Opus; worker unittests; regression green. Model: SONNET impl / OPUS review.

### P2.2 `019e8f3098` — host capability `host.terminal.exec` (SECOND)
Add an OPTIONAL Minerva-core host capability so a plugin's bash routes through the visible UI terminal PTY (same substrate as `minerva_terminal_*`), with a headless fallback when ungranted/headless. Sibling of `host.providers.chat`/`host.files.*`/`host.dialogs.*`/`host.notify`. Wire P2.1's bash to prefer it when granted. DoD: capability gated/granted; routes through terminal when granted; clean fallback; core fine without it; cold-Opus; regression green. Model: OPUS (design-bearing host API).

### P2.3 `019e8f30d2` — HARD-remove core file primitives + no-bleed guard (LAST)
Only after P2.1+P2.2 exist. REMOVE (inventory verified 2026-06-03):
- Delete `src/Scripts/Services/CodeTools/` (8 files, ~919 ln: Glob/Grep/Bash/Cwd/Read/Write/Edit/Policy.gd).
- Delete `src/Scripts/Services/MCP/Modules/MCPCodeTools.gd` (registers `minerva_file_glob`/`minerva_file_grep`/`minerva_bash`/`minerva_cwd`).
- Remove instantiation `MCPCodeTools.new(self),` at `MinervaMCPServer.gd:~109`.
- KEEP `minerva_doc_*` (`MCPDocTools.gd`) — separate, buffer-coupled.
- Move out the 5 file-primitive tests (`test_codetools_glob`/`_read`/`_edit_grep_bash`/`_cwd_write`/`_policy`); KEEP `test_codetools_panel_gate` + `test_marketplace_install_start_codetools`.
- Re-scope the shipped "File and Code Tools" skill (`master.dct` id `019d5c…0006`): drop the 4 file tools from `tool_deps`, keep `minerva_doc_*`; invalidate baseline-docket cache (author-minerva-skill workflow).
- `PolicyEngine.gd`/`ActionNormalizer.gd` pattern-match `minerva_bash`/`minerva_file_read` by name (rule patterns, not registrations) — decide keep-generic vs clean; update `test_policy_engine`/`test_tool_search_index`.
ADD the no-bleed contract (DCR comment 410): boundary test asserting core MCP registers NO `minerva_codetools_*`/`minerva_file_*`/`minerva_bash`/`minerva_cwd` + a CI guard.
DoD: core BOOTS + full regression green WITHOUT codetools; boundary test + CI guard green; `grep` of `src/` (outside tests) shows ZERO refs to CodeTools/Glob/Grep/Bash/Cwd/Write/Edit/Policy; cold-Opus. Model: SONNET impl / OPUS review.

### Durable decisions / debt (see docket)
- **No-bleed contract** (DCR comment 410): agent file *tools* live in the sidecar; only the *generic platform* stays in core. 5 clauses + boundary test + CI guard.
- **Generic schema-driven plugin-config mechanism** `019e8af5` (won the rubric); `019e8a27` (CodeTools policy UI) re-scoped onto it. Interim: codetools `policy.json` in `<plugin_data_dir>`, fails safe.
- **DRY-debt** `019e7b86ab` (gates P4): extract `build_codetools_fixture()` shared helper.

---

## 1. How to build / test codetools

- `godot` is on PATH (4.6.x). GDScript suite runs headless: `scripts/run-functional-tests.sh [--all]` → `godot --headless --path src --script test/<t>.gd`. **Run from the Minerva repo root** (`--path src` is relative).
- Marketplace functional: `src/test/test_marketplace_install_start_codetools.gd` (in `--all`). Builds the real binary, installs via the real `MarketplaceClient`+`PluginManager`, asserts the envelope. SKIPs without the plugins checkout / `go` / a bundle.
- **Embedded-bundle gotcha:** the Go binary embeds the worker at *bundle-build* time. After ANY worker `.py` change, rebuild the bundle or Tier-1 runs stale code: `cd ~/github/minerva-plugins && bash scripts/build-python-runtime-bundle.sh codetools <triple>` (PBS cached → ~3s; triples: `linux-x86_64`, `macos-arm64`, …). `261c6a7` makes the Go runtime self-heal (stamps bundle sha, re-extracts on mismatch). For `go test`/manual, `codetools/scripts/dev-make-placeholder-bundle.sh` compiles without a full bundle (Tier-3 system `python3`).
- Worker unit tests: `cd codetools/worker && python3 -m unittest discover -t . -s tests -p 'test_*.py'` (tree-sitter tests need the deps below).
- Go: `cd codetools && go build -o codetools-plugin . && go vet ./... && go test ./...`. Smoke (expect tools=11 today): `python3 scripts/smoke/mcp_smoke.py "$PWD/codetools/codetools-plugin"` — **smoke script is at the plugins REPO ROOT `scripts/smoke/`, not `codetools/scripts`.**
- **Offline indexing for the panel** (no LLM): `python3.12 -m venv /tmp/ctv && /tmp/ctv/bin/pip install "tree-sitter~=0.22" ~/github/minerva-plugins/codetools/worker/vendored/code_visualizer/vendor/tree-sitter-gdscript`; then `cd codetools/worker && PYTHONPATH=/tmp/ctv/lib/python3.12/site-packages /tmp/ctv/bin/python -m vendored.code_visualizer.analyzer.index <repo> --db /tmp/cg.db --project <name>`. **Panel reads `~/github/minerva-plugins/codetools/code_visualizer.db`** for an in-place install (NOT app_userdata — hint `019e8edf`; that db is gitignored).
- CI: `.github/workflows/codetools.yml` (binary-size floor 20MB; worker unittests on linux). Watch: `gh run watch <id> --exit-status`.

---

## 2. Discovery anchors (survive compaction)

- **DCR `019e7b6609`** (`minerva` docket) — design + decisions. Comment 34 = execution playbook/gates; 35 = skills + test decision; 36 = workflow/repo; 37/386 = envelope `data`-field (RESOLVED: typed artifacts, no `data`); **410 = file-access no-bleed contract (read before P2)**.
- **Docket kb `019e7f366d99`** (`minerva`, active) — canonical reference. Mirrors memory `project_active_codetools_extraction.md`.
- **Item map** (all in `minerva`): P0 `019e7b862f` ✅, **P1 `019e7b8650` ✅** (P1.1 `…86e4`, P1.2 `…86f2`, P1.3 `…870f`, P1.4 `…871b` all ✅). **P2 `019e7b8664` ← next** (P2.1 `019e8f306e`, P2.2 `019e8f3098`, P2.3 `019e8f30d2`). P3 `019e7b867e`, P4 `019e7b8699`, DRY-debt `019e7b86ab`, plugin-config `019e8af5`. P1.4 follow-ups: `019e8f2489`/`019e8f2282`/`019e8f29a2`. Hints: discovery map `019e7b8804`, repo+branch workflow `019e7b9196`, plus this session's `019e8b3a`/`019e8edf`/`019e8e43`/`019e8e4a`.
- Plugin API docs: `~/github/minerva-plugins/docs/PLUGIN_DEVELOPER_GUIDE.md` + `PLUGIN_API_COVERAGE.md`.

---

## 3. Build / version state (2026-06-03)

| Component | Version / commit | Notes |
|---|---|---|
| Minerva | `development` @ `0bfa445e` (pushed) | P2 hard removal (253 tools) + P3.4 sightline_probe addon removed |
| minerva-plugins | `main` @ `e40c996` (pushed) | P2 file primitives + P3 code-probe (vendor + wrapper + harness) |
| **codetools plugin** | **`codetools-v0.1.0`** (released, all 3 targets) | optional, not bundled. smoke **tools=18** (P2 +4, P3 +3); 201 worker tests; no new tag yet |
| CAD plugin | `cad-v0.1.2` | unaffected |
| Presentation | `presentation-v0.0.3` | prior work |

Known: Minerva `development` CI has a pre-existing, unrelated smoke-test failure (owner-confirmed). Not a regression from this work.

---

## 4. Hard rules

- Per-file `git add` only. No `-A` / `.`. No `--no-verify`. No `vendor/` touches. No force-push, no `git reset --hard`.
- Commit co-author trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Push authorization (this initiative):** owner authorized push-as-we-go 2026-05-31 — Minerva→`development`, minerva-plugins→`main`. No feature branches; commit straight to the integration branch.

---

## 5. First actions for next session

1. Read this file + the canonical kb `019e7f366d99`. Pull both repos. Read DCR comment 410 (no-bleed contract) before touching P2.
2. Start **P2.1 `019e8f306e`** — reimplement glob/grep(bundled rg)/bash/cwd in the worker `files/`, envelope-routed, `minerva_codetools_*`. Suggested: `/work-cycle` (SONNET impl + OPUS review). Build P2.1 then P2.2 BEFORE the P2.3 core removal.
3. Keep the three P1.4 follow-ups (`019e8f2489`/`019e8f2282`/`019e8f29a2`) in mind but they're backlog, not P2 blockers.
