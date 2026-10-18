extends SceneTree
## Actual legacy child: exact parent context, invalid/stale provenance, opt-in lifetime.
var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)

func _collect(operation: Callable, replies: Array) -> void:
	replies.append(await operation.call())

func _wait(replies: Array) -> bool:
	var until := Time.get_ticks_msec() + 5000
	while replies.is_empty() and Time.get_ticks_msec() < until:
		await process_frame
	return replies.size() == 1

func _run() -> void:
	# These scripts require autoload context under the standalone runner.
	var connection_script = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var context_script = load("res://Scripts/Services/MCP/MCPExecutionContext.gd")
	var fixture := ProjectSettings.globalize_path("res://test/fixtures/parent_capability_probe/probe.py")
	var connection = connection_script.new("parent-fixture")
	connection.plugin_id = "parent_fixture"
	connection.configure_stdio("python3", PackedStringArray([fixture]))
	check("real legacy parent peer connects", await connection.connect_to_server() == OK)
	var first = context_script.create("internal", "first-chat")
	var replies: Array = []
	_collect(connection.call_tool_with_context.bind("hold", {}, first), replies)
	var until := Time.get_ticks_msec() + 3000
	while connection.pending_request_count() != 1 and Time.get_ticks_msec() < until:
		await process_frame
	check("legacy non-opted cancellation has a real outstanding call", connection.pending_request_count() == 1)
	first.cancel()
	var counts: Dictionary = await connection.call_tool("counts", {})
	check("non-opted Rust-style legacy reader receives no cancel notification", await _wait(replies)
		and counts.get("cancelled_ids", []).is_empty())
	var calls: Array = []
	connection.capability_request_handler = func(_owner: String, _capability: String, args: Dictionary) -> Dictionary:
		calls.append(args)
		return {"success": true}
	var absent: Dictionary = await connection.call_tool("parent", {"mode": "absent"})
	check("absent provenance retains actual legacy three-argument handler", absent.get("success") == true and calls.size() == 1)
	var expected = context_script.create("internal", "owning-chat")
	connection.capability_request_handler = func(_owner: String, _capability: String, _args: Dictionary, context: MCPExecutionContext) -> Dictionary:
		calls.append(context)
		return {"success": context.lifetime == expected.lifetime, "chat": context.caller_chat_id}
	var live: Dictionary = await connection.call_tool_with_context("parent", {"mode": "live"}, expected)
	check("live parent resolves exact owning lifetime and chat", live.get("success") == true and live.get("chat") == "owning-chat" and calls.size() == 2)
	for arguments: Dictionary in [{"mode": "stale"}, {"mode": "invalid", "parent": null},
			{"mode": "invalid", "parent": true}, {"mode": "invalid", "parent": 1.5},
			{"mode": "invalid", "parent": "unknown"}]:
		var refused: Dictionary = await connection.call_tool("parent", JSON.parse_string(JSON.stringify(arguments)))
		check("invalid or completed parent refuses before broker " + JSON.stringify(arguments),
			refused.get("error_code") == "parent_request_unknown" and calls.size() == 2)
	var opted = context_script.create("internal")
	var opted_replies: Array = []
	_collect(connection.call_tool_with_context.bind("hold", {}, opted), opted_replies)
	until = Time.get_ticks_msec() + 3000
	while connection.pending_request_count() != 1 and Time.get_ticks_msec() < until:
		await process_frame
	opted.cancel()
	counts = await connection.call_tool("counts", {})
	check("legacy parent provenance opts in only its process", await _wait(opted_replies) and counts.get("cancelled_ids", []).size() == 1)
	connection.disconnect_from_server()
	check("same connection starts a fresh process generation", await connection.connect_to_server() == OK)
	var replacement = context_script.create("internal")
	var replacement_replies: Array = []
	_collect(connection.call_tool_with_context.bind("hold", {}, replacement), replacement_replies)
	until = Time.get_ticks_msec() + 3000
	while connection.pending_request_count() != 1 and Time.get_ticks_msec() < until:
		await process_frame
	replacement.cancel()
	counts = await connection.call_tool("counts", {})
	check("restarted non-opted process receives no previous generation cancellation", await _wait(replacement_replies)
		and counts.get("cancelled_ids", []).is_empty() and connection.pending_request_count() == 0)
	connection.disconnect_from_server()
	print("Parent context results: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
