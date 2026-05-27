extends SceneTree
## Per-plugin functional test — exercises the MARKETPLACE install path
## (MarketplaceClient.install_from_url with a PluginManager installer) and
## then attempts to start the plugin, which is the user-visible failure
## that motivated this loop (DCR3 / RCA "ERR_CANT_CONNECT after marketplace
## install").
##
## Hermetic: builds a fixture tarball from the LOCAL ~/github/plugins/scansort
## tree (manifest + binary + SHA256SUMS, mirroring the live release layout)
## and serves it on localhost. No network dependency. Run with
##   godot --headless --path src --script test/test_marketplace_install_start_scansort.gd
##
## SKIP semantics:
##   - Linux x86_64 only (the scansort binary is platform-specific).
##   - SKIPs cleanly when the scansort source dir or binary is unavailable.
##
## Tracks docket / pickup: marketplace install→start green gate (Docs/pickup.md).

const MARKETPLACE_GD := "res://Scripts/Services/Plugins/MarketplaceClient.gd"
const PLUGIN_MANAGER_GD := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_ID := "scansort"
const PLUGIN_SRC_REL := "/github/plugins/scansort"
const BINARY_NAME := "scansort-plugin"
const PORT := 18766

const S_RUNNING := 2
const S_STOPPED := 3

var _temp_dir: String = ""
var _server_pid: int = -1
var _pm = null  # PluginManager — held for teardown so we can scrub the DB record
var _pass: int = 0
var _fail: int = 0
var _skipped: bool = false
var _skip_reason: String = ""


func _init() -> void:
	print("=== Marketplace install→start test (scansort) ===")
	await _run()
	_teardown()
	if _skipped:
		print("\n=== SKIPPED — %s ===" % _skip_reason)
		quit(0)
		return
	print("\n=== %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	await process_frame

	# --- Platform / fixture gate ---
	if OS.get_name() != "Linux":
		_skip("only Linux x86_64 supported (got %s)" % OS.get_name())
		return
	if OS.has_feature("arm64"):
		_skip("scansort binary is x86_64; this host is arm64")
		return

	var home: String = OS.get_environment("HOME")
	if home == "":
		_skip("$HOME unset")
		return
	var src_dir: String = home + PLUGIN_SRC_REL
	var src_manifest: String = src_dir + "/manifest.json"
	var src_binary: String = src_dir + "/" + BINARY_NAME
	if not FileAccess.file_exists(src_manifest):
		_skip("no scansort manifest at %s" % src_manifest)
		return
	if not FileAccess.file_exists(src_binary):
		_skip("no scansort binary at %s (build it first)" % src_binary)
		return

	# --- Build fixture tarball + start HTTP server ---
	if not await _setup_fixture(src_manifest, src_binary):
		return  # _setup_fixture sets _skip / _fail

	var url := "http://127.0.0.1:%d/scansort-fixture.tar.gz" % PORT

	# --- Singleton bootstrap (PluginManager parse-time refs SingletonObject) ---
	await process_frame
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout

	# --- Instantiate PluginManager ---
	var pm_cls = load(PLUGIN_MANAGER_GD)
	if pm_cls == null:
		_skip("could not load PluginManager.gd")
		return
	_pm = pm_cls.new()
	root.add_child(_pm)
	await process_frame
	if _pm._db == null:
		_skip("PluginManager did not initialise (no _db)")
		return
	var pm = _pm  # local alias for readability

	# If a previous run left scansort around, get rid of it before installing.
	if pm._db.has_plugin(PLUGIN_ID):
		print("  scrubbing pre-existing scansort registration")
		if pm._db.get_by_id(PLUGIN_ID).state == S_RUNNING:
			await pm.stop_plugin(PLUGIN_ID)
		pm._db.remove(PLUGIN_ID)
	_rm_dir_recursive("user://plugins/%s" % PLUGIN_ID)

	# --- Instantiate MarketplaceClient ---
	var mc_cls = load(MARKETPLACE_GD)
	var mc = mc_cls.new()
	root.add_child(mc)

	# --- Step 1: install via marketplace path ---
	print("\n-- step 1: install_from_url --")
	var install_result: Dictionary = await mc.install_from_url(url, pm)
	if not install_result.get("ok", false):
		print("FAIL: install_from_url returned: %s" % JSON.stringify(install_result))
		_fail += 1
		return
	print("  install ok: plugin_id=%s manifest_path=%s"
			% [install_result.get("plugin_id"), install_result.get("manifest_path")])

	# Capture install-state forensics — these inform the diagnosis when the
	# subsequent start fails.
	var def = pm._db.get_by_id(PLUGIN_ID)
	if def == null:
		print("FAIL: post-install — PluginManager has no scansort definition")
		_fail += 1
		return
	var globalized_dir := ProjectSettings.globalize_path(def.data_directory)
	var entrypoint_rel: String = def.entrypoint
	if entrypoint_rel.begins_with("./"):
		entrypoint_rel = entrypoint_rel.substr(2)
	var entrypoint_abs := "%s/%s" % [globalized_dir, entrypoint_rel]
	print("  data_directory: %s" % def.data_directory)
	print("    globalized:   %s" % globalized_dir)
	print("  entrypoint:     %s" % def.entrypoint)
	print("    resolved abs: %s" % entrypoint_abs)
	print("    exists:       %s" % FileAccess.file_exists(entrypoint_abs))
	# +x bit forensics — the no-exec hypothesis is rank-3 in pickup.md.
	var stat_out: Array = []
	var stat_rc := OS.execute("stat", ["-c", "%a %n", entrypoint_abs], stat_out, true)
	print("  stat (mode):    rc=%d out=%s" % [stat_rc, "\n".join(stat_out).strip_edges()])
	# Permissions on parent dir for completeness.
	var ls_out: Array = []
	OS.execute("ls", ["-la", globalized_dir], ls_out, true)
	print("  ls -la dir:\n%s" % "\n".join(ls_out))

	# --- Step 2: start_plugin (this is the bug site) ---
	print("\n-- step 2: start_plugin --")
	var start_result: Dictionary = await pm.start_plugin(PLUGIN_ID)
	print("  start_result: %s" % JSON.stringify(start_result))
	if not start_result.get("ok", false):
		print("FAIL: start_plugin failed — error=%s" % start_result.get("error", "?"))
		print("  current state: %s" % def.state)
		_fail += 1
		return

	# --- Step 3: assert RUNNING + connection alive ---
	var post_state: int = def.state
	if post_state != S_RUNNING:
		print("FAIL: expected state S_RUNNING(%d), got %d" % [S_RUNNING, post_state])
		_fail += 1
		await pm.stop_plugin(PLUGIN_ID)
		return
	var conn = pm.get_connection(PLUGIN_ID)
	if conn == null:
		print("FAIL: no MCP connection after start_plugin")
		_fail += 1
		await pm.stop_plugin(PLUGIN_ID)
		return
	print("PASS: install + start (state=RUNNING, conn live)")
	_pass += 1

	# --- Step 4: clean stop ---
	print("\n-- step 3: stop_plugin --")
	var stop_result: Dictionary = await pm.stop_plugin(PLUGIN_ID)
	if not stop_result.get("ok", false):
		print("FAIL: stop_plugin failed: %s" % JSON.stringify(stop_result))
		_fail += 1
		return
	if def.state != S_STOPPED:
		print("FAIL: expected state S_STOPPED(%d), got %d" % [S_STOPPED, def.state])
		_fail += 1
		return
	print("PASS: clean stop (state=STOPPED)")
	_pass += 1


# ---------------------------------------------------------------------------
# Fixture build
# ---------------------------------------------------------------------------

func _setup_fixture(src_manifest: String, src_binary: String) -> bool:
	_temp_dir = "%s/mp_start_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	if not _mkdir(_temp_dir):
		_fail += 1
		print("FAIL: could not make temp dir %s" % _temp_dir)
		return false

	var pack := "%s/pack" % _temp_dir
	_mkdir(pack)

	# Copy manifest + binary into the pack dir, preserving permissions on the
	# binary (cp -p) so the source tarball has +x. The live release tarball
	# has the same shape (manifest.json + scansort-plugin + SHA256SUMS).
	if not _run_cmd("cp", ["-p", src_manifest, pack.path_join("manifest.json")]):
		_fail += 1
		print("FAIL: copy manifest into pack")
		return false
	if not _run_cmd("cp", ["-p", src_binary, pack.path_join(BINARY_NAME)]):
		_fail += 1
		print("FAIL: copy binary into pack")
		return false

	# Generate SHA256SUMS in the same format the marketplace verifier expects.
	if not _run_cmd("bash", ["-c",
			"cd '%s' && sha256sum %s manifest.json > SHA256SUMS" % [pack, BINARY_NAME]]):
		_fail += 1
		print("FAIL: sha256sum")
		return false

	# Pack into ../scansort-fixture.tar.gz.
	if not _run_cmd("bash", ["-c",
			"cd '%s' && tar -czf ../scansort-fixture.tar.gz ." % pack]):
		_fail += 1
		print("FAIL: tar")
		return false

	# Spawn http server in _temp_dir (so /scansort-fixture.tar.gz resolves).
	_server_pid = OS.create_process("python3", [
		"-m", "http.server", str(PORT),
		"--directory", _temp_dir,
		"--bind", "127.0.0.1",
	])
	if _server_pid <= 0:
		_fail += 1
		print("FAIL: could not spawn python http.server")
		return false

	# Wait for the server to bind.
	for i in range(50):
		await create_timer(0.1).timeout
		var probe := HTTPRequest.new()
		probe.timeout = 1.0
		root.add_child(probe)
		var err := probe.request("http://127.0.0.1:%d/" % PORT)
		if err == OK:
			var result: Array = await probe.request_completed
			probe.queue_free()
			if result[1] in [200, 403, 404]:
				return true
		else:
			probe.queue_free()
	_fail += 1
	print("FAIL: http.server didn't come up in 5s")
	return false


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _skip(reason: String) -> void:
	_skipped = true
	_skip_reason = reason


func _mkdir(path: String) -> bool:
	if path.begins_with("user://") or path.begins_with("res://"):
		return DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path)) == OK
	return DirAccess.make_dir_recursive_absolute(path) == OK


func _run_cmd(cmd: String, args: Array) -> bool:
	var out: Array = []
	var rc := OS.execute(cmd, args, out, true)
	if rc != 0:
		print("  cmd %s %s failed (rc=%d): %s" % [cmd, args, rc, "\n".join(out)])
		return false
	return true


func _rm_dir_recursive(rel_path: String) -> void:
	var abs := ProjectSettings.globalize_path(rel_path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	OS.execute("rm", ["-rf", abs], [], true)


func _teardown() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
	if not _temp_dir.is_empty():
		OS.execute("rm", ["-rf", _temp_dir], [], true)
	# Scrub the persisted PluginDB record so the next test in the suite (which
	# may side-load scansort from ~/github/plugins/scansort/) doesn't pick up
	# our orphan user://plugins/scansort/ pointer.
	if _pm != null and _pm._db != null and _pm._db.has_plugin(PLUGIN_ID):
		_pm._db.remove(PLUGIN_ID)
	_rm_dir_recursive("user://plugins/%s" % PLUGIN_ID)
