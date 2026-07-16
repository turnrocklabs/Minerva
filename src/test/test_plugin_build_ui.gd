extends SceneTree
## Population-probe tests (W-13 lesson: probe POPULATION, not registration)
## for the setup-pipeline UI + MCP surface — DCR 019f69428fa0 round R3-UI
## (G4.1/G4.2/G4.3), contract: Docs/design/plugin-setup-pipeline.md §2/§3.
##
## Run: godot --headless --path src --script test/test_plugin_build_ui.gd
##
## What this drives, all against the REAL PluginManagerPanel scene
## (res://Scenes/PluginManagerPanel.tscn) instantiated headless, with the REAL
## PluginManager class running the REAL SetupPipeline over the same fixtures
## test_plugin_setup_pipeline.gd uses (FakeDB backing store — reused from that
## suite via load(), see _helpers below — so the developer's real
## user://plugins/plugins.json is never touched):
##
##   A. S_BUILDING — list row text carries "Building… (step N/M: <type>)" and
##      the detail pane's setup-status section shows the same, live, driven
##      purely by PluginManager's plugin_build_step_* signals (no polling).
##   B. Exec approval gate — the dialog displays the literal argv; Approve
##      lets the step run; the pipeline completes.
##   C. S_BUILD_FAILED — failing step + exit code + stderr tail rendered;
##      Rebuild button present, visible, enabled.
##   D. S_NEEDS_BINARY — BOTH failed toolchain requirements listed (two-
##      missing-tools fixture), with found/required/install-hint text.
##   E. Rebuild button — actually calls PluginManager.rebuild(): fix the
##      broken fixture, click the button, pipeline reruns to success.
##   F. Deny path — Cancel on the gate produces the §3 envelope with
##      detail=exec_denied and the panel renders "declined", not broken-build.
##   G. App-quit path — tearing the panel out of the tree while a worker is
##      blocked on the gate auto-denies and RELEASES the worker (the await
##      completing at all is the no-hung-thread proof).
##   H. MCP — minerva_plugin_build_status / minerva_plugin_setup_dry_run
##      through PluginMCPTools.handle_tool_call (the exact entry point
##      MinervaMCPServer routes minerva_plugin_* calls to).
##
## PluginManager.gd is loaded at RUNTIME after `await process_frame`, never
## statically typed (bug 019f69abc131 — static PluginManager typing in
## headless scripts SIGSEGVs; same workaround as test_plugin_setup_pipeline.gd,
## whose doc comment carries the full analysis).

const FIXTURES_ROOT := "res://test/fixtures/setup_pipeline"
const TOOLCHAIN_FIXTURES_RES := "res://test/fixtures/toolchain"
const PANEL_TSCN := "res://Scenes/PluginManagerPanel.tscn"
const PIPELINE_TEST_SCRIPT := "res://test/test_plugin_setup_pipeline.gd"
const PM_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const MCP_TOOLS_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginMCPTools.gd"

var _pass_count: int = 0
var _fail_count: int = 0

var _pm_script: GDScript = null
var _panel_scene: PackedScene = null
## test_plugin_setup_pipeline.gd, loaded for its FakeDB inner class (reuse,
## not copy — the class and its "why not the real PluginDB" rationale live
## there).
var _helpers: GDScript = null
var _mcp_tools_script: GDScript = null

var _scratch_state_files: Array[String] = []
var _scratch_configs: Array[String] = []
var _scratch_dirs: Array[String] = []


func _init() -> void:
	print("=== Plugin Build UI + MCP Surface Tests (R3-UI) ===\n")

	await process_frame
	_pm_script = load(PM_SCRIPT_PATH)
	_panel_scene = load(PANEL_TSCN)
	_helpers = load(PIPELINE_TEST_SCRIPT)
	_mcp_tools_script = load(MCP_TOOLS_SCRIPT_PATH)
	_ensure_fixtures_executable()

	print("-- A/B: S_BUILDING row + detail population; gate shows literal argv; approve completes --")
	await test_building_population_and_gate_approve()

	print("\n-- C: S_BUILD_FAILED population + Rebuild button --")
	await test_build_failed_population()

	print("\n-- D: S_NEEDS_BINARY lists BOTH missing tools --")
	await test_needs_binary_lists_both_tools()

	print("\n-- E: Rebuild button click actually rebuilds (fixed fixture -> success) --")
	await test_rebuild_button_rebuilds()

	print("\n-- F: gate deny -> exec_denied envelope + 'declined' rendering --")
	await test_gate_deny_produces_exec_denied()

	print("\n-- G: panel teardown mid-approval auto-denies (no hung worker) --")
	await test_panel_teardown_releases_blocked_worker()

	print("\n-- H: MCP build-status + dry-run through handle_tool_call --")
	await test_mcp_build_status_and_dry_run()

	print("\n-- I: unattended install (no panel, no approver) fails CLOSED on exec steps --")
	await test_unattended_install_denies_exec()

	_cleanup_scratch()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# A/B — S_BUILDING population + approve path
# ---------------------------------------------------------------------------

func test_building_population_and_gate_approve() -> void:
	var ctx := await _make_pm_and_panel()
	var pm = ctx["pm"]
	var panel = ctx["panel"]
	var id := "setup_pipeline_pm_slow_test"

	var install_result: Dictionary = await pm.install_plugin(_fixture("pm_install_slow/manifest.json"), true)
	check("A install kicks off ok", install_result.get("ok", false) == true, str(install_result))

	var gate = panel._exec_gate
	check("A panel created an exec gate on connect", gate != null)
	var gate_ok := await _wait_gate_pending(gate)
	check("A gate received the exec-step approval request", gate_ok)

	# By the time the gate request is on screen, the step_started deferred has
	# landed (FIFO deferred queue) — the row must show live step info.
	var row_text := _row_text_for(panel, id)
	check("A list row shows Building… with step info", row_text.contains("Building… (step 1/1: exec)"), row_text)

	# Select the plugin through the real selection path; detail pane must show
	# the same Building… line in the setup-status section.
	_select_plugin_row(panel, id)
	var status_text := _collect_text(panel._setup_status_container)
	check("A detail pane setup-status shows Building… (step 1/1: exec)",
			status_text.contains("Building… (step 1/1: exec)"), status_text)
	check("A Start button disabled while building", panel._start_button.disabled)

	# B — the dialog carries the LITERAL argv, verbatim.
	check("B gate dialog argv text is the literal argv", gate._argv_value.text == "[\"./slow.sh\"]", gate._argv_value.text)
	check("B gate dialog names the step index", gate._step_label.text.contains("Step 0"), gate._step_label.text)

	gate._on_confirmed()
	await _wait_not_building(pm, id)
	var def = pm.get_db().get_by_id(id)
	check("B approved exec step -> pipeline completes to S_INSTALLED", def.state == _pm_script.S_INSTALLED, "got %d" % def.state)

	row_text = _row_text_for(panel, id)
	check("B row no longer shows Building… once terminal", not row_text.contains("Building…"), row_text)
	check("B setup-status section hidden after success", not panel._setup_status_container.visible)

	_teardown(ctx, id)


# ---------------------------------------------------------------------------
# C — S_BUILD_FAILED population
# ---------------------------------------------------------------------------

func test_build_failed_population() -> void:
	var ctx := await _make_pm_and_panel()
	var pm = ctx["pm"]
	var panel = ctx["panel"]
	var id := "setup_pipeline_pm_fail_test"

	await pm.install_plugin(_fixture("pm_install_fail/manifest.json"), true)
	var gate = panel._exec_gate
	await _wait_gate_pending(gate)
	gate._on_confirmed()  # approve — the step itself then exits 2
	await _wait_not_building(pm, id)

	var def = pm.get_db().get_by_id(id)
	check("C state is S_BUILD_FAILED", def.state == _pm_script.S_BUILD_FAILED, "got %d" % def.state)

	var row_text := _row_text_for(panel, id)
	check("C list row flags the failure", row_text.contains("Build failed"), row_text)

	_select_plugin_row(panel, id)
	var status_text := _collect_text(panel._setup_status_container)
	check("C setup-status names the failing step", status_text.contains("step 0: exec"), status_text)
	check("C setup-status shows the exit code", status_text.contains("exit=2"), status_text)
	check("C setup-status shows the stderr tail", status_text.contains("boom"), status_text)

	var rebuild_btn := _find_button(panel._setup_status_container, "Rebuild")
	check("C Rebuild button present", rebuild_btn != null)
	if rebuild_btn != null:
		check("C Rebuild button visible", rebuild_btn.visible)
		check("C Rebuild button enabled", not rebuild_btn.disabled)
	check("C Start button disabled on build failure", panel._start_button.disabled)

	_teardown(ctx, id)


# ---------------------------------------------------------------------------
# D — S_NEEDS_BINARY lists every failed requirement
# ---------------------------------------------------------------------------

func test_needs_binary_lists_both_tools() -> void:
	var ctx := await _make_pm_and_panel()
	var pm = ctx["pm"]
	var panel = ctx["panel"]
	var id := "setup_pipeline_pm_two_tools_test"

	pm.setup_pipeline_factory = func() -> SetupPipeline:
		var p := SetupPipeline.new()
		var reg := ToolchainRegistry.new()
		reg.config_path = _scratch_config_path("two_tools")
		reg.search_dirs_override = [ProjectSettings.globalize_path(TOOLCHAIN_FIXTURES_RES.path_join("empty"))]
		p.toolchain_registry = reg
		return p

	await pm.install_plugin(_fixture("pm_install_missing_two_tools/manifest.json"), true)
	await _wait_not_building(pm, id)

	var def = pm.get_db().get_by_id(id)
	check("D state is S_NEEDS_BINARY", def.state == _pm_script.S_NEEDS_BINARY, "got %d" % def.state)

	var row_text := _row_text_for(panel, id)
	check("D list row flags the missing toolchain", row_text.contains("Needs toolchain"), row_text)

	_select_plugin_row(panel, id)
	var status_text := _collect_text(panel._setup_status_container)
	check("D setup-status lists the go failure", status_text.contains("go — toolchain_missing"), status_text)
	check("D setup-status lists the cargo failure", status_text.contains("cargo — toolchain_missing"), status_text)
	check("D setup-status shows go's required min", status_text.contains("required: 1.22"), status_text)
	check("D setup-status shows cargo's required min", status_text.contains("required: 1.70"), status_text)
	check("D setup-status carries install hints", status_text.contains("install: "), status_text)

	var rebuild_btn := _find_button(panel._setup_status_container, "Rebuild")
	check("D Rebuild button present for NEEDS_BINARY too", rebuild_btn != null)

	_teardown(ctx, id)


# ---------------------------------------------------------------------------
# E — Rebuild button actually rebuilds
# ---------------------------------------------------------------------------

func test_rebuild_button_rebuilds() -> void:
	# Copy the failing fixture somewhere writable so we can "fix" it.
	var scratch_dir := _copy_fixture_to_scratch("pm_install_fail", "ui_rebuild_case")
	OS.execute("chmod", ["+x", scratch_dir.path_join("exit2.sh")])

	var ctx := await _make_pm_and_panel()
	var pm = ctx["pm"]
	var panel = ctx["panel"]
	var id := "setup_pipeline_pm_fail_test"
	var gate = panel._exec_gate

	await pm.install_plugin(scratch_dir.path_join("manifest.json"), true)
	await _wait_gate_pending(gate)
	gate._on_confirmed()
	await _wait_not_building(pm, id)
	var def = pm.get_db().get_by_id(id)
	check("E initial install lands in S_BUILD_FAILED", def.state == _pm_script.S_BUILD_FAILED, "got %d" % def.state)

	# Fix the fixture: exit 0 now.
	var f := FileAccess.open(scratch_dir.path_join("exit2.sh"), FileAccess.WRITE)
	f.store_string("#!/usr/bin/env bash\nexit 0\n")
	f.close()
	OS.execute("chmod", ["+x", scratch_dir.path_join("exit2.sh")])

	_select_plugin_row(panel, id)
	var rebuild_btn := _find_button(panel._setup_status_container, "Rebuild")
	check("E Rebuild button found before click", rebuild_btn != null)
	if rebuild_btn == null:
		_teardown(ctx, id)
		return

	rebuild_btn.pressed.emit()
	check("E click transitions to S_BUILDING (rebuild() really ran)",
			def.state == _pm_script.S_BUILDING, "got %d" % def.state)

	await _wait_gate_pending(gate)
	gate._on_confirmed()
	await _wait_not_building(pm, id)
	check("E rebuilt pipeline succeeds -> S_INSTALLED", def.state == _pm_script.S_INSTALLED, "got %d" % def.state)
	check("E envelope cleared after successful rebuild", pm.get_setup_envelope(id).is_empty())

	pm._delete_directory_recursive(scratch_dir)
	_teardown(ctx, id)


# ---------------------------------------------------------------------------
# F — deny path
# ---------------------------------------------------------------------------

func test_gate_deny_produces_exec_denied() -> void:
	var ctx := await _make_pm_and_panel()
	var pm = ctx["pm"]
	var panel = ctx["panel"]
	var id := "setup_pipeline_pm_slow_test"
	var gate = panel._exec_gate

	await pm.install_plugin(_fixture("pm_install_slow/manifest.json"), true)
	await _wait_gate_pending(gate)
	check("F gate shows the literal argv before deny", gate._argv_value.text.contains("slow.sh"), gate._argv_value.text)

	gate._on_canceled()
	await _wait_not_building(pm, id)

	var def = pm.get_db().get_by_id(id)
	check("F denied exec lands in S_BUILD_FAILED", def.state == _pm_script.S_BUILD_FAILED, "got %d" % def.state)
	var envelope: Dictionary = pm.get_setup_envelope(id)
	check("F envelope detail is exec_denied", str(envelope.get("detail", "")) == "exec_denied", str(envelope))
	check("F envelope keeps the step's argv", str(envelope.get("resolved_argv", [])).contains("slow.sh"), str(envelope))

	_select_plugin_row(panel, id)
	var status_text := _collect_text(panel._setup_status_container)
	check("F panel renders the denial as 'declined', not a broken build",
			status_text.contains("You declined this exec step."), status_text)

	_teardown(ctx, id)


# ---------------------------------------------------------------------------
# G — app-quit / teardown path
# ---------------------------------------------------------------------------

func test_panel_teardown_releases_blocked_worker() -> void:
	var ctx := await _make_pm_and_panel()
	var pm = ctx["pm"]
	var panel = ctx["panel"]
	var id := "setup_pipeline_pm_slow_test"
	var gate = panel._exec_gate

	await pm.install_plugin(_fixture("pm_install_slow/manifest.json"), true)
	await _wait_gate_pending(gate)

	# Tear the panel out of the tree while the pipeline worker is BLOCKED on
	# the gate's Semaphore — exactly what an app quit does to every UI node.
	# The gate's _exit_tree must deny + release; if it doesn't, the
	# _wait_not_building below times out and the assertions fail (and the
	# process would then hang on exit trying to join the worker — the CI-level
	# symptom this guards against). remove_child fires _exit_tree synchronously
	# (posting the Semaphore); the deferred queue_free then frees the node
	# after the released worker has left approve()'s stack frame.
	root.remove_child(panel)
	panel.queue_free()
	await process_frame

	await _wait_not_building(pm, id)
	var def = pm.get_db().get_by_id(id)
	check("G teardown mid-approval resolves the pipeline (worker released)",
			def.state != _pm_script.S_BUILDING, "still S_BUILDING — worker hung")
	check("G teardown resolves as DENY (S_BUILD_FAILED)", def.state == _pm_script.S_BUILD_FAILED, "got %d" % def.state)
	check("G envelope detail is exec_denied", str(pm.get_setup_envelope(id).get("detail", "")) == "exec_denied",
			str(pm.get_setup_envelope(id)))
	check("G panel teardown reset the manager's approver seam", not pm.exec_approver.is_valid())

	ctx["panel"] = null  # already freed
	_teardown(ctx, id)


# ---------------------------------------------------------------------------
# H — MCP surface
# ---------------------------------------------------------------------------

func test_mcp_build_status_and_dry_run() -> void:
	var ctx := await _make_pm_and_panel()
	var pm = ctx["pm"]
	var panel = ctx["panel"]
	var gate = panel._exec_gate
	var id := "setup_pipeline_pm_slow_test"

	var tools = _mcp_tools_script.new(pm, null, null, null)

	# Registration probe (cheap sanity before the population probes).
	var tool_names: Array[String] = []
	for td in tools.get_tool_definitions():
		tool_names.append(td.get("name", ""))
	check("H minerva_plugin_build_status registered", tool_names.has("minerva_plugin_build_status"))
	check("H minerva_plugin_setup_dry_run registered", tool_names.has("minerva_plugin_setup_dry_run"))

	# Unknown id errors.
	var missing: Dictionary = await tools.handle_tool_call("minerva_plugin_build_status", {"id": "no-such-plugin"})
	check("H build_status on unknown id errors", missing.has("error"), str(missing))

	# Live S_BUILDING snapshot (worker parked on the gate keeps the window open).
	await pm.install_plugin(_fixture("pm_install_slow/manifest.json"), true)
	await _wait_gate_pending(gate)
	var building: Dictionary = await tools.handle_tool_call("minerva_plugin_build_status", {"id": id})
	check("H building status success", building.get("success", false) == true, str(building))
	check("H building=true while S_BUILDING", building.get("building", false) == true, str(building))
	check("H state_name is BUILDING", building.get("state_name", "") == "BUILDING", str(building))
	var progress: Dictionary = building.get("progress", {})
	check("H progress carries step_type exec", progress.get("step_type", "") == "exec", str(progress))
	check("H progress carries step_count 1", int(progress.get("step_count", -1)) == 1, str(progress))

	# Deny -> terminal failure status incl. envelope + build log.
	gate._on_canceled()
	await _wait_not_building(pm, id)
	var failed: Dictionary = await tools.handle_tool_call("minerva_plugin_build_status", {"id": id})
	check("H failed status state_name is BUILD_FAILED", failed.get("state_name", "") == "BUILD_FAILED", str(failed))
	check("H failed status building=false", failed.get("building", true) == false, str(failed))
	var envelope: Dictionary = failed.get("envelope", {})
	check("H failed status carries the envelope", envelope.get("error", "") == "setup_step_failed", str(envelope))
	check("H envelope carries exec_denied detail", envelope.get("detail", "") == "exec_denied", str(envelope))
	var log: Array = failed.get("build_log", [])
	check("H build_log non-empty", not log.is_empty(), str(log))
	check("H build_log records the failed step", str(log).contains("step 1/1 exec"), str(log))

	# NEEDS_BINARY envelope surfaces the failures array through MCP.
	var id2 := "setup_pipeline_pm_two_tools_test"
	pm.setup_pipeline_factory = func() -> SetupPipeline:
		var p := SetupPipeline.new()
		var reg := ToolchainRegistry.new()
		reg.config_path = _scratch_config_path("mcp_two_tools")
		reg.search_dirs_override = [ProjectSettings.globalize_path(TOOLCHAIN_FIXTURES_RES.path_join("empty"))]
		p.toolchain_registry = reg
		return p
	await pm.install_plugin(_fixture("pm_install_missing_two_tools/manifest.json"), true)
	await _wait_not_building(pm, id2)
	var nb: Dictionary = await tools.handle_tool_call("minerva_plugin_build_status", {"id": id2})
	check("H needs-binary state_name", nb.get("state_name", "") == "NEEDS_BINARY", str(nb))
	var nb_failures: Array = (nb.get("envelope", {}) as Dictionary).get("failures", [])
	check("H needs-binary envelope carries BOTH failures via MCP", nb_failures.size() == 2, str(nb_failures))

	# Dry run — by manifest_path (installable, not installed).
	var dr: Dictionary = await tools.handle_tool_call("minerva_plugin_setup_dry_run",
			{"manifest_path": _fixture("pm_install_happy/manifest.json")})
	check("H dry-run success", dr.get("success", false) == true, str(dr))
	check("H dry-run has_setup", dr.get("has_setup", false) == true, str(dr))
	var plan: String = str(dr.get("plan", ""))
	check("H dry-run plan header present", plan.contains("setup plan for"), plan)
	check("H dry-run plan shows the copy step", plan.contains("copy 'assets/plugin.txt' -> 'bin/plugin.txt'"), plan)
	check("H dry-run plan shows the expected artifact", plan.contains("expected_artifact=bin/plugin.txt"), plan)

	# Dry run — by installed id.
	var dr2: Dictionary = await tools.handle_tool_call("minerva_plugin_setup_dry_run", {"id": id})
	check("H dry-run by id success", dr2.get("success", false) == true, str(dr2))
	check("H dry-run by id renders the exec argv", str(dr2.get("plan", "")).contains("slow.sh"), str(dr2.get("plan", "")))

	# Dry run — no setup stanza.
	var dr3: Dictionary = await tools.handle_tool_call("minerva_plugin_setup_dry_run",
			{"manifest_path": _fixture("pm_install_no_stanza/manifest.json")})
	check("H dry-run without stanza reports has_setup=false", dr3.get("has_setup", true) == false, str(dr3))

	# Dry run — neither arg.
	var dr4: Dictionary = await tools.handle_tool_call("minerva_plugin_setup_dry_run", {})
	check("H dry-run with no args errors", dr4.has("error"), str(dr4))

	_teardown(ctx, id)
	_cleanup_pm_data_dir(pm, id2)


# ---------------------------------------------------------------------------
# I — unattended fail-closed default (review MF1)
# ---------------------------------------------------------------------------

func test_unattended_install_denies_exec() -> void:
	# Deliberately NO panel and NO exec_approver — the headless / MCP-driven
	# install shape. Contract §1: exec steps require explicit confirmation, so
	# with nobody to ask this must DENY (fail closed), never auto-run the argv
	# and never leave the worker blocked.
	var db = _helpers.FakeDB.new()
	var pm = _pm_script.new()
	pm._db = db
	var state_path := "user://test_build_ui_state_%d.json" % Time.get_ticks_usec()
	_scratch_state_files.append(state_path)
	pm.setup_state_path = state_path
	var id := "setup_pipeline_pm_slow_test"

	var t0 := Time.get_ticks_msec()
	var install_result: Dictionary = await pm.install_plugin(_fixture("pm_install_slow/manifest.json"), true)
	check("I install kicks off ok", install_result.get("ok", false) == true, str(install_result))

	await _wait_not_building(pm, id)
	var elapsed_ms := Time.get_ticks_msec() - t0
	var def = pm.get_db().get_by_id(id)
	check("I unattended exec install lands in S_BUILD_FAILED",
			def.state == _pm_script.S_BUILD_FAILED, "got %d" % def.state)
	# slow.sh sleeps 2s if it ever runs; finishing well under that proves BOTH
	# that the argv never executed AND that the worker was never left blocked
	# waiting for an approver that does not exist.
	check("I denial resolves promptly — argv never ran, worker never blocked (%dms)" % elapsed_ms,
			elapsed_ms < 1500, "took %dms (slow.sh sleeps 2000ms — did it run, or did the worker hang?)" % elapsed_ms)

	var envelope: Dictionary = pm.get_setup_envelope(id)
	check("I envelope carries the headless-denial marker",
			str(envelope.get("detail", "")) == "exec_denied_headless", str(envelope))
	check("I envelope keeps the base §3 shape (error=setup_step_failed)",
			envelope.get("error", "") == "setup_step_failed", str(envelope))

	var log: Array = pm.get_build_log(id)
	check("I build log explains the unattended deny",
			str(log).contains("unattended fail-closed default"), str(log))

	# The marker also flows through the MCP surface.
	var tools = _mcp_tools_script.new(pm, null, null, null)
	var status: Dictionary = await tools.handle_tool_call("minerva_plugin_build_status", {"id": id})
	check("I MCP build_status surfaces exec_denied_headless",
			str((status.get("envelope", {}) as Dictionary).get("detail", "")) == "exec_denied_headless", str(status))

	_cleanup_pm_data_dir(pm, id)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Fresh FakeDB-backed PluginManager + a REAL PluginManagerPanel scene wired
## to it via the panel's _pm_override seam, both live in the tree.
func _make_pm_and_panel() -> Dictionary:
	var db = _helpers.FakeDB.new()
	var pm = _pm_script.new()
	pm._db = db
	var state_path := "user://test_build_ui_state_%d.json" % Time.get_ticks_usec()
	_scratch_state_files.append(state_path)
	pm.setup_state_path = state_path

	var panel = _panel_scene.instantiate()
	panel._pm_override = pm
	root.add_child(panel)
	await process_frame

	return {"pm": pm, "panel": panel, "db": db}


func _teardown(ctx: Dictionary, plugin_id: String) -> void:
	var panel = ctx.get("panel", null)
	if panel != null and is_instance_valid(panel):
		if panel.get_parent() == root:
			root.remove_child(panel)
		panel.free()
	_cleanup_pm_data_dir(ctx["pm"], plugin_id)


func _fixture(rel: String) -> String:
	return ProjectSettings.globalize_path(FIXTURES_ROOT.path_join(rel))


func _scratch_config_path(label: String) -> String:
	var path := "user://test_build_ui_toolchain_%s_%d.cfg" % [label, Time.get_ticks_usec()]
	_scratch_configs.append(path)
	return path


func _copy_fixture_to_scratch(fixture_rel: String, case_name: String) -> String:
	var src_abs: String = ProjectSettings.globalize_path(FIXTURES_ROOT.path_join(fixture_rel))
	var dst_abs: String = ProjectSettings.globalize_path("user://build_ui_scratch").path_join(case_name)
	DirAccess.make_dir_recursive_absolute(dst_abs)
	_scratch_dirs.append(dst_abs)
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


func _cleanup_scratch() -> void:
	for p in _scratch_state_files + _scratch_configs:
		var abs := ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(abs):
			DirAccess.remove_absolute(abs)


## Waits until the gate has a request on screen (its worker caller is blocked).
func _wait_gate_pending(gate, timeout_ms: int = 20000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while gate._current_request == null and Time.get_ticks_msec() < deadline:
		await process_frame
	return gate._current_request != null


func _wait_not_building(pm, plugin_id: String, timeout_ms: int = 20000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var def = pm.get_db().get_by_id(plugin_id)
	while def != null and def.state == _pm_script.S_BUILDING and Time.get_ticks_msec() < deadline:
		await process_frame


## The ItemList row text for the given plugin id (matched via item metadata).
func _row_text_for(panel, plugin_id: String) -> String:
	var list: ItemList = panel._plugin_list
	for i in list.item_count:
		if str(list.get_item_metadata(i)) == plugin_id:
			return list.get_item_text(i)
	return "<no row for %s>" % plugin_id


## Selects the plugin's row through the panel's real selection handler.
func _select_plugin_row(panel, plugin_id: String) -> void:
	var list: ItemList = panel._plugin_list
	for i in list.item_count:
		if str(list.get_item_metadata(i)) == plugin_id:
			list.select(i)
			panel._on_plugin_selected(i)
			return


## Recursively concatenates all Label/Button text under `node`, skipping
## children already queued for deletion (the populate methods queue_free old
## rows before adding new ones — stale nodes are still children this frame).
func _collect_text(node: Node) -> String:
	var out := ""
	if node.is_queued_for_deletion():
		return out
	if node is Label or node is Button:
		out += node.text + "\n"
	for child in node.get_children():
		out += _collect_text(child)
	return out


## First non-queued-for-deletion Button under `node` with exact text.
func _find_button(node: Node, text: String) -> Button:
	if node.is_queued_for_deletion():
		return null
	if node is Button and node.text == text:
		return node
	for child in node.get_children():
		var found := _find_button(child, text)
		if found != null:
			return found
	return null


func _ensure_fixtures_executable() -> void:
	OS.execute("chmod", ["+x", _fixture("pm_install_fail/exit2.sh")])
	OS.execute("chmod", ["+x", _fixture("pm_install_slow/slow.sh")])


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
