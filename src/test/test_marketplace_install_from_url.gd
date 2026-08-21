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
var _sha_cmd: String = ""
var _skipped: bool = false


func _init() -> void:
	print("=== MarketplaceClient.install_from_url integration test ===")
	await _run()
	print("\n=== %d passed, %d failed ===" % [_pass, _fail])
	_teardown()
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	await process_frame
	if not await _setup():
		if not _skipped:
			_fail += 1
		return

	await _test_happy_path()
	await _test_404()
	await _test_bad_sha()
	await _test_reinstall_with_hidden_files()
	await _test_reinstall_symlink_not_followed()
	await _test_reserved_id_rejected()


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _setup() -> bool:
	# Base macOS ships shasum, not sha256sum; use whichever exists and SKIP
	# (not fail) when neither does, like the other hermetic-tier tests.
	if _run_cmd("bash", ["-c", "command -v sha256sum >/dev/null"]):
		_sha_cmd = "sha256sum"
	elif _run_cmd("bash", ["-c", "command -v shasum >/dev/null"]):
		_sha_cmd = "shasum -a 256"
	else:
		print("SKIP: neither sha256sum nor shasum is available")
		_skipped = true
		return false

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
	if not _run_cmd("bash", ["-c", "cd '%s' && %s test-marketplace-binary manifest.json > SHA256SUMS" % [good_pack, _sha_cmd]]):
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

	# Build hidden-file fixture: like the pcb plugin, ships a dotfile inside a
	# subdirectory (library/.gitattributes). Regression fixture for
	# install_move_failed on reinstall.
	var hidden_pack := "%s/hidden_pack" % _temp_dir
	_mkdir(hidden_pack)
	_mkdir("%s/library" % hidden_pack)
	var hidden_manifest := manifest.duplicate(true)
	hidden_manifest["id"] = "test_hidden_plugin"
	hidden_manifest["name"] = "Test Hidden-File Plugin"
	_write_file("%s/manifest.json" % hidden_pack, JSON.stringify(hidden_manifest))
	_write_file("%s/test-marketplace-binary" % hidden_pack, "FAKE_BINARY_PLACEHOLDER")
	_write_file("%s/library/.gitattributes" % hidden_pack, "*.kicad_mod text\n")
	if not _run_cmd("bash", ["-c", "cd '%s' && %s test-marketplace-binary manifest.json library/.gitattributes > SHA256SUMS" % [hidden_pack, _sha_cmd]]):
		print("setup FAIL: sha256sum hidden pack failed")
		return false
	if not _run_cmd("bash", ["-c", "cd '%s' && tar -czf ../test_hidden.tar.gz ." % hidden_pack]):
		print("setup FAIL: tar hidden failed")
		return false

	# Build reserved-id fixture: id "data" would alias user://plugins/data/,
	# the shared per-plugin data root the install path recursively deletes.
	var reserved_pack := "%s/reserved_pack" % _temp_dir
	_mkdir(reserved_pack)
	var reserved_manifest := manifest.duplicate(true)
	reserved_manifest["id"] = "data"
	_write_file("%s/manifest.json" % reserved_pack, JSON.stringify(reserved_manifest))
	_write_file("%s/test-marketplace-binary" % reserved_pack, "FAKE_BINARY_PLACEHOLDER")
	if not _run_cmd("bash", ["-c", "cd '%s' && %s test-marketplace-binary manifest.json > SHA256SUMS" % [reserved_pack, _sha_cmd]]):
		print("setup FAIL: sha256sum reserved pack failed")
		return false
	if not _run_cmd("bash", ["-c", "cd '%s' && tar -czf ../test_reserved.tar.gz ." % reserved_pack]):
		print("setup FAIL: tar reserved failed")
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


## Regression test for install_move_failed on reinstall (docket bug
## 01a021b14aa4, minerva project): the old install dir contains dotfiles,
## which MarketplaceClient._rm_dir_recursive must delete (DirAccess defaults
## include_hidden=false, hiding them from the walk). Before the fix, the
## second install failed because user://plugins/<id>/ couldn't be removed
## and the staging rename hit an existing non-empty destination.
func _test_reinstall_with_hidden_files() -> void:
	var url := "http://127.0.0.1:%d/test_hidden.tar.gz" % PORT
	var client = _make_client()
	# Precondition: a leaked install from an earlier failed test would turn
	# the "first install" below into a reinstall.
	_rm_dir_recursive("user://plugins/test_hidden_plugin")

	# First install: no pre-existing destination, must succeed. installer=null
	# stops after staging — the download/extract/verify/move path is what's
	# under test, not registration.
	var first = await client.install_from_url(url, null)
	if not (first is Dictionary and first.get("ok") == true):
		print("FAIL: reinstall_hidden — first install failed: %s" % JSON.stringify(first))
		_fail += 1
		return

	# Second install over the existing dir with a dotfile in a subdir.
	var second = await client.install_from_url(url, null)
	if not (second is Dictionary and second.get("ok") == true):
		print("FAIL: reinstall_hidden — reinstall over existing install failed: %s" % JSON.stringify(second))
		_fail += 1
		_rm_dir_recursive("user://plugins/test_hidden_plugin")
		return
	if not FileAccess.file_exists("user://plugins/test_hidden_plugin/library/.gitattributes"):
		print("FAIL: reinstall_hidden — hidden file missing after reinstall")
		_fail += 1
		_rm_dir_recursive("user://plugins/test_hidden_plugin")
		return
	print("PASS: reinstall_hidden (reinstall over install containing dotfiles succeeds)")
	_pass += 1
	_rm_dir_recursive("user://plugins/test_hidden_plugin")


## The old install dir may contain symlinks (venvs, plugin-authored links).
## The reinstall delete must unlink them, never recurse through them —
## following a symlinked directory would delete the link TARGET's contents
## outside the plugin tree.
func _test_reinstall_symlink_not_followed() -> void:
	var url := "http://127.0.0.1:%d/test_hidden.tar.gz" % PORT
	var client = _make_client()
	_rm_dir_recursive("user://plugins/test_hidden_plugin")

	var first = await client.install_from_url(url, null)
	if not (first is Dictionary and first.get("ok") == true):
		print("FAIL: symlink — first install failed: %s" % JSON.stringify(first))
		_fail += 1
		return

	# Plant an external dir with a sentinel file, then a dot-named symlink to
	# it inside the installed plugin (dot-named so only the include_hidden
	# walk even sees it).
	var external := "%s/symlink_target" % _temp_dir
	_mkdir(external)
	_write_file("%s/sentinel.txt" % external, "must survive reinstall")
	var plug_abs := ProjectSettings.globalize_path("user://plugins/test_hidden_plugin")
	if not _run_cmd("ln", ["-s", external, "%s/.linked" % plug_abs]):
		print("FAIL: symlink — could not create test symlink")
		_fail += 1
		_rm_dir_recursive("user://plugins/test_hidden_plugin")
		return

	var second = await client.install_from_url(url, null)
	if not (second is Dictionary and second.get("ok") == true):
		print("FAIL: symlink — reinstall over dir containing symlink failed: %s" % JSON.stringify(second))
		_fail += 1
		_rm_dir_recursive("user://plugins/test_hidden_plugin")
		return
	if not FileAccess.file_exists("%s/sentinel.txt" % external):
		print("FAIL: symlink — delete followed the symlink and destroyed the target's contents")
		_fail += 1
		_rm_dir_recursive("user://plugins/test_hidden_plugin")
		return
	print("PASS: symlink (reinstall unlinks symlinks without touching their targets)")
	_pass += 1
	_rm_dir_recursive("user://plugins/test_hidden_plugin")


## The manifest id is interpolated into the delete/rename target before
## registration-time validation runs, so install_from_url must reject bad
## ids itself. "data" is the sharpest case: user://plugins/data/ is the
## shared per-plugin data root, and accepting it would wipe and hijack it.
func _test_reserved_id_rejected() -> void:
	var url := "http://127.0.0.1:%d/test_reserved.tar.gz" % PORT
	var client = _make_client()

	# Sentinel inside the data root: must be untouched by the rejected install.
	_mkdir("user://plugins/data/sentinel_plugin")
	_write_file(ProjectSettings.globalize_path("user://plugins/data/sentinel_plugin/keep.txt"), "must survive")

	var result = await client.install_from_url(url, null)
	if not (result is Dictionary and result.get("ok") == false and result.get("error") == "bad_manifest"):
		print("FAIL: reserved_id — expected error=bad_manifest, got %s" % JSON.stringify(result))
		_fail += 1
	elif not FileAccess.file_exists("user://plugins/data/sentinel_plugin/keep.txt"):
		print("FAIL: reserved_id — install with id \"data\" deleted the shared data root")
		_fail += 1
	else:
		print("PASS: reserved_id (id \"data\" rejected before the destructive delete)")
		_pass += 1
	_rm_dir_recursive("user://plugins/data/sentinel_plugin")


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
	_rm_dir_recursive("user://plugins/test_hidden_plugin")
