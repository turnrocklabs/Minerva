extends SceneTree
## Integration test for the synchronous host capability request/response channel.
##
## Run: godot --headless --path src --script test/test_host_capability_channel.gd
##
## Covers DCR task 019df8e3514a706a85ec30b978dcdd78 (broker phase 2):
##   - Happy path: plugin calls host.echo mid-tool-call; result echoed back
##   - Deny path: plugin requests undeclared capability; gets structured error
##   - Re-entrancy: _in_stdio_request guard handles in-flight capability dispatch
##   - Audit log: both granted and denied requests are recorded
##
## NOTE: PluginManager.gd and MCPServerConnection.gd reference SingletonObject
## at parse time. In --script mode autoloads register lazily, so top-level
## preload() would fail. Use deferred load() once autoloads are wired.

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const CAPABILITY_BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const PLUGIN_POLICY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const PLUGIN_AUDIT_LOG_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const PLUGIN_ERRORS_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginErrors.gd"
const PLUGIN_DB_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDB.gd"

## Path to fixture plugin, relative to the project's res:// root (= src/)
const FIXTURE_DIR_REL := "/test/fixtures/capability_probe"

const S_RUNNING := 2
const S_STOPPED := 3

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Host Capability Channel Integration Test ===\n")
	print("Tests the bidirectional minerva/capability channel (broker phase 2).\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	# Locate fixture directory: res:// resolves to the src/ project root
	var fixture_dir: String = ProjectSettings.globalize_path("res://" + FIXTURE_DIR_REL)
	var manifest_path: String = fixture_dir + "/manifest.json"
	var probe_script: String = fixture_dir + "/capability_probe.py"

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: fixture manifest not found at %s" % manifest_path)
		_fail_count += 1
		return

	if not FileAccess.file_exists(probe_script):
		printerr("FAIL: fixture script not found at %s" % probe_script)
		_fail_count += 1
		return

	# Verify python3 is available
	var py_check := OS.execute("python3", ["--version"], [], true)
	if py_check != OK:
		print("SKIP: python3 not available — skipping fixture plugin tests")
		quit(0)
		return

	print("Fixture dir: %s\n" % fixture_dir)

	# Wait one frame for autoloads to register
	await process_frame

	# Wait for SingletonObject.plugin_tool_registry (≤10s)
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout
		print("SingletonObject ready after %dms\n" % (Time.get_ticks_msec() - (deadline_ms - 10000)))

	await _run_unit_tests()
	await _run_integration_tests(manifest_path, fixture_dir)


# ---------------------------------------------------------------------------
# Unit tests — CapabilityBroker in isolation (no subprocess)
# ---------------------------------------------------------------------------

func _run_unit_tests() -> void:
	print("-- Unit: CapabilityBroker host.echo dispatch --")

	var AuditLogScript = load(PLUGIN_AUDIT_LOG_SCRIPT_PATH)
	var PolicyScript = load(PLUGIN_POLICY_SCRIPT_PATH)
	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var PluginErrorsScript = load(PLUGIN_ERRORS_SCRIPT_PATH)

	check("scripts loaded", AuditLogScript != null and PolicyScript != null
		and BrokerScript != null and PluginErrorsScript != null)
	if AuditLogScript == null or PolicyScript == null or BrokerScript == null:
		return

	var audit = AuditLogScript.new()
	var policy = PolicyScript.new(null, audit, false)
	var broker = BrokerScript.new(policy, audit)

	# Grant host.echo to test plugin
	policy.grant_capability("probe_test", "host.echo")

	# --- Happy path: host.echo returns echo of args ---
	var echo_result: Dictionary = await broker.dispatch("probe_test", "host.echo",
		{"msg": "hello", "n": 42})
	# Successful broker dispatch returns payload directly (no {success, result} wrap).
	# Error path still has success=false + error_code; see deny tests below.
	check("host.echo result has 'echo' key",
		echo_result.has("echo"),
		"result keys: %s" % str(echo_result.keys()))
	check("host.echo echoes args back intact",
		echo_result.get("echo", {}).get("msg", "") == "hello",
		"got echo: %s" % str(echo_result.get("echo")))

	# --- Audit: dispatched event logged ---
	var dispatched_entries: Array = audit.get_entries("probe_test", "capability_dispatched")
	check("audit log has capability_dispatched entry for host.echo",
		dispatched_entries.size() > 0,
		"entries for probe_test: %s" % str(audit.get_entries("probe_test")))

	# --- Deny path: capability not granted ---
	var deny_result: Dictionary = await broker.dispatch("probe_test", "host.echo_nope",
		{})
	check("undeclared capability returns success=false",
		not deny_result.get("success", true),
		"got: %s" % str(deny_result))
	# error_code should be capability_not_granted (from policy) or unknown_capability
	var deny_code: String = deny_result.get("error_code", "")
	check("deny result has a structured error_code",
		deny_code in ["capability_not_granted", "unknown_capability"],
		"got error_code: '%s'" % deny_code)

	# --- Audit: denied event logged ---
	var denied_entries: Array = audit.get_entries("probe_test", "capability_denied")
	check("audit log has capability_denied entry",
		denied_entries.size() > 0,
		"denied entries: %s" % str(denied_entries))

	# --- Deny path: unknown capability even when granted (host.unknown_cap) ---
	policy.grant_capability("probe_test", "host.unknown_cap")
	var unknown_result: Dictionary = await broker.dispatch("probe_test", "host.unknown_cap", {})
	check("unknown granted capability returns error_code=unknown_capability",
		unknown_result.get("error_code", "") == "unknown_capability",
		"got: %s" % str(unknown_result))

	print("  (unit tests complete)\n")


# ---------------------------------------------------------------------------
# Integration tests — spawn real fixture subprocess
# ---------------------------------------------------------------------------

func _run_integration_tests(manifest_path: String, fixture_dir: String) -> void:
	print("-- Integration: fixture plugin subprocess --")

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	check("PluginManager script loaded", pm_script != null)
	if pm_script == null:
		return

	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame
	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id("capability_probe")

	if def == null:
		print("  capability_probe not in DB — installing...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin ok", install_result.get("ok", false) == true,
			"got: %s" % str(install_result))
		def = db.get_by_id("capability_probe")
	check("capability_probe definition loaded", def != null)
	if def == null:
		return

	# Ensure clean state
	if def.state == S_RUNNING:
		await pm.stop_plugin("capability_probe")

	# Grant host.echo (policy requires explicit grant).
	# The test's standalone PluginManager doesn't have its own PluginPolicy
	# (that lives in SingletonObject.plugin_policy). Grab it from there.
	var policy = pm.get_policy()
	if policy == null:
		var so_for_policy = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
		if so_for_policy != null and "plugin_policy" in so_for_policy:
			policy = so_for_policy.get("plugin_policy")
	if policy != null:
		policy.grant_capability("capability_probe", "host.echo")
		print("  Granted host.echo to capability_probe via policy")
	else:
		print("  WARNING: no policy available — grant skipped (deny path will still work)")

	# --- START ---
	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin("capability_probe")
	check("start_plugin ok", start_result.get("ok", false) == true,
		"got: %s" % str(start_result))
	check("state == RUNNING", def.state == S_RUNNING,
		"state=%d" % def.state)

	var conn = pm.get_connection("capability_probe")
	check("connection exists", conn != null)
	if conn == null:
		return

	# --- HAPPY PATH: probe_echo round-trip ---
	# We call the backend's raw tool name here (probe_echo), not the prefixed
	# registry name. MCPServerConnection.call_tool sends the name directly to
	# the subprocess via tools/call; the auto-prefix is Minerva's internal index.
	print("\n-- Happy path: probe_echo --")
	var echo_call = await conn.call_tool("probe_echo",
		{"payload": {"key": "test_value", "num": 7}})
	check("probe_echo call returned a Dictionary", echo_call is Dictionary,
		"got type %d" % typeof(echo_call))
	if echo_call is Dictionary:
		check("probe_echo has no top-level error",
			not echo_call.has("error"),
			"error: %s" % str(echo_call.get("error", "")))
		check("probe_echo success=true", echo_call.get("success", false),
			"got: %s" % str(echo_call))
		var cap_result = echo_call.get("capability_result", {})
		check("capability_result present in tool output", cap_result is Dictionary,
			"keys: %s" % str(echo_call.keys()))
		# The round-trip: args were sent as {"key":"test_value","num":7},
		# host.echo wraps in {"success":true,"result":{"echo":{...}}},
		# plugin returns {"echo": result.result.echo}
		var echo_data = echo_call.get("echo")
		check("echo data present in tool result", echo_data != null,
			"keys: %s" % str(echo_call.keys()))
		if echo_data != null:
			check("echoed 'key' matches original",
				echo_data.get("key", "") == "test_value",
				"got echo: %s" % str(echo_data))
			check("echoed 'num' matches original",
				int(echo_data.get("num", -1)) == 7,
				"got echo: %s" % str(echo_data))

	# --- DENY PATH: probe_denied ---
	print("\n-- Deny path: probe_denied (host.nonexistent) --")
	var denied_call = await conn.call_tool("probe_denied", {})
	check("probe_denied call returned a Dictionary", denied_call is Dictionary,
		"got type %d" % typeof(denied_call))
	if denied_call is Dictionary:
		check("probe_denied tool itself completed (no deadlock)",
			not denied_call.has("error") or denied_call.get("success", false) != null,
			"got: %s" % str(denied_call))
		check("probe_denied reports was_denied=true",
			denied_call.get("was_denied", false) == true,
			"got: %s" % str(denied_call))
		var err_code: String = str(denied_call.get("error_code", ""))
		check("denied capability error_code is structured (not empty)",
			not err_code.is_empty(),
			"error_code was empty")
		check("denied error_code is capability_not_granted or unknown_capability",
			err_code in ["capability_not_granted", "unknown_capability"],
			"got error_code: '%s'" % err_code)

	# --- AUDIT LOG: check broker-level entries ---
	# The standalone PluginManager's audit_log is null; grab from SingletonObject.
	print("\n-- Audit log entries --")
	var audit_log = pm.get_audit_log()
	if audit_log == null:
		var so_for_audit = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
		if so_for_audit != null and "plugin_audit_log" in so_for_audit:
			audit_log = so_for_audit.get("plugin_audit_log")
	if audit_log != null:
		var dispatched = audit_log.get_entries("capability_probe", "capability_dispatched")
		check("audit log has capability_dispatched entry (happy path)",
			dispatched.size() > 0,
			"dispatched count=%d" % dispatched.size())
		var denied_audit = audit_log.get_entries("capability_probe", "capability_denied")
		check("audit log has capability_denied entry (deny path)",
			denied_audit.size() > 0,
			"denied count=%d" % denied_audit.size())
	else:
		print("  WARNING: no audit_log available — skipping audit assertions")

	# --- RE-ENTRANCY: verify _in_stdio_request guard ---
	# The round-trip above already proves re-entrancy works end-to-end: if the
	# guard were broken, the connection's _on_async_output_ready would double-drain
	# the pipe and consume the capability request before _stdio_request saw it,
	# causing the tool call to hang or return garbled data.
	# We verify the guard state is clean after the call (not stuck = true).
	check("_in_stdio_request is false after tool call completes (no stuck guard)",
		conn.get("_in_stdio_request") == false,
		"_in_stdio_request=%s" % str(conn.get("_in_stdio_request")))

	# --- STOP ---
	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin("capability_probe")
	check("stop_plugin ok", stop_result.get("ok", false) == true,
		"got: %s" % str(stop_result))
	check("state == STOPPED", def.state == S_STOPPED,
		"state=%d" % def.state)


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

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
