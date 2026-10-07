extends SceneTree
## A real STDIO child distinguishes user quit from crash, startup loss and I/O failure.

const Profile = preload("res://Scripts/Services/MCP/MCPProfile.gd")
const S_STARTING := 1
const S_RUNNING := 2
const S_STOPPED := 3
const S_ERROR := 4

var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for scenario: Array in [
		["docket", S_RUNNING, "exit", 0, S_STOPPED],
		["docket", S_RUNNING, "stdout_eof_exit", 0, S_STOPPED],
		["docket", S_RUNNING, "exit", 7, S_ERROR],
		["other", S_RUNNING, "exit", 0, S_ERROR],
		["docket", S_STARTING, "exit", 0, S_ERROR],
		["docket", S_RUNNING, "overflow_exit", 0, S_ERROR],
	]:
		await _scenario(scenario)
	print("NATURAL_EXIT_RESULTS: %d failed" % failed)
	if failed == 0:
		print("=== PASS ===")
	quit(1 if failed else 0)

func _scenario(scenario: Array) -> void:
	var id: String = scenario[0]
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	var definition = load("res://Scripts/Services/Plugins/PluginDefinition.gd").new()
	definition.id = id
	definition.state = scenario[1]
	manager._db._plugins[id] = definition
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new(id)
	var fixture := ProjectSettings.globalize_path("res://test/fixtures/stdio_timing_probe/stdio_timing_probe.py")
	var python := "python" if OS.get_name() == "Windows" else "python3"
	# Match Docket's protocol so cold discovery cannot change whether quit executes.
	connection.configure_stdio(python, PackedStringArray([fixture, "--profile", "legacy"]))
	_check("child connected", await connection.connect_to_server() == OK)
	_check("initialized legacy profile", connection.protocol_profile.era == Profile.Era.INITIALIZED_LEGACY)
	manager._ensure_runtime(id)["connection"] = connection
	connection.disconnected.connect(manager._on_plugin_disconnected.bind(id))
	var stops: Array = []
	var crashes: Array = []
	manager.plugin_stopped.connect(func(value: String) -> void: stops.append(value))
	manager.plugin_crashed.connect(func(value: String) -> void: crashes.append(value))
	var arguments := {"code": scenario[3]}
	if scenario[2] != "overflow_exit":
		arguments["wait_for_release"] = true
	var reply: Dictionary = await connection.call_tool(scenario[2], arguments, 5.0)
	if scenario[2] != "overflow_exit":
		# A reply still adapting when its process exits may be dropped by the generation guard.
		_check("final response delivered", reply.get("exiting") == true and connection.pending_request_count() == 0)
		_check("exit released after response", connection._write_stdio_notification(
			{"jsonrpc": "2.0", "method": "test/release_exit"}, connection._process_generation))
	var deadline := Time.get_ticks_msec() + 5000
	while definition.state == scenario[1] and Time.get_ticks_msec() < deadline:
		await process_frame
	var clean: bool = scenario[4] == S_STOPPED
	_check("%s %s/%s -> %s" % [id, scenario[2], scenario[3], scenario[4]],
		definition.state == scenario[4] and stops.size() == int(clean) and crashes.size() == int(not clean))
	if scenario[2] != "overflow_exit":
		_check("natural status retained", connection.last_stdio_exit_code == scenario[3])
	else:
		_check("overflow is not a clean exit", connection.last_stdio_exit_code == -1 and reply.has("error"))
	_check("runtime released", manager.get_connection(id) == null)
	if clean:
		var host = load("res://Scripts/Services/DocketHost/DocketHost.gd").new()
		host.start(manager)
		var singleton = root.get_node("SingletonObject")
		var previous = singleton.docket_host
		singleton.docket_host = host
		var policy = load("res://Scripts/Services/MCP/PolicyEngine.gd").new()
		var refused: Dictionary = await policy.admit("minerva_docket_query", {})
		_check("machine quit refusal is clear and non-retryable",
			refused.get("error_code") == "docket_stopped_by_user" and refused.get("retryable") == false
			and "Tools > Docket" in refused.get("error", "") and not host.pickup_pending())
		var read: Dictionary = await host.open_projects()
		_check("direct host read preserves quit refusal", read.get("code") == "docket_stopped_by_user")
		singleton.docket_host = previous
		host.free()
	await create_timer(0.1).timeout
	_check("no automatic restart", manager.get_connection(id) == null and definition.state == scenario[4])
	connection.disconnect_from_server()
	manager.free()

func _check(label: String, condition: bool) -> void:
	if condition:
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)
