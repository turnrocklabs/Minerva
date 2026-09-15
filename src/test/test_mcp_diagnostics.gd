extends SceneTree
## Presentation and lifecycle coverage with no network or subprocess. The
## removal path writes MCP config, so run this suite with isolated user data.

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var Diagnostics = load("res://Scripts/Services/MCP/MCPServerDiagnostics.gd")
	check("modern and legacy status remain distinct",
		Diagnostics.status_text({"state": "connected", "transport": "stdio",
			"era": "modern", "version": "2026-07-28"}) ==
			"Connected · STDIO · MCP 2026-07-28"
		and Diagnostics.status_text({"state": "connected", "transport": "http",
			"era": "legacy", "version": "2025-06-18"}) ==
			"Connected · HTTP · Legacy MCP 2025-06-18")
	check("custom transports do not claim a modern version",
		Diagnostics.status_text({"state": "connected", "transport": "websocket",
			"era": "custom"}) == "Connected · WebSocket · Custom protocol")
	check("failed attempt is actionable without endpoint or command data",
		Diagnostics.status_text({"state": "failed", "transport": "stdio",
			"failure": "Tool discovery failed"}) ==
			"Connection failed · STDIO · Tool discovery failed")
	check("subsecond timeout wording never rounds to zero",
		Diagnostics.timeout_text(0.01) == "10ms"
		and Diagnostics.timeout_text(0.25) == "250ms"
		and Diagnostics.timeout_text(2.0) == "2s")
	var Connection = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	var parsed_peer_error: Dictionary = JSON.parse_string(
		'{"code":-32602,"message":"SECRET_PEER_PAYLOAD"}')
	var peer_error: Dictionary = parsed_peer_error
	var category: String = Connection.new()._safe_peer_error_category(peer_error)
	check("peer failures expose bounded codes without their payload",
		category == "peer error code -32602" and "SECRET_PEER_PAYLOAD" not in category)
	var Manager = load("res://Scripts/Services/MCP/MCPManager.gd")
	var Profile = load("res://Scripts/Services/MCP/MCPProfile.gd")
	var manager = Manager.new()
	var Config = load("res://Scripts/Services/MCP/MCPConfig.gd")
	manager.config = Config.new()
	manager.config.servers.clear()
	var probe_config = Config.ServerConfig.create_stdio("probe", "first-command")
	probe_config.origin = "user"
	probe_config.persistent = false
	manager.config.set_server(probe_config)
	manager._record_connection_failure("probe", "stdio", "Handshake failed", -1,
		manager._server_config_key(probe_config))
	var failed_state: Dictionary = manager.get_server_diagnostic("probe")
	var custom_profile = Profile.custom(1)
	# A tiny object-shaped fixture keeps this test independent of transports.
	var custom := {"protocol_profile": custom_profile}
	var connected_diagnostic: Dictionary = manager._connected_diagnostic("http", custom)
	connected_diagnostic["config_key"] = manager._server_config_key(probe_config)
	manager._connection_diagnostics["probe"] = connected_diagnostic
	var replaced_state: Dictionary = manager.get_server_diagnostic("probe")
	check("manager retains a failed attempt until a successful replacement is recorded",
		failed_state.failure == "Handshake failed" and failed_state.state == "failed"
		and replaced_state.failure == "" and replaced_state.state == "connected"
		and Diagnostics.status_text(replaced_state) == "Connected · HTTP · Custom protocol")
	var replacement = Config.ServerConfig.create_stdio("probe", "replacement-command")
	replacement.origin = "user"
	replacement.persistent = false
	var replace_error: Error = await manager.add_server_at_runtime(replacement, false)
	check("config replacement prunes stale diagnostics and updates transport inputs",
		replace_error == OK and manager.get_server_diagnostic("probe", "stdio").state == "disconnected"
		and manager.config.get_server("probe").command == "replacement-command")
	manager._connection_diagnostics["probe"] = failed_state
	manager.remove_server_at_runtime("probe")
	check("removing a server prunes its diagnostic", not manager._connection_diagnostics.has("probe"))

	var Preferences = load("res://Scripts/UI/Views/PreferencesPopup.gd")
	var DiagnosticsFixture = load("res://test/helpers/mcp_diagnostics_fixture.gd")
	var popup = Preferences.new()
	popup._server_list_container = VBoxContainer.new()
	popup.add_child(popup._server_list_container)
	var diagnostic_manager = DiagnosticsFixture.new()
	diagnostic_manager.config = Config.new()
	diagnostic_manager.config.servers.clear()
	diagnostic_manager.config.set_server(Config.ServerConfig.create_stdio("probe", "safe"))
	diagnostic_manager.diagnostics["probe"] = {"state": "connecting", "transport": "stdio"}
	var singleton = root.get_node("SingletonObject")
	var original_manager = singleton.mcp_manager
	singleton.mcp_manager = diagnostic_manager
	popup._rebuild_server_list(diagnostic_manager.config)
	var status: Label = popup._server_status_labels["probe"]
	var connection_button: Button = popup._server_connection_buttons["probe"]
	diagnostic_manager.diagnostics["probe"] = {"state": "connected", "transport": "stdio",
		"era": "modern", "version": "2026-07-28"}
	diagnostic_manager.server_connected.emit("probe")
	check("an open Preferences row reacts to manager lifecycle signals",
		status.text == "Connected · STDIO · MCP 2026-07-28"
		and connection_button.text == "Disconnect")
	diagnostic_manager.diagnostics["probe"] = {"state": "failed", "transport": "stdio",
		"failure": "Handshake rejected"}
	diagnostic_manager.server_error.emit("probe", "untrusted peer detail")
	check("an open Preferences row shows an actionable safe failure",
		status.text == "Connection failed · STDIO · Handshake rejected"
		and connection_button.text == "Connect")
	var retired_text := status.text
	popup._rebuild_server_list(diagnostic_manager.config)
	diagnostic_manager.diagnostics["probe"] = {"state": "connecting", "transport": "stdio"}
	diagnostic_manager.server_connected.emit("probe")
	check("rebuilt rows own subsequent asynchronous status updates",
		status.text == retired_text
		and popup._server_status_labels["probe"].text == "Connecting · STDIO")
	singleton.mcp_manager = original_manager
	popup._ensure_server_status_signals(null)
	popup.free()
	diagnostic_manager.free()
	var Router = load("res://Scripts/Services/Plugins/PluginNotifyRouter.gd")
	var capture = load("res://test/helpers/log_capture.gd").new()
	OS.add_logger(capture)
	var log_start: int = capture.size()
	Router.route("probe", {"level": "warning", "message": "SECRET_MESSAGE",
		"details": {"token": "SECRET_DETAIL"}})
	var notices: String = capture.since(log_start)
	OS.remove_logger(capture)
	check("host.notify keeps intended UI content out of console fallbacks",
		"probe" in notices and "SECRET_MESSAGE" not in notices and "SECRET_DETAIL" not in notices)
	manager.free()

	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)
