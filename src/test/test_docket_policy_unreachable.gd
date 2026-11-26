extends SceneTree
## Exercise the real policy gate against an explicit Stop and a lost connection.

const TOOL := "minerva_tool_search"
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
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new()
	server.policy_engine = load("res://Scripts/Services/MCP/PolicyEngine.gd").new()
	var started: Dictionary = await manager.start_plugin("docket")
	if _check("fixture attaches before Stop", started.get("attached", false)):
		manager.stop_plugin("docket", true)
		_check("Stop is recorded as a person's stop", host.stopped_by_user())
		await _check_calls(server, "person stopped Docket")
		started = await manager.start_plugin("docket")
		if _check("fixture reattaches before connection loss", started.get("attached", false)):
			var connection: RefCounted = manager.get_connection("docket")
			connection.disconnect_from_server()
			await _check_calls(server, "Docket connection lost")
	singleton.set("docket_host", previous_host)
	host.free()
	manager.free()
	print("=== PASS ===" if _failures == 0 else "=== FAIL ===")
	quit(0 if _failures == 0 else 1)

func _check_calls(server: RefCounted, scenario: String) -> void:
	var arguments := {"activate": false}
	var external: Dictionary = await server.call_tool(TOOL, arguments, Context.create("http"))
	_check(scenario + ": HTTP tool runs", external.get("success", false) and external.get("tools") is Array, external)
	var internal: Dictionary = await server.call_tool(TOOL, arguments, Context.create("internal"))
	_check(scenario + ": in-app tool is refused with a retryable unreachable error",
		internal.get("allowed", true) == false and not internal.has("tools")
		and internal.get("error_code") == "docket_unreachable" and internal.get("retryable", false), internal)

func _check(label: String, ok: bool, result: Dictionary = {}) -> bool:
	if ok:
		print("PASS: ", label)
	else:
		_failures += 1
		printerr("FAIL: ", label, " ", result)
	return ok
