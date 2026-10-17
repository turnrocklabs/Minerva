extends SceneTree
## One legacy real-child completion; capture the fallback drainer's race window.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame
	var connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new("stderr_probe")
	connection.configure_stdio("python3", PackedStringArray([ProjectSettings.globalize_path("res://test/fixtures/stdio_timing_probe/stdio_timing_probe.py")]))
	if await connection.connect_to_server() != OK:
		quit(1)
		return
	# Leave the real native stderr queue to the legacy tool-completion drainer,
	# rather than its competing stderr_ready consumer. No transport is mocked.
	for listener: Dictionary in connection._subprocess.stderr_ready.get_connections():
		connection._subprocess.stderr_ready.disconnect(listener.callable)
	var definition_type = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	var definition = definition_type.from_dict({"id": "stderr_probe", "name": "Stderr probe", "version": "1.0.0", "host_api_version": "2"})
	definition.state = definition_type.State.RUNNING
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	manager._db._plugins[definition.id] = definition
	manager._runtime[definition.id] = {"connection": connection}
	var audit = load("res://Scripts/Services/Plugins/PluginAuditLog.gd").new()
	var registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new(manager, null, audit)
	registry.register_plugin_tools(definition.id, [{"name": "minerva_stderr_probe_line", "description": "Diagnostic", "input_schema": {"type": "object"}, "_backend_name": "stderr_line"}])
	var queued := {"seen": false}
	manager.backend_tool_called.connect(func(_plugin: String, _tool: String) -> void:
		queued.seen = connection._subprocess.has_stderr())
	var capture = load("res://test/helpers/log_capture.gd").new()
	OS.add_logger(capture)
	var result: Dictionary = await registry.handle_tool_call("minerva_stderr_probe_line", {"index": 7, "text": "ERROR LEGACY_STDERR_SENTINEL"})
	var leaked: bool = "LEGACY_STDERR_SENTINEL" in capture.combined() or "LEGACY_STDERR_SENTINEL" in JSON.stringify(audit.get_entries())
	var passed: bool = result.get("index") == 7 and queued.seen and not leaked and not connection._subprocess.has_stderr()
	OS.remove_logger(capture)
	connection.disconnect_from_server()
	manager._runtime.clear()
	manager.free()
	print("LEGACY_STDERR_PASS" if passed else "LEGACY_STDERR_FAIL")
	quit(0 if passed else 1)
