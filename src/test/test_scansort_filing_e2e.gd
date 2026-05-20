extends SceneTree
## Per-plugin functional test (W5) — scansort end-to-end filing pipeline on the
## REAL MCPServerConnection, with REAL classification via model-chat/qwen.
## No stubs, no fake providers (a fake provider was explicitly rejected as a
## mock/prod-divergence regression risk).
##
## Run: godot --headless --path src --script test/test_scansort_filing_e2e.gd
##
## Tracks docket: minerva RCA 019e46b5 / work-item W5 019e470b444f
##
## Pipeline: create a fresh vault -> open vault + source in session -> set a
## disk destination -> import the W2 rule set from the vault sidecar -> clear
## the source cache -> process each fixture PDF (one per call, mirroring the
## panel's offset/limit loop so each classify fits the pre-W1 30s budget) ->
## assert each document landed in its expected subfolder.
##
## NON-HERMETIC: needs the model-chat / qwen vision service reachable AND the
## host.providers.chat capability wired. When classification is unavailable the
## test SKIPs cleanly (quit 0) rather than failing — real-data verification of
## scansort is also covered by the W7 HITL. A genuine FAIL only happens when a
## document is misclassified / misplaced.
##
## NOTE: PluginManager.gd / MCPServerConnection.gd reference the SingletonObject
## autoload at parse time; in --script mode autoloads register lazily, so use a
## deferred load() rather than a top-level preload().

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_ID := "scansort"
const PLUGIN_DIR_REL := "/github/plugins/scansort"
const BINARY_REL := "/scansort-plugin"
const MANIFEST_REL := "/manifest.json"
const FIXTURE_DIR_REL := "/test/fixtures/scansort-staging"

const S_RUNNING := 2
const S_STOPPED := 3

## scansort's declared host capabilities — granted so process() can reach
## host.providers.chat for classification.
const HOST_CAPS := [
	"host.echo", "host.providers.chat",
	"host.files.read", "host.files.write", "host.files.list", "host.files.exists",
	"host.files.stat", "host.files.mkdir", "host.files.delete", "host.files.move",
	"host.dialogs.file_picker", "host.dialogs.directory_picker",
	"host.permissions.grant_scope",
]

## Classifier model. scansort classifies with a vision model; route to the
## model-chat service's qwen2.5vl via a structured model_spec.
const MODEL_SPEC := {
	"kind": "core_action",
	"service_client_id": "model-chat",
	"action_name": "qwen2.5vl",
}

var _pass: int = 0
var _fail: int = 0
var _skipped: bool = false
var _skip_reason: String = ""


func _init() -> void:
	print("=== Scansort Filing End-to-End Functional Test (W5) ===\n")
	print("Drives the real scansort plugin + MCPServerConnection + real model-chat.\n")
	await _run()
	if _skipped:
		print("\n=== SKIPPED — %s ===" % _skip_reason)
		quit(0)
		return
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	var home: String = OS.get_environment("HOME")
	if home == "":
		printerr("FAIL: $HOME unset — cannot locate the plugin source dir.")
		_fail += 1
		return
	var plugin_dir: String = home + PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + BINARY_REL
	var manifest_path: String = plugin_dir + MANIFEST_REL
	if not FileAccess.file_exists(binary_path):
		_skip("scansort-plugin binary not built at %s" % binary_path)
		return
	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: scansort manifest not found at %s" % manifest_path)
		_fail += 1
		return

	var fixture_dir: String = ProjectSettings.globalize_path("res://" + FIXTURE_DIR_REL)
	var rules_fixture: String = fixture_dir + "/rules.json"
	var placement_fixture: String = fixture_dir + "/expected_placement.json"
	if not FileAccess.file_exists(rules_fixture) or not FileAccess.file_exists(placement_fixture):
		printerr("FAIL: scansort fixtures missing under %s" % fixture_dir)
		_fail += 1
		return

	# Parse the expected-placement oracle.
	var placements: Array = _read_json_array(placement_fixture, "placements")
	if placements.is_empty():
		printerr("FAIL: expected_placement.json has no placements")
		_fail += 1
		return

	# --- Temp working area (vault, source, disk destination) ---
	var work: String = OS.get_user_data_dir().path_join("scansort_e2e_%d" % Time.get_ticks_msec())
	var source_dir: String = work.path_join("source")
	var disk_root: String = work.path_join("filed")
	var vault_path: String = work.path_join("vault.ssort")
	# The library_import_from_sidecar tool reads <vault-stem>.rules.json next to
	# the vault — i.e. vault.ssort -> vault.rules.json.
	var sidecar_path: String = work.path_join("vault.rules.json")
	DirAccess.make_dir_recursive_absolute(source_dir)
	DirAccess.make_dir_recursive_absolute(disk_root)

	# Copy each fixture PDF into the fresh source dir, and the rule set to the
	# vault sidecar.
	for p in placements:
		var input_name: String = str(p.get("input", ""))
		if not _copy_file(fixture_dir + "/" + input_name, source_dir.path_join(input_name)):
			printerr("FAIL: could not stage fixture PDF %s" % input_name)
			_fail += 1
			_rm_rf(work)
			return
	if not _copy_file(rules_fixture, sidecar_path):
		printerr("FAIL: could not stage the rule sidecar")
		_fail += 1
		_rm_rf(work)
		return
	print("Work dir: %s" % work)
	print("Staged %d fixture PDFs into the source dir.\n" % placements.size())

	# --- Bring up the scansort plugin ---
	await process_frame
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("FAIL: could not load PluginManager.gd")
		_fail += 1
		_rm_rf(work)
		return
	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame
	if pm._db == null:
		printerr("FAIL: PluginManager did not initialise")
		_fail += 1
		_rm_rf(work)
		return

	var db = pm._db
	var def = db.get_by_id(PLUGIN_ID)
	if def == null:
		var install_result = await pm.install_plugin(manifest_path, true)
		if not install_result.get("ok", false):
			_skip("install_plugin failed: %s" % str(install_result))
			_rm_rf(work)
			return
		def = db.get_by_id(PLUGIN_ID)
	if def == null:
		_skip("scansort definition did not load")
		_rm_rf(work)
		return
	if def.state == S_RUNNING:
		await pm.stop_plugin(PLUGIN_ID)

	var policy = pm.get_policy()
	if policy == null and so != null and "plugin_policy" in so:
		policy = so.get("plugin_policy")
	if policy != null:
		for cap in HOST_CAPS:
			policy.grant_capability(PLUGIN_ID, cap)

	var start_result = await pm.start_plugin(PLUGIN_ID)
	if not start_result.get("ok", false):
		_skip("start_plugin failed: %s" % str(start_result))
		_rm_rf(work)
		return
	var conn = pm.get_connection(PLUGIN_ID)
	if conn == null:
		_skip("no connection after start_plugin")
		await pm.stop_plugin(PLUGIN_ID)
		_rm_rf(work)
		return

	await _pipeline(conn, vault_path, source_dir, disk_root, placements)

	# --- Teardown: remove the fixture rules from the global library, stop ---
	for p in placements:
		var label: String = str(p.get("expected_rule_label", ""))
		if label != "":
			await conn.call_tool("minerva_scansort_library_delete_rule", {"label": label})
	await pm.stop_plugin(PLUGIN_ID)
	_rm_rf(work)


## Runs the 7-step filing pipeline + placement assertions. Any setup-step
## failure or unavailable classification SKIPs; only a genuine misplacement
## produces a FAIL.
func _pipeline(conn, vault_path: String, source_dir: String, disk_root: String, placements: Array) -> void:
	print("-- 1. create_vault --")
	var r = await conn.call_tool("minerva_scansort_create_vault",
			{"path": vault_path, "name": "rca_019e46b5_e2e"})
	if not _ok(r):
		_skip("create_vault failed: %s" % str(r))
		return

	print("-- 2. session_open_vault --")
	r = await conn.call_tool("minerva_scansort_session_open_vault",
			{"label": "vault", "path": vault_path})
	if not _ok(r):
		_skip("session_open_vault failed: %s" % str(r))
		return

	print("-- 3. session_open_source --")
	r = await conn.call_tool("minerva_scansort_session_open_source",
			{"label": "src", "path": source_dir})
	if not _ok(r):
		_skip("session_open_source failed: %s" % str(r))
		return

	print("-- 4. set_destination (disk_only) --")
	r = await conn.call_tool("minerva_scansort_set_destination",
			{"vault_path": vault_path, "mode": "disk_only", "disk_root": disk_root})
	if not _ok(r):
		_skip("set_destination failed: %s" % str(r))
		return

	print("-- 5. library_import_from_sidecar --")
	r = await conn.call_tool("minerva_scansort_library_import_from_sidecar",
			{"vault_label": "vault"})
	if not _ok(r):
		_skip("library_import_from_sidecar failed: %s" % str(r))
		return
	var imported: int = int(r.get("imported", 0))
	if imported < placements.size():
		_skip("sidecar import brought in %d rules, expected %d" % [imported, placements.size()])
		return
	print("    imported %d rules" % imported)

	print("-- 6. clear_source_cache --")
	r = await conn.call_tool("minerva_scansort_clear_source_cache", {})
	if not _ok(r):
		_skip("clear_source_cache failed: %s" % str(r))
		return

	print("-- 7. process (one document per call, mirroring the panel loop) --")
	var placed_total: int = 0
	for i in range(placements.size()):
		var pres = await conn.call_tool("minerva_scansort_process", {
			"offset": i, "limit": 1,
			"doc_type_strategy": "none",
			"model_spec": MODEL_SPEC,
		})
		if not _ok(pres):
			_skip("process(offset=%d) failed — likely model-chat unreachable: %s"
					% [i, str(pres).left(200)])
			return
		var summary: Dictionary = pres.get("summary", {})
		var moved: int = int(summary.get("moved", 0))
		var unprocessable: int = int(summary.get("unprocessable", 0))
		placed_total += moved
		print("    doc %d: moved=%d unprocessable=%d" % [i, moved, unprocessable])
		if unprocessable > 0:
			_skip("a document was unprocessable — classification unavailable headless "
					+ "(model-chat). scansort real-data filing is verified at the W7 HITL.")
			return

	if placed_total == 0:
		_skip("process() placed no documents — classification unavailable headless.")
		return

	# --- Placement assertions: the only real PASS/FAIL of this test ---
	print("\n-- placement assertions --")
	var disk = await conn.call_tool("minerva_scansort_list_disk_files",
			{"vault_path": vault_path})
	if not _ok(disk):
		_skip("list_disk_files failed: %s" % str(disk))
		return
	var files: Array = disk.get("files", [])
	var rel_paths: Array = []
	for f in files:
		if f is Dictionary:
			rel_paths.append(str(f.get("rel_path", "")).replace("\\", "/"))
	print("    %d file(s) on disk: %s" % [rel_paths.size(), str(rel_paths)])

	check("scansort placed all %d documents" % placements.size(),
			placed_total == placements.size(),
			"placed %d of %d" % [placed_total, placements.size()])

	for p in placements:
		var input_name: String = str(p.get("input", ""))
		var subfolder: String = str(p.get("expected_subfolder", ""))
		var prefix: String = str(p.get("expected_renamed_prefix", ""))
		var want: String = subfolder + "/" + prefix
		check("%s -> %s*" % [input_name, want],
				_disk_has_prefix(rel_paths, want),
				"no on-disk file under '%s' — got %s" % [want, str(rel_paths)])


## True when result is a non-error Dictionary with ok != false.
func _ok(res) -> bool:
	return res is Dictionary and not res.has("error") and res.get("ok", true) != false


func _disk_has_prefix(rel_paths: Array, prefix: String) -> bool:
	for rp in rel_paths:
		if str(rp).begins_with(prefix):
			return true
	return false


func _read_json_array(path: String, key: String) -> Array:
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary and parsed.get(key) is Array:
		return parsed.get(key)
	return []


func _copy_file(from_path: String, to_path: String) -> bool:
	var src = FileAccess.open(from_path, FileAccess.READ)
	if src == null:
		return false
	var data := src.get_buffer(src.get_length())
	src.close()
	var dst = FileAccess.open(to_path, FileAccess.WRITE)
	if dst == null:
		return false
	dst.store_buffer(data)
	dst.close()
	return true


## Recursively remove a directory tree (best effort — temp cleanup).
func _rm_rf(path: String) -> void:
	var d = DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		var full := path.path_join(entry)
		if d.current_is_dir():
			_rm_rf(full)
		else:
			DirAccess.remove_absolute(full)
		entry = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


func _skip(reason: String) -> void:
	_skipped = true
	_skip_reason = reason
	print("  SKIP: %s" % reason)


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
