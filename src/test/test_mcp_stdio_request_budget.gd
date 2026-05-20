extends SceneTree
## Substrate functional tests F5/F6 — caller-set per-request budget and
## post-abandonment connection health, on the REAL MCPServerConnection driving
## the stdio_timing_probe fixture plugin.
##
## Run: godot --headless --path src --script test/test_mcp_stdio_request_budget.gd
##
## Tracks docket: minerva RCA 019e46b5 / work-item W4 019e470b39f3
##
## These exercise W1's NEW API — call_tool(tool, args, timeout_sec). On pre-W1
## code call_tool has no timeout parameter, so this file SKIPs cleanly (quit 0)
## and only runs real assertions once W1 has landed.
##
## F5 — a caller that sets a 2s budget on never_reply gets a structured error
##      at ~2s; an unbounded (timeout_sec=0) call is NOT prematurely killed and
##      still returns its real result.
## F6 — after a call is abandoned by its budget expiring, the connection is not
##      wedged: the very next call still completes correctly.

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const FIXTURE_DIR_REL := "/test/fixtures/stdio_timing_probe"
const PLUGIN_ID := "stdio_timing_probe"

const S_RUNNING := 2
const S_STOPPED := 3

## Caller budget under test, in seconds.
const F5_BUDGET_SEC := 2.0
## A sleep an unbounded call must be allowed to wait out, in ms.
const F5_UNBOUNDED_SLEEP_MS := 4000

var _pass_count: int = 0
var _fail_count: int = 0
var _skipped: bool = false


func _init() -> void:
	print("=== MCP STDIO Request-Budget Functional Tests (F5/F6) ===\n")
	print("Drives the real MCPServerConnection + stdio_timing_probe fixture — no stubs.")
	print("Exercises W1's call_tool(tool, args, timeout_sec) API.\n")
	await _run()
	if _skipped:
		print("\n=== SKIPPED (pre-W1): F5/F6 require W1's timeout_sec API ===")
		quit(0)
		return
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
		_skipped = true
		return

	print("Fixture dir: %s\n" % fixture_dir)

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
		# W1 adds the timeout_sec parameter to call_tool. If it is not present
		# yet (pre-W1), F5/F6 cannot run — skip cleanly rather than crash on a
		# wrong-arity call.
		var arg_count: int = _call_tool_arg_count(conn)
		if arg_count < 3:
			print("\nSKIP: call_tool has %d parameter(s) — W1's timeout_sec API is not present yet." % arg_count)
			print("      F5/F6 are validated only after W1 lands.")
			_skipped = true
			await pm.stop_plugin(PLUGIN_ID)
			return
		await _test_f5(conn)
		await _test_f6(conn)

	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin(PLUGIN_ID)
	check("stop_plugin returns ok", stop_result.get("ok", false) == true,
			"got: %s" % str(stop_result))


## F5 — caller-set per-request budget.
func _test_f5(conn) -> void:
	print("\n-- F5: caller-set per-request budget --")
	# A 2s budget on never_reply (which deliberately never replies) must error
	# at ~2s rather than hanging.
	var t0: int = Time.get_ticks_msec()
	var res = await conn.call_tool("never_reply", {}, F5_BUDGET_SEC)
	var elapsed: int = Time.get_ticks_msec() - t0
	check("F5: budgeted never_reply call returned (did not hang)",
			res is Dictionary, "got type %d" % typeof(res))
	check("F5: budgeted call errored close to its 2s budget (1.5s-5s window)",
			elapsed >= 1500 and elapsed <= 5000,
			"returned after %dms" % elapsed)
	check("F5: budget expiry produced a structured error {error:{code,message}}",
			res is Dictionary and res.get("error") is Dictionary
				and not str(res.get("error", {}).get("message", "")).is_empty(),
			"got: %s" % str(res))
	# An unbounded call (timeout_sec = 0) must NOT be prematurely killed.
	var t1: int = Time.get_ticks_msec()
	var slow = await conn.call_tool("sleep", {"ms": F5_UNBOUNDED_SLEEP_MS}, 0.0)
	var slow_elapsed: int = Time.get_ticks_msec() - t1
	check("F5: unbounded (timeout_sec=0) call waited for the real reply",
			slow is Dictionary and int(slow.get("slept_ms", -1)) == F5_UNBOUNDED_SLEEP_MS,
			"got %s after %dms" % [str(slow), slow_elapsed])


## F6 — connection stays healthy after a call is abandoned by budget expiry.
func _test_f6(conn) -> void:
	print("\n-- F6: connection stays healthy after a call is abandoned --")
	# Abandon a call by letting its 2s budget expire.
	var abandoned = await conn.call_tool("never_reply", {}, F5_BUDGET_SEC)
	check("F6: the abandoned call returned via its budget",
			abandoned is Dictionary and abandoned.has("error"),
			"got: %s" % str(abandoned))
	# The very next call must still complete correctly — the connection is not
	# wedged by the abandoned request still sitting in the pending map.
	var t0: int = Time.get_ticks_msec()
	var after = await conn.call_tool("echo", {"marker": "after-abandon"}, 10.0)
	var elapsed: int = Time.get_ticks_msec() - t0
	check("F6: the call after an abandoned call completed without error",
			after is Dictionary and not after.has("error"),
			"got: %s" % str(after))
	check("F6: that call returned its own correct result",
			_echo_marker(after) == "after-abandon",
			"got: %s" % str(after))
	check("F6: that call was served promptly (connection not wedged)",
			elapsed < 3000, "took %dms" % elapsed)


## Number of declared parameters on conn.call_tool — used to detect whether
## W1's timeout_sec parameter has landed.
func _call_tool_arg_count(conn) -> int:
	for m in conn.get_method_list():
		if m.get("name", "") == "call_tool":
			var args = m.get("args", [])
			return args.size() if args is Array else 0
	return 0


## Extract the echo fixture's marker from a normalized call_tool result.
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
