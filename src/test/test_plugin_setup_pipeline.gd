extends SceneTree
## Non-mocked functional-floor tests for SetupPipeline (the setup-pipeline
## orchestrator: preflight -> steps -> entrypoint check, threaded) and its
## PluginManager integration (S_BUILDING/S_BUILD_FAILED/S_NEEDS_BINARY, the
## always-build rule, rebuild(), and cross-restart envelope persistence).
##
## DCR 019f69428fa0 (G3.1/G3.2), contract: Docs/design/plugin-setup-pipeline.md.
##
## Run: godot --headless --path src --script test/test_plugin_setup_pipeline.gd
##
## Two sections:
##
##   A. SetupPipeline direct — drives the real worker-thread pipeline against
##      real fixture executables (fake-go, the R1 exec-step fixtures). Covers
##      the §4 fixture matrix: F1, F2 (go_build), F3, F7, F13 (always-build),
##      plus threading (non-blocking start), abort-on-first-failure, the
##      approver seam, and the final entrypoint-artifact check.
##
##   B. PluginManager integration — drives the REAL PluginManager class
##      (install_plugin / start_plugin / rebuild / get_setup_envelope) end to
##      end, including the setup-pipeline kickoff and its terminal-state
##      handling. The underlying PluginDB is swapped for an in-memory FakeDB
##      (deliberate deviation from this repo's pcb/cad/scansort smoke-test
##      convention of using the REAL PluginDB — see FakeDB's doc comment for
##      why) so this suite never mutates the developer's real
##      user://plugins/plugins.json. Every other PluginManager code path
##      (state machine, capability grants, directory creation, the setup
##      pipeline itself) runs for real, unmocked.

const FIXTURES_ROOT := "res://test/fixtures/setup_pipeline"
const PLUGIN_SETUP_FIXTURES_RES := "res://test/fixtures/plugin_setup"
const TOOLCHAIN_FIXTURES_RES := "res://test/fixtures/toolchain"

var _pass_count: int = 0
var _fail_count: int = 0
var _tools_dir: String = ""
var _plugin_setup_fixtures_dir: String = ""
var _scratch_configs: Array[String] = []
var _scratch_state_files: Array[String] = []

## PluginManager.gd is loaded dynamically at RUNTIME (never referenced as a
## static type anywhere in this file) and only after `await process_frame`
## below. Reuse-scan finding, not a stylistic choice: PluginManager.gd's own
## (pre-existing, untouched-by-this-round) `typeof(SingletonObject)` reference
## in _build_available_tools() makes the engine try to resolve the
## SingletonObject autoload AT SCRIPT-COMPILE TIME whenever anything statically
## types a variable/parameter/return value as `PluginManager` — and in
## `--script` headless mode that compile can be forced before the autoload
## singleton table is populated, which corrupts the script's GDScript
## resource for the rest of the process (observed as a hard SIGSEGV later,
## reproduced identically on the pre-existing, unmodified
## test_plugin_manager_hot_reload.gd — not something introduced by this
## round). test_pcb_plugin_smoke.gd already works around this the same way:
## `load(PLUGIN_MANAGER_SCRIPT_PATH)` inside _init(), never a bare
## `PluginManager` type reference.
var _pm_script: GDScript = null


func _init() -> void:
	print("=== SetupPipeline + PluginManager Integration Tests ===\n")

	await process_frame
	_pm_script = load("res://Scripts/Services/Plugins/PluginManager.gd")

	_tools_dir = ProjectSettings.globalize_path(FIXTURES_ROOT.path_join("tools"))
	_plugin_setup_fixtures_dir = ProjectSettings.globalize_path(PLUGIN_SETUP_FIXTURES_RES)
	_ensure_fixtures_executable()

	print("########## SECTION A — SetupPipeline direct ##########\n")

	print("-- F1: copy-only happy path --")
	await test_f1_copy_only_happy()

	print("\n-- F2: go_build happy path (fake-go fixture) --")
	await test_f2_go_build_happy()

	print("\n-- F3: missing tool -> S_NEEDS_BINARY --")
	await test_f3_missing_tool()

	print("\n-- preflight with MULTIPLE missing tools -> all surfaced in envelope --")
	await test_preflight_multiple_failures_all_surfaced()

	print("\n-- F7: step exits 2 -> S_BUILD_FAILED --")
	await test_f7_step_exit_2()

	print("\n-- F13: re-run F2 unchanged -> always-build proven --")
	await test_f13_rerun_always_builds()

	print("\n-- threading: run_async() does not block the caller --")
	await test_run_async_does_not_block_main_thread()

	print("\n-- abort-on-first-failure: remaining steps never run --")
	await test_aborts_remaining_steps_on_first_failure()

	print("\n-- approver seam: deny --")
	await test_approver_denies_exec_step()

	print("\n-- approver seam: approve --")
	await test_approver_approves_exec_step()

	print("\n-- entrypoint-artifact check: steps ok but entrypoint missing --")
	await test_entrypoint_artifact_missing_fails_pipeline()

	print("\n\n########## SECTION B — PluginManager integration (real class, FakeDB) ##########\n")

	print("-- install_plugin() success: S_BUILDING then S_INSTALLED --")
	await test_pm_install_success_registers_after_pipeline()

	print("\n-- install_plugin() failure: S_BUILD_FAILED + envelope; start_plugin() refused --")
	await test_pm_install_failure_sets_build_failed_and_envelope()

	print("\n-- install_plugin() preflight failure: S_NEEDS_BINARY --")
	await test_pm_install_missing_tool_sets_needs_binary()

	print("\n-- rebuild() after fixing the broken fixture -> success --")
	await test_pm_rebuild_after_fixing_fixture_succeeds()

	print("\n-- envelope persists across a simulated restart --")
	await test_pm_setup_envelope_persists_across_restart()

	print("\n-- stanza-less manifest: zero behavior change --")
	await test_pm_install_no_stanza_is_unaffected()

	print("\n-- remove_plugin() refused while S_BUILDING (MF1 guard) --")
	await test_pm_remove_refused_while_building()

	_cleanup_scratch_files()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Section A — SetupPipeline direct
# ---------------------------------------------------------------------------

func test_f1_copy_only_happy() -> void:
	var plugin_dir := _fresh_dir("f1_copy_only")
	var src_dir := plugin_dir.path_join("assets")
	DirAccess.make_dir_recursive_absolute(src_dir)
	var f := FileAccess.open(src_dir.path_join("policy.json"), FileAccess.WRITE)
	f.store_string("{\"ok\":true}")
	f.close()

	var setup := {"requires": [], "steps": [
		{"type": "copy", "from": "assets/policy.json", "to": "bin/policy.json"},
	]}
	var pipeline := SetupPipeline.new()
	var rec := Recorder.new()
	pipeline.finished.connect(rec.on_finished)
	pipeline.run_async("f1", setup, plugin_dir, "bin/policy.json")
	await _wait_pipeline_done(pipeline)

	check("F1 pipeline succeeds", rec.finished_result.get("ok", false) == true, str(rec.finished_result))
	check("F1 state is 'registered'", rec.finished_result.get("state", "") == "registered", str(rec.finished_result))
	check("F1 artifact exists", FileAccess.file_exists(plugin_dir.path_join("bin/policy.json")))


func test_f2_go_build_happy() -> void:
	var plugin_dir := _fresh_dir("f2_go_build")
	var setup := {
		"requires": [{"tool": "go", "min": "1.22"}],
		"steps": [{"type": "go_build", "package": "./", "output": "bin/fake-plugin", "timeout_s": 15}],
	}
	var pipeline := SetupPipeline.new()
	pipeline.toolchain_registry = _fake_go_registry("f2")
	var rec := Recorder.new()
	pipeline.finished.connect(rec.on_finished)
	pipeline.run_async("f2", setup, plugin_dir, "bin/fake-plugin")
	await _wait_pipeline_done(pipeline)

	check("F2 pipeline succeeds", rec.finished_result.get("ok", false) == true, str(rec.finished_result))
	check("F2 artifact was written by fake-go", FileAccess.file_exists(plugin_dir.path_join("bin/fake-plugin")))


func test_f3_missing_tool() -> void:
	var plugin_dir := _fresh_dir("f3_missing_tool")
	var setup := {"requires": [{"tool": "go", "min": "1.22"}], "steps": []}
	var pipeline := SetupPipeline.new()
	var reg := ToolchainRegistry.new()
	reg.config_path = _scratch_config_path("f3")
	reg.search_dirs_override = [_toolchain_fixture_dir("empty")]
	pipeline.toolchain_registry = reg
	var rec := Recorder.new()
	pipeline.finished.connect(rec.on_finished)
	pipeline.run_async("f3", setup, plugin_dir, "")
	await _wait_pipeline_done(pipeline)

	check("F3 pipeline fails", rec.finished_result.get("ok", true) == false, str(rec.finished_result))
	check("F3 state is S_NEEDS_BINARY", rec.finished_result.get("state", "") == "S_NEEDS_BINARY", str(rec.finished_result))
	var envelope: Dictionary = rec.finished_result.get("envelope", {})
	check("F3 envelope error is toolchain_missing", envelope.get("error", "") == "toolchain_missing", str(envelope))
	check("F3 envelope tool is 'go'", envelope.get("tool", "") == "go", str(envelope))


## Review minor-fix 1: ToolchainRegistry.preflight() reports EVERY failed
## requirement (never stops at the first) — the pipeline envelope must not
## re-hide that. The envelope's top level stays the first failure's flat §2
## shape; `failures` carries the full per-tool array.
func test_preflight_multiple_failures_all_surfaced() -> void:
	var plugin_dir := _fresh_dir("preflight_multi")
	var setup := {
		"requires": [
			{"tool": "go", "min": "1.22"},
			{"tool": "cargo", "min": "1.70"},
		],
		"steps": [],
	}
	var pipeline := SetupPipeline.new()
	var reg := ToolchainRegistry.new()
	reg.config_path = _scratch_config_path("preflight_multi")
	reg.search_dirs_override = [_toolchain_fixture_dir("empty")]
	pipeline.toolchain_registry = reg
	var rec := Recorder.new()
	pipeline.finished.connect(rec.on_finished)
	pipeline.run_async("preflight_multi", setup, plugin_dir, "")
	await _wait_pipeline_done(pipeline)

	check("multi-failure pipeline lands in S_NEEDS_BINARY",
			rec.finished_result.get("state", "") == "S_NEEDS_BINARY", str(rec.finished_result))
	var envelope: Dictionary = rec.finished_result.get("envelope", {})
	check("envelope top level keeps the flat §2 shape (first failure)",
			envelope.get("error", "") == "toolchain_missing" and envelope.get("tool", "") != "", str(envelope))
	var failures: Array = envelope.get("failures", [])
	check("envelope carries BOTH failures in `failures`", failures.size() == 2,
			"got %d: %s" % [failures.size(), str(failures)])
	var tools_seen := {}
	for fe in failures:
		tools_seen[fe.get("tool", "")] = fe.get("error", "")
	check("go failure present in failures array", tools_seen.get("go", "") == "toolchain_missing", str(tools_seen))
	check("cargo failure present in failures array", tools_seen.get("cargo", "") == "toolchain_missing", str(tools_seen))


func test_f7_step_exit_2() -> void:
	var plugin_dir := _fresh_dir("f7_exit2")
	var script := _plugin_setup_fixtures_dir.path_join("exit2-with-stderr.sh")
	var setup := {"requires": [], "steps": [
		{"type": "exec", "argv": [script], "timeout_s": 15},
	]}
	var pipeline := SetupPipeline.new()
	var rec := Recorder.new()
	pipeline.finished.connect(rec.on_finished)
	pipeline.run_async("f7", setup, plugin_dir, "")
	await _wait_pipeline_done(pipeline)

	check("F7 pipeline fails", rec.finished_result.get("ok", true) == false, str(rec.finished_result))
	check("F7 state is S_BUILD_FAILED", rec.finished_result.get("state", "") == "S_BUILD_FAILED", str(rec.finished_result))
	var envelope: Dictionary = rec.finished_result.get("envelope", {})
	check("F7 envelope error is setup_step_failed", envelope.get("error", "") == "setup_step_failed", str(envelope))
	check("F7 envelope exit_code is 2", envelope.get("exit_code", -1) == 2, str(envelope))
	check("F7 envelope stderr_tail contains the fixture's stderr", str(envelope.get("stderr_tail", "")).contains("boom"), str(envelope))


func test_f13_rerun_always_builds() -> void:
	var plugin_dir := _fresh_dir("f13_rerun")
	var setup := {
		"requires": [{"tool": "go", "min": "1.22"}],
		"steps": [{"type": "go_build", "package": "./", "output": "bin/fake-plugin", "timeout_s": 15}],
	}
	var marker := plugin_dir.path_join(".fake_go_invocations")
	# _fresh_dir() does not wipe a pre-existing directory (matching the R1
	# test convention — see test_plugin_setup_executors.gd's own
	# _fresh_plugin_dir), and this fixture dir path is stable across separate
	# process invocations of this whole test file — clear any marker left
	# over from a PRIOR run so this test's own "exactly twice" assertion is
	# never polluted by counts accumulated across unrelated runs.
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)

	for i in range(2):
		var pipeline := SetupPipeline.new()
		pipeline.toolchain_registry = _fake_go_registry("f13_%d" % i)
		var rec := Recorder.new()
		pipeline.finished.connect(rec.on_finished)
		pipeline.run_async("f13", setup, plugin_dir, "bin/fake-plugin")
		await _wait_pipeline_done(pipeline)
		check("F13 run #%d succeeds" % i, rec.finished_result.get("ok", false) == true, str(rec.finished_result))

	check("F13 invocation marker exists", FileAccess.file_exists(marker))
	if FileAccess.file_exists(marker):
		var f := FileAccess.open(marker, FileAccess.READ)
		var count := int(f.get_as_text().strip_edges())
		f.close()
		check("F13 fake-go was invoked exactly twice (always-build; no skip cache)", count == 2, "got %d" % count)


func test_run_async_does_not_block_main_thread() -> void:
	var plugin_dir := _fresh_dir("threading")
	var script := _plugin_setup_fixtures_dir.path_join("sleep-forever.sh")
	var setup := {"requires": [], "steps": [
		{"type": "exec", "argv": [script], "timeout_s": 2},
	]}
	var pipeline := SetupPipeline.new()
	var rec := Recorder.new()
	pipeline.finished.connect(rec.on_finished)

	var start_ms := Time.get_ticks_msec()
	pipeline.run_async("threading", setup, plugin_dir, "")
	var kickoff_elapsed_ms := Time.get_ticks_msec() - start_ms
	check("run_async() returns near-instantly (elapsed=%dms)" % kickoff_elapsed_ms,
			kickoff_elapsed_ms < 250, "elapsed=%dms — main thread was blocked" % kickoff_elapsed_ms)

	await _wait_pipeline_done(pipeline)
	var total_elapsed_ms := Time.get_ticks_msec() - start_ms
	check("pipeline actually ran in the background for ~timeout_s before finishing (total=%dms)" % total_elapsed_ms,
			total_elapsed_ms >= 1800, "total=%dms" % total_elapsed_ms)
	check("timed-out exec step reports pipeline failure", rec.finished_result.get("ok", true) == false, str(rec.finished_result))


func test_aborts_remaining_steps_on_first_failure() -> void:
	var plugin_dir := _fresh_dir("abort_on_failure")
	var script := _plugin_setup_fixtures_dir.path_join("exit2-with-stderr.sh")
	var setup := {
		"requires": [],
		"steps": [
			{"type": "exec", "argv": [script], "timeout_s": 15},
			{"type": "copy", "from": "assets/never.txt", "to": "bin/never.txt"},
		],
	}
	var pipeline := SetupPipeline.new()
	var rec := Recorder.new()
	pipeline.step_started.connect(rec.on_step_started)
	pipeline.finished.connect(rec.on_finished)
	pipeline.run_async("abort", setup, plugin_dir, "")
	await _wait_pipeline_done(pipeline)

	check("only step 0 ever started", rec.started_indices == [0], "got %s" % str(rec.started_indices))
	check("step 1's artifact was never produced", not FileAccess.file_exists(plugin_dir.path_join("bin/never.txt")))
	check("pipeline reports failure", rec.finished_result.get("ok", true) == false, str(rec.finished_result))


func test_approver_denies_exec_step() -> void:
	var plugin_dir := _fresh_dir("approver_deny")
	var setup := {"requires": [], "steps": [
		{"type": "exec", "argv": ["/bin/echo", "hi"], "timeout_s": 15},
	]}
	var pipeline := SetupPipeline.new()
	var rec := Recorder.new()
	pipeline.approver = rec.on_approve_deny
	pipeline.finished.connect(rec.on_finished)
	pipeline.run_async("deny", setup, plugin_dir, "")
	await _wait_pipeline_done(pipeline)

	check("approver was consulted", rec.approve_calls == 1, "got %d" % rec.approve_calls)
	check("denied exec step fails the pipeline", rec.finished_result.get("ok", true) == false, str(rec.finished_result))
	check("denied state is S_BUILD_FAILED", rec.finished_result.get("state", "") == "S_BUILD_FAILED", str(rec.finished_result))
	var envelope: Dictionary = rec.finished_result.get("envelope", {})
	check("denied envelope stderr_tail mentions the denial", str(envelope.get("stderr_tail", "")).contains("denied"), str(envelope))
	check("denied envelope is machine-distinguishable from a broken build (detail=exec_denied)",
			envelope.get("detail", "") == "exec_denied", str(envelope))


func test_approver_approves_exec_step() -> void:
	var plugin_dir := _fresh_dir("approver_allow")
	var outfile := plugin_dir.path_join("out.txt")
	var setup := {"requires": [], "steps": [
		{"type": "exec", "argv": ["/bin/sh", "-c", "echo hi > \"%s\"" % outfile], "timeout_s": 15, "artifact": "out.txt"},
	]}
	var pipeline := SetupPipeline.new()
	var rec := Recorder.new()
	pipeline.approver = rec.on_approve_allow
	pipeline.finished.connect(rec.on_finished)
	pipeline.run_async("allow", setup, plugin_dir, "")
	await _wait_pipeline_done(pipeline)

	check("approver was consulted exactly once", rec.approve_calls == 1, "got %d" % rec.approve_calls)
	check("approved exec step succeeds", rec.finished_result.get("ok", false) == true, str(rec.finished_result))
	check("approved exec step's artifact exists", FileAccess.file_exists(outfile))


func test_entrypoint_artifact_missing_fails_pipeline() -> void:
	var plugin_dir := _fresh_dir("entrypoint_missing")
	var src_dir := plugin_dir.path_join("assets")
	DirAccess.make_dir_recursive_absolute(src_dir)
	var f := FileAccess.open(src_dir.path_join("policy.json"), FileAccess.WRITE)
	f.store_string("{}")
	f.close()

	# The declared step succeeds and produces its OWN artifact (bin/policy.json),
	# but the manifest's entrypoint points somewhere else entirely
	# (bin/does-not-exist) — every step-level check passes, yet the pipeline
	# must still fail on the final entrypoint-existence check.
	var setup := {"requires": [], "steps": [
		{"type": "copy", "from": "assets/policy.json", "to": "bin/policy.json"},
	]}
	var pipeline := SetupPipeline.new()
	var rec := Recorder.new()
	pipeline.finished.connect(rec.on_finished)
	pipeline.run_async("entrypoint_missing", setup, plugin_dir, "bin/does-not-exist")
	await _wait_pipeline_done(pipeline)

	check("pipeline fails on the entrypoint check even though all steps ok",
			rec.finished_result.get("ok", true) == false, str(rec.finished_result))
	check("state is S_BUILD_FAILED", rec.finished_result.get("state", "") == "S_BUILD_FAILED", str(rec.finished_result))
	var envelope: Dictionary = rec.finished_result.get("envelope", {})
	check("envelope names the missing entrypoint artifact",
			envelope.get("artifact_expected", "") == "bin/does-not-exist", str(envelope))


# ---------------------------------------------------------------------------
# Section B — PluginManager integration
# ---------------------------------------------------------------------------

func test_pm_install_success_registers_after_pipeline() -> void:
	var db := FakeDB.new()
	var pm = _make_pm(db)
	var manifest := _pm_fixture("pm_install_happy/manifest.json")
	var id := "setup_pipeline_pm_test"

	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("install_plugin returns ok", install_result.get("ok", false) == true, str(install_result))
	check("install_plugin result flags building:true", install_result.get("building", false) == true, str(install_result))

	var def = db.get_by_id(id)
	check("plugin registered in db", def != null)
	if def == null:
		return
	check("state is S_BUILDING right after install_plugin() returns (proves non-blocking kickoff)",
			def.state == _pm_script.S_BUILDING, "got %d" % def.state)

	await _wait_not_building(pm, id)
	check("state is S_INSTALLED ('registered') once the pipeline finishes", def.state == _pm_script.S_INSTALLED, "got %d" % def.state)

	var artifact: String = ProjectSettings.globalize_path(def.data_directory).path_join("bin/plugin.txt")
	check("copy step's artifact exists on disk", FileAccess.file_exists(artifact))
	check("no leftover setup envelope on success", pm.get_setup_envelope(id).is_empty())

	_cleanup_pm_data_dir(pm, id)


func test_pm_install_failure_sets_build_failed_and_envelope() -> void:
	var db := FakeDB.new()
	var pm = _make_pm(db)
	var manifest := _pm_fixture("pm_install_fail/manifest.json")
	var id := "setup_pipeline_pm_fail_test"

	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("install_plugin still returns ok (kickoff succeeded; the BUILD fails later)",
			install_result.get("ok", false) == true, str(install_result))

	await _wait_not_building(pm, id)
	var def = db.get_by_id(id)
	check("state is S_BUILD_FAILED", def.state == _pm_script.S_BUILD_FAILED, "got %d" % def.state)

	var envelope: Dictionary = pm.get_setup_envelope(id)
	check("envelope error is setup_step_failed", envelope.get("error", "") == "setup_step_failed", str(envelope))
	check("envelope exit_code is 2", envelope.get("exit_code", -1) == 2, str(envelope))
	check("envelope stderr_tail contains the fixture's stderr", str(envelope.get("stderr_tail", "")).contains("boom"), str(envelope))

	# The ~line-549 "binary not found" failure must be unreachable here —
	# start_plugin() refuses BEFORE it ever gets to entrypoint resolution.
	var start_result: Dictionary = await pm.start_plugin(id)
	check("start_plugin() refuses a build-failed plugin", start_result.has("error"), str(start_result))

	_cleanup_pm_data_dir(pm, id)


func test_pm_install_missing_tool_sets_needs_binary() -> void:
	var db := FakeDB.new()
	var pm = _make_pm(db)
	var id := "setup_pipeline_pm_needs_binary_test"
	pm.setup_pipeline_factory = func() -> SetupPipeline:
		var p := SetupPipeline.new()
		var reg := ToolchainRegistry.new()
		reg.config_path = _scratch_config_path("pm_needs_binary")
		reg.search_dirs_override = [_toolchain_fixture_dir("empty")]
		p.toolchain_registry = reg
		return p

	var manifest := _pm_fixture("pm_install_missing_tool/manifest.json")
	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("install_plugin kicks off ok", install_result.get("ok", false) == true, str(install_result))

	await _wait_not_building(pm, id)
	var def = db.get_by_id(id)
	check("state is S_NEEDS_BINARY", def.state == _pm_script.S_NEEDS_BINARY, "got %d" % def.state)

	var envelope: Dictionary = pm.get_setup_envelope(id)
	check("envelope error is toolchain_missing", envelope.get("error", "") == "toolchain_missing", str(envelope))
	check("envelope tool is 'go'", envelope.get("tool", "") == "go", str(envelope))
	check("envelope's stored/persisted surface carries the full failures array",
			(envelope.get("failures", []) as Array).size() == 1, str(envelope))

	var start_result: Dictionary = await pm.start_plugin(id)
	check("start_plugin() refuses a needs-binary plugin", start_result.has("error"), str(start_result))

	_cleanup_pm_data_dir(pm, id)


func test_pm_rebuild_after_fixing_fixture_succeeds() -> void:
	var scratch_dir := _copy_fixture_to_scratch("pm_install_fail", "rebuild_case")
	var manifest := scratch_dir.path_join("manifest.json")
	OS.execute("chmod", ["+x", scratch_dir.path_join("exit2.sh")])

	var db := FakeDB.new()
	var pm = _make_pm(db)
	var id := "setup_pipeline_pm_fail_test"

	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("rebuild-case install kicks off ok", install_result.get("ok", false) == true, str(install_result))
	await _wait_not_building(pm, id)
	var def = db.get_by_id(id)
	check("rebuild-case initial state is S_BUILD_FAILED", def.state == _pm_script.S_BUILD_FAILED, "got %d" % def.state)

	var rebuild_before: Dictionary = pm.rebuild(id + "-not-a-real-id")
	check("rebuild() on an unknown id errors", rebuild_before.has("error"), str(rebuild_before))

	# "Fix" the fixture: the script that used to exit 2 now exits 0.
	var f := FileAccess.open(scratch_dir.path_join("exit2.sh"), FileAccess.WRITE)
	f.store_string("#!/usr/bin/env bash\nexit 0\n")
	f.close()
	OS.execute("chmod", ["+x", scratch_dir.path_join("exit2.sh")])

	var rebuild_result: Dictionary = pm.rebuild(id)
	check("rebuild() returns ok", rebuild_result.get("ok", false) == true, str(rebuild_result))
	check("rebuild() transitions straight to S_BUILDING", def.state == _pm_script.S_BUILDING, "got %d" % def.state)

	await _wait_not_building(pm, id)
	check("state is S_INSTALLED after the rebuilt pipeline succeeds", def.state == _pm_script.S_INSTALLED, "got %d" % def.state)
	check("envelope cleared after a successful rebuild", pm.get_setup_envelope(id).is_empty())

	pm._delete_directory_recursive(scratch_dir)


func test_pm_setup_envelope_persists_across_restart() -> void:
	var db1 := FakeDB.new()
	var pm1 = _make_pm(db1)
	var id := "setup_pipeline_pm_fail_test"
	var scratch_state_path := "user://test_setup_state_%d.json" % Time.get_ticks_usec()
	_scratch_state_files.append(scratch_state_path)
	pm1.setup_state_path = scratch_state_path

	var manifest := _pm_fixture("pm_install_fail/manifest.json")
	await pm1.install_plugin(manifest, true)
	await _wait_not_building(pm1, id)
	var def1 = db1.get_by_id(id)
	check("persistence setup: state is S_BUILD_FAILED before the simulated restart",
			def1.state == _pm_script.S_BUILD_FAILED, "got %d" % def1.state)
	var original_envelope: Dictionary = pm1.get_setup_envelope(id)
	check("sidecar state file was written", FileAccess.file_exists(scratch_state_path))
	_cleanup_pm_data_dir(pm1, id)

	# Simulate a restart: a FRESH PluginManager + a FRESH DB record for the
	# same plugin at S_INSTALLED — exactly what PluginDB.load_db() produces
	# for every plugin on every real app boot (it always resets runtime state;
	# see that method's own doc comment). _load_setup_state() must override it.
	var db2 := FakeDB.new()
	var fresh_def := PluginDefinition.from_manifest(manifest)
	db2._plugins[fresh_def.id] = fresh_def
	var pm2 = _pm_script.new()
	pm2._db = db2
	pm2.setup_state_path = scratch_state_path
	pm2._load_setup_state()

	var def2 = db2.get_by_id(id)
	check("restored state is S_BUILD_FAILED after the simulated restart",
			def2.state == _pm_script.S_BUILD_FAILED, "got %d" % def2.state)
	# Field-by-field with `==` (not a str()/JSON round-trip comparison):
	# JSON.parse() returns every persisted number as float (documented, repo-
	# wide GDScript characteristic — see SetupSteps.timeout_of()'s own comment
	# on the same quirk), so exit_code/step_index survive the sidecar
	# save/load as 2.0/0.0 rather than 2/0. `2 == 2.0` is true in GDScript, so
	# this does not affect any real consumer that compares values rather than
	# serialized strings; a str()-based comparison would spuriously fail here.
	var restored_envelope: Dictionary = pm2.get_setup_envelope(id)
	var envelope_keys_match := true
	for key in original_envelope:
		if not restored_envelope.has(key) or restored_envelope[key] != original_envelope[key]:
			envelope_keys_match = false
			break
	check("restored envelope matches the original field-by-field", envelope_keys_match,
			"orig=%s restored=%s" % [str(original_envelope), str(restored_envelope)])


func test_pm_install_no_stanza_is_unaffected() -> void:
	var db := FakeDB.new()
	var pm = _make_pm(db)
	var manifest := _pm_fixture("pm_install_no_stanza/manifest.json")
	var id := "setup_pipeline_pm_no_stanza_test"

	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("no-stanza install returns ok", install_result.get("ok", false) == true, str(install_result))
	check("no-stanza install result carries no 'building' key (unchanged shape)",
			not install_result.has("building"), str(install_result))

	var def = db.get_by_id(id)
	check("no-stanza plugin lands directly in S_INSTALLED (never touches S_BUILDING)",
			def != null and def.state == _pm_script.S_INSTALLED, "got %s" % (str(def.state) if def != null else "<null>"))

	_cleanup_pm_data_dir(pm, id)


## Review MF1: while S_BUILDING, _setup_pipelines holds the only strong ref
## to a RefCounted pipeline whose worker thread is still running — removal
## mid-build was a use-after-free ("Thread destroyed while running") plus a
## delete_data rm of the plugin dir under a live subprocess. remove_plugin()
## must refuse until the pipeline is terminal.
func test_pm_remove_refused_while_building() -> void:
	var db := FakeDB.new()
	var pm = _make_pm(db)
	var manifest := _pm_fixture("pm_install_slow/manifest.json")
	var id := "setup_pipeline_pm_slow_test"

	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("slow-build install kicks off ok", install_result.get("ok", false) == true, str(install_result))

	var def = db.get_by_id(id)
	check("slow-build plugin is S_BUILDING (window for the removal attempt is open)",
			def != null and def.state == _pm_script.S_BUILDING,
			"got %s" % (str(def.state) if def != null else "<null>"))

	var remove_result: Dictionary = pm.remove_plugin(id, true)
	check("remove_plugin(delete_data=true) is REFUSED while S_BUILDING",
			remove_result.has("error"), str(remove_result))
	check("refusal message names the build", str(remove_result.get("error", "")).contains("building"), str(remove_result))
	check("state unchanged by the refused removal", def.state == _pm_script.S_BUILDING, "got %d" % def.state)
	check("plugin still present in db after the refused removal", db.has_plugin(id))

	# The build must complete cleanly despite the removal attempt (no UAF, no
	# thread abort — a crash here would take the whole test process down).
	await _wait_not_building(pm, id)
	check("pipeline completes cleanly after the refused removal (slow.sh exits 0 -> S_INSTALLED)",
			def.state == _pm_script.S_INSTALLED, "got %d" % def.state)

	var remove_after: Dictionary = pm.remove_plugin(id, true)
	check("remove_plugin succeeds once the build is terminal", remove_after.get("ok", false) == true, str(remove_after))
	check("plugin gone from db after the successful removal", not db.has_plugin(id))

	_cleanup_pm_data_dir(pm, id)


# ---------------------------------------------------------------------------
# Recorder — signal/callable capture helper.
#
# GDScript lambdas capture outer local variables BY VALUE for reassignment
# (`func(r): captured = r` does NOT propagate to the enclosing `captured`);
# only mutation of a captured reference type does. Using a real bound method
# on a RefCounted instance sidesteps that pitfall entirely (self-mutation is
# always visible), so every signal/Callable capture in this file goes through
# one of these instead of a `func(x): outer = x` lambda.
# ---------------------------------------------------------------------------

class Recorder extends RefCounted:
	var finished_result: Dictionary = {}
	var finished_count: int = 0
	var started_indices: Array[int] = []
	var approve_calls: int = 0

	func on_finished(r: Dictionary) -> void:
		finished_result = r
		finished_count += 1

	func on_step_started(step_index: int, _step_type: String) -> void:
		started_indices.append(step_index)

	func on_approve_deny(_step: Dictionary, _step_index: int) -> bool:
		approve_calls += 1
		return false

	func on_approve_allow(_step: Dictionary, _step_index: int) -> bool:
		approve_calls += 1
		return true


# ---------------------------------------------------------------------------
# FakeDB — minimal in-memory stand-in for PluginDB.
#
# PluginDB.gd is OUT of this round's scope fence and has no test-isolation
# seam (DB_PATH is a hardcoded `user://plugins/plugins.json` const, the SAME
# file a real running Minerva instance on this machine would be using) — so
# a test driving the real file-backed PluginDB risks a lost-write race against
# a concurrently running app. This repo's existing pcb/cad/scansort smoke
# tests accept that risk and use the real PluginDB directly; this suite makes
# the opposite, more conservative call given the number of real plugins a dev
# machine may have installed. Every OTHER PluginManager code path below
# (install_plugin/start_plugin/rebuild/the setup pipeline itself/state
# transitions/capability grants/directory creation) is exercised for real,
# unmocked — only the backing store is swapped.
# ---------------------------------------------------------------------------

class FakeDB extends RefCounted:
	var _plugins: Dictionary = {}

	func install(manifest_path: String):  # -> PluginDefinition | null
		var def = PluginDefinition.from_manifest(manifest_path)
		if def == null:
			return null
		if _plugins.has(def.id):
			return null
		_plugins[def.id] = def
		return def

	func get_by_id(plugin_id: String):  # -> PluginDefinition | null
		return _plugins.get(plugin_id, null)

	func get_all() -> Array:
		return _plugins.values()

	func get_by_status(status: int) -> Array:
		var out: Array = []
		for def in _plugins.values():
			if def.state == status:
				out.append(def)
		return out

	func get_autostart_plugins() -> Array:
		var out: Array = []
		for def in _plugins.values():
			if def.autostart:
				out.append(def)
		return out

	func has_plugin(plugin_id: String) -> bool:
		return _plugins.has(plugin_id)

	func remove(plugin_id: String) -> bool:
		if not _plugins.has(plugin_id):
			return false
		_plugins.erase(plugin_id)
		return true

	func update_state(plugin_id: String, new_state: int) -> bool:
		var def = _plugins.get(plugin_id, null)
		if def == null:
			return false
		def.state = new_state
		return true

	func update_definition(def) -> bool:  # def: PluginDefinition
		if not _plugins.has(def.id):
			return false
		def.state = _plugins[def.id].state
		_plugins[def.id] = def
		return true

	func set_auto_reload(plugin_id: String, enabled: bool) -> bool:
		var def = _plugins.get(plugin_id, null)
		if def == null:
			return false
		def.auto_reload = enabled
		return true


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _make_pm(db):
	var pm = _pm_script.new()
	pm._db = db
	return pm


func _pm_fixture(rel: String) -> String:
	return ProjectSettings.globalize_path(FIXTURES_ROOT.path_join(rel))


func _toolchain_fixture_dir(name: String) -> String:
	return ProjectSettings.globalize_path(TOOLCHAIN_FIXTURES_RES.path_join(name))


func _fake_go_registry(label: String) -> ToolchainRegistry:
	var reg := ToolchainRegistry.new()
	reg.config_path = _scratch_config_path(label)
	reg.search_dirs_override = [_tools_dir]
	return reg


func _scratch_config_path(label: String) -> String:
	var path := "user://test_setup_pipeline_toolchain_%s_%d.cfg" % [label, Time.get_ticks_usec()]
	_scratch_configs.append(path)
	return path


func _fresh_dir(case_name: String) -> String:
	var dir: String = ProjectSettings.globalize_path("user://setup_pipeline_direct_tests").path_join(case_name)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _copy_fixture_to_scratch(fixture_rel: String, case_name: String) -> String:
	var src_abs: String = ProjectSettings.globalize_path(FIXTURES_ROOT.path_join(fixture_rel))
	var dst_abs: String = ProjectSettings.globalize_path("user://setup_pipeline_pm_scratch").path_join(case_name)
	DirAccess.make_dir_recursive_absolute(dst_abs)
	_copy_dir_recursive(src_abs, dst_abs)
	return dst_abs


func _copy_dir_recursive(src: String, dst: String) -> void:
	var dir := DirAccess.open(src)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var s := src.path_join(entry)
			var d := dst.path_join(entry)
			if dir.current_is_dir():
				DirAccess.make_dir_recursive_absolute(d)
				_copy_dir_recursive(s, d)
			else:
				DirAccess.copy_absolute(s, d)
		entry = dir.get_next()
	dir.list_dir_end()


func _cleanup_pm_data_dir(pm, plugin_id: String) -> void:
	pm._delete_directory_recursive("user://plugins/data".path_join(plugin_id))


func _cleanup_scratch_files() -> void:
	for cfg_path in _scratch_configs:
		var abs := ProjectSettings.globalize_path(cfg_path)
		if FileAccess.file_exists(abs):
			DirAccess.remove_absolute(abs)
	for state_path in _scratch_state_files:
		var abs := ProjectSettings.globalize_path(state_path)
		if FileAccess.file_exists(abs):
			DirAccess.remove_absolute(abs)


## Waits until a SetupPipeline's terminal `finished` signal has actually been
## emitted AND the worker thread joined (is_running() only flips false inside
## that deferred callback — see SetupPipeline's THREADING CONTRACT doc).
func _wait_pipeline_done(pipeline: SetupPipeline, timeout_ms: int = 20000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while pipeline.is_running() and Time.get_ticks_msec() < deadline:
		await process_frame


func _wait_not_building(pm, plugin_id: String, timeout_ms: int = 20000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var def = pm.get_db().get_by_id(plugin_id)
	while def != null and def.state == _pm_script.S_BUILDING and Time.get_ticks_msec() < deadline:
		await process_frame


## Fixture scripts are checked out from git, which does not always preserve
## the executable bit reliably across every checkout path (worktrees, CI
## artifact extraction, etc). Defensive chmod so this test never fails for a
## reason unrelated to the pipeline logic under test.
func _ensure_fixtures_executable() -> void:
	OS.execute("chmod", ["+x", _tools_dir.path_join("go")])
	OS.execute("chmod", ["+x", _plugin_setup_fixtures_dir.path_join("exit2-with-stderr.sh")])
	OS.execute("chmod", ["+x", _plugin_setup_fixtures_dir.path_join("sleep-forever.sh")])
	OS.execute("chmod", ["+x", _pm_fixture("pm_install_fail/exit2.sh")])
	OS.execute("chmod", ["+x", _pm_fixture("pm_install_slow/slow.sh")])


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
