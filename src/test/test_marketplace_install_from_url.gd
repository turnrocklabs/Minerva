extends SceneTree
## Headless integration test for MarketplaceClient.install_from_url.
##
## Spawns a local Python HTTP server serving fixture tarballs, then
## drives install_from_url through happy + failure paths. The fixture
## plugin is minimal (no panels) so PluginDB's class_name + capability
## validation passes; install_from_url is what's being tested, not
## the PluginDefinition surface.
##
## Run: godot --headless --path src --script test/test_marketplace_install_from_url.gd

const MARKETPLACE_GD := "res://Scripts/Services/Plugins/MarketplaceClient.gd"
const PLUGINDB_GD := "res://Scripts/Services/Plugins/PluginDB.gd"

const PORT := 18765

var _temp_dir: String = ""
var _server_pid: int = -1
var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== MarketplaceClient.install_from_url integration test ===")
	await _run()
	print("\n=== %d passed, %d failed ===" % [_pass, _fail])
	_teardown()
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	await process_frame
	if not await _setup():
		_fail += 1
		return

	await _test_happy_path()
	await _test_404()
	await _test_bad_sha()


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _setup() -> bool:
	# Use a unique temp dir under user-data so we don't pollute the real
	# user://plugins/.
	_temp_dir = "%s/test_marketplace_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	if not _mkdir(_temp_dir):
		print("setup FAIL: could not make temp dir %s" % _temp_dir)
		return false

	# Build good fixture: manifest + binary + SHA256SUMS.
	var good_pack := "%s/good_pack" % _temp_dir
	_mkdir(good_pack)
	var manifest := {
		"id": "test_marketplace_plugin",
		"name": "Test Marketplace Plugin",
		"version": "0.0.1",
		"host_api_version": "1",
		"backend": {
			"transport": "stdio",
			"entrypoint": "./test-marketplace-binary",
			"args": [],
		},
		"tools": [],
		"ui": {"panels": [], "ipc_messages": []},
		"permissions": {"host_capabilities": []},
		"autostart": false,
		"auto_reload": false,
	}
	_write_file("%s/manifest.json" % good_pack, JSON.stringify(manifest))
	_write_file("%s/test-marketplace-binary" % good_pack, "FAKE_BINARY_PLACEHOLDER")
	if not _run_cmd("bash", ["-c", "cd '%s' && sha256sum test-marketplace-binary manifest.json > SHA256SUMS" % good_pack]):
		print("setup FAIL: sha256sum failed")
		return false
	if not _run_cmd("bash", ["-c", "cd '%s' && tar -czf ../test_good.tar.gz ." % good_pack]):
		print("setup FAIL: tar good failed")
		return false

	# Build corrupted fixture: same layout but SHA256SUMS lists wrong hash.
	var bad_pack := "%s/bad_pack" % _temp_dir
	_mkdir(bad_pack)
	_write_file("%s/manifest.json" % bad_pack, JSON.stringify(manifest))
	_write_file("%s/test-marketplace-binary" % bad_pack, "FAKE_BINARY_PLACEHOLDER_BAD")
	# Hash from the GOOD pack (mismatches the bad binary content).
	if not _run_cmd("bash", ["-c", "cp '%s/SHA256SUMS' '%s/SHA256SUMS'" % [good_pack, bad_pack]]):
		print("setup FAIL: copy SHA256SUMS for bad pack")
		return false
	if not _run_cmd("bash", ["-c", "cd '%s' && tar -czf ../test_bad.tar.gz ." % bad_pack]):
		print("setup FAIL: tar bad failed")
		return false

	# Spawn Python http server. --directory points at _temp_dir, so the
	# tarballs are served at http://127.0.0.1:PORT/test_good.tar.gz etc.
	_server_pid = OS.create_process("python3", [
		"-m", "http.server", str(PORT),
		"--directory", _temp_dir,
		"--bind", "127.0.0.1",
	])
	if _server_pid <= 0:
		print("setup FAIL: could not spawn python http.server")
		return false

	# Wait for server to bind.
	for i in range(50):
		await create_timer(0.1).timeout
		var probe := HTTPRequest.new()
		probe.timeout = 1.0
		root.add_child(probe)
		var err := probe.request("http://127.0.0.1:%d/" % PORT)
		if err == OK:
			var result: Array = await probe.request_completed
			probe.queue_free()
			if result[1] in [200, 404, 403]:
				return true
		else:
			probe.queue_free()
	print("setup FAIL: server didn't come up in 5s")
	return false


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func _test_happy_path() -> void:
	var url := "http://127.0.0.1:%d/test_good.tar.gz" % PORT
	var client = _make_client()
	var db = _make_db()

	# Pre-condition: plugin not yet registered.
	if db.has_plugin("test_marketplace_plugin"):
		db.remove("test_marketplace_plugin")

	var result = await client.install_from_url(url, db)
	if not (result is Dictionary and result.get("ok") == true):
		print("FAIL: happy_path — result=%s" % JSON.stringify(result))
		_fail += 1
		return
	if result.get("plugin_id") != "test_marketplace_plugin":
		print("FAIL: happy_path — wrong plugin_id %s" % result.get("plugin_id"))
		_fail += 1
		return
	if not FileAccess.file_exists("user://plugins/test_marketplace_plugin/test-marketplace-binary"):
		print("FAIL: happy_path — binary missing at user://plugins/test_marketplace_plugin/")
		_fail += 1
		return
	if not db.has_plugin("test_marketplace_plugin"):
		print("FAIL: happy_path — plugin not registered in PluginDB")
		_fail += 1
		return
	print("PASS: happy_path (downloads + extracts + verifies SHA + registers)")
	_pass += 1

	# Clean up so subsequent tests don't see the stale install.
	db.remove("test_marketplace_plugin")
	_rm_dir_recursive("user://plugins/test_marketplace_plugin")


func _test_404() -> void:
	var url := "http://127.0.0.1:%d/does_not_exist.tar.gz" % PORT
	var client = _make_client()
	var db = _make_db()
	var result = await client.install_from_url(url, db)
	if result is Dictionary and result.get("ok") == false and result.get("error") == "download_bad_status":
		print("PASS: 404 — install_from_url returned error=download_bad_status")
		_pass += 1
	else:
		print("FAIL: 404 — expected error=download_bad_status, got %s" % JSON.stringify(result))
		_fail += 1


func _test_bad_sha() -> void:
	var url := "http://127.0.0.1:%d/test_bad.tar.gz" % PORT
	var client = _make_client()
	var db = _make_db()
	var result = await client.install_from_url(url, db)
	if result is Dictionary and result.get("ok") == false and result.get("error") == "sha256_mismatch":
		print("PASS: bad_sha — install_from_url returned error=sha256_mismatch")
		_pass += 1
	else:
		print("FAIL: bad_sha — expected error=sha256_mismatch, got %s" % JSON.stringify(result))
		_fail += 1


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _make_client():
	var cls = load(MARKETPLACE_GD)
	var c = cls.new()
	root.add_child(c)
	return c


func _make_db():
	var cls = load(PLUGINDB_GD)
	return cls.new()


func _mkdir(path: String) -> bool:
	if path.begins_with("user://") or path.begins_with("res://"):
		return DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path)) == OK
	return DirAccess.make_dir_recursive_absolute(path) == OK


func _write_file(abs_path: String, content: String) -> void:
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()


func _run_cmd(cmd: String, args: Array) -> bool:
	var out := []
	var rc := OS.execute(cmd, args, out, true)
	if rc != 0:
		print("  cmd %s %s failed (rc=%d): %s" % [cmd, args, rc, "\n".join(out)])
		return false
	return true


func _rm_dir_recursive(rel_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(rel_path)
	if not DirAccess.dir_exists_absolute(abs_path):
		return
	OS.execute("rm", ["-rf", abs_path], [], true)


func _teardown() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
	if not _temp_dir.is_empty():
		OS.execute("rm", ["-rf", _temp_dir], [], true)
	# Also clean any installed test plugin if a test left it behind.
	_rm_dir_recursive("user://plugins/test_marketplace_plugin")
