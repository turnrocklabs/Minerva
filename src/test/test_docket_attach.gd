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
	record.pid = 99
	_write(discovery.profile_directory, record)
	await manager.start_plugin("docket")
	check("dead registration takes the pinned spawn path", manager.stdio_starts == 1
		and not manager.get_plugin_status("docket").get("attached", true)
		and manager.get_plugin_status("docket").get("attach_choices", [1]).is_empty())
	discovery.profile_directory = profile.path_join("Absent-Docket-fixture")
	await manager.start_plugin("docket")
	check("absent registration takes the pinned spawn path", manager.stdio_starts == 2)
	manager.free()
	_finish()

func _write(directory: String, record: Dictionary) -> void:
	var file := FileAccess.open(directory.path_join("instance.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(record))
	file.close()

func _finish() -> void:
	print("DOCKET_ATTACH_RESULTS: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
