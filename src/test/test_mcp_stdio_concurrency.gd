extends SceneTree
## Substrate functional tests F1/F2/F4 — concurrent MCP-over-stdio calls on the
## REAL MCPServerConnection, driving the stdio_timing_probe fixture plugin.
## No StubMCPConnection — mock connections are exactly why the connection-layer
## regression (RCA 019e46b5) shipped invisibly.
##
## Run: godot --headless --path src --script test/test_mcp_stdio_concurrency.gd
##
## Tracks docket: minerva RCA 019e46b5 / work-item W4 019e470b39f3
##
## F1 — two concurrent call_tool calls in flight; each caller receives its own
##      JSON-RPC id's result (id-routing correctness). Passes pre- and post-fix.
## F2 — one slow sleep(8s) + five instant echoes fired concurrently. The echoes
##      must each return promptly rather than queue behind the sleep. THIS IS
##      THE FAIL-FIRST REGRESSION REPRO: the fcdeda02 serialization gate makes
##      every echo wait out the slow call, so on pre-W1 code F2 FAILS; after W1
##      (single dispatcher, per-id routing) it PASSES.
## F4 — a stray/unmatched-id response frame must not wedge a live waiter, and a
##      concurrent normal call still receives its own correct result.
##
## NOTE: PluginManager.gd / MCPServerConnection.gd reference the SingletonObject
## autoload at parse time; in --script mode autoloads register lazily, so use a
## deferred load() rather than a top-level preload().

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const FIXTURE_DIR_REL := "/test/fixtures/stdio_timing_probe"
const PLUGIN_ID := "stdio_timing_probe"

const S_RUNNING := 2
const S_STOPPED := 3

## sleep() duration for F2. Must be well above F2's starvation threshold and
## well below the pre-W1 30s poll ceiling so the slow call itself still returns.
const F2_SLEEP_MS := 8000
## A concurrent call that has not been starved should finish far inside this.
const F2_ECHO_BUDGET_MS := 2000

var _pass_count: int = 0
var _fail_count: int = 0

## key -> result Dictionary, populated by _call_and_store as each call resolves.
var _results: Dictionary = {}
## key -> wall-clock ms the call took, populated alongside _results.
var _timings: Dictionary = {}


func _init() -> void:
	print("=== MCP STDIO Concurrency Functional Tests (F1/F2/F4) ===\n")
	print("Drives the real MCPServerConnection + stdio_timing_probe fixture — no stubs.")
	print("F2 is the fail-first repro for RCA 019e46b5; it FAILS until W1 lands.\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run() -> void:
	var fixture_dir: String = ProjectSettings.globalize_path("res://" + FIXTURE_DIR_REL)
	var manifest_path: String = fixture_dir + "/manifest.json"
	var probe_script: String = fixture_dir + "/stdio_timing_probe.py"

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: fixture manifest not found at %s" % manifest_path)
		_fail_count += 1
		return
	if not FileAccess.file_exists(probe_script):
		printerr("FAIL: fixture script not found at %s" % probe_script)
		_fail_count += 1
		return
	if OS.execute("python3", ["--version"], [], true) != OK:
		print("SKIP: python3 not available — cannot run the stdio fixture plugin.")
		quit(0)
		return

	print("Fixture dir: %s\n" % fixture_dir)

	# Wait one frame for autoloads (SingletonObject) to register, then for the
	# plugin_tool_registry to be wired (late-init; see the smoke-test precedents).
	await process_frame
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("FAIL: could not load PluginManager.gd")
		_fail_count += 1
		return
	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame
	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id(PLUGIN_ID)
	if def == null:
		print("Fixture not in PluginDB — installing from manifest...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true,
				"got: %s" % str(install_result))
		def = db.get_by_id(PLUGIN_ID)
	check("fixture definition loaded into DB", def != null)
	if def == null:
		return

	if def.state == S_RUNNING:
		print("Fixture already RUNNING — stopping first for a clean baseline.")
		await pm.stop_plugin(PLUGIN_ID)

	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin(PLUGIN_ID)
	check("start_plugin returns ok", start_result.get("ok", false) == true,
			"got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING,
			"got state=%d" % def.state)

	var conn = pm.get_connection(PLUGIN_ID)
	check("connection exists post-start", conn != null)
	if conn != null:
		await _test_f1(conn)
		await _test_f2(conn)
		await _test_f4(conn)

	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin(PLUGIN_ID)
	check("stop_plugin returns ok", stop_result.get("ok", false) == true,
			"got: %s" % str(stop_result))


## F1 — two concurrent calls; each must receive its own id's result.
func _test_f1(conn) -> void:
	print("\n-- F1: concurrent calls are routed to the correct caller --")
	_results.clear()
	_timings.clear()
	_call_and_store(conn, "echo", {"marker": "alpha"}, "a")
	_call_and_store(conn, "echo", {"marker": "beta"}, "b")
	var ok: bool = await _await_keys(["a", "b"], 30000)
	check("F1: both concurrent calls completed", ok,
			"results present: %s" % str(_results.keys()))
	if not ok:
		return
	check("F1: call A received call A's own result (id-routed, not B's)",
			_echo_marker(_results.get("a")) == "alpha",
			"got: %s" % str(_results.get("a")))
	check("F1: call B received call B's own result (id-routed, not A's)",
			_echo_marker(_results.get("b")) == "beta",
			"got: %s" % str(_results.get("b")))


## F2 — FAIL-FIRST REPRO. A slow call must not starve concurrent fast calls.
func _test_f2(conn) -> void:
	print("\n-- F2: a slow call must not starve concurrent fast calls (REPRO) --")
	_results.clear()
	_timings.clear()
	var echo_keys: Array = []
	# Launch the slow call first so it owns the connection when the echoes land.
	_call_and_store(conn, "sleep", {"ms": F2_SLEEP_MS}, "slow")
	for i in range(5):
		var k: String = "e%d" % i
		echo_keys.append(k)
		_call_and_store(conn, "echo", {"marker": k}, k)
	# Wait only for the five echoes — they must not have to wait on the 8s sleep.
	var echoes_ok: bool = await _await_keys(echo_keys, 30000)
	check("F2: all five concurrent echoes completed", echoes_ok,
			"results present: %s" % str(_results.keys()))
	var slowest_echo_ms: int = 0
	for k in echo_keys:
		slowest_echo_ms = max(slowest_echo_ms, int(_timings.get(k, 999999)))
	# THE fail-first assertion: on pre-W1 code the fcdeda02 gate makes every
	# echo wait out the full 8s sleep, so slowest_echo_ms ~= 8000+ and this
	# FAILS. After W1 the dispatcher routes by id and echoes return in <100ms.
	check("F2: slowest concurrent echo returned in <%dms (not starved by the slow call)" % F2_ECHO_BUDGET_MS,
			slowest_echo_ms < F2_ECHO_BUDGET_MS,
			"slowest echo took %dms — the slow call starved it (RCA 019e46b5)" % slowest_echo_ms)
	# The slow call must still complete and return its own correct result.
	var slow_ok: bool = await _await_keys(["slow"], 30000)
	check("F2: the slow call still completed", slow_ok)
	if slow_ok:
		check("F2: the slow call returned its own correct result",
				int(_results.get("slow", {}).get("slept_ms", -1)) == F2_SLEEP_MS,
				"got: %s" % str(_results.get("slow")))


## F4 — a stray unmatched-id response must not wedge a live waiter.
func _test_f4(conn) -> void:
	print("\n-- F4: a stray unmatched-id response must not wedge a waiter --")
	_results.clear()
	_timings.clear()
	# emit_stray sends an unmatched-id frame, THEN its real reply.
	_call_and_store(conn, "emit_stray", {}, "stray")
	# A concurrent normal call proves interleaved traffic stays id-routed.
	_call_and_store(conn, "echo", {"marker": "concurrent"}, "co")
	var ok: bool = await _await_keys(["stray", "co"], 30000)
	check("F4: both calls completed despite the stray frame", ok,
			"results present: %s" % str(_results.keys()))
	if not ok:
		return
	check("F4: the emit_stray call resolved to its own real reply",
			_results.get("stray", {}).get("emitted_stray", false) == true,
			"got: %s" % str(_results.get("stray")))
	check("F4: the concurrent echo still received its own correct result",
			_echo_marker(_results.get("co")) == "concurrent",
			"got: %s" % str(_results.get("co")))


## Fire conn.call_tool as a background coroutine; store its result + timing
## under `key` when it resolves. Called WITHOUT await so multiple calls are in
## flight on the one connection at once — the scenario RCA 019e46b5 is about.
func _call_and_store(conn, tool_name: String, args: Dictionary, key: String) -> void:
	var t0: int = Time.get_ticks_msec()
	var res = await conn.call_tool(tool_name, args)
	_timings[key] = Time.get_ticks_msec() - t0
	_results[key] = res


## Poll until every key is present in _results, or timeout. Returns true if all
## arrived.
func _await_keys(keys: Array, timeout_ms: int) -> bool:
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var all_present: bool = true
		for k in keys:
			if not _results.has(k):
				all_present = false
				break
		if all_present:
			return true
		await Engine.get_main_loop().create_timer(0.05).timeout
	return false


## Extract the echo fixture's marker from a normalized call_tool result.
## echo returns {"success": true, "echo": {<args>}}.
func _echo_marker(res) -> String:
	if res is Dictionary:
		var e = res.get("echo", {})
		if e is Dictionary:
			return str(e.get("marker", ""))
	return ""


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
