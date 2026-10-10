extends SceneTree
## Real manager/host/registry with an observable public-endpoint fixture.
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
func _collect(operation: Callable, done: Array) -> void:
	await operation.call()
	done.append(true)

func _run() -> void:
	await process_frame
	var profile := OS.get_environment("MINERVA_TEST_PROFILE_ROOT")
	if not profile.is_absolute_path() or not OS.get_user_data_dir().begins_with(profile + "/"):
		quit(2)
		return
	var manager = load("res://test/helpers/docket_attach_manager.gd").new()
	manager._db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	var def = load("res://Scripts/Services/Plugins/PluginDefinition.gd").new()
	def.id = "docket"
	def.entrypoint = "unused-fixture"
	manager._db._plugins.docket = def
	var discovery = manager.endpoint_discovery
	discovery.profile_directory = profile.path_join("Docket-fixture")
	discovery.pid_alive = func(pid: int) -> bool: return pid == 42
	DirAccess.make_dir_recursive_absolute(discovery.profile_directory)
	var record := {"pid":42, "version":"fixture", "protocol_version":"2025-03-26",
		"endpoint":{"host":"127.0.0.1", "port":12345}, "profile":discovery.profile_directory, "started_at":"fixture"}
	_write(discovery.profile_directory, record)
	var host = load("res://Scripts/Services/DocketHost/DocketHost.gd").new()
	root.add_child(host)
	host.start(manager)
	await manager.start_plugin("docket")
	check("attached host adds master through public endpoint", host.state in ["ready", "degraded"]
		and host.master_path == ProjectSettings.globalize_path("user://master.dct")
		and manager.tool_calls.any(func(tool_call: Dictionary) -> bool: return tool_call.name == "docket_project_add" and tool_call.arguments.get("create") == false))
	check("attached host does not save a hosted session", not FileAccess.file_exists("user://docket_host_session.json"))
	var session_text := '{"version":1,"paths":["hosted-session-sentinel"]}'
	var session_file := FileAccess.open("user://docket_host_session.json", FileAccess.WRITE)
	session_file.store_string(session_text)
	session_file.close()
	var ordinary := {"name":"ordinary", "path":profile.path_join("ordinary.dct"), "open_generation":"ordinary"}
	manager.fake_projects.append(ordinary)
	await host._reconcile()
	manager.fake_projects.erase(ordinary)
	await host.open_projects()
	var forgot: String = await host.forget_project(ordinary.path)
	check("attached session repair preserves hosted session bytes", not forgot.is_empty()
		and FileAccess.get_file_as_string("user://docket_host_session.json") == session_text)
	var vault: Dictionary = await host.vault_details()
	check("attached vault is disabled with app explanation", vault.get("mode") == "unavailable" and "docket.app" in vault.get("message", ""))
	var observed: String = await host.write_policy_observation("fixture", "fixture")
	check("attached policy observation write is refused", "attached" in observed.to_lower())
	var seeding = load("res://Scripts/Services/Plugins/PluginSeedingDocket.gd").new(host)
	check("attached plugin pickup is refused", "attached" in seeding.unavailable().to_lower())
	var singleton := root.get_node("SingletonObject")
	var previous := [singleton.plugin_manager, singleton.docket_host, singleton.plugin_tool_registry]
	singleton.plugin_manager = manager
	singleton.docket_host = host
	var registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new(manager)
	await registry.register_backend_tools("docket", manager.get_connection("docket"))
	singleton.plugin_tool_registry = registry
	var handover: Dictionary = await load("res://Scripts/Services/Terminal/SessionHandover.gd").run("fixture", "fixture", "fixture")
	check("attached session handover is refused before local changes", "attached" in str(handover.get("error", "")).to_lower())
	var focus: Dictionary = await singleton.open_docket_panel()
	var new_docket: Dictionary = await singleton.open_docket_panel("", null, true)
	check("attached focus and New use the public connection", focus.get("ok", false) and new_docket.get("ok", false)
		and manager.tool_calls.any(func(tool_call: Dictionary) -> bool: return tool_call.name == "docket_gui_open" and tool_call.arguments == {"focus":true})
		and manager.tool_calls.any(func(tool_call: Dictionary) -> bool: return tool_call.name == "docket_gui_open" and tool_call.arguments == {"focus":true,"new_docket":true}))
	manager.stop_plugin("docket")
	manager.fake_projects.clear()
	manager.refuse_master = true
	await manager.start_plugin("docket")
	check("missing attached master has explicit open quit choices", host.state == "failed"
		and manager.get_plugin_status("docket").get("attach_choices", []).size() == 2
		and "attached Docket has no Minerva master" in manager.get_plugin_status("docket").get("notice", ""))
	focus = await singleton.open_docket_panel()
	check("attached app can be focused to resolve missing master", focus.get("ok", false))
	manager.refuse_master = false
	var stops: Array = []
	manager.plugin_stopped.connect(func(id: String) -> void: stops.append(id))
	var other = load("res://Scripts/Services/Plugins/PluginDefinition.gd").new()
	other.id = "other"
	other.state = manager.S_RUNNING
	manager._db._plugins.other = other
	var crashes: Array = []
	manager.plugin_crashed.connect(func(id: String) -> void: crashes.append(id))
	var health_done: Array = []
	manager.delay_health = true
	_collect(manager._run_health_checks, health_done)
	await process_frame
	manager.stop_plugin("other")
	manager.health_release.emit()
	await process_frame
	check("delayed health sweep preserves another plugin's deliberate stop", other.state == manager.S_STOPPED
		and crashes.is_empty() and not health_done.is_empty())
	manager._db._plugins.erase("other")
	manager.delay_health = false
	stops.clear()
	var http = load("res://Scripts/Services/MCP/MCPHttpTransport.gd").new()
	http.profile = load("res://Scripts/Services/MCP/MCPProfile.gd").legacy("2025-03-26", {"tools":{}}, 0)
	var capacity_conn = load("res://Scripts/Services/MCP/MCPServerConnection.gd").new("capacity")
	capacity_conn.server_connected = true
	capacity_conn._http_transport = http
	for index in 32: http._active[index] = null
	var capacity_alive: bool = await capacity_conn.check_http_liveness()
	check("local HTTP capacity refusal does not declare endpoint loss", capacity_alive and capacity_conn.server_connected)
	http._active.clear()
	capacity_conn.disconnect_from_server()
	await manager._run_health_checks()
	await manager._run_health_checks()
	check("attached endpoint stays running across two health ticks", def.state == manager.S_RUNNING
		and stops.is_empty() and manager.stdio_starts == 0)
	manager.http_alive = false
	await manager._run_health_checks()
	check("endpoint loss stops with notification and no spawn", def.state == manager.S_STOPPED
		and stops == ["docket"] and manager.stdio_starts == 0
		and "Docket stopped" in manager.get_plugin_status("docket").get("notice", ""))
	check("loss does not restart automatically", manager.get_connection("docket") == null)
	record.pid = 99
	_write(discovery.profile_directory, record)
	await manager.start_plugin("docket")
	check("Start after external process exits uses pinned spawn", manager.stdio_starts == 1)
	record.pid = 42
	_write(discovery.profile_directory, record)
	manager.http_alive = true
	await manager.start_plugin("docket")
	var conn = manager.get_connection("docket")
	conn.server_connected = false
	def.state = manager.S_STARTING
	var before_disconnect: int = manager.disconnects
	manager.stop_plugin("docket")
	check("Stop cancels an initializing HTTP connection", manager.disconnects == before_disconnect + 1)
	await manager.start_plugin("docket")
	manager.shutdown_all()
	check("shutdown disconnects and leaves external PID alone", manager.get_connection("docket") == null
		and discovery.discover().get("attached", false) and manager.stdio_starts == 1)
	singleton.plugin_manager = previous[0]
	singleton.docket_host = previous[1]
	singleton.plugin_tool_registry = previous[2]
	host.free()
	manager.free()
	print("DOCKET_ATTACH_LIFECYCLE_RESULTS: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
func _write(directory: String, record: Dictionary) -> void:
	var file := FileAccess.open(directory.path_join("instance.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(record))
	file.close()
