extends SceneTree
## Isolated registration/transport selection. No owner profile or process is used.
var failed := 0
var passed := 0

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
	manager.stop_plugin("docket")
	record.pid = 99
	_write(discovery.profile_directory, record)
	await manager.start_plugin("docket")
	check("dead registration takes the pinned spawn path", manager.stdio_starts == 1)
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
