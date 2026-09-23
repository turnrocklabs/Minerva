extends SceneTree
## MarketplaceClient installs as a transaction, against real archives served
## over local HTTP and a real PluginDB:
##
##   - an archive whose version differs from its registry entry is refused
##     and the installed copy (files and DB record) is untouched;
##   - a registration that fails after changing the DB puts the old files and
##     the old DB record back;
##   - the startup sweep deletes orphan staging, moves back an install that
##     was set aside but never committed, and leaves a live operation alone;
##   - frames keep ticking while a large archive is extracted and verified,
##     and the result names the installed id and version;
##   - cancelling a download removes that operation's staging and nothing
##     else's.
##
## Run: godot --headless --path src --script test/test_marketplace_install_transaction.gd

const MARKETPLACE_GD := "res://Scripts/Services/Plugins/MarketplaceClient.gd"
const PLUGINDB_GD := "res://Scripts/Services/Plugins/PluginDB.gd"
const OPERATION_GD := "res://Scripts/Services/Plugins/PluginInstallOperation.gd"
const HELPERS_GD := "res://test/marketplace_test_helpers.gd"
const THROTTLED_PY := "res://test/fixtures/throttled_http_server.py"
const ID := "test_txn_plugin"
const PLUGIN_DIR := "user://plugins/" + ID
const STAGING := "user://plugins/.staging"
const BIG_BYTES := 96 * 1024 * 1024

## A PluginDB whose next update_definition applies the change and then
## reports failure: registration that fails after touching the DB.
class FailingDB extends "res://Scripts/Services/Plugins/PluginDB.gd":
	var fail_next := true

	func update_definition(def) -> bool:
		var applied := super(def)
		if fail_next:
			fail_next = false
			return false
		return applied


var _h
var _temp := ""
var _base_url := ""
var _fail := 0


func _init() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL: timed out")
		_h.teardown()
		quit(1))
	await process_frame
	_h = load(HELPERS_GD).new(self)
	_temp = "%s/test_install_txn_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	var sha := "sha256sum" if _h.have_cmd("sha256sum") else "shasum -a 256"
	var packed: bool = _pack("v1", "1.0.0", 0, sha) and _pack("v2", "2.0.0", 0, sha) \
		and _pack("big", "3.0.0", BIG_BYTES, sha)
	var port: int = _h.random_high_port()
	_base_url = "http://127.0.0.1:%d/" % port
	if not packed or not await _h.start_http_server(_temp, port):
		print("FAIL: fixture setup")
		_finish(1)
		return

	await _test_identity_mismatch_leaves_install_intact()
	await _test_failed_registration_restores_files_and_record()
	await _test_startup_sweep()
	await _test_frames_tick_during_extract_and_verify()
	await _test_cancel_cleans_only_its_own_staging()
	_finish(1 if _fail else 0)


func _test_identity_mismatch_leaves_install_intact() -> void:
	var db = await _installed_v1(load(PLUGINDB_GD).new())
	var client = _client()
	var entry := {"id": ID, "version": "2.1.0",
		"downloads": {client.resolve_platform_target(): _base_url + "v2.tar.gz"}}
	var result: Dictionary = await client.install_from_registry_entry(entry, db)
	_check(result.get("error", "") == "identity_mismatch", "version mismatch refused: %s" % result)
	_check_v1_intact(db, "after a refused mismatch")


func _test_failed_registration_restores_files_and_record() -> void:
	var db = await _installed_v1(FailingDB.new())
	var before = db.get_by_id(ID)
	var result: Dictionary = await _client().install_from_url(_base_url + "v2.tar.gz", db)
	_check(result.get("error", "") == "update_definition_failed", "registration failure reported: %s" % result)
	_check(db.get_by_id(ID) == before, "the DB holds the previous record again")
	_check_v1_intact(db, "after a failed registration")


func _test_startup_sweep() -> void:
	var db = await _installed_v1(load(PLUGINDB_GD).new())
	var staging := ProjectSettings.globalize_path(STAGING)
	# An install that crashed after setting v1 aside and moving v2 in.
	var crashed := staging.path_join("op_crashed")
	DirAccess.make_dir_recursive_absolute(crashed)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(PLUGIN_DIR), crashed.path_join("previous"))
	_write(crashed.path_join("op.json"), JSON.stringify({"id": ID}))
	_h.run_cmd("touch", ["-t", "200001010000", crashed.path_join("op.json")])  # its heartbeat stopped long ago
	_h.run_cmd("bash", ["-c", "mkdir -p '%s' && tar -xzf '%s/v2.tar.gz' -C '%s'" % [
		ProjectSettings.globalize_path(PLUGIN_DIR), _temp, ProjectSettings.globalize_path(PLUGIN_DIR)]])
	# A download that never got as far as a replace.
	var orphan := staging.path_join("op_orphan")
	DirAccess.make_dir_recursive_absolute(orphan.path_join("extract"))
	_write(orphan.path_join("download.tar.gz"), "partial")
	# Another process's install, heartbeat fresh.
	var live := staging.path_join("op_live")
	DirAccess.make_dir_recursive_absolute(live)
	_write(live.path_join("op.json"), JSON.stringify({"id": ""}))

	load(MARKETPLACE_GD).sweep_staging(db)
	_check_v1_intact(db, "after the sweep moved the uncommitted install back")
	var left := Array(DirAccess.get_directories_at(staging))
	_check("op_live" in left and not "op_crashed" in left and not "op_orphan" in left,
		"the sweep removes stale staging and keeps the live operation: %s" % [left])
	_h.rm_dir_recursive(live)


func _test_frames_tick_during_extract_and_verify() -> void:
	var op = load(OPERATION_GD).new()
	var frames := [0]
	var count := func() -> void: frames[0] += 1
	process_frame.connect(count)
	var seen := {}
	op.stage_changed.connect(func(stage: String) -> void: seen[stage] = frames[0])
	var result: Dictionary = await _client().install_from_url(_base_url + "big.tar.gz", null, false, op)
	process_frame.disconnect(count)
	_check(result.get("plugin_id", "") == ID and result.get("version", "") == "3.0.0",
		"the result names the installed id and version: %s" % result)
	var ticked: int = seen.get("register", 0) - seen.get("extract", 0)
	# Blocking the main thread for this long would leave a frame or two.
	_check(seen.has("verify") and ticked >= 10, "%d frames ticked while %d MiB were extracted and verified" % [ticked, BIG_BYTES >> 20])
	_h.rm_dir_recursive(PLUGIN_DIR)


func _test_cancel_cleans_only_its_own_staging() -> void:
	var sibling := ProjectSettings.globalize_path(STAGING).path_join("op_sibling")
	DirAccess.make_dir_recursive_absolute(sibling)
	_write(sibling.path_join("keep.txt"), "another install's scratch")
	var port: int = _h.random_high_port() + 1
	var server := OS.create_process("python3", [ProjectSettings.globalize_path(THROTTLED_PY),
		_temp.path_join("big.tar.gz"), str(port), "--rate", "1048576"])
	for i in 50:
		if OS.execute("bash", ["-c", "exec 3<>/dev/tcp/127.0.0.1/%d" % port]) == 0:
			break
		await create_timer(0.1).timeout
	var op = load(OPERATION_GD).new()
	var install = _client().install_from_url("http://127.0.0.1:%d/big.tar.gz" % port, null, false, op)
	var give_up := Time.get_ticks_msec() + 20000
	while (op.stage != "download" or op.done < 65536) and Time.get_ticks_msec() < give_up:
		await process_frame  # cancel mid-download
	op.cancel()
	var result: Dictionary = await install
	OS.kill(server)
	_check(result.get("error", "") == "cancelled", "cancelled download reports cancelled: %s" % result)
	_check(not DirAccess.dir_exists_absolute(op.staging_dir), "its own staging is gone")
	_check(FileAccess.file_exists(sibling.path_join("keep.txt")), "another operation's staging is untouched")
	_h.rm_dir_recursive(sibling)


## Install v1 through `db` (fresh), with a sentinel file beside it.
func _installed_v1(db):
	if db.has_plugin(ID):
		db.remove(ID)
	_h.rm_dir_recursive(PLUGIN_DIR)
	var result: Dictionary = await _client().install_from_url(_base_url + "v1.tar.gz", db)
	if not result.get("ok", false):
		print("FAIL: installing v1: %s" % result)
		_fail += 1
	_write(ProjectSettings.globalize_path(PLUGIN_DIR + "/sentinel.txt"), "v1 install")
	return db


func _check_v1_intact(db, when: String) -> void:
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(PLUGIN_DIR + "/manifest.json"))
	var files_ok: bool = manifest is Dictionary and manifest.get("version") == "1.0.0" \
		and FileAccess.file_exists(PLUGIN_DIR + "/sentinel.txt")
	var record = db.get_by_id(ID)
	_check(files_ok and record != null and record.version == "1.0.0", "v1 files and DB record intact %s" % when)


## Archive `<name>.tar.gz` in the temp dir: manifest, placeholder binary,
## optional random payload, SHA256SUMS.
func _pack(name: String, version: String, payload_bytes: int, sha: String) -> bool:
	var dir := _temp.path_join(name)
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join("manifest.json"), JSON.stringify({
		"id": ID, "name": "Transaction Test Plugin", "version": version, "host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": "./test-binary", "args": []},
		"tools": [], "ui": {"panels": [], "ipc_messages": []},
		"permissions": {"host_capabilities": []}, "autostart": false, "auto_reload": false,
	}))
	_write(dir.path_join("test-binary"), "PLACEHOLDER")
	if payload_bytes > 0:
		var f := FileAccess.open(dir.path_join("payload.bin"), FileAccess.WRITE)
		f.store_buffer(Crypto.new().generate_random_bytes(payload_bytes))
		f.close()
	return _h.run_cmd("bash", ["-c", "cd '%s' && %s $(ls) > SHA256SUMS && tar -czf ../%s.tar.gz ." % [dir, sha, name]])


func _client():
	var client = load(MARKETPLACE_GD).new()
	root.add_child(client)
	return client


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1


func _finish(code: int) -> void:
	var db = load(PLUGINDB_GD).new()
	if db.has_plugin(ID):
		db.remove(ID)
	_h.rm_dir_recursive(PLUGIN_DIR)
	_h.teardown()
	OS.execute("rm", ["-rf", _temp])
	print("=== %s ===" % ("FAIL" if code else "PASS"))
	quit(code)
