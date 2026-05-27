extends SceneTree
## Per-plugin functional test — exercises the MARKETPLACE install path
## (MarketplaceClient.install_from_url with a PluginManager installer)
## AND the plugin's evaluate worker — that second half is the W2
## acceptance for DCR 019e6a4bcb0c (embedded PBS python runtime).
##
## Parallels test_marketplace_install_start_scansort.gd but adds the
## post-RUNNING step the scansort sibling lacks: call mcad_validate via
## MCPServerConnection and assert the worker actually responded with a
## non-error envelope. The scansort sibling stops at state=RUNNING; that
## is the gap that masked HITL #2 (cad evaluate failed with
## bridge.Worker.Start fork/exec ENOENT even though state=RUNNING was
## green).
##
## RED PROOF: against cad-v0.1.0 (the current release without embedded
## python), the install + start succeed and the mcad_validate step FAILS
## with a worker spawn error. After cad-v0.1.1 ships with go:embed'd
## PBS runtime (W1a/b/c + W3), the mcad_validate step passes.
##
## Hermetic: builds a fixture tarball from the LOCAL ~/github/plugins/cad
## tree (manifest + binary + ui/ + SHA256SUMS, mirroring the live release
## layout). Spawns python3 http.server on localhost. No network.
##
## Run with
##   godot --headless --path src --script test/test_marketplace_install_start_cad_evaluate.gd
##
## SKIP semantics: Linux x86_64 only (matches the cad binary build).

const MARKETPLACE_GD := "res://Scripts/Services/Plugins/MarketplaceClient.gd"
const PLUGIN_MANAGER_GD := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_ID := "cad"
const PLUGIN_SRC_REL := "/github/plugins/cad"
const BINARY_NAME := "cad-plugin"
# Randomized port: hardcoded ports collide with orphaned http.server processes
# from prior killed test runs (timeout=SIGTERM doesn't propagate to children).
# A 30000-50000 range gives 20k slots and is well above ephemeral-port territory.
var PORT: int = 30000 + (Time.get_ticks_msec() % 20000)

const S_RUNNING := 2
const S_STOPPED := 3

# mcad_validate is the cheapest worker call that exercises the full
# python-spawn + build123d-import path. Source compiles cleanly so the
# response shape on success is { ok: true, result: { ok: true, errors: [] } }.
const VALIDATE_SOURCE := "result = sphere(5)"
const VALIDATE_TIMEOUT_SEC := 60.0  # OCCT cold-start can take ~10s; give margin.

var _temp_dir: String = ""
var _server_pid: int = -1
var _pm = null
var _pass: int = 0
var _fail: int = 0
var _skipped: bool = false
var _skip_reason: String = ""


func _init() -> void:
	print("=== Marketplace install→start→evaluate test (cad) ===")
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
		_skip("cad binary is x86_64; this host is arm64")
		return

	var home: String = OS.get_environment("HOME")
	if home == "":
		_skip("$HOME unset")
		return
	var src_dir: String = home + PLUGIN_SRC_REL
	var src_manifest: String = src_dir + "/manifest.json"
	var src_binary: String = src_dir + "/" + BINARY_NAME
	var src_ui: String = src_dir + "/ui"
	if not FileAccess.file_exists(src_manifest):
		_skip("no cad manifest at %s" % src_manifest)
		return
	if not FileAccess.file_exists(src_binary):
		_skip("no cad binary at %s (build it first: cd %s && go build .)" % [src_binary, src_dir])
		return
	if not DirAccess.dir_exists_absolute(src_ui):
		_skip("no cad ui/ dir at %s" % src_ui)
		return

	# --- Build fixture tarball + start HTTP server ---
	if not await _setup_fixture(src_manifest, src_binary, src_ui):
		return  # _setup_fixture sets _skip / _fail

	var url := "http://127.0.0.1:%d/cad-fixture.tar.gz" % PORT

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
	var pm = _pm

	# Scrub any prior cad registration so we install fresh.
	if pm._db.has_plugin(PLUGIN_ID):
		print("  scrubbing pre-existing cad registration")
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

	var def = pm._db.get_by_id(PLUGIN_ID)
	if def == null:
		print("FAIL: post-install — PluginManager has no cad definition")
		_fail += 1
		return
	var globalized_dir := ProjectSettings.globalize_path(def.data_directory)
	print("  data_directory: %s" % def.data_directory)
	print("    globalized:   %s" % globalized_dir)
	print("  entrypoint:     %s" % def.entrypoint)

	# --- Step 2: start_plugin (DCR3 bug site, fixed) ---
	print("\n-- step 2: start_plugin --")
	var start_result: Dictionary = await pm.start_plugin(PLUGIN_ID)
	print("  start_result: %s" % JSON.stringify(start_result))
	if not start_result.get("ok", false):
		print("FAIL: start_plugin failed — error=%s" % start_result.get("error", "?"))
		print("  current state: %s" % def.state)
		_fail += 1
		return

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

	# --- Step 3: THE NEW ACCEPTANCE — mcad_validate via MCP ---
	# This is the W2 gate. cad-v0.1.0 returns a worker-spawn error here.
	# cad-v0.1.1 (post-DCR) returns ok=true with empty errors[].
	print("\n-- step 3: mcad_validate (DCR 019e6a4bcb0c acceptance) --")
	print("  source: %s" % VALIDATE_SOURCE)
	var validate_result: Dictionary = await conn.call_tool(
		"mcad_validate",
		{"source": VALIDATE_SOURCE},
		VALIDATE_TIMEOUT_SEC,
	)
	print("  validate_result: %s" % JSON.stringify(validate_result))

	# Reject any error envelope first — including the diagnostic fork/exec
	# message that motivated this DCR. We do this BEFORE checking the
	# success shape so the failure log surfaces the actual error string.
	var err_text: String = ""
	if validate_result.get("isError", false):
		err_text = JSON.stringify(validate_result)
	elif validate_result.has("error"):
		err_text = JSON.stringify(validate_result.get("error"))
	else:
		# Inspect the tool envelope: { result: { content: [{type:"text", text:"<JSON>"}], isError? } }
		# Per project_mcp_stdio_result_envelope memory, the plugin's tools/call
		# wraps {ok, result} JSON in a content text item. MCPServerConnection
		# normalizes that — confirm.
		var payload = validate_result.get("result", validate_result)
		if typeof(payload) == TYPE_DICTIONARY:
			# The plugin wraps with {ok: true, result: {...}} on success
			# and {ok: false, error: {...}} on failure (cad main.go ~430).
			if not payload.get("ok", true):
				err_text = JSON.stringify(payload.get("error", payload))
			elif payload.get("isError", false):
				err_text = JSON.stringify(payload)

	if err_text != "":
		print("FAIL: mcad_validate returned an error envelope:")
		print("  %s" % err_text)
		# Specific diagnosis for the DCR's RED baseline — this is the bug
		# being fixed. Surface it loudly so RED runs are unambiguous.
		if "fork/exec" in err_text or "python3" in err_text or "no such file or directory" in err_text:
			print("  (RED baseline — worker python spawn failure; the bug DCR 019e6a4bcb0c fixes)")
		elif "Python runtime not bundled" in err_text:
			print("  (post-W1c sentinel — non-linux platform sentinel triggered on linux build, unexpected)")
		_fail += 1
		await pm.stop_plugin(PLUGIN_ID)
		return

	# Success shape: payload.result.ok = true, errors list empty
	var payload = validate_result.get("result", validate_result)
	if typeof(payload) != TYPE_DICTIONARY:
		print("FAIL: validate_result.result is not a Dictionary; got %s" % typeof(payload))
		_fail += 1
		await pm.stop_plugin(PLUGIN_ID)
		return
	if not payload.get("ok", false):
		print("FAIL: payload.ok != true; payload=%s" % JSON.stringify(payload))
		_fail += 1
		await pm.stop_plugin(PLUGIN_ID)
		return
	var inner = payload.get("result", {})
	var ok_inner: bool = false
	var errors_inner: Array = []
	if typeof(inner) == TYPE_DICTIONARY:
		ok_inner = inner.get("ok", false)
		errors_inner = inner.get("errors", [])
	if not ok_inner or not errors_inner.is_empty():
		print("FAIL: mcad_validate inner result not clean; inner=%s" % JSON.stringify(inner))
		_fail += 1
		await pm.stop_plugin(PLUGIN_ID)
		return

	print("PASS: mcad_validate ok=true errors=[] (worker spawned + validated source)")
	_pass += 1

	# --- Step 4: clean stop ---
	print("\n-- step 4: stop_plugin --")
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

func _setup_fixture(src_manifest: String, src_binary: String, src_ui: String) -> bool:
	_temp_dir = "%s/mp_cad_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	if not _mkdir(_temp_dir):
		_fail += 1
		print("FAIL: could not make temp dir %s" % _temp_dir)
		return false

	var pack := "%s/pack" % _temp_dir
	_mkdir(pack)

	# manifest + binary (preserve +x with cp -p) + ui/ tree.
	if not _run_cmd("cp", ["-p", src_manifest, pack.path_join("manifest.json")]):
		_fail += 1
		print("FAIL: copy manifest")
		return false
	if not _run_cmd("cp", ["-p", src_binary, pack.path_join(BINARY_NAME)]):
		_fail += 1
		print("FAIL: copy binary")
		return false
	if not _run_cmd("cp", ["-rp", src_ui, pack.path_join("ui")]):
		_fail += 1
		print("FAIL: copy ui/ tree")
		return false

	# SHA256SUMS over binary + manifest + every ui/ file (release format).
	# Two-space separator preserved by `sha256sum` default; sed strips the
	# leading `./` so paths match the install layout.
	if not _run_cmd("bash", ["-c",
			"cd '%s' && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum | sed 's| \\./| |' > SHA256SUMS" % pack]):
		_fail += 1
		print("FAIL: SHA256SUMS")
		return false

	if not _run_cmd("bash", ["-c",
			"cd '%s' && tar -czf ../cad-fixture.tar.gz ." % pack]):
		_fail += 1
		print("FAIL: tar")
		return false

	_server_pid = OS.create_process("python3", [
		"-m", "http.server", str(PORT),
		"--directory", _temp_dir,
		"--bind", "127.0.0.1",
	])
	if _server_pid <= 0:
		_fail += 1
		print("FAIL: could not spawn python http.server")
		return false

	# Cad test runs in a full-singleton boot context with concurrent MCP
	# server connects (nudge/cobrowser/codetools). Those starve create_timer
	# and HTTPRequest workers, so the 5s probe used by the scansort sibling
	# isn't enough here. We use a two-stage probe: first an OS-level socket
	# check (deterministic, not engine-dependent), then a single HTTPRequest
	# verification once the socket is open.
	var sock_up := false
	for i in range(150):
		await create_timer(0.1).timeout
		var sock_out: Array = []
		var rc := OS.execute("bash", ["-c",
				"exec 3<>/dev/tcp/127.0.0.1/%d 2>/dev/null && echo up && exec 3<&-" % PORT],
				sock_out, true)
		if rc == 0 and sock_out.size() > 0 and "up" in str(sock_out[0]):
			sock_up = true
			break
	if not sock_up:
		_fail += 1
		print("FAIL: http.server didn't accept TCP on port %d in 15s" % PORT)
		return false
	# Verify HTTP response shape too — port open but not http would be worse.
	var probe := HTTPRequest.new()
	probe.timeout = 5.0
	root.add_child(probe)
	var err := probe.request("http://127.0.0.1:%d/" % PORT)
	if err != OK:
		probe.queue_free()
		_fail += 1
		print("FAIL: HTTPRequest.request returned %d" % err)
		return false
	var result: Array = await probe.request_completed
	probe.queue_free()
	if result[1] in [200, 403, 404]:
		return true
	_fail += 1
	print("FAIL: http server responded with HTTP %d (expected 200/403/404)" % result[1])
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
	if _pm != null and _pm._db != null and _pm._db.has_plugin(PLUGIN_ID):
		_pm._db.remove(PLUGIN_ID)
	_rm_dir_recursive("user://plugins/%s" % PLUGIN_ID)
