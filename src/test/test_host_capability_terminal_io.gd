extends SceneTree
## Integration test for host.terminal.{list,read,write,wait} (A2/A3,
## agent-relay DCR 019eafbdcfb3) + live bell/shell-exit plumbing (A1).
##
## Run: godot --headless --path src --script test/test_host_capability_terminal_io.gd
##
## Coverage:
##    1. all four caps in ALLOWED_HOST_CAPABILITIES
##    2. ungranted → capability_not_granted
##    3. granted + unknown arg → schema_validation_failed
##    4. no terminal present: list → success count 0; read → terminal_tool_error
##    5. override seam passthrough + consumed
##    6. REAL TerminalNew (forkpty works headless): list sees it; write+wait
##       round-trip a command; raw=false unescapes while the broker default
##       (raw=true) does not mangle; printf '\a' → bell_serial + bell_rung;
##       `exit` → shell_exited + shell_exit_code (A1 live verification)
##
## Test isolation: clears TEST_PLUGIN_ID from user://plugins/policy.json
## before and after the run.

const DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"
const BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const TERMINAL_SCENE_PATH := "res://Scenes/Terminal.tscn"

const TEST_PLUGIN_ID := "terminal_io_probe_test"
const CAPS := [
	"host.terminal.list",
	"host.terminal.read",
	"host.terminal.write",
	"host.terminal.wait",
]

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.terminal.{list,read,write,wait} Capability Test (A2/A3) ===\n")
	_clear_policy_for_test()
	await _run_tests()
	_clear_policy_for_test()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	# Same autoload-settling pattern as test_host_capability_terminal.gd.
	await process_frame
	await process_frame

	var so = root.get_node_or_null("SingletonObject")
	if so == null or so.get("plugin_capability_broker") == null \
			or so.get("plugin_policy") == null or so.get("plugin_manager") == null:
		print("  SKIP: SingletonObject / capability broker not available under this invocation")
		return

	var Def = load(DEFINITION_SCRIPT_PATH)
	for cap in CAPS:
		check("%s in ALLOWED_HOST_CAPABILITIES" % cap, cap in Def.ALLOWED_HOST_CAPABILITIES)

	var broker = so.plugin_capability_broker
	var policy = so.plugin_policy
	var db = so.plugin_manager.get_db()
	var def = Def.new(TEST_PLUGIN_ID)
	var caps_typed: Array[String] = []
	caps_typed.assign(CAPS)
	def.host_capabilities = caps_typed
	db._plugins[TEST_PLUGIN_ID] = def

	var Broker = load(BROKER_SCRIPT_PATH)
	Broker._test_terminal_tool_override = null

	# 1. ungranted → capability_not_granted
	var deny: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.read", {})
	check_eq("ungranted read → capability_not_granted",
		deny.get("error_code", ""), "capability_not_granted")

	for cap in CAPS:
		policy.grant_capability(TEST_PLUGIN_ID, cap)

	# 2. unknown arg → schema_validation_failed
	var unk: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.read",
		{"bogus": 1})
	check_eq("unknown arg → schema_validation_failed",
		unk.get("error_code", ""), "schema_validation_failed")

	# 3. no terminal present: list succeeds empty, read errors cleanly
	var empty_list: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.list", {})
	check("list (no terminals) → success", empty_list.get("success", false),
		"got: %s" % str(empty_list))
	check_eq("list (no terminals) → count 0",
		empty_list.get("result", {}).get("count", -1), 0)

	var no_term_read: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.read", {})
	check_eq("read (no terminals) → terminal_tool_error",
		no_term_read.get("error_code", ""), "terminal_tool_error")

	# 4. override seam passthrough + consumed
	Broker._test_terminal_tool_override = {"content": "fake", "bell_rung": true}
	var ov: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.wait", {})
	check("override → success", ov.get("success", false), "got: %s" % str(ov))
	check_eq("override → bell_rung passthrough",
		ov.get("result", {}).get("bell_rung", false), true)
	check_eq("override consumed", Broker._test_terminal_tool_override, null)

	# 5. Real terminal: start a live PTY (forkpty works headless)
	var term_scene = load(TERMINAL_SCENE_PATH)
	if term_scene == null:
		check("Terminal.tscn loads", false)
		return
	var term = term_scene.instantiate()
	root.add_child(term)
	# Let _ready run, the shell start, and the first prompt arrive.
	for i in range(30):
		await process_frame
	if not term._terminal_available:
		print("  SKIP: terminal extension not available — live PTY tests skipped")
		term.queue_free()
		return

	# Headless layout collapses the control to ~1x2 cells; give the PTY a
	# real grid (same calls the resized handler makes) so output is readable.
	term._cols = 80
	term._rows = 24
	term.terminal.resize(80, 24)
	await process_frame

	var listed: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.list", {})
	check_eq("list (live) → count 1", listed.get("result", {}).get("count", -1), 1)
	var term_id: String = str(listed.get("result", {}).get("terminals", [{}])[0].get("id", ""))

	# 6. write (broker default raw=true: real control chars pass byte-for-byte)
	var wr: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.write",
		{"terminal_id": term_id, "text": "printf 'marker_%s\\n' io_alpha\r"})
	check("write (raw default) → success", wr.get("success", false), "got: %s" % str(wr))

	var waited: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.wait",
		{"terminal_id": term_id, "timeout_ms": 10000, "settle_ms": 400})
	check("wait → success", waited.get("success", false), "got: %s" % str(waited))
	check("wait content has command output",
		str(waited.get("result", {}).get("content", "")).find("marker_io_alpha") != -1,
		"content=%s" % str(waited.get("result", {}).get("content", "")))

	# 7. write raw=false unescapes \r into a real Enter
	var wr2: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.write",
		{"terminal_id": term_id, "text": "printf 'marker_%s\\\\n' io_beta\\r", "raw": false})
	check("write (raw=false) → success", wr2.get("success", false), "got: %s" % str(wr2))
	var waited2: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.wait",
		{"terminal_id": term_id, "timeout_ms": 10000, "settle_ms": 400})
	check("raw=false unescape round-trip",
		str(waited2.get("result", {}).get("content", "")).find("marker_io_beta") != -1,
		"content=%s" % str(waited2.get("result", {}).get("content", "")))

	# 8. A1 live: standalone BEL → bell_serial + wait.bell_rung
	var bell_before: int = term.bell_serial
	var wr3: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.write",
		{"terminal_id": term_id, "text": "printf '\\a'\r"})
	check("write bell → success", wr3.get("success", false), "got: %s" % str(wr3))
	var waited3: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.wait",
		{"terminal_id": term_id, "timeout_ms": 10000, "settle_ms": 400})
	check("bell_serial increased after BEL", term.bell_serial > bell_before,
		"before=%d after=%d" % [bell_before, term.bell_serial])
	check_eq("wait → bell_rung true",
		waited3.get("result", {}).get("bell_rung", false), true)

	# 9. A1 live: shell exit → shell_exited + exit code
	var wr4: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.write",
		{"terminal_id": term_id, "text": "exit 3\r"})
	check("write exit → success", wr4.get("success", false), "got: %s" % str(wr4))
	var waited4: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.terminal.wait",
		{"terminal_id": term_id, "timeout_ms": 10000, "settle_ms": 400})
	check_eq("wait → shell_exited true",
		waited4.get("result", {}).get("shell_exited", false), true)
	check_eq("wait → shell_exit_code 3",
		waited4.get("result", {}).get("shell_exit_code", -1), 3)

	term.queue_free()
	await process_frame


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
