extends SceneTree
## One source-built registered Docket, using a disposable profile supplied by the runner.
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(label: String, condition: bool) -> void:
	print(("PASS: " if condition else "FAIL: ") + label)
	if not condition:
		failures += 1
func _run() -> void:
	await process_frame
	var profile := OS.get_environment("MINERVA_TEST_PROFILE_ROOT")
	var docket_profile := OS.get_environment("DOCKET_ATTACH_PROFILE")
	if not profile.is_absolute_path() or not docket_profile.begins_with(profile + "/") \
			or not OS.get_user_data_dir().begins_with(profile + "/"):
		quit(2)
		return
	var manager = load("res://Scripts/Services/Plugins/PluginManager.gd").new()
	manager._db = load("res://Scripts/Services/Plugins/PluginDB.gd").new()
	var def = load("res://Scripts/Services/Plugins/PluginDefinition.gd").new()
	def.id = "docket"
	def.entrypoint = "deliberately-unavailable"
	manager._db._plugins.docket = def
	manager.endpoint_discovery.profile_directory = docket_profile
	root.add_child(manager)
	var host = load("res://Scripts/Services/DocketHost/DocketHost.gd").new()
	root.add_child(host)
	host.start(manager)
	var master_file := FileAccess.open("user://master.dct", FileAccess.WRITE)
	master_file.store_buffer(FileAccess.get_file_as_bytes("res://Data/master.dct"))
	master_file.close()
	var result: Dictionary = await manager.start_plugin("docket")
	if result.has("error"):
		printerr("REAL_ATTACH_FAILURE: ", result.error)
	var conn = manager.get_connection("docket")
	check("registered real Docket attaches without a subprocess", result.get("attached", false)
		and conn != null and conn._subprocess == null and conn.transport == 0)
	check("real attached catalog satisfies Minerva host tools", result.get("ok", false))
	await create_timer(6.0).timeout
	check("real attach survives a scheduled health interval", manager.get_plugin_status("docket").get("running", false)
		and manager.get_connection("docket") == conn and conn._subprocess == null)
	var policies: Dictionary = await host.policy_items()
	var prompt: Dictionary = await host.system_prompt("system")
	var skills: Dictionary = await host.skill_catalog()
	check("real public master reads remain available", host.state in ["ready", "degraded"] and host.master_project().size() > 0
		and not policies.has("error") and not prompt.has("error") and skills.get("status") == "ok")
	manager.shutdown_all()
	check("disconnect leaves registered external PID alive", manager.endpoint_discovery.discover().get("attached", false))
	host.free()
	manager.free()
	print("DOCKET_REAL_ATTACH_RESULTS: %d failed" % failures)
	quit(1 if failures else 0)
