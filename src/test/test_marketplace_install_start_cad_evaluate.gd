extends SceneTree
## Functional test — CAD plugin marketplace install + start + evaluate.
##
## Downloads the REAL release tarball for the host platform from
## imrans-lab/minerva-plugins (no local-fixture build), installs via
## MarketplaceClient, starts the plugin, then calls mcad_validate via the
## live MCP connection and checks the worker actually responded.
##
## This is the W2 gate for DCR 019e6a4bcb0c (CAD plugin embedded PBS python
## runtime, Plan A). Rewritten 2026-05-27 per scope amendment:
##   - Real-release-tarball download replaces the previous local-fixture flow
##     (the hermetic fixture only worked on machines with a pre-built binary).
##   - Cross-platform: runs on any host that has a matching release asset
##     (linux-x86_64, linux-arm64, macos-universal, windows-x86_64).
##   - Shared helpers (HTTP server, PluginManager bootstrap, MarketplaceClient
##     setup) factored to marketplace_test_helpers.gd.
##
## RED / GREEN protocol:
##   - TARGET_VERSION=cad-v0.1.0 → expects the mcad_validate step to FAIL
##     with a platform-specific worker-spawn error (proves the bug; the
##     test is asserting what the DCR fixes).
##   - TARGET_VERSION=cad-v0.1.1 → expects ok=true (post-W3 GREEN flip).
##
## Run with:
##   godot --headless --path src --script test/test_marketplace_install_start_cad_evaluate.gd
##
## Env override: MCAD_VALIDATE_TIMEOUT_SEC (defaults to 60). OCCT cold-start
## on a fresh-extracted runtime can exceed 30s; the default gives margin.

const PLUGIN_ID := "cad"
const CACHE_DIR := "user://test_fixtures/"
const RELEASES_REPO := "imrans-lab/minerva-plugins"

# Edit TARGET_VERSION to flip RED → GREEN once cad-v0.1.1 ships.
const TARGET_VERSION := "cad-v0.1.0"  # RED baseline; bump to v0.1.1 post-W3.
const TARGET_VERSION_BARE := "0.1.0"   # used to build the asset filename

# True when TARGET_VERSION is the pre-fix release. The test asserts FAILURE
# (and matches the platform-specific error) when this is true.
const EXPECT_RED := true  # flip to false when bumping to cad-v0.1.1

const VALIDATE_SOURCE := "result = sphere(5)"

const HELPER_GD := "res://test/marketplace_test_helpers.gd"

var _helper = null  # MarketplaceTestHelpers instance
var _pm = null
var _pass: int = 0
var _fail: int = 0
var _skipped: bool = false
var _skip_reason: String = ""


func _init() -> void:
	print("=== Marketplace install→start→evaluate test (cad) ===")
	print("  target release: %s" % TARGET_VERSION)
	print("  expectation:    %s" % ("RED (worker spawn failure)" if EXPECT_RED else "GREEN (ok=true)"))
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

	# Load and instantiate helpers.
	var helper_cls = load(HELPER_GD)
	if helper_cls == null:
		_skip("could not load %s" % HELPER_GD)
		return
	_helper = helper_cls.new(self)

	# --- Pick the release asset for this host ---
	var triple: String = _helper.release_triple_for_host()
	if triple == "":
		_skip("host platform %s/%s has no cad release asset" % [OS.get_name(), OS.get_environment("HOSTTYPE")])
		return
	var asset_name := "cad-%s-%s.tar.gz" % [TARGET_VERSION_BARE, triple]
	print("  host triple:   %s" % triple)
	print("  asset:         %s" % asset_name)

	# --- Download (or cache hit) ---
	print("\n-- step 0: fetch release tarball --")
	var dl: Dictionary = await _helper.download_release_tarball(
		RELEASES_REPO, TARGET_VERSION, asset_name, CACHE_DIR, 180.0)
	if not dl.get("ok", false):
		_skip("could not download %s: %s" % [asset_name, dl.get("error", "?")])
		return
	if dl.get("cached", false):
		print("  cached: %s" % dl.get("path"))
	else:
		print("  downloaded %d bytes: %s" % [dl.get("size", 0), dl.get("path")])

	# Local HTTP server serving CACHE_DIR. The marketplace install path expects
	# an HTTP URL (it doesn't trust local file paths). Port is randomized to
	# avoid colliding with orphans from prior killed test runs.
	var port: int = _helper.random_high_port()
	var serve_dir := ProjectSettings.globalize_path(CACHE_DIR)
	if not await _helper.start_http_server(serve_dir, port, 15.0):
		_fail += 1
		print("FAIL: http.server didn't come up")
		return
	var url := "http://127.0.0.1:%d/%s" % [port, asset_name]
	print("  serving at: %s" % url)

	# --- PluginManager bootstrap ---
	_pm = await _helper.bootstrap_plugin_manager()
	if _pm == null:
		_skip("PluginManager bootstrap failed")
		return
	await _helper.scrub_plugin(_pm, PLUGIN_ID)

	# --- Step 1: install via marketplace path ---
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
		print("FAIL: post-install — PluginManager has no cad definition")
		_fail += 1
		return
	print("  data_directory: %s" % def.data_directory)
	print("  entrypoint:     %s" % def.entrypoint)

	# --- Step 2: start_plugin ---
	print("\n-- step 2: start_plugin --")
	var start_result: Dictionary = await _pm.start_plugin(PLUGIN_ID)
	print("  start_result: %s" % JSON.stringify(start_result))
	if not start_result.get("ok", false):
		# Even start_plugin failure can be the RED indicator if the binary
		# can't spawn at all on this platform (e.g., missing libs). Report
		# it but don't treat as test PASS — the DCR fix has to make start AND
		# evaluate work.
		print("FAIL: start_plugin failed — error=%s" % start_result.get("error", "?"))
		_fail += 1
		return
	if def.state != _helper.S_RUNNING:
		print("FAIL: expected state RUNNING, got %d" % def.state)
		_fail += 1
		return
	var conn = _pm.get_connection(PLUGIN_ID)
	if conn == null:
		print("FAIL: no MCP connection after start_plugin")
		_fail += 1
		await _pm.stop_plugin(PLUGIN_ID)
		return
	print("PASS: install + start (state=RUNNING, conn live)")
	_pass += 1

	# --- Step 3: mcad_validate (the DCR acceptance gate) ---
	print("\n-- step 3: mcad_validate (DCR 019e6a4bcb0c acceptance) --")
	print("  source: %s" % VALIDATE_SOURCE)
	var validate_timeout: float = float(OS.get_environment("MCAD_VALIDATE_TIMEOUT_SEC")) if not OS.get_environment("MCAD_VALIDATE_TIMEOUT_SEC").is_empty() else 60.0
	var validate_result: Dictionary = await conn.call_tool(
		"mcad_validate",
		{"source": VALIDATE_SOURCE},
		validate_timeout,
	)
	print("  validate_result: %s" % JSON.stringify(validate_result))

	# Extract an error string from the various envelope shapes we might see.
	var err_text: String = _extract_error_text(validate_result)
	var ok_text: bool = _looks_like_success(validate_result)

	if EXPECT_RED:
		# RED: assert failure with a platform-appropriate error matcher.
		if err_text == "" or ok_text:
			print("FAIL: expected RED (worker-spawn failure) but mcad_validate succeeded.")
			print("  result: %s" % JSON.stringify(validate_result))
			print("  This means cad-v0.1.0 unexpectedly works — either the test is broken or")
			print("  the v0.1.0 release somehow ships embedded python (which it shouldn't).")
			_fail += 1
		elif _matches_platform_red(err_text):
			print("PASS: mcad_validate returned the expected RED baseline error")
			print("  matched-platform-failure-mode: %s" % err_text)
			_pass += 1
		else:
			print("FAIL: mcad_validate returned an error but it doesn't match a known RED mode.")
			print("  err_text: %s" % err_text)
			print("  This may mean a NEW failure mode emerged on this platform; update the matcher.")
			_fail += 1
	else:
		# GREEN: assert ok=true.
		if err_text != "":
			print("FAIL: GREEN expected ok=true but got error: %s" % err_text)
			_fail += 1
		elif not ok_text:
			print("FAIL: GREEN expected ok=true but couldn't confirm success in envelope.")
			print("  result: %s" % JSON.stringify(validate_result))
			_fail += 1
		else:
			print("PASS: mcad_validate returned ok=true (worker spawned + validated source)")
			_pass += 1

	# --- Step 4: clean stop ---
	print("\n-- step 4: stop_plugin --")
	var stop_result: Dictionary = await _pm.stop_plugin(PLUGIN_ID)
	if not stop_result.get("ok", false):
		print("WARN: stop_plugin failed (non-fatal): %s" % JSON.stringify(stop_result))
	elif def.state == _helper.S_STOPPED:
		print("PASS: clean stop")
		_pass += 1


# ---------------------------------------------------------------------------
# Envelope inspection helpers
# ---------------------------------------------------------------------------

# Returns a non-empty string when the envelope carries an error message
# (covers isError flag, top-level "error" key, and the {ok:false, error:...}
# inner envelope that cad's main.go emits per project_mcp_stdio_result_envelope).
func _extract_error_text(env: Dictionary) -> String:
	if env.get("isError", false):
		return JSON.stringify(env)
	if env.has("error"):
		return JSON.stringify(env.get("error"))
	# Inner envelope: result might be {ok:false, error:{...}} — cad's success
	# wrapper shape.
	var payload = env.get("result", env)
	if typeof(payload) == TYPE_DICTIONARY:
		if not payload.get("ok", true):
			return JSON.stringify(payload.get("error", payload))
		if payload.get("isError", false):
			return JSON.stringify(payload)
	return ""


# Returns true if the envelope looks like a clean ok=true result.
func _looks_like_success(env: Dictionary) -> bool:
	if env.get("isError", false) or env.has("error"):
		return false
	var payload = env.get("result", env)
	if typeof(payload) != TYPE_DICTIONARY:
		return false
	if not payload.get("ok", false):
		return false
	# Inner result.ok=true is the worker's confirmation; if it's missing,
	# only the MCP envelope ok is true, which is necessary but not sufficient.
	var inner = payload.get("result", null)
	if typeof(inner) == TYPE_DICTIONARY:
		return inner.get("ok", false)
	return true  # MCP-envelope ok=true is acceptable when no inner shape


# Matches RED failure modes per platform. Per W2 docket spec:
#   Linux:   fork/exec, python3, No such file
#   macOS:   ModuleNotFoundError, No module named, build123d
#   Windows: similar to macOS, or "is not recognized as an internal or external command"
# A single matcher returns true if ANY platform's expected substring appears —
# the platform that actually owns the cad-v0.1.0 failure on this host is
# revealed by the matched substring.
func _matches_platform_red(err_text: String) -> bool:
	var lower := err_text.to_lower()
	# Linux / no-python-on-PATH
	if "fork/exec" in lower or "no such file" in lower:
		return true
	# macOS / Windows — python exists but lacks build123d / mcad_worker
	if "modulenotfounderror" in lower or "no module named" in lower:
		return true
	if "build123d" in lower or "mcad_worker" in lower:
		return true
	# Windows-specific "not recognized" / "cannot find the path"
	if "is not recognized" in lower or "cannot find the path" in lower:
		return true
	# Worker-spawn error from the bridge (any of: crashed / python / internal)
	if "worker did not emit worker.ready" in lower:
		return true
	return false


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
