extends SceneTree
## Functional test — Code Tools plugin marketplace install + start + ping.
##
## P1.1 Gate-A centerpiece (DCR 019e7b6609, item 019e7b86e4): proves the
## codetools substrate installs through the REAL MarketplaceClient +
## PluginManager and that minerva_codetools_ping round-trips over the live MCP
## stdio connection — no stubs anywhere. The plugin binary, the Python worker,
## the install/verify/start path, and the tool call are all real.
##
## Hermetic + cross-platform: builds a fixture tarball from the LOCAL
## ~/github/minerva-plugins/codetools tree (go build with the embedded PBS
## bundle, exactly the production shape: binary + manifest + SHA256SUMS) and
## serves it on localhost. No network beyond the one-time PBS download the
## bundle build may need (cached afterwards).
##
## Run with:
##   godot --headless --path src --script test/test_marketplace_install_start_codetools.gd
##
## SKIPs cleanly when the codetools source tree, the Go toolchain, or a usable
## embedded bundle is unavailable (e.g. CI for the Minerva repo without the
## plugins checkout) — mirroring the scansort/cad sibling tests.

const PLUGIN_ID := "codetools"
const SRC_REL := "/github/minerva-plugins/codetools"
const BINARY_NAME := "codetools-plugin"
const HELPER_GD := "res://test/marketplace_test_helpers.gd"
const PING_TIMEOUT := 60.0  # first call extracts the embedded bundle on a cold data dir

var _helper = null  # MarketplaceTestHelpers
var _pm = null
var _temp_dir: String = ""
var _pass: int = 0
var _fail: int = 0
var _skipped: bool = false
var _skip_reason: String = ""


func _init() -> void:
	print("=== Marketplace install→start→ping test (codetools) ===")
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

	var helper_cls = load(HELPER_GD)
	if helper_cls == null:
		_skip("could not load %s" % HELPER_GD)
		return
	_helper = helper_cls.new(self)

	# --- Locate source + toolchain + bundle target ---
	var home: String = OS.get_environment("HOME")
	if home == "":
		_skip("$HOME unset")
		return
	var src_dir: String = home + SRC_REL
	var src_manifest: String = src_dir + "/manifest.json"
	if not FileAccess.file_exists(src_manifest):
		_skip("no codetools source at %s" % src_dir)
		return
	if not _helper.have_cmd("go"):
		_skip("go toolchain not on PATH")
		return
	var triple: String = _helper.host_bundle_triple()
	if triple == "":
		_skip("unsupported host %s/arm64=%s" % [OS.get_name(), OS.has_feature("arm64")])
		return

	# --- Build fixture tarball (real binary + embedded bundle) + serve it ---
	_temp_dir = "%s/mp_codetools_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	var fx: Dictionary = _helper.build_codetools_fixture(src_dir, triple, _temp_dir, BINARY_NAME, false)
	if not fx.get("ok", false):
		if fx.has("skip"):
			_skip(fx["skip"])
		else:
			_fail += 1
			print("FAIL: fixture build — %s" % fx.get("fail", "?"))
		return

	var port: int = _helper.random_high_port()
	if not await _helper.start_http_server(_temp_dir, port, 15.0):
		_fail += 1
		print("FAIL: http.server didn't come up")
		return
	var url := "http://127.0.0.1:%d/codetools-fixture.tar.gz" % port
	print("  serving at: %s" % url)

	# --- PluginManager bootstrap + scrub ---
	_pm = await _helper.bootstrap_plugin_manager()
	if _pm == null:
		_skip("PluginManager bootstrap failed")
		return
	await _helper.scrub_plugin(_pm, PLUGIN_ID)
	# EnsureRuntime caches the extracted bundle under <data_dir>/runtime/<version>
	# keyed by VERSION — a same-version worker change would otherwise be masked by
	# a stale extraction from a prior run. Clear it so each run extracts the bundle
	# we just built. (No-op on a clean machine / CI runner.)
	_helper.clear_runtime_cache(PLUGIN_ID)

	# --- Step 1: install via the real marketplace path ---
	print("\n-- step 1: install_from_url --")
	var mc = _helper.make_marketplace_client()
	var install_result: Dictionary = await mc.install_from_url(url, _pm)
	if not install_result.get("ok", false):
		print("FAIL: install_from_url returned: %s" % JSON.stringify(install_result))
		_fail += 1
		return
	print("  install ok: plugin_id=%s manifest_path=%s"
			% [install_result.get("plugin_id"), install_result.get("manifest_path")])

	var def = _pm._db.get_by_id(PLUGIN_ID)
	if def == null:
		print("FAIL: post-install — PluginManager has no codetools definition")
		_fail += 1
		return
	print("  data_directory: %s" % def.data_directory)
	print("  entrypoint:     %s" % def.entrypoint)

	# --- Step 2: start_plugin ---
	print("\n-- step 2: start_plugin --")
	var start_result: Dictionary = await _pm.start_plugin(PLUGIN_ID)
	print("  start_result: %s" % JSON.stringify(start_result))
	if not start_result.get("ok", false):
		print("FAIL: start_plugin failed — error=%s" % start_result.get("error", "?"))
		_fail += 1
		return
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

	# --- Step 3: ping over the live MCP connection (the Gate-A acceptance) ---
	print("\n-- step 3: minerva_codetools_ping --")
	var ping_result: Dictionary = await conn.call_tool(
		"minerva_codetools_ping", {"echo": "mp"}, PING_TIMEOUT)
	print("  ping_result: %s" % JSON.stringify(ping_result))
	var envl := _unwrap_envelope(ping_result)  # the P1.2 unified result envelope
	if envl.is_empty():
		print("FAIL: could not extract a unified envelope from ping result")
		_fail += 1
	elif envl.get("status") != "ok":
		print("FAIL: envelope status != ok; envelope=%s" % JSON.stringify(envl))
		_fail += 1
	else:
		var arts: Array = envl.get("artifacts", [])
		var info: Dictionary = arts[0] if arts.size() > 0 and arts[0] is Dictionary else {}
		if info.get("pong", false) != true:
			print("FAIL: no pong artifact in envelope; envelope=%s" % JSON.stringify(envl))
			_fail += 1
		else:
			if info.get("echo") != "mp":
				print("WARN: echo mismatch (got %s)" % str(info.get("echo")))
			print("PASS: ping round-trip (status=ok, pong=true, worker=%s python=%s)"
					% [info.get("worker", "?"), info.get("python", "?")])
			_pass += 1

	# --- Step 3b: code-visualizer round-trip (P1.3 Gate-A) ---
	# Asserts the install→start→tool path also works for the 9 P1.3 tools, not
	# just ping. analyze:stats works against an empty SQLite store (returns
	# zero counts) so we don't need an indexed corpus to prove the round-trip.
	print("\n-- step 3b: minerva_codetools_analyze (stats) --")
	# def.data_directory is a Godot URI (`user://...`); the Python worker is an
	# external process, so we have to globalize before handing the path off.
	var db_path := "%s/test_visualizer_stats.db" \
			% ProjectSettings.globalize_path(def.data_directory)
	var analyze_result: Dictionary = await conn.call_tool(
		"minerva_codetools_analyze",
		{"analysis": "stats", "db_path": db_path},
		PING_TIMEOUT)
	print("  analyze_result: %s" % JSON.stringify(analyze_result))
	var an_env := _unwrap_envelope(analyze_result)
	if an_env.is_empty():
		print("FAIL: could not extract envelope from analyze result")
		_fail += 1
	elif an_env.get("status") != "ok":
		print("FAIL: analyze envelope status != ok; envelope=%s" % JSON.stringify(an_env))
		_fail += 1
	else:
		var an_arts: Array = an_env.get("artifacts", [])
		var an_art: Dictionary = an_arts[0] if an_arts.size() > 0 and an_arts[0] is Dictionary else {}
		if an_art.get("type") != "analysis" or an_art.get("analysis") != "stats":
			print("FAIL: analyze artifact mismatch; artifact=%s" % JSON.stringify(an_art))
			_fail += 1
		else:
			print("PASS: analyze:stats round-trip (typed artifact ok)")
			_pass += 1

	# --- Step 4: clean stop ---
	print("\n-- step 4: stop_plugin --")
	var stop_result: Dictionary = await _pm.stop_plugin(PLUGIN_ID)
	if not stop_result.get("ok", false):
		print("WARN: stop_plugin failed (non-fatal): %s" % JSON.stringify(stop_result))
	elif def.state == _helper.S_STOPPED:
		print("PASS: clean stop (state=STOPPED)")
		_pass += 1


# ---------------------------------------------------------------------------
# Fixture build — go build the real binary (embedded bundle) + production-shape
# tarball (binary + manifest + SHA256SUMS), mirroring codetools.yml's pack step.
# ---------------------------------------------------------------------------

# Dig the P1.2 unified result envelope ({status, summary, artifacts, ...}) out
# of whatever wrapping call_tool returns: the MCP {content:[{text:"<json>"}]}
# part, the transport {ok:true, result:<envelope>} wrapper, or the envelope
# itself. Returns the envelope dict (it carries "status"), or {} if not found.
func _unwrap_envelope(env: Dictionary) -> Dictionary:
	# Already the envelope.
	if env.has("status") and env.has("artifacts"):
		return env
	# MCP content array with a JSON text part.
	if env.has("content") and typeof(env["content"]) == TYPE_ARRAY and env["content"].size() > 0:
		var first = env["content"][0]
		if typeof(first) == TYPE_DICTIONARY and first.has("text"):
			var parsed = JSON.parse_string(str(first["text"]))
			if typeof(parsed) == TYPE_DICTIONARY:
				return _unwrap_envelope(parsed)
	# Transport wrapper {ok:..., result:<envelope-or-deeper-wrapper>}.
	if env.has("result") and typeof(env["result"]) == TYPE_DICTIONARY:
		return _unwrap_envelope(env["result"])
	return {}


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
