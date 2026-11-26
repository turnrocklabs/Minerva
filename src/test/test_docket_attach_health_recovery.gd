extends SceneTree
## A live attached Docket misses a single ping after a person has stopped and started it.

const Context = preload("res://Scripts/Services/MCP/MCPExecutionContext.gd")
var _failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	# These scripts depend on the SingletonObject autoload and are loaded at runtime.
	var manager = load("res://test/helpers/docket_attach_manager.gd").new()
	var configured: Error = manager.configure_registered_docket(OS.get_environment("MINERVA_TEST_PROFILE_ROOT"))
	if configured != OK:
		printerr("FAIL: isolated Docket fixture setup: ", error_string(configured))
		manager.free()
		quit(1)
		return
	var singleton := root.get_node("SingletonObject")
	var previous_host: Node = singleton.get("docket_host")
	var host = load("res://Scripts/Services/DocketHost/DocketHost.gd").new()
	root.add_child(host)
	host.start(manager)
	singleton.set("docket_host", host)
	var started: Dictionary = await manager.start_plugin("docket")
	if _check("fixture attaches before Stop", started.get("attached", false)):
		manager.stop_plugin("docket", true)
		_check("Stop is recorded as a person's stop", host.stopped_by_user())
		started = await manager.start_plugin("docket")
		if _check("fixture reattaches after Start", started.get("attached", false)):
			await _check_recovery(manager, host)
			manager.stop_plugin("docket")
	singleton.set("docket_host", previous_host)
	host.free()
	manager.free()
	print("=== PASS ===" if _failures == 0 else "=== FAIL ===")
	quit(0 if _failures == 0 else 1)

func _check_recovery(manager: Node, host: Node) -> void:
	var person_stops: int = manager.person_stops("docket")
	var stdio_starts: int = manager.stdio_starts
	manager.http_alive = false
	await manager._run_health_checks()
	_check("missed ping does not record a person's stop",
		manager.person_stops("docket") == person_stops and not host.stopped_by_user())
	_check("a missed ping marks Docket not ready", not manager.get_plugin_status("docket").get("ready", false))
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new()
	server.policy_engine = load("res://Scripts/Services/MCP/PolicyEngine.gd").new()
	var result: Dictionary = await server.call_tool(
		"minerva_tool_search", {"activate": false}, Context.create("http"))
	_check("HTTP tool runs after the missed ping", result.get("success", false) and result.get("tools") is Array, result)
	manager.http_alive = true
	var status: Dictionary = {}
	for _tick in 3:
		await manager._run_health_checks()
		status = manager.get_plugin_status("docket")
		if status.get("ready", false):
			break
	_check("answering endpoint returns to attached and ready without Start or a spawn",
		status.get("attached", false) and status.get("running", false) and status.get("ready", false)
		and manager.stdio_starts == stdio_starts, status)

func _check(label: String, ok: bool, result: Dictionary = {}) -> bool:
	if ok:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label, " ", result)
	return ok
