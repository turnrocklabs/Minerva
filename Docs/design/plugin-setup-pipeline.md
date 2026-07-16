# Plugin Setup Pipeline — Contracts (R0)

DCR `019f69428fa0` — deterministic manifest-install build pipeline. This document
is the R0 output: the contracts every later round implements against. Decisions
here were settled in the 2026-07-15 design conversation; changing them mid-campaign
requires a checkpoint comment on the DCR explaining why.

Lane split (context): manifest install ≡ dev with source present → ALWAYS build as
an install stage. Marketplace install ≡ SHA-pinned release artifact (existing
pattern; out of scope here except C6). No-FCIB: git holds source + recipe +
lockfiles, never binaries.

## 1. `setup` stanza schema (G1.1)

**Serialization decision: JSON inside `manifest.json`.** Godot core has no YAML
parser; the grammar is CI-shaped but the encoding is the manifest's native JSON.
A YAML sidecar can be revisited if plugin authors ask for it — the schema below
is encoding-independent.

```json
"setup": {
  "requires": [
    {"tool": "go",     "min": "1.22"},
    {"tool": "python", "min": "3.10"}
  ],
  "steps": [
    {"type": "go_build",    "package": "./",   "output": "bin/pcb-plugin"},
    {"type": "python_venv", "dir": "worker",   "install": "editable"},
    {"type": "copy",        "from": "assets/policy.json", "to": "bin/policy.json"},
    {"type": "exec",        "argv": ["./scripts/postinstall.sh"], "artifact": "bin/generated.dat"}
  ]
}
```

### Step vocabulary (v1 — closed; additions must pass the litmus test below)

| type | required fields | optional | implicit artifact |
|---|---|---|---|
| `go_build` | `package`, `output` | `timeout_s` | `output` |
| `cargo_build` | `manifest_dir`, `artifact` | `profile` (default `release`), `timeout_s` | `artifact` |
| `python_venv` | `dir`, `install` (`"editable"` \| `"requirements"`) | `requirements_file` (default `requirements.txt`), `timeout_s` | `<dir>/.venv` marker (`pyvenv.cfg`) |
| `copy` | `from`, `to` | — | `to` |
| `exec` | `argv` (non-empty string array) | `artifact`, `timeout_s` | none |

Rules:
- All paths are **relative to the plugin data_directory** (the dev source dir).
  Absolute paths and `..`-escapes are validation errors. **No env-var expansion
  anywhere** — `%X%`/`$X` are literal characters (the stray `pcb/worker/%SystemDrive%`
  dir is the cautionary tale).
- **Working directory (amended 2026-07-15, R1 review MF1/MF2)**: steps are
  **cwd-independent** — Godot cannot set a child cwd, and every wrapper that
  fakes one either breaks a platform (`env -C` is GNU-only; macOS BSD env lacks
  it) or re-introduces a shell (`cmd.exe /c`). Executors therefore absolutize
  paths against the plugin dir at argv-build time: `go_build` uses
  `go build -C <plugin_dir>` (go >= 1.20; declare in `requires`); `cargo_build`
  uses an absolute `--manifest-path`; `python_venv`/`copy` use absolute paths.
  `exec` gets **no cwd guarantee**: argv[0] beginning with `./` is resolved
  against the plugin dir; an exec'd program needing the plugin dir derives it
  from argv[0] or takes it as an explicit argument. Never wrap argv in a shell
  or env-relay to simulate cwd.
- Any step MAY declare `artifact`; the runner verifies existence after the step.
  `go_build`/`cargo_build`/`copy` verify their implicit artifact regardless.
- `timeout_s` default: 300 per step; probe timeout is separate (5s).
- `exec` is the only step requiring explicit user confirmation at install (its
  argv is shown verbatim); it is deterministic (literal argv, no shell) but
  arbitrary.
- Litmus for new vocabulary: could two machines with the same checkout + same
  tool versions disagree about what to execute? If yes, it doesn't go in.

### Validation (PluginDefinition load-time; typed error codes)

| code | condition |
|---|---|
| `setup_unknown_step_type` | step `type` not in vocabulary |
| `setup_step_missing_field` | required field absent (error names step index + field) |
| `setup_path_escape` | absolute path or `..` traversal in any path field |
| `setup_bad_requires` | `requires` entry missing `tool`/`min`, or `min` not semver-ish |
| `setup_empty_argv` | `exec` with empty/non-string argv |

A manifest with no `setup` stanza is valid (plugin ships no native step — GDScript-
only plugins). A manifest with an entrypoint binary but no `setup` stanza gets a
load-time WARNING (the binary has no declared producer).

## 2. Toolchain registry + preflight contract (C2)

Registry entries (core, v1): `go`, `cargo`, `python`, `node`, `bun`, `zig`, `scons`.
Each entry: candidate exe names (e.g. python → `python`, `python3`), version argv
(e.g. `["go", "version"]`), version-parse regex, well-known install dirs per OS,
install-hint URL, shim-reject patterns.

Probe contract:
1. Resolution order: user override (config) → well-known dirs → PATH. GUI-launched
   Godot does not inherit shell PATH; the well-known tier is mandatory.
2. Reject-before-execute: candidate path matching a shim pattern
   (`*/Microsoft/WindowsApps/*`) is skipped with reason `toolchain_shim_rejected`.
3. Execute the version argv with a **5s timeout**. Pass = exit 0 AND regex parses
   a version. Hang or garbage = fail. Presence on PATH is never sufficiency.
4. Semver-compare parsed version vs `min`.
5. Persist resolved absolute paths machine-locally (`user://` config section
   `toolchain_paths`); invalidate on explicit re-check or failed build. Resolved
   paths are handed to executors verbatim — no re-resolution mid-build.

Preflight error envelope (one per failed requirement):
```json
{"error": "toolchain_missing" | "toolchain_too_old" | "toolchain_shim_rejected" | "toolchain_probe_failed",
 "tool": "go", "found_path": "...", "found_version": "1.19", "required_min": "1.22",
 "install_hint": "https://go.dev/dl"}
```
Preflight is advisory (fast, specific errors for the 90% case); the always-run
build is the real gate.

## 3. State machine + error envelope (G3.2 contract)

New states alongside the existing PluginManager states:
- `S_BUILDING` — setup pipeline running. Detail: current step index/type.
- `S_BUILD_FAILED` — terminal until Rebuild. Carries the envelope below.
- `S_NEEDS_BINARY` — installed but no runnable artifact for this platform and no
  setup lane available (marketplace lane, C6; also the preflight-failed landing
  state, carrying the preflight envelope).

Transitions: `S_BUILDING → registered/S_STARTING | S_BUILD_FAILED`;
`S_BUILD_FAILED → S_BUILDING` (Rebuild = preflight + pipeline rerun). States and
envelopes persist across restart — a half-installed plugin reports honestly on
next launch.

Build-failure envelope:
```json
{"error": "setup_step_failed", "step_type": "go_build", "step_index": 1,
 "resolved_argv": ["/usr/local/go/bin/go", "build", "-o", "bin/pcb-plugin", "./"],
 "exit_code": 2, "stderr_tail": "<= 2KB>", "artifact_expected": "bin/pcb-plugin"}
```
`artifact_expected` present ⇔ failure was the post-step artifact check
(`exit_code` 0, artifact absent ⇒ manifest bug — say so in the UI string).

Final entrypoint verification (amended 2026-07-15, R2 review): a mismatch between
the manifest's declared entrypoint and what the steps produced reuses this same
envelope with `step_type: "entrypoint_check"` and `step_index = steps.size()`.

Always-build rule: the pipeline runs on EVERY manifest install/reinstall; the
toolchain's incremental build is the cache. No Minerva-level source-hash skip in v1.

## 4. Fixture matrix (C5 contract)

Fake tools are real executables (shell/py scripts in the fixture dir) spawned by
the real runner — outermost-boundary fakes, satisfying the functional floor.

Coverage audit (this round, docket C5): every row below names the deepest
level actually exercised — `schema`/`registry`/`executor`/`SetupPipeline`
(direct, worker-thread) / `PluginManager` (real install/rebuild path, FakeDB
backing store). Rows with no `PluginManager`-level test include the reason
inline (either genuinely untestable at that level, or the propagation
mechanism is already proven by a sibling row's PluginManager-level test, so a
second PluginManager fixture would duplicate proof rather than add coverage).

| # | fixture | expected terminal state | covering test(s) | level |
|---|---|---|---|---|
| F1 | copy-only happy path | registered; artifact exists | `test_plugin_setup_executors.gd::test_copy_happy_path`; `test_plugin_setup_pipeline.gd::test_f1_copy_only_happy`; `test_plugin_setup_pipeline.gd::test_pm_install_success_registers_after_pipeline` (fixture `pm_install_happy`) | executor + SetupPipeline + **PluginManager** |
| F2 | go_build happy (fake `go` prints version, writes `output`) | registered | `test_plugin_setup_executors.gd::test_go_build_happy_path`; `test_plugin_setup_pipeline.gd::test_f2_go_build_happy`; `test_setup_matrix.gd::test_f2_pm_install_go_build_happy` (fixture `pm_install_go_build`, gap filled this round) | executor + SetupPipeline + **PluginManager** |
| F3 | requires tool absent everywhere | S_NEEDS_BINARY + `toolchain_missing` | `test_toolchain_registry.gd::test_missing_envelope`; `test_plugin_setup_pipeline.gd::test_f3_missing_tool`; `test_plugin_setup_pipeline.gd::test_pm_install_missing_tool_sets_needs_binary` (fixture `pm_install_missing_tool`) | registry + SetupPipeline + **PluginManager** |
| F4 | fake go prints `go1.19` vs min 1.22 | S_NEEDS_BINARY + `toolchain_too_old` | `test_toolchain_registry.gd::test_too_old_envelope`; `test_setup_matrix.gd::test_f4_pm_install_tool_too_old` (fixture `pm_install_tool_too_old`, reuses `fixtures/toolchain/too_old`, gap filled this round) | registry + **PluginManager** |
| F5 | only candidate lives under a `Microsoft/WindowsApps/` fixture dir | S_NEEDS_BINARY + `toolchain_shim_rejected` | `test_toolchain_registry.gd::test_shim_rejected_without_execution`; `test_setup_matrix.gd::test_f5_pm_install_shim_only_candidate` (fixture `pm_install_tool_shim`, reuses `fixtures/toolchain/shim`, marker-file proof of non-execution carried through the full install path, gap filled this round) | registry + **PluginManager** |
| F6 | fake tool sleeps > probe timeout | S_NEEDS_BINARY + `toolchain_probe_failed` (within deadline) | `test_toolchain_registry.gd::test_hang_deadline_enforced`; `test_setup_matrix.gd::test_f6_pm_install_hanging_probe` (fixture `pm_install_tool_hang`, reuses `fixtures/toolchain/hang`, asserts the full `install_plugin()` round trip stays under ~7.5s despite the fixture's 8s sleep, gap filled this round) | registry + **PluginManager** (wall-clock bound asserted at both levels) |
| F7 | step exits 2 | S_BUILD_FAILED, envelope has exit_code 2 + stderr_tail | `test_plugin_setup_executors.gd::test_exec_exit_2_returns_failure_envelope`; `test_plugin_setup_pipeline.gd::test_f7_step_exit_2`; `test_plugin_setup_pipeline.gd::test_pm_install_failure_sets_build_failed_and_envelope` (fixture `pm_install_fail`) | executor + SetupPipeline + **PluginManager** |
| F8 | step exits 0, artifact absent | S_BUILD_FAILED with `artifact_expected` | `test_plugin_setup_executors.gd::test_exec_exit_0_no_artifact_returns_artifact_expected`; related entrypoint-check variant (§3 amendment, same envelope shape with `step_type: "entrypoint_check"`) at `test_plugin_setup_pipeline.gd::test_entrypoint_artifact_missing_fails_pipeline`. No dedicated PluginManager-level fixture: the `setup_step_failed` → S_BUILD_FAILED propagation from SetupExecutors through SetupPipeline into PluginManager is already proven end-to-end by F7's PluginManager test (identical error code, identical propagation path, only the *reason* for step failure differs) — a second PluginManager fixture would duplicate that proof, not add coverage. Executor level is the deepest level that isolates the `artifact_expected` condition itself. | executor (+ pipeline entrypoint-check variant); PluginManager propagation covered via F7 |
| F9 | step exceeds `timeout_s` | S_BUILD_FAILED within deadline | `test_plugin_setup_executors.gd::test_exec_timeout_is_enforced`; `test_plugin_setup_pipeline.gd::test_run_async_does_not_block_main_thread` (an actual `timeout_s`-exceeding exec step run through the real worker-thread pipeline, with wall-clock assertions). No dedicated PluginManager-level fixture for the same duplication reason as F8 — see that row. | executor + SetupPipeline; PluginManager propagation covered via F7 |
| F10 | exec step | argv reaches the fake executable verbatim (echo-argv fixture) | `test_plugin_setup_executors.gd::test_exec_argv_reaches_process_verbatim`, `::test_exec_relative_argv0_resolved_against_plugin_dir`, `::test_dry_run_and_executor_argv_parity`. Exec steps are also exercised end-to-end through the real SetupPipeline in `test_plugin_setup_pipeline.gd::test_approver_approves_exec_step`/`::test_approver_denies_exec_step` (real `/bin/sh`/`/bin/echo` subprocesses) and through PluginManager via F7's `pm_install_fail` fixture (`exec` step type). No dedicated PluginManager-level argv-capture fixture: the verbatim-argv guarantee is a property of `SetupExecutors.run_step()` alone (plugin_dir-relative resolution, no shell) and is identical regardless of caller; executor level is the deepest level that isolates it. | executor (deepest for argv-content assertions) + SetupPipeline + PluginManager (exec-step plumbing only) |
| F11 | schema rejects (one per validation code) | load-time typed error, nothing runs | `test_plugin_setup_schema.gd` — one test per code: `test_unknown_step_type` (`setup_unknown_step_type`), `test_missing_required_field_names_index_and_field` (`setup_step_missing_field`), `test_absolute_path_rejected`/`test_dotdot_traversal_rejected` (`setup_path_escape`), `test_requires_missing_tool`/`test_requires_missing_min`/`test_requires_bad_min_format` (`setup_bad_requires`), `test_exec_empty_argv_rejected`/`test_exec_non_string_argv_entry_rejected` (`setup_empty_argv`); plus real load-time rejection via `test_from_manifest_rejects_bad_setup_fixture` (fixture `bad_setup_manifest.json`) and `test_plugin_definition_validate_surfaces_setup_errors`. `PluginDefinition.from_manifest()` IS the real production load path a manifest-install goes through before `PluginManager.install_plugin()` ever runs — this is already the deepest sensible level; a bad-schema manifest never reaches `install_plugin()` in production either. | schema unit + **real load-time path** (`PluginDefinition.from_manifest`) |
| F12 | dry-run golden | rendered plan byte-identical to golden file | `test_plugin_setup_executors.gd::test_dry_run_matches_golden_file`, `::test_dry_run_is_deterministic_across_repeated_calls` | unit (SetupDryRun has no subprocess/filesystem surface of its own — this is the deepest possible level, see that suite's own module comment) |
| F13 | re-run F2 unchanged | registered again; fake go invoked again (always-build proven) | `test_plugin_setup_pipeline.gd::test_f13_rerun_always_builds` (same `plugin_dir`, two separate `run_async()` calls, invocation-marker asserted == 2). No PluginManager-level equivalent: `PluginManager.rebuild()` is only callable from `S_BUILD_FAILED`/`S_NEEDS_BINARY` (`PluginManager.gd:813`) and `install_plugin()` refuses a duplicate id, so "reinstall an already-`S_INSTALLED` plugin unchanged" is not a reachable PluginManager-level flow in the product — there is nothing deeper to test against. The always-build guarantee is a `SetupPipeline`-level contract (§3) and this is the correct boundary to prove it at. | SetupPipeline (deepest reachable level — see reasoning) |

Gap-filling suite: `src/test/test_setup_matrix.gd` (F2/F4/F5/F6 PluginManager-level
tests) + `src/test/run_setup_suites.sh` (one-command runner for all five
suites, CI-ready). New fixtures: `fixtures/setup_pipeline/pm_install_go_build/`,
`pm_install_tool_too_old/`, `pm_install_tool_shim/`, `pm_install_tool_hang/`
(each reuses the existing `fixtures/toolchain/{too_old,shim,hang}` fake-tool
scripts via `search_dirs_override`, no new fake-tool scripts needed).

## 5. Out of scope (this campaign)

C6 marketplace lane (separate cycle — would be a second HITL); `container:`
executor; Minerva-level build cache; YAML sidecar.
