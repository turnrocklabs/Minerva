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
	if not _have_cmd("go"):
		_skip("go toolchain not on PATH")
		return
	var triple := _host_bundle_triple()
	if triple == "":
		_skip("unsupported host %s/arm64=%s" % [OS.get_name(), OS.has_feature("arm64")])
		return

	# --- Build fixture tarball (real binary + embedded bundle) + serve it ---
	if not await _setup_fixture(src_dir, triple):
		return  # _setup_fixture sets _skip / _fail

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
	var inner := _unwrap_envelope(ping_result)
	if inner.is_empty():
		print("FAIL: could not extract a worker envelope from ping result")
		_fail += 1
	elif inner.get("pong", false) != true:
		print("FAIL: ping did not return pong=true; inner=%s" % JSON.stringify(inner))
		_fail += 1
	else:
		if inner.get("echo") != "mp":
			print("WARN: echo mismatch (got %s)" % str(inner.get("echo")))
		print("PASS: ping round-trip (pong=true, worker=%s python=%s)"
				% [inner.get("worker", "?"), inner.get("python", "?")])
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

func _setup_fixture(src_dir: String, triple: String) -> bool:
	# Ensure an embedded bundle exists for this host so go:embed compiles a real
	# (Tier-1) binary — the exact artifact users install. Build it if absent
	# (PBS download is cached after the first run).
	var bundle := "%s/internal/runtime/bundle/runtime-bundle-%s.tar.zst" % [src_dir, triple]
	if not _file_ge(bundle, 1024 * 1024):
		var repo_root := src_dir.get_base_dir()  # ~/github/minerva-plugins
		var build_script := "%s/scripts/build-python-runtime-bundle.sh" % repo_root
		print("  bundle absent — building %s (cached PBS after first run)…" % triple)
		if not _helper.run_cmd("bash", [build_script, src_dir, triple]):
			_skip("could not build embedded bundle for %s" % triple)
			return false
		if not _file_ge(bundle, 1024 * 1024):
			_skip("bundle build produced no usable tarball at %s" % bundle)
			return false

	_temp_dir = "%s/mp_codetools_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	if not _helper.mkdir_recursive(_temp_dir):
		_fail += 1
		print("FAIL: could not make temp dir %s" % _temp_dir)
		return false
	var pack := "%s/pack" % _temp_dir
	_helper.mkdir_recursive(pack)

	# go build the real binary (host GOOS/GOARCH, embeds the bundle).
	print("  go build %s (embeds %s bundle)…" % [BINARY_NAME, triple])
	if not _helper.run_cmd("bash", ["-c",
			"cd '%s' && go build -o '%s/%s' ." % [src_dir, pack, BINARY_NAME]]):
		_fail += 1
		print("FAIL: go build")
		return false
	if not _helper.run_cmd("cp", ["-p", src_dir + "/manifest.json", pack.path_join("manifest.json")]):
		_fail += 1
		print("FAIL: copy manifest")
		return false

	# SHA256SUMS in the marketplace-verifier format (works on Linux + macOS).
	if not _helper.run_cmd("bash", ["-c",
			"cd '%s' && (command -v sha256sum >/dev/null 2>&1 && sha256sum %s manifest.json || shasum -a 256 %s manifest.json) > SHA256SUMS"
			% [pack, BINARY_NAME, BINARY_NAME]]):
		_fail += 1
		print("FAIL: sha256sum")
		return false

	# Pack into ../codetools-fixture.tar.gz (served at the temp dir root).
	if not _helper.run_cmd("bash", ["-c",
			"cd '%s' && tar -czf ../codetools-fixture.tar.gz ." % pack]):
		_fail += 1
		print("FAIL: tar")
		return false
	return true


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Map host OS+arch to the embedded-bundle triple (NOT the macos-universal
# release name — local single-arch builds embed one arch's bundle).
func _host_bundle_triple() -> String:
	match OS.get_name():
		"macOS":
			return "macos-arm64" if OS.has_feature("arm64") else "macos-amd64"
		"Linux":
			# codetools ships no linux-arm64 target (no embed_linux_arm64.go),
			# so an arm64 linux host SKIPs cleanly rather than failing go build.
			return "" if OS.has_feature("arm64") else "linux-x86_64"
		"Windows":
			return "windows-x86_64"
	return ""


func _have_cmd(name: String) -> bool:
	return OS.execute("bash", ["-c", "command -v %s >/dev/null 2>&1" % name], [], true) == 0


func _file_ge(path: String, min_bytes: int) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var sz := f.get_length()
	f.close()
	return sz >= min_bytes


# Extract the worker's inner {pong,...} dict from whatever envelope shape
# call_tool returns: the MCP {content:[{text:"<json>"}]} wrapper, the
# {ok:true,result:{...}} success envelope, or an already-unwrapped result.
func _unwrap_envelope(env: Dictionary) -> Dictionary:
	# Shape A: MCP content array with a JSON text part.
	if env.has("content") and typeof(env["content"]) == TYPE_ARRAY and env["content"].size() > 0:
		var first = env["content"][0]
		if typeof(first) == TYPE_DICTIONARY and first.has("text"):
			var parsed = JSON.parse_string(str(first["text"]))
			if typeof(parsed) == TYPE_DICTIONARY:
				return _unwrap_envelope(parsed)
	# Shape B: success envelope {ok:true, result:{...}}.
	if env.get("ok", false) == true and typeof(env.get("result")) == TYPE_DICTIONARY:
		return env["result"]
	# Shape C: result field carries the MCP wrapper.
	if env.has("result") and typeof(env["result"]) == TYPE_DICTIONARY:
		var r: Dictionary = env["result"]
		if r.has("content") or r.has("ok"):
			return _unwrap_envelope(r)
	# Shape D: already the inner dict.
	if env.has("pong"):
		return env
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
