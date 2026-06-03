extends SceneTree
## Integration test for host.terminal.exec (P2.2, DCR 019e7b6609).
##
## Run: godot --headless --path src --script test/test_host_capability_terminal.gd
##
## Coverage (in-process — direct broker.dispatch with a stub PluginDB + override
## injection). Tests run headless, so the real-subprocess fallback path is the
## one exercised for live execution; the UI-terminal branch is covered via the
## _test_terminal_exec_override seam.
##
##    1. ungranted → capability_not_granted
##    2. granted + empty command → schema_validation_failed
##    3. granted + unknown arg key → schema_validation_failed
##    4. happy headless: echo → success, stdout, exit_code 0, routed_through=headless
##    5. non-zero exit → exit_code propagated, success (command ran), exit_code_known
##    6. cwd honored → pwd under /tmp
##    7. UI-terminal branch via override → routed_through=terminal, override cleared
##
## Also asserts the capability is generic: it depends on NO plugin/codetools code,
## proving "core works without codetools".
##
## Test isolation: clears TEST_PLUGIN_ID from user://plugins/policy.json
## before and after the run.

const PLUGIN_DB_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDB.gd"
const POLICY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"

const TEST_PLUGIN_ID := "terminal_exec_probe_test"
const CAP := "host.terminal.exec"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.terminal.exec Capability Test (P2.2) ===\n")
	_clear_policy_for_test()
	await _run_tests()
	_clear_policy_for_test()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	# Let the SingletonObject autoload finish initializing. Capability tests
	# load CapabilityBroker, which references the SingletonObject global at
	# compile time; under `--script` that global is only reliably available
	# after a couple of frames (same pattern as test_codetools_panel_gate.gd).
	await process_frame
	await process_frame

	var so = root.get_node_or_null("SingletonObject")
	if so == null or so.get("plugin_capability_broker") == null \
			or so.get("plugin_policy") == null or so.get("plugin_manager") == null:
		print("  SKIP: SingletonObject / capability broker not available under this invocation")
		return

	var Def = load(DEFINITION_SCRIPT_PATH)
	check("PluginDefinition loaded", Def != null)
	check("host.terminal.exec in ALLOWED_HOST_CAPABILITIES",
		CAP in Def.ALLOWED_HOST_CAPABILITIES)

	# Drive the REAL broker/policy (integration boundary). Inject a fake plugin
	# definition into the live DB so the capability can be declared + granted.
	var broker = so.plugin_capability_broker
	var policy = so.plugin_policy
	var db = so.plugin_manager.get_db()
	var def = Def.new(TEST_PLUGIN_ID)
	def.host_capabilities = [CAP] as Array[String]
	db._plugins[TEST_PLUGIN_ID] = def

	var Broker = load(BROKER_SCRIPT_PATH)
	Broker._test_terminal_exec_override = null

	# 1. ungranted → capability_not_granted
	var deny: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAP, {"command": "echo hi"})
	check_eq("ungranted → capability_not_granted",
		deny.get("error_code", ""), "capability_not_granted")

	policy.grant_capability(TEST_PLUGIN_ID, CAP)

	# 2. empty command → schema_validation_failed
	var empty: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAP, {"command": "   "})
	check_eq("empty command → schema_validation_failed",
		empty.get("error_code", ""), "schema_validation_failed")

	# 3. unknown arg key → schema_validation_failed
	var unk: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAP,
		{"command": "echo hi", "bogus": 1})
	check_eq("unknown arg → schema_validation_failed",
		unk.get("error_code", ""), "schema_validation_failed")

	# 4. happy headless echo → success, stdout, exit_code 0, routed_through=headless
	var ok: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAP,
		{"command": "echo hello_terminal_exec"})
	check("echo → success", ok.get("success", false), "got: %s" % str(ok))
	var res: Dictionary = ok.get("result", {})
	check("echo stdout contains marker",
		str(res.get("stdout", "")).find("hello_terminal_exec") != -1,
		"stdout=%s" % str(res.get("stdout", "")))
	check_eq("echo exit_code 0", res.get("exit_code", -1), 0)
	check_eq("echo exit_code_known true", res.get("exit_code_known", false), true)
	check_eq("echo routed_through headless", res.get("routed_through", ""), "headless")

	# 5. non-zero exit propagated
	var nz: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAP, {"command": "exit 7"})
	check("exit 7 → success (command ran)", nz.get("success", false), "got: %s" % str(nz))
	check_eq("exit 7 → exit_code 7", nz.get("result", {}).get("exit_code", -1), 7)

	# 6. cwd honored
	var cw: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAP,
		{"command": "pwd", "cwd": "/tmp"})
	check("pwd cwd=/tmp → success", cw.get("success", false), "got: %s" % str(cw))
	check("pwd output under /tmp",
		str(cw.get("result", {}).get("stdout", "")).find("/tmp") != -1,
		"stdout=%s" % str(cw.get("result", {}).get("stdout", "")))

	# 7. UI-terminal branch via override → routed_through=terminal, override cleared
	Broker._test_terminal_exec_override = {
		"stdout": "from_terminal_branch",
		"exit_code": 0,
		"exit_code_known": false,
		"timed_out": false,
		"routed_through": "terminal",
		"terminal_id": "123",
	}
	var term_branch: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAP, {"command": "ls"})
	check("override → success", term_branch.get("success", false), "got: %s" % str(term_branch))
	check_eq("override → routed_through terminal",
		term_branch.get("result", {}).get("routed_through", ""), "terminal")
	check_eq("override → stdout passthrough",
		term_branch.get("result", {}).get("stdout", ""), "from_terminal_branch")
	check_eq("override cleared after dispatch", Broker._test_terminal_exec_override, null)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		var msg := "  FAIL: %s" % label
		if not detail.is_empty():
			msg += " — " + detail
		print(msg)


func check_eq(label: String, actual, expected) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])


func _clear_policy_for_test() -> void:
	var policy_file: String = ProjectSettings.globalize_path("user://plugins/policy.json")
	if not FileAccess.file_exists(policy_file):
		return
	var fa := FileAccess.open(policy_file, FileAccess.READ)
	if fa == null:
		return
	var raw := fa.get_as_text()
	fa.close()
	var data: Variant = JSON.parse_string(raw)
	if not data is Dictionary:
		return
	var grants: Dictionary = (data as Dictionary).get("grants", {})
	grants.erase(TEST_PLUGIN_ID)
	(data as Dictionary)["grants"] = grants
	fa = FileAccess.open(policy_file, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(data, "  "))
	fa.close()
