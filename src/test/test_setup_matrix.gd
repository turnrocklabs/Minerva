extends SceneTree
## Fixture-matrix gap-filler for the plugin setup pipeline (DCR 019f69428fa0,
## docket C5). Contract: Docs/design/plugin-setup-pipeline.md §4 (F1-F13).
##
## This file does NOT re-test what the four existing suites already cover —
## it exists purely to close the gaps a full audit of those suites found:
## F4 (too-old tool), F5 (shim-only candidate), and F6 (hanging probe) were
## only exercised at the ToolchainRegistry level (test_toolchain_registry.gd);
## nothing drove them through the REAL PluginManager.install_plugin() path,
## so the S_NEEDS_BINARY state transition + persisted-envelope + refused-start
## behavior for those three failure modes was unproven end to end. F2
## (go_build happy path) was proven at the SetupPipeline-direct and
## SetupExecutors levels (test_plugin_setup_pipeline.gd, test_plugin_setup_
## executors.gd) but never through install_plugin() either — this is the one
## step type in the matrix that actually substitutes a resolved tool_path,
## so it is worth a real end-to-end proof alongside F4/F5/F6.
##
## Every other F# (F1, F3, F7-F13) already has a real-PluginManager-level (or,
## for F11/F12, load-time/unit-level, which IS the deepest sensible level —
## see Docs/design/plugin-setup-pipeline.md §4 annotations) test in one of the
## four existing suites; see that file's own annotation for the reasoning.
##
## Non-mocked functional floor, same as its sibling suites: every fake tool
## here is a real executable spawned through the real ToolchainProbe/
## SetupExecutors code paths — nothing about resolution, probing, or
## subprocess execution is mocked, only the search space (search_dirs_override)
## and the backing plugin store (FakeDB, same rationale as
## test_plugin_setup_pipeline.gd's own FakeDB doc comment).
##
## Run: godot --headless --path src --script test/test_setup_matrix.gd

const FIXTURES_ROOT := "res://test/fixtures/setup_pipeline"
const TOOLCHAIN_FIXTURES_RES := "res://test/fixtures/toolchain"

var _pass_count: int = 0
var _fail_count: int = 0
var _tools_dir: String = ""
var _scratch_configs: Array[String] = []

## See test_plugin_setup_pipeline.gd's identical `_pm_script` doc comment for
## why PluginManager.gd is loaded dynamically at runtime rather than ever
## referenced as a static type: a bare `PluginManager` type reference forces
## an early compile-time resolution of the SingletonObject autoload in
## `--script` headless mode, corrupting the script resource (SIGSEGV later).
## Bug 019f69abc131.
var _pm_script: GDScript = null


func _init() -> void:
	print("=== Setup Pipeline Fixture-Matrix Gap Fillers (F2/F4/F5/F6 @ PluginManager level) ===\n")

	await process_frame
	_pm_script = load("res://Scripts/Services/Plugins/PluginManager.gd")

	_tools_dir = ProjectSettings.globalize_path(FIXTURES_ROOT.path_join("tools"))
	_ensure_fixtures_executable()

	print("-- F2 (PM level): go_build happy path through install_plugin() --")
	await test_f2_pm_install_go_build_happy()

	print("\n-- F4 (PM level): too-old tool -> S_NEEDS_BINARY / toolchain_too_old --")
	await test_f4_pm_install_tool_too_old()

	print("\n-- F5 (PM level): shim-only candidate -> S_NEEDS_BINARY / toolchain_shim_rejected, never executed --")
	await test_f5_pm_install_shim_only_candidate()

	print("\n-- F6 (PM level): hanging probe -> S_NEEDS_BINARY / toolchain_probe_failed within deadline --")
	await test_f6_pm_install_hanging_probe()

	_cleanup_scratch_files()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# F2 — go_build happy path, through the REAL install_plugin() path
# ---------------------------------------------------------------------------

## Proves the one substitution-bearing step type (go_build resolves a
## preflighted tool_path and hands it to the real subprocess) works end to
## end through PluginManager: install_plugin() -> S_BUILDING -> preflight
## resolves the fake `go` -> go_build step invokes it -> artifact written ->
## entrypoint-artifact check passes -> S_INSTALLED, with no leftover envelope.
func test_f2_pm_install_go_build_happy() -> void:
	var db := FakeDB.new()
	var pm = _make_pm(db)
	pm.setup_pipeline_factory = func() -> SetupPipeline:
		var p := SetupPipeline.new()
		var reg := ToolchainRegistry.new()
		reg.config_path = _scratch_config_path("f2_pm")
		reg.search_dirs_override = [_tools_dir]
		p.toolchain_registry = reg
		return p

	var manifest := _pm_fixture("pm_install_go_build/manifest.json")
	var id := "setup_pipeline_pm_go_build_test"

	# data_directory for a manifest-install fixture IS this fixture's own
	# directory (PluginDefinition.from_manifest derives it from the manifest
	# path's base dir) — so the fake-go invocation marker from a PRIOR run of
	# this exact test could still be sitting next to this manifest. Clear it
	# for a clean "did the real subprocess actually run" proof, same rationale
	# as test_plugin_setup_pipeline.gd's F13 marker-reset comment.
	var plugin_fixture_dir := ProjectSettings.globalize_path(FIXTURES_ROOT.path_join("pm_install_go_build"))
	var marker := plugin_fixture_dir.path_join(".fake_go_invocations")
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)
	# Clear bin/ up front too: the end-of-test cleanup is skipped by the
	# def==null early return, and a leaked bin/fake-plugin from a prior run
	# would false-pass the artifact check (review note, R3-B).
	_delete_dir_recursive(plugin_fixture_dir.path_join("bin"))

	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("F2 PM: install_plugin returns ok", install_result.get("ok", false) == true, str(install_result))
	check("F2 PM: install_plugin result flags building:true", install_result.get("building", false) == true, str(install_result))

	var def = db.get_by_id(id)
	check("F2 PM: plugin registered in db", def != null)
	if def == null:
		return
	check("F2 PM: state is S_BUILDING right after install_plugin() returns",
			def.state == _pm_script.S_BUILDING, "got %d" % def.state)

	await _wait_not_building(pm, id)
	check("F2 PM: state is S_INSTALLED once the real go_build step + entrypoint check finish",
			def.state == _pm_script.S_INSTALLED, "got %d" % def.state)

	check("F2 PM: fake-go actually ran (invocation marker exists)", FileAccess.file_exists(marker))
	var artifact := plugin_fixture_dir.path_join("bin/fake-plugin")
	check("F2 PM: go_build artifact was written by the real fake-go subprocess", FileAccess.file_exists(artifact))
	check("F2 PM: no leftover setup envelope on success", pm.get_setup_envelope(id).is_empty())

	_cleanup_pm_data_dir(pm, id)
	_delete_dir_recursive(plugin_fixture_dir.path_join("bin"))
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)


# ---------------------------------------------------------------------------
# F4 — too-old tool, through the REAL install_plugin() path
# ---------------------------------------------------------------------------

func test_f4_pm_install_tool_too_old() -> void:
	var db := FakeDB.new()
	var pm = _make_pm(db)
	pm.setup_pipeline_factory = func() -> SetupPipeline:
		var p := SetupPipeline.new()
		var reg := ToolchainRegistry.new()
		reg.config_path = _scratch_config_path("f4_pm")
		reg.search_dirs_override = [_toolchain_fixture_dir("too_old")]
		p.toolchain_registry = reg
		return p

	var manifest := _pm_fixture("pm_install_tool_too_old/manifest.json")
	var id := "setup_pipeline_pm_too_old_test"

	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("F4 PM: install_plugin kicks off ok", install_result.get("ok", false) == true, str(install_result))

	await _wait_not_building(pm, id)
	var def = db.get_by_id(id)
	check("F4 PM: state is S_NEEDS_BINARY", def != null and def.state == _pm_script.S_NEEDS_BINARY,
			"got %s" % (str(def.state) if def != null else "<null>"))

	var envelope: Dictionary = pm.get_setup_envelope(id)
	check("F4 PM: envelope error is toolchain_too_old", envelope.get("error", "") == "toolchain_too_old", str(envelope))
	check("F4 PM: envelope tool is 'go'", envelope.get("tool", "") == "go", str(envelope))
	check("F4 PM: envelope found_version is the fixture's reported 1.19.0",
			envelope.get("found_version", "") == "1.19.0", str(envelope))
	check("F4 PM: envelope required_min echoes the manifest's declared 1.22",
			envelope.get("required_min", "") == "1.22", str(envelope))
	check("F4 PM: envelope found_path points at the too_old fixture's go",
			envelope.get("found_path", "") == _toolchain_fixture_dir("too_old").path_join("go"), str(envelope))
	check("F4 PM: envelope install_hint present", envelope.get("install_hint", "") != "")

	var start_result: Dictionary = await pm.start_plugin(id)
	check("F4 PM: start_plugin() refuses a needs-binary plugin", start_result.has("error"), str(start_result))

	_cleanup_pm_data_dir(pm, id)


# ---------------------------------------------------------------------------
# F5 — shim-only candidate, through the REAL install_plugin() path
# ---------------------------------------------------------------------------

## The ONLY candidate this registry can find lives under a
## `Microsoft/WindowsApps/` fixture dir — contract §2 rule 2 says a shim-
## pattern candidate is "skipped with reason toolchain_shim_rejected" and
## MUST be rejected BEFORE execution. The fixture script itself writes a
## marker file if it is ever actually invoked (see fixtures/toolchain/shim's
## own comment); this test asserts that marker is absent after the full
## install_plugin() -> S_BUILDING -> S_NEEDS_BINARY round trip, proving the
## reject-before-execute rule holds even through the full PluginManager path,
## not just the bare ToolchainRegistry call already covered in
## test_toolchain_registry.gd.
func test_f5_pm_install_shim_only_candidate() -> void:
	var shim_dir := _toolchain_fixture_dir("shim/Microsoft/WindowsApps")
	var marker := shim_dir.path_join("marker_ran.txt")
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)  # clean slate in case of a prior failed run

	var db := FakeDB.new()
	var pm = _make_pm(db)
	pm.setup_pipeline_factory = func() -> SetupPipeline:
		var p := SetupPipeline.new()
		var reg := ToolchainRegistry.new()
		reg.config_path = _scratch_config_path("f5_pm")
		reg.search_dirs_override = [shim_dir]
		p.toolchain_registry = reg
		return p

	var manifest := _pm_fixture("pm_install_tool_shim/manifest.json")
	var id := "setup_pipeline_pm_shim_test"

	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("F5 PM: install_plugin kicks off ok", install_result.get("ok", false) == true, str(install_result))

	await _wait_not_building(pm, id)
	var def = db.get_by_id(id)
	check("F5 PM: state is S_NEEDS_BINARY", def != null and def.state == _pm_script.S_NEEDS_BINARY,
			"got %s" % (str(def.state) if def != null else "<null>"))

	var envelope: Dictionary = pm.get_setup_envelope(id)
	check("F5 PM: envelope error is toolchain_shim_rejected", envelope.get("error", "") == "toolchain_shim_rejected", str(envelope))
	check("F5 PM: envelope tool is 'go'", envelope.get("tool", "") == "go", str(envelope))
	check("F5 PM: shim candidate was NEVER executed through the full install path (no marker file)",
			not FileAccess.file_exists(marker), "marker file exists at %s — shim ran!" % marker)

	var start_result: Dictionary = await pm.start_plugin(id)
	check("F5 PM: start_plugin() refuses a needs-binary plugin", start_result.has("error"), str(start_result))

	_cleanup_pm_data_dir(pm, id)
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)  # don't leak state into a re-run


# ---------------------------------------------------------------------------
# F6 — hanging probe, through the REAL install_plugin() path
# ---------------------------------------------------------------------------

## The only candidate hangs (sleeps 8s) past the 5s hard probe deadline
## (contract §2 rule 3). Asserts BOTH the terminal state/envelope AND a
## wall-clock bound on the full install_plugin() -> S_BUILDING -> terminal
## round trip, proving the deadline is enforced end to end (not just inside
## the bare ToolchainProbe call already covered in test_toolchain_registry.gd)
## and that a single hanging tool candidate cannot wedge S_BUILDING forever.
func test_f6_pm_install_hanging_probe() -> void:
	var db := FakeDB.new()
	var pm = _make_pm(db)
	pm.setup_pipeline_factory = func() -> SetupPipeline:
		var p := SetupPipeline.new()
		var reg := ToolchainRegistry.new()
		reg.config_path = _scratch_config_path("f6_pm")
		reg.search_dirs_override = [_toolchain_fixture_dir("hang")]
		p.toolchain_registry = reg
		return p

	var manifest := _pm_fixture("pm_install_tool_hang/manifest.json")
	var id := "setup_pipeline_pm_hang_test"

	var start_ms := Time.get_ticks_msec()
	var install_result: Dictionary = await pm.install_plugin(manifest, true)
	check("F6 PM: install_plugin kicks off ok (non-blocking; the hang happens on the worker thread)",
			install_result.get("ok", false) == true, str(install_result))

	var def = db.get_by_id(id)
	check("F6 PM: state is S_BUILDING immediately after kickoff (kickoff itself never blocked on the probe)",
			def != null and def.state == _pm_script.S_BUILDING,
			"got %s" % (str(def.state) if def != null else "<null>"))

	await _wait_not_building(pm, id, 15000)
	var elapsed_ms := Time.get_ticks_msec() - start_ms
	check("F6 PM: state is S_NEEDS_BINARY", def.state == _pm_script.S_NEEDS_BINARY, "got %d" % def.state)
	# 5s hard probe deadline (contract §2) + generous scheduling/PM-plumbing
	# slack, but well short of the fixture's own 8s sleep — a real hang proves
	# the deadline is enforced end to end rather than the child happening to
	# finish quickly or the install path silently waiting it out.
	check("F6 PM: full install_plugin() round trip returns within ~7.5s deadline (elapsed=%dms)" % elapsed_ms,
			elapsed_ms < 7500, "elapsed=%dms" % elapsed_ms)

	var envelope: Dictionary = pm.get_setup_envelope(id)
	check("F6 PM: envelope error is toolchain_probe_failed", envelope.get("error", "") == "toolchain_probe_failed", str(envelope))
	check("F6 PM: envelope tool is 'go'", envelope.get("tool", "") == "go", str(envelope))

	var start_result: Dictionary = await pm.start_plugin(id)
	check("F6 PM: start_plugin() refuses a needs-binary plugin", start_result.has("error"), str(start_result))

	_cleanup_pm_data_dir(pm, id)


# ---------------------------------------------------------------------------
# FakeDB — minimal in-memory stand-in for PluginDB. Identical rationale and
# shape to test_plugin_setup_pipeline.gd's own FakeDB (see that file's doc
# comment); duplicated here rather than shared because GDScript SceneTree
# test files are standalone entrypoints, not importable libraries.
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


func _scratch_config_path(label: String) -> String:
	var path := "user://test_setup_matrix_toolchain_%s_%d.cfg" % [label, Time.get_ticks_usec()]
	_scratch_configs.append(path)
	return path


func _cleanup_pm_data_dir(pm, plugin_id: String) -> void:
	pm._delete_directory_recursive("user://plugins/data".path_join(plugin_id))


func _delete_dir_recursive(abs_path: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_path):
		return
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full := abs_path.path_join(entry)
			if dir.current_is_dir():
				_delete_dir_recursive(full)
			else:
				DirAccess.remove_absolute(full)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs_path)


func _cleanup_scratch_files() -> void:
	for cfg_path in _scratch_configs:
		var abs := ProjectSettings.globalize_path(cfg_path)
		if FileAccess.file_exists(abs):
			DirAccess.remove_absolute(abs)


func _wait_not_building(pm, plugin_id: String, timeout_ms: int = 20000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	var def = pm.get_db().get_by_id(plugin_id)
	while def != null and def.state == _pm_script.S_BUILDING and Time.get_ticks_msec() < deadline:
		await process_frame


## Fixture scripts are checked out from git, which does not always preserve
## the executable bit reliably across every checkout path (worktrees, CI
## artifact extraction, etc). Defensive chmod so this test never fails for a
## reason unrelated to the pipeline logic under test — same rationale as the
## sibling suites' own _ensure_fixtures_executable().
func _ensure_fixtures_executable() -> void:
	OS.execute("chmod", ["+x", _tools_dir.path_join("go")])
	OS.execute("chmod", ["+x", _toolchain_fixture_dir("too_old").path_join("go")])
	OS.execute("chmod", ["+x", _toolchain_fixture_dir("hang").path_join("go")])
	OS.execute("chmod", ["+x", _toolchain_fixture_dir("shim/Microsoft/WindowsApps").path_join("go")])


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
