extends SceneTree
## Isolated registration/transport selection. No owner profile or process is used.
var failed := 0
var passed := 0

class Queue extends Node:
	var requested := 0
	func pending_for(_id: String): return null
	func request(_entry: Dictionary, _required: bool, _update: bool, _seed: bool, _manual: bool):
		requested += 1
		return load("res://Scripts/Services/Plugins/PluginInstallJob.gd").new()


func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)

func _run() -> void:
	await process_frame
	var profile := OS.get_environment("MINERVA_TEST_PROFILE_ROOT")
	if not profile.is_absolute_path() or not OS.get_user_data_dir().begins_with(profile + "/"):
		quit(2)
		return
	var manager = load("res://test/helpers/docket_attach_manager.gd").new()
	if not "endpoint_discovery" in manager:
		check("live registration attaches without spawning", false)
		manager.free()
		_finish()
		return
	manager._db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	var def = load("res://Scripts/Services/Plugins/PluginDefinition.gd").new()
	def.id = "docket"
	def.version = "installed"
	def.entrypoint = "unused-fixture"
	manager._db._plugins.docket = def
	var discovery = manager.endpoint_discovery
	discovery.profile_directory = profile.path_join("Docket-fixture")
	discovery.pid_alive = func(pid: int) -> bool: return pid == 42
	DirAccess.make_dir_recursive_absolute(discovery.profile_directory)
	var record := {"pid": 42, "version": "attached", "protocol_version": "2025-03-26",
		"endpoint": {"host": "127.0.0.1", "port": 12345}, "profile": discovery.profile_directory,
		"started_at": "2026-10-10T00:00:00Z"}
	_write(discovery.profile_directory, record)
	var ready: Array = []
	manager.plugin_ready.connect(func(id: String) -> void: ready.append(id))
	var started: Dictionary = await manager.start_plugin("docket")
	check("live registration attaches without spawning", started.get("ok", false) and manager.stdio_starts == 0
		and manager.get_connection("docket").transport == 0)
	var degraded: Dictionary = manager.get_plugin_status("docket")
	check("core-only Docket stays attached with named capability degradation", started.get("degraded", false)
		and degraded.get("attached", false) and degraded.get("running", false)
		and "docket_schema_declare" in degraded.get("notice", "")
		and "docket_project_bootstrap" in degraded.get("notice", "")
		and "docket_vault_control" in degraded.get("notice", ""))
	check("attached runtime has public catalog and no panel secret", ready == ["docket"]
		and manager.discovered.size() == load("res://Scripts/Services/Plugins/RequiredPlugins.gd").PLUGINS.docket.host_tools.size()
		and manager.get_panel_authority("docket") == null)
	var active_conn = manager.get_connection("docket")
	record.protocol_version = "2024-11-05"
	_write(discovery.profile_directory, record)
	await manager.start_plugin("docket")
	check("active start refusal preserves its connection and running state", manager.get_connection("docket") == active_conn
		and manager.get_plugin_status("docket").get("running", false))
	manager.stop_plugin("docket")
	var before_ready := ready.size()
	record.protocol_version = "2024-11-05"
	_write(discovery.profile_directory, record)
	var refused: Dictionary = await manager.start_plugin("docket")
	check("old protocol refuses with update quit choice before readiness", refused.has("error")
		and refused.get("choices", []).size() == 2 and manager.stdio_starts == 0 and ready.size() == before_ready)
	manager.stop_plugin("docket")
	record.erase("protocol_version")
	_write(discovery.profile_directory, record)
	refused = await manager.start_plugin("docket")
	check("missing protocol refuses without spawn", refused.has("error") and manager.stdio_starts == 0)
	manager.stop_plugin("docket")
	record.protocol_version = "2025-06-18"
	_write(discovery.profile_directory, record)
	started = await manager.start_plugin("docket")
	check("newer compatible protocol attaches", started.get("attached", false) and manager.stdio_starts == 0)
	var status: Dictionary = manager.get_plugin_status("docket")
	check("installed and attached versions stay separate", status.get("version") == "installed"
		and status.get("attached_version") == "attached" and status.get("attached", false))
	var singleton := root.get_node("SingletonObject")
	var previous_manager = singleton.plugin_manager
	var previous_size := root.size
	var previous_embed := root.gui_embed_subwindows
	root.size = Vector2i(1400, 900)
	root.gui_embed_subwindows = true
	singleton.plugin_manager = manager
	var panel = load("res://Scenes/PluginManagerPanel.tscn").instantiate()
	root.add_child(panel)
	panel._populate_detail_panel("docket")
	check("attached row shows versions and disables managed controls", "installed" in panel._detail_version_label.text
		and "attached" in panel._detail_version_label.text and panel._update_button.disabled and panel._restart_button.disabled)
	manager.stop_plugin("docket")
	record.protocol_version = "2024-11-05"
	_write(discovery.profile_directory, record)
	await manager.start_plugin("docket")
	panel._populate_detail_panel("docket")
	check("startup refusal row offers update and quit choices", panel._remove_confirm != null
		and panel._remove_confirm.visible and panel._remove_confirm.ok_button_text == "Update docket.app"
		and "Quit docket.app" in panel._remove_confirm.cancel_button_text)
	panel._remove_confirm.hide()
	panel.free()
	singleton.plugin_manager = previous_manager
	root.size = previous_size
	root.gui_embed_subwindows = previous_embed
	manager.stop_plugin("docket")
	record.protocol_version = "2025-06-18"
	_write(discovery.profile_directory, record)
	await manager.start_plugin("docket")
	var queue := Queue.new()
	manager.install_queue = queue
	def.install_lane = "marketplace"
	def.auto_update = true
	var updater = load("res://Scripts/Services/Plugins/PluginAutoUpdater.gd")
	var queued = updater.queue_update(manager, "docket", {"id": "docket", "version": "999.0.0"}, true)
	check("attached manual update never queues an install", queued == null and queue.requested == 0)
	queue.free()
	manager.install_queue = null
	def.install_lane = "manifest"
	manager.stop_plugin("docket")
	manager.omit_tool = "minerva_docket_get"
	before_ready = ready.size()
	refused = await manager.start_plugin("docket")
	check("missing host tool refuses before data readiness", refused.has("error")
		and refused.get("choices", []).size() == 2 and ready.size() == before_ready and manager.stdio_starts == 0)
	manager.stop_plugin("docket")
	manager.omit_tool = ""
	record.profile = profile.path_join("Wrong-Docket-profile")
	_write(discovery.profile_directory, record)
	refused = await manager.start_plugin("docket")
	status = manager.get_plugin_status("docket")
	check("mismatched registration profile is refused and named", refused.has("error")
		and "instance.json" in refused.error and status.get("attach_refused", false)
		and not status.get("attached", true) and manager.stdio_starts == 0)
	record.profile = discovery.profile_directory
	record.pid = 99
	_write(discovery.profile_directory, record)
	await manager.start_plugin("docket")
	check("dead registration takes the pinned spawn path", manager.stdio_starts == 1
		and not manager.get_plugin_status("docket").get("attached", true)
		and "Fixture launcher" in manager.get_plugin_status("docket").get("notice", ""))
	discovery.profile_directory = profile.path_join("Absent-Docket-fixture")
	await manager.start_plugin("docket")
	check("absent registration takes the pinned spawn path", manager.stdio_starts == 2)
	manager.free()
	await _launcher_checks(profile)
	_finish()


func _launcher_checks(profile: String) -> void:
	var tools: Array[String] = []
	for name in RequiredPlugins.PLUGINS.docket.host_tools:
		tools.append(str(name).trim_prefix("minerva_"))
	var tools_path := profile.path_join("launcher-tools.json")
	var tools_file := FileAccess.open(tools_path, FileAccess.WRITE)
	tools_file.store_string(JSON.stringify(tools))
	tools_file.close()
	for mode in ["spawn", "fail", "slow"]:
		# The real connection and launcher exercise their public process/HTTP
		# boundaries; runtime-loaded script avoids the --script autoload parse order.
		var manager = load("res://test/helpers/docket_attach_manager.gd").new()
		manager.real_launcher = true
		manager.real_connection = true
		manager._db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
		var def = load("res://Scripts/Services/Plugins/PluginDefinition.gd").new()
		def.id = "docket"
		def.entrypoint = "python3"
		var directory: String = profile.path_join("launcher-" + mode)
		def.args = PackedStringArray([ProjectSettings.globalize_path("res://test/fixtures/docket_launcher.py"),
			mode, directory, tools_path])
		manager._db._plugins.docket = def
		manager.endpoint_discovery.profile_directory = directory
		var ready: Array = []
		manager.plugin_ready.connect(func(id: String) -> void: ready.append(id))
		if mode == "slow":
			var results: Array = []
			_collect_start(manager.start_plugin.bind("docket"), results)
			await process_frame
			check("launcher wait yields with STARTING visible", def.state == manager.S_STARTING and results.is_empty())
			var deadline: int = Time.get_ticks_msec() + 5000
			while not FileAccess.file_exists(directory.path_join("instance.json")) and Time.get_ticks_msec() < deadline:
				await process_frame
			manager.stop_plugin("docket")
			while results.is_empty() and Time.get_ticks_msec() < deadline:
				await process_frame
			check("Stop cancels attachment without readiness", not results.is_empty()
				and results[0].get("error") == "Docket start was cancelled" and ready.is_empty()
				and manager.get_connection("docket") == null)
		else:
			var result: Dictionary = await manager.start_plugin("docket")
			if mode == "fail":
				check("failed launcher surfaces its reason", result.get("error") == "fixture startup refused"
					and def.state == manager.S_ERROR and ready.is_empty())
				var runtime: Dictionary = manager._ensure_runtime("docket")
				runtime["start_pending"] = true
				var repeated: Dictionary = await manager._start_plugin_now("docket", int(runtime.start_generation))
				check("rollback cannot run a second launcher", repeated.has("error")
					and FileAccess.get_file_as_string(directory.path_join("starts.txt")) == "start\n")
				runtime["start_pending"] = false
			else:
				var conn = manager.get_connection("docket")
				check("one-shot launcher attaches real HTTP child", result.get("attached", false)
					and conn != null and conn._subprocess == null and ready == ["docket"])
		manager.shutdown_all()
		var registration: Dictionary = manager.endpoint_discovery.discover()
		if mode != "fail":
			check("disconnect/shutdown leaves child alive " + mode, registration.get("attached", false))
			if registration.get("attached", false):
				OS.kill(PluginEndpointDiscovery._integer_value(registration.record.pid))  # this fixture's private child only
		manager.free()


func _collect_start(operation: Callable, results: Array) -> void:
	results.append(await operation.call())

func _write(directory: String, record: Dictionary) -> void:
	var file := FileAccess.open(directory.path_join("instance.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(record))
	file.close()

func _finish() -> void:
	print("DOCKET_ATTACH_RESULTS: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
