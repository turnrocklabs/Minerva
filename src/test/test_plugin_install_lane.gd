extends SceneTree
## Install-lane tests: what separates a dev/manifest install from a marketplace
## install (Docs/design/plugin-setup-pipeline.md §1 lane split).
##
## Both lanes register the SAME manifest.json through the SAME
## PluginManager.install_plugin() call — the marketplace one just arrives
## inside a SHA-pinned release tarball. That means a `setup` stanza written for
## the dev lane would, without a lane, try to build source that was never
## packaged. These tests pin the divergence:
##
##   A. PluginDefinition — the lane field, its round trip, and the location-
##      based migration for records written before the field existed.
##   B. PluginManager — identical fixture, two lanes, opposite outcomes:
##      the dev lane builds (and here, fails, because the fixture's build
##      input is deliberately absent), the marketplace lane never builds and
##      verifies the shipped artifact instead.
##   C. Repair paths — rebuild() belongs to the lane that has a producer;
##      the marketplace lane is told to reinstall instead.
##
## Non-mocked: the real PluginManager, the real SetupPipeline, real fixture
## files on disk. Only the backing store is a FakeDB (same rationale as
## test_plugin_setup_pipeline.gd's own FakeDB) so the developer's real
## user://plugins/plugins.json is never touched.
##
## Run: godot --headless --path src --script test/test_plugin_install_lane.gd

const FIXTURES_ROOT := "res://test/fixtures/setup_pipeline"

var _pass_count: int = 0
var _fail_count: int = 0
var _scratch_dirs: Array[String] = []
var _scratch_state_files: Array[String] = []

## Loaded at runtime, never referenced as a static type — see
## test_plugin_setup_pipeline.gd's `_pm_script` comment (bug 019f69abc131).
var _pm_script: GDScript = null


func _init() -> void:
	print("=== Plugin Install Lane Tests ===\n")

	await process_frame
	_pm_script = load("res://Scripts/Services/Plugins/PluginManager.gd")

	print("-- A. PluginDefinition: lane field + persistence --")
	test_default_lane_is_manifest()
	test_lane_round_trips_through_to_dict_from_dict()
	test_unknown_stored_lane_falls_back()

	print("\n-- A. PluginDefinition: migration of pre-lane records --")
	test_pre_lane_record_under_user_plugins_migrates_to_marketplace()
	test_pre_lane_record_with_checkout_path_migrates_to_manifest()
	test_stored_lane_beats_location_inference()

	print("\n-- B. PluginManager: same fixture, two lanes --")
	await test_manifest_lane_builds_the_stanza()
	await test_marketplace_lane_never_builds()

	print("\n-- B. PluginManager: marketplace artifact verification --")
	await test_marketplace_missing_binary_lands_needs_binary()
	await test_marketplace_present_binary_stays_installed()

	print("\n-- C. Repair paths --")
	await test_rebuild_refuses_marketplace_lane()
	await test_start_refuses_with_lane_specific_message()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	_cleanup_scratch()
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s%s" % [description, (" — %s" % detail) if detail != "" else ""])


# ---------------------------------------------------------------------------
# A. PluginDefinition — lane field, round trip, migration
# ---------------------------------------------------------------------------

func test_default_lane_is_manifest() -> void:
	print("test_default_lane_is_manifest:")
	var def := PluginDefinition.new()
	check("a fresh definition defaults to the manifest lane",
		def.install_lane == PluginDefinition.LANE_MANIFEST, def.install_lane)


func test_lane_round_trips_through_to_dict_from_dict() -> void:
	print("test_lane_round_trips_through_to_dict_from_dict:")
	# The lane has to survive a restart: rebuild() and the build UI read it
	# every session, not just at install time.
	var def := _minimal_def()
	def.install_lane = PluginDefinition.LANE_MARKETPLACE
	var serialized: Dictionary = def.to_dict()
	check("to_dict() carries install_lane",
		serialized.get("install_lane", "") == PluginDefinition.LANE_MARKETPLACE, str(serialized.get("install_lane")))

	var restored := PluginDefinition.from_dict(serialized)
	check("from_dict() restores the definition", restored != null)
	if restored == null:
		return
	check("marketplace lane survives the round trip",
		restored.install_lane == PluginDefinition.LANE_MARKETPLACE, restored.install_lane)


func test_unknown_stored_lane_falls_back() -> void:
	print("test_unknown_stored_lane_falls_back:")
	# A hand-edited or future-versioned plugins.json must not produce a lane
	# no branch handles — the dev lane is the safe default (it builds, which
	# fails loudly, rather than silently trusting a binary).
	check("garbage lane with a checkout dir falls back to manifest",
		PluginDefinition.resolve_install_lane("wat", "/home/dev/plugins/thing") == PluginDefinition.LANE_MANIFEST)
	check("empty lane string is treated as unset",
		PluginDefinition.resolve_install_lane("", "/home/dev/plugins/thing") == PluginDefinition.LANE_MANIFEST)


func test_pre_lane_record_under_user_plugins_migrates_to_marketplace() -> void:
	print("test_pre_lane_record_under_user_plugins_migrates_to_marketplace:")
	# Records written before the lane existed carry no field. MarketplaceClient
	# extracts every release to user://plugins/<id>/ and nothing else installs
	# there, so location is a sound one-time migration signal.
	var record := _minimal_def().to_dict()
	record["data_directory"] = "user://plugins/presentation"
	record.erase("install_lane")

	var def := PluginDefinition.from_dict(record)
	check("record restored", def != null)
	if def == null:
		return
	check("pre-lane record staged under user://plugins/ migrates to marketplace",
		def.install_lane == PluginDefinition.LANE_MARKETPLACE, def.install_lane)


func test_pre_lane_record_with_checkout_path_migrates_to_manifest() -> void:
	print("test_pre_lane_record_with_checkout_path_migrates_to_manifest:")
	var record := _minimal_def().to_dict()
	record["data_directory"] = "/home/imran/github/minerva-plugins/pcb"
	record.erase("install_lane")

	var def := PluginDefinition.from_dict(record)
	check("record restored", def != null)
	if def == null:
		return
	check("pre-lane record pointing at a source checkout migrates to manifest",
		def.install_lane == PluginDefinition.LANE_MANIFEST, def.install_lane)


func test_stored_lane_beats_location_inference() -> void:
	print("test_stored_lane_beats_location_inference:")
	# Inference is a migration, not a rule: once a lane is recorded it wins,
	# so a dev who side-loads into user://plugins/ still gets dev behavior.
	var record := _minimal_def().to_dict()
	record["data_directory"] = "user://plugins/handrolled"
	record["install_lane"] = PluginDefinition.LANE_MANIFEST

	var def := PluginDefinition.from_dict(record)
	check("record restored", def != null)
	if def == null:
		return
	check("an explicitly stored lane is not overridden by location",
		def.install_lane == PluginDefinition.LANE_MANIFEST, def.install_lane)


# ---------------------------------------------------------------------------
# B. PluginManager — one fixture, two lanes
# ---------------------------------------------------------------------------

## Scratch plugin dir shaped like a release that was already built: the
## entrypoint artifact (bin/plugin.txt) is present, but the `copy` step's
## SOURCE (assets/plugin.txt) is absent. So the build is guaranteed to fail if
## it runs at all — which is what makes "did this lane build?" observable
## rather than inferred.
func _make_prebuilt_scratch(label: String) -> String:
	var dir := _scratch_dir(label)
	DirAccess.make_dir_recursive_absolute(dir.path_join("bin"))
	_write_file(dir.path_join("bin/plugin.txt"), "prebuilt binary stand-in\n")
	_write_file(dir.path_join("manifest.json"), _fixture_manifest_json("install_lane_%s" % label))
	return dir


func test_manifest_lane_builds_the_stanza() -> void:
	print("test_manifest_lane_builds_the_stanza:")
	var dir := _make_prebuilt_scratch("dev")
	var db := FakeDB.new()
	var pm = _make_pm(db, "dev")

	var result: Dictionary = await pm.install_plugin(dir.path_join("manifest.json"), true)
	check("dev-lane install returns ok", result.get("ok", false) == true, str(result))
	check("dev lane reports building:true — the stanza IS its producer here",
		result.get("building", false) == true, str(result))

	var id := "install_lane_dev"
	await _wait_not_building(pm, id)
	var def = db.get_by_id(id)
	check("plugin registered", def != null)
	if def == null:
		return
	check("dev lane recorded as manifest", def.install_lane == PluginDefinition.LANE_MANIFEST, def.install_lane)
	# The copy step's source is missing, so a lane that builds MUST fail here.
	# That failure is the proof the build ran — the marketplace test below
	# asserts the exact opposite outcome on a byte-identical fixture.
	check("dev lane actually ran the pipeline (build failed on the absent copy source)",
		def.state == _pm_script.S_BUILD_FAILED, "state=%d" % def.state)
	var envelope: Dictionary = pm.get_setup_envelope(id)
	check("dev-lane envelope is a step failure", envelope.get("error", "") == "setup_step_failed", str(envelope))

	_cleanup_pm_data_dir(pm, id)


func test_marketplace_lane_never_builds() -> void:
	print("test_marketplace_lane_never_builds:")
	var dir := _make_prebuilt_scratch("mkt")
	var db := FakeDB.new()
	var pm = _make_pm(db, "mkt")

	var result: Dictionary = await pm.install_plugin(
		dir.path_join("manifest.json"), true, PluginDefinition.LANE_MARKETPLACE)
	check("marketplace-lane install returns ok", result.get("ok", false) == true, str(result))
	check("marketplace lane does NOT report building",
		not result.get("building", false), str(result))

	var id := "install_lane_mkt"
	var def = db.get_by_id(id)
	check("plugin registered", def != null)
	if def == null:
		return
	check("marketplace lane recorded", def.install_lane == PluginDefinition.LANE_MARKETPLACE, def.install_lane)
	# Same fixture that just failed to build on the dev lane. Staying
	# S_INSTALLED is only possible if the pipeline never ran.
	check("state is S_INSTALLED — the inert stanza was skipped, not built",
		def.state == _pm_script.S_INSTALLED, "state=%d" % def.state)
	check("no build envelope on the marketplace lane", pm.get_setup_envelope(id).is_empty(),
		str(pm.get_setup_envelope(id)))
	check("no build log either — nothing ran", pm.get_build_log(id).is_empty(),
		str(pm.get_build_log(id)))

	_cleanup_pm_data_dir(pm, id)


func test_marketplace_missing_binary_lands_needs_binary() -> void:
	print("test_marketplace_missing_binary_lands_needs_binary:")
	# A release that shipped without a build for this platform: manifest
	# present, entrypoint artifact absent. Before the lane existed this
	# surfaced as a raw spawn failure the first time the user pressed Start.
	var dir := _scratch_dir("nobin")
	_write_file(dir.path_join("manifest.json"), _fixture_manifest_json("install_lane_nobin"))
	var db := FakeDB.new()
	var pm = _make_pm(db, "nobin")

	var result: Dictionary = await pm.install_plugin(
		dir.path_join("manifest.json"), true, PluginDefinition.LANE_MARKETPLACE)
	check("install still reports ok — the plugin IS registered", result.get("ok", false) == true, str(result))
	check("install flags needs_binary", result.get("needs_binary", false) == true, str(result))

	var id := "install_lane_nobin"
	var def = db.get_by_id(id)
	check("plugin registered", def != null)
	if def == null:
		return
	check("state is S_NEEDS_BINARY", def.state == _pm_script.S_NEEDS_BINARY, "state=%d" % def.state)

	var envelope: Dictionary = pm.get_setup_envelope(id)
	check("envelope error is plugin_binary_missing",
		envelope.get("error", "") == "plugin_binary_missing", str(envelope))
	check("envelope names the marketplace lane",
		envelope.get("lane", "") == PluginDefinition.LANE_MARKETPLACE, str(envelope))
	check("envelope carries the path that was checked",
		str(envelope.get("expected_path", "")).ends_with("bin/plugin.txt"), str(envelope))
	check("envelope names the platform", str(envelope.get("platform", "")) == OS.get_name(), str(envelope))
	check("envelope carries an install hint", str(envelope.get("install_hint", "")) != "")

	_cleanup_pm_data_dir(pm, id)


func test_marketplace_present_binary_stays_installed() -> void:
	print("test_marketplace_present_binary_stays_installed:")
	# The ordinary marketplace case: binary shipped, no stanza at all. This is
	# every plugin installed today, and it must be untouched by the change.
	var dir := _scratch_dir("plain")
	DirAccess.make_dir_recursive_absolute(dir.path_join("bin"))
	_write_file(dir.path_join("bin/plugin.txt"), "prebuilt binary stand-in\n")
	_write_file(dir.path_join("manifest.json"), _fixture_manifest_json("install_lane_plain", false))
	var db := FakeDB.new()
	var pm = _make_pm(db, "plain")

	var result: Dictionary = await pm.install_plugin(
		dir.path_join("manifest.json"), true, PluginDefinition.LANE_MARKETPLACE)
	check("install ok", result.get("ok", false) == true, str(result))
	check("no needs_binary flag when the artifact is there", not result.has("needs_binary"), str(result))

	var id := "install_lane_plain"
	var def = db.get_by_id(id)
	check("plugin registered", def != null)
	if def == null:
		return
	check("state is S_INSTALLED", def.state == _pm_script.S_INSTALLED, "state=%d" % def.state)
	check("no envelope", pm.get_setup_envelope(id).is_empty())

	_cleanup_pm_data_dir(pm, id)


# ---------------------------------------------------------------------------
# C. Repair paths
# ---------------------------------------------------------------------------

func test_rebuild_refuses_marketplace_lane() -> void:
	print("test_rebuild_refuses_marketplace_lane:")
	var dir := _scratch_dir("rebuild")
	_write_file(dir.path_join("manifest.json"), _fixture_manifest_json("install_lane_rebuild"))
	var db := FakeDB.new()
	var pm = _make_pm(db, "rebuild")

	await pm.install_plugin(dir.path_join("manifest.json"), true, PluginDefinition.LANE_MARKETPLACE)
	var id := "install_lane_rebuild"
	var def = db.get_by_id(id)
	check("parked in S_NEEDS_BINARY", def != null and def.state == _pm_script.S_NEEDS_BINARY,
		"state=%s" % (str(def.state) if def != null else "<null>"))

	# Reachable state + a declared stanza: without the lane check this WOULD
	# start a pipeline against source that was never packaged.
	var rebuild_result: Dictionary = pm.rebuild(id)
	check("rebuild() refuses", rebuild_result.has("error"), str(rebuild_result))
	check("refusal names the lane, not a missing stanza",
		str(rebuild_result.get("error", "")).contains("rebuild_unavailable_marketplace"), str(rebuild_result))
	check("plugin was not flipped into S_BUILDING", def.state == _pm_script.S_NEEDS_BINARY,
		"state=%d" % def.state)
	check("no build log — no pipeline started", pm.get_build_log(id).is_empty())

	_cleanup_pm_data_dir(pm, id)


func test_start_refuses_with_lane_specific_message() -> void:
	print("test_start_refuses_with_lane_specific_message:")
	# Both lanes refuse to start an unbuilt plugin; only the remedy differs,
	# and pointing a marketplace user at rebuild() is a dead end now that
	# rebuild() refuses them.
	var dir := _scratch_dir("startmsg")
	_write_file(dir.path_join("manifest.json"), _fixture_manifest_json("install_lane_startmsg"))
	var db := FakeDB.new()
	var pm = _make_pm(db, "startmsg")

	await pm.install_plugin(dir.path_join("manifest.json"), true, PluginDefinition.LANE_MARKETPLACE)
	var id := "install_lane_startmsg"

	var start_result: Dictionary = await pm.start_plugin(id)
	check("start_plugin() refuses", start_result.has("error"), str(start_result))
	var msg: String = str(start_result.get("error", ""))
	check("refusal tells a marketplace user to reinstall", msg.contains("reinstall"), msg)
	check("refusal does not send them to rebuild()", not msg.contains("rebuild()"), msg)

	_cleanup_pm_data_dir(pm, id)


# ---------------------------------------------------------------------------
# Fixtures / helpers
# ---------------------------------------------------------------------------

## Manifest for a plugin whose entrypoint is a build product. With
## `with_stanza`, it also declares the producer — a `copy` step whose source is
## deliberately never created, so any lane that builds fails observably.
func _fixture_manifest_json(id: String, with_stanza: bool = true) -> String:
	var manifest := {
		"id": id,
		"name": "Install Lane Fixture",
		"version": "0.1.0",
		"host_api_version": "1",
		"backend": {
			"transport": "stdio",
			"entrypoint": "./bin/plugin.txt",
			"args": [],
		},
		"ui": {"panels": [], "ipc_messages": []},
		"permissions": {
			"host_capabilities": [],
			"network": {"mode": "none"},
			"filesystem": {"mode": "none", "paths": []},
		},
	}
	if with_stanza:
		manifest["setup"] = {
			"requires": [],
			"steps": [{"type": "copy", "from": "assets/plugin.txt", "to": "bin/plugin.txt"}],
		}
	return JSON.stringify(manifest, "\t")


func _make_pm(db, label: String):
	var pm = _pm_script.new()
	pm._db = db
	# Never write the developer's real setup-state file.
	var state_path := "user://test_install_lane_%s_%d.json" % [label, Time.get_ticks_usec()]
	pm.setup_state_path = state_path
	_scratch_state_files.append(state_path)
	return pm


func _scratch_dir(label: String) -> String:
	var abs := ProjectSettings.globalize_path(
		"user://test_install_lane_%s_%d" % [label, Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(abs)
	_scratch_dirs.append(abs)
	return abs


func _write_file(abs_path: String, text: String) -> void:
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		printerr("  (fixture write failed: %s)" % abs_path)
		return
	f.store_string(text)
	f.close()


func _wait_not_building(pm, id: String) -> void:
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var def = pm._db.get_by_id(id)
		if def == null or def.state != _pm_script.S_BUILDING:
			return
		await process_frame


func _cleanup_pm_data_dir(pm, plugin_id: String) -> void:
	pm._delete_directory_recursive("user://plugins/data".path_join(plugin_id))


func _cleanup_scratch() -> void:
	for d in _scratch_dirs:
		_delete_dir_recursive(d)
	for p in _scratch_state_files:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _delete_dir_recursive(abs_path: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_path):
		return
	var dir := DirAccess.open(abs_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := abs_path.path_join(entry)
		if dir.current_is_dir():
			_delete_dir_recursive(child)
		else:
			DirAccess.remove_absolute(child)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(abs_path)


func _minimal_def() -> PluginDefinition:
	var def := PluginDefinition.new()
	def.id = "lane_fixture"
	def.name = "Lane Fixture"
	def.version = "0.1.0"
	def.transport = "stdio"
	def.entrypoint = "./lane-fixture"
	return def


# ---------------------------------------------------------------------------
# FakeDB — in-memory plugin store (same rationale + shape as
# test_plugin_setup_pipeline.gd's FakeDB: keep the developer's real
# user://plugins/plugins.json out of the test).
# ---------------------------------------------------------------------------

class FakeDB extends RefCounted:
	var _plugins: Dictionary = {}

	func install(manifest_path: String, lane: String = PluginDefinition.LANE_MANIFEST):
		var def = PluginDefinition.from_manifest(manifest_path)
		if def == null:
			return null
		if _plugins.has(def.id):
			return null
		def.install_lane = lane
		_plugins[def.id] = def
		return def

	func get_by_id(plugin_id: String):
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

	func update_definition(def) -> bool:
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
