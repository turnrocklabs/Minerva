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
##
## 2026-05-27 refactor: shell + HTTP-server + PluginManager bootstrap helpers
## extracted to marketplace_test_helpers.gd for re-use by the cad-evaluate
## sibling test (DCR 019e6a4bcb0c W2 scope amendment).

const PLUGIN_ID := "scansort"
const PLUGIN_SRC_REL := "/github/plugins/scansort"
const BINARY_NAME := "scansort-plugin"
const PORT := 18766

const HELPER_GD := "res://test/marketplace_test_helpers.gd"

var _helper = null  # MarketplaceTestHelpers
var _pm = null
var _temp_dir: String = ""
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

	# Load helpers.
	var helper_cls = load(HELPER_GD)
	if helper_cls == null:
		_skip("could not load %s" % HELPER_GD)
		return
	_helper = helper_cls.new(self)

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

	# --- Bootstrap PluginManager + scrub any prior registration ---
	_pm = await _helper.bootstrap_plugin_manager()
	if _pm == null:
		_skip("PluginManager bootstrap failed")
		return
	await _helper.scrub_plugin(_pm, PLUGIN_ID)

	# --- Instantiate MarketplaceClient ---
	var mc = _helper.make_marketplace_client()

	# --- Step 1: install via marketplace path ---
	print("\n-- step 1: install_from_url --")
	var install_result: Dictionary = await mc.install_from_url(url, _pm)
	if not install_result.get("ok", false):
		print("FAIL: install_from_url returned: %s" % JSON.stringify(install_result))
		_fail += 1
		return
	print("  install ok: plugin_id=%s manifest_path=%s"
			% [install_result.get("plugin_id"), install_result.get("manifest_path")])

	# Capture install-state forensics — these inform the diagnosis when the
	# subsequent start fails.
	var def = _pm._db.get_by_id(PLUGIN_ID)
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
	var start_result: Dictionary = await _pm.start_plugin(PLUGIN_ID)
	print("  start_result: %s" % JSON.stringify(start_result))
	if not start_result.get("ok", false):
		print("FAIL: start_plugin failed — error=%s" % start_result.get("error", "?"))
		print("  current state: %s" % def.state)
		_fail += 1
		return

	# --- Step 3: assert RUNNING + connection alive ---
	if def.state != _helper.S_RUNNING:
		print("FAIL: expected state RUNNING(%d), got %d" % [_helper.S_RUNNING, def.state])
		_fail += 1
		await _pm.stop_plugin(PLUGIN_ID)
		return
	var conn = _pm.get_connection(PLUGIN_ID)
	if conn == null:
		print("FAIL: no MCP connection after start_plugin")
		_fail += 1
		await _pm.stop_plugin(PLUGIN_ID)
		return
	print("PASS: install + start (state=RUNNING, conn live)")
	_pass += 1

	# --- Step 4: clean stop ---
	print("\n-- step 3: stop_plugin --")
	var stop_result: Dictionary = await _pm.stop_plugin(PLUGIN_ID)
	if not stop_result.get("ok", false):
		print("FAIL: stop_plugin failed: %s" % JSON.stringify(stop_result))
		_fail += 1
		return
	if def.state != _helper.S_STOPPED:
		print("FAIL: expected state STOPPED(%d), got %d" % [_helper.S_STOPPED, def.state])
		_fail += 1
		return
	print("PASS: clean stop (state=STOPPED)")
	_pass += 1


# ---------------------------------------------------------------------------
# Fixture build (scansort-specific — keeps the local-binary tarball flow)
# ---------------------------------------------------------------------------

func _setup_fixture(src_manifest: String, src_binary: String) -> bool:
	_temp_dir = "%s/mp_start_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	if not _helper.mkdir_recursive(_temp_dir):
		_fail += 1
		print("FAIL: could not make temp dir %s" % _temp_dir)
		return false

	var pack := "%s/pack" % _temp_dir
	_helper.mkdir_recursive(pack)

	# Copy manifest + binary into the pack dir, preserving permissions on the
	# binary (cp -p) so the source tarball has +x. The live release tarball
	# has the same shape (manifest.json + scansort-plugin + SHA256SUMS).
	if not _helper.run_cmd("cp", ["-p", src_manifest, pack.path_join("manifest.json")]):
		_fail += 1
		print("FAIL: copy manifest into pack")
		return false
	if not _helper.run_cmd("cp", ["-p", src_binary, pack.path_join(BINARY_NAME)]):
		_fail += 1
		print("FAIL: copy binary into pack")
		return false

	# Generate SHA256SUMS in the same format the marketplace verifier expects.
	if not _helper.run_cmd("bash", ["-c",
			"cd '%s' && sha256sum %s manifest.json > SHA256SUMS" % [pack, BINARY_NAME]]):
		_fail += 1
		print("FAIL: sha256sum")
		return false

	# Pack into ../scansort-fixture.tar.gz.
	if not _helper.run_cmd("bash", ["-c",
			"cd '%s' && tar -czf ../scansort-fixture.tar.gz ." % pack]):
		_fail += 1
		print("FAIL: tar")
		return false

	# Spawn http server in _temp_dir (so /scansort-fixture.tar.gz resolves).
	if not await _helper.start_http_server(_temp_dir, PORT, 10.0):
		_fail += 1
		print("FAIL: http.server didn't come up")
		return false
	return true


# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

func _skip(reason: String) -> void:
	_skipped = true
	_skip_reason = reason


func _teardown() -> void:
	if _helper != null:
		if _pm != null and _pm._db != null and _pm._db.has_plugin(PLUGIN_ID):
			_pm._db.remove(PLUGIN_ID)
			_helper.rm_dir_recursive("user://plugins/%s" % PLUGIN_ID)
		_helper.teardown()
	if not _temp_dir.is_empty():
		OS.execute("rm", ["-rf", _temp_dir], [], true)
