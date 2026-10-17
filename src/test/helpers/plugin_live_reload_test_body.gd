extends Node
## Real host/broker/editors/buffers plus a stdio MCP peer. Deliberate scene
## engine errors are covered by the separate LiveSwap child-process oracle.
signal completed(code: int)
const Host := preload("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
const Store := preload("res://Scripts/Services/Plugins/PluginGenerationStore.gd")
const IDS: Array[String] = ["live_integration_a", "live_integration_b"]
var passed: int = 0
var failed: int = 0
var manager: PluginManager
var broker: PluginScenePanelBroker
var editors: Array[Editor] = []
var buffers: Array[DocumentBuffer] = []
var block_publication: bool = false
var blocked: bool = false


func _ready() -> void:
	_run.call_deferred()


func _write(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()


func _fixture(plugin_id: String, version: int, directory: String = "") -> String:
	if directory.is_empty():
		directory = "user://plugins/" + plugin_id
	var manifest := {"id": plugin_id, "name": plugin_id, "version": "1.0.%d" % version,
		"host_api_version": "2", "capabilities": ["live_reload"],
		"backend": {"transport": "stdio", "entrypoint": "python3"},
		"ui": {"ipc_messages": ["probe_denied"], "panels": [{"name": "main", "title": "Main", "kind": "godot_scene",
			"entry_scene": "Panel.tscn", "scripts": ["Panel.gd", "nested/Dependency.gd"],
			"ipc_channels": ["probe_denied"]}]}}
	_write(directory.path_join("manifest.json"), JSON.stringify(manifest))
	_write(directory.path_join("Panel.gd"), FileAccess.get_file_as_string(
		"res://test/fixtures/live_reload/IntegratedPanel.gd.template").replace("VERSION_TOKEN", str(version)))
	_write(directory.path_join("nested/Dependency.gd"), "extends RefCounted\nstatic func operation(value: int) -> int:\n\treturn value + %d\n" % version)
	_write(directory.path_join("Panel.tscn"), '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="Panel.gd" id="1"]\n[node name="Panel" type="Control"]\nscript = ExtResource("1")\n[node name="Marker" type="Label" parent="."]\ntext = "%d"\n' % version)
	return directory


func _run() -> void:
	await get_tree().create_timer(3.0).timeout
	if "--live-integration-baseline" in OS.get_cmdline_user_args():
		print("BASELINE_DONE")
		completed.emit(0)
		return
	get_tree().create_timer(90.0).timeout.connect(func() -> void: completed.emit(1))
	manager = PluginManager.new()
	manager._db = PluginDB.new()
	var singleton: Node = get_tree().root.get_node("SingletonObject")
	var old_manager: Variant = singleton.plugin_manager
	var old_broker: Variant = singleton.plugin_scene_panel_broker
	var old_registry: Variant = singleton.plugin_tool_registry
	var policy := PluginPolicy.new(manager.get_db(), null, false)
	var capabilities := CapabilityBroker.new(policy)
	broker = PluginScenePanelBroker.new(manager, policy, capabilities)
	singleton.plugin_manager = manager
	singleton.plugin_scene_panel_broker = broker
	add_child(manager)
	for plugin_id: String in IDS:
		var directory := _fixture(plugin_id, 1)
		var definition: PluginDefinition = manager.get_db().install(directory.path_join("manifest.json"))
		check(definition != null, "real opt-in manifest installs: " + plugin_id)
		if definition == null:
			completed.emit(1)
			return
		definition.auto_reload = true
		definition.state = PluginDefinition.State.RUNNING
	for index: int in 3:
		var plugin_id := IDS[0] if index < 2 else IDS[1]
		var editor := Editor.create_plugin_scene(plugin_id, "main")
		add_child(editor)
		editors.append(editor)
		var opened := DocumentRegistry.get_instance().create_unbacked_buffer()
		var buffer: DocumentBuffer = opened.buffer
		buffers.append(buffer)
		check(broker.attach_buffer_to_panel(plugin_id, editor.plugin_panel_key, buffer), "real buffer attaches")
		var panel: Control = editor.plugin_scene_root
		panel.document = {"unsaved": index, "undo": [1, 2], "view": {"scroll": 11}, "large": 9007199254740993}
		buffer.apply_edit("unsaved buffer %d" % index)
	await get_tree().process_frame
	var conn := MCPServerConnection.new(IDS[0])
	conn.plugin_id = IDS[0]
	conn.capability_request_handler = capabilities.dispatch
	conn.configure_stdio("python3", PackedStringArray([ProjectSettings.globalize_path("res://test/fixtures/capability_probe/capability_probe.py")]))
	check(await conn.connect_to_server() == OK, "real stdio MCP peer connects")
	manager._runtime[IDS[0]] = {"connection": conn}
	var registry := PluginToolRegistry.new(manager, policy)
	singleton.plugin_tool_registry = registry
	var registered := await registry.register_backend_tools(IDS[0], conn)
	check(not registered.has("error") and registry.get_plugin_tools(IDS[0]).size() == 2, "nonempty real MCP tools catalog")
	var tools_before: Array = registry.get_plugin_tools(IDS[0]).duplicate(true)
	for version: int in range(2, 5):
		for plugin_id: String in IDS:
			_fixture(plugin_id, version)
			var swapped: Dictionary = await manager.reload_scene_plugin(plugin_id)
			check(swapped.get("ok", false), "explicit swap %s v%d: %s" % [plugin_id, version, swapped])
		await get_tree().process_frame
		_assert_wiring(version)
		check(await conn.refresh_tools() == OK and conn.tools.size() == 2
			and registry.get_plugin_tools(IDS[0]) == tools_before, "tools/list and installation catalog remain exactly once")
	_fixture(IDS[0], 5)
	var changed_policy_path := "user://plugins/" + IDS[0] + "/manifest.json"
	var changed_policy: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(changed_policy_path))
	changed_policy.ui.panels[0].save_mode = "none"
	_write(changed_policy_path, JSON.stringify(changed_policy))
	var policy_refusal: Dictionary = await manager.reload_scene_plugin(IDS[0])
	check(not policy_refusal.get("ok", true) and str(policy_refusal.error).contains("policy changed")
		and editors[0].plugin_scene_root.VERSION == 4 and editors[0].plugin_save_mode == "host_owned", "incompatible save policy refuses without changing current tabs")
	_fixture(IDS[0], 4)
	# Change document attachment in the actual preparation frame window.
	var changed_buffer: DocumentBuffer = DocumentRegistry.get_instance().create_unbacked_buffer().buffer
	changed_buffer.apply_edit("unsaved buffer 0")
	var prior_buffer := buffers[0]
	var before_switch: int = editors[0].plugin_scene_root.get_instance_id()
	_switch_buffer.call_deferred(changed_buffer)
	var switched: Dictionary = await manager.reload_scene_plugin(IDS[0])
	check(not switched.get("ok", true) and editors[0].plugin_scene_root.get_instance_id() == before_switch
		and broker.get_attached_buffer(IDS[0], editors[0].plugin_panel_key) == changed_buffer,
		"attachment change during prepare refuses and retains CURRENT document")
	buffers[0] = changed_buffer
	DocumentRegistry.get_instance().dispose_buffer(prior_buffer.file_path)
	check((await manager.reload_scene_plugin(IDS[0])).get("ok", false), "reuse succeeds after attachment refusal")
	_assert_wiring(4)
	# Actual publication failure after real broker rewiring, with changed IPC
	# metadata. Rollback must restore old registration and action callbacks.
	_fixture(IDS[0], 5)
	var manifest_path := "user://plugins/" + IDS[0] + "/manifest.json"
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	manifest.ui.ipc_messages = ["probe_echo"]
	manifest.ui.panels[0].ipc_channels = ["probe_echo"]
	_write(manifest_path, JSON.stringify(manifest))
	broker.panel_registered.connect(_publication_fault)
	block_publication = true
	var before_failure: Array = editors.map(func(editor: Editor) -> int: return editor.plugin_scene_root.get_instance_id())
	var old_actions: Array = editors.map(func(editor: Editor) -> int: return editor.get_node("VBoxContainer/ButtonsHBoxContainer/GenerationAction").get_instance_id())
	var failed_publication: Dictionary = await manager.reload_scene_plugin(IDS[0])
	var selector_path := Store.new(IDS[0]).selector_path()
	check(blocked and not failed_publication.get("ok", true), "real selector rename refuses after real host registration")
	check(DirAccess.rename_absolute(selector_path, selector_path + ".blocked") == OK
		and DirAccess.rename_absolute(selector_path + ".saved", selector_path) == OK, "restore injected filesystem boundary without deletion")
	broker.panel_registered.disconnect(_publication_fault)
	check(editors.map(func(editor: Editor) -> int: return editor.plugin_scene_root.get_instance_id()) == before_failure, "rollback preserves real old root identities")
	check(editors.map(func(editor: Editor) -> int: return editor.get_node("VBoxContainer/ButtonsHBoxContainer/GenerationAction").get_instance_id()) == old_actions, "rollback preserves contributed control identities")
	_assert_wiring(4)
	var old_root: Control = editors[0].plugin_scene_root
	var ipc: Node = old_root.get_node("_MinervaIPC")
	old_root.request.emit("probe_denied", {}, "after-rollback")
	var actual_reply: Dictionary = await ipc.await_reply("after-rollback")
	check(actual_reply.get("success", false), "rollback restores old IPC channel and real backend request")
	_fixture(IDS[0], 4)
	# Recursive content hashing admits nested edits even within one mtime tick.
	var service: Node = manager._scene_reload_service()
	var before: Dictionary = service.scan_files(IDS[0], PackedStringArray(["gd", "tscn"]))
	_write("user://plugins/" + IDS[0] + "/nested/Dependency.gd", "extends RefCounted\nstatic func operation(value: int) -> int:\n\treturn value + 5\n")
	var after: Dictionary = service.scan_files(IDS[0], PackedStringArray(["gd", "tscn"]))
	check(before != after and after.size() == 3, "recursive watcher hash sees same-second nested change")
	manager._pending_changed_paths[IDS[0]] = ["user://plugins/" + IDS[0] + "/nested/Dependency.gd"]
	await manager._on_reload_debounce_expired(IDS[0])
	check(editors[0].plugin_scene_root.operation(10) == 15 and manager.get_restart_required_reason(IDS[0]).is_empty(), "watcher debounce uses same swap without restart flag")
	_fixture(IDS[0], 6)
	check((await manager.reload_scene_plugin(IDS[0])).get("ok", false), "explicit development reload remains live")
	_assert_wiring(6, 4)
	# A committed marketplace update never activates scenes in this session.
	var old_ids: Array = editors.map(func(editor: Editor) -> int: return editor.plugin_scene_root.get_instance_id())
	var store := Store.new(IDS[0])
	var selector := FileAccess.get_file_as_bytes(store.selector_path())
	_fixture(IDS[0], 99)
	var next_definition := PluginDefinition.from_manifest("user://plugins/" + IDS[0] + "/manifest.json")
	check(manager.get_db().update_definition(next_definition), "installed definition commit remains distinct")
	var pending: Dictionary = manager.installed_scene_update(IDS[0])
	check(pending.get("ok", false) and pending.message == "Update installed; restart to load the new panels"
		and manager.get_plugin_status(IDS[0]).live_reload.restart_pending, "installed update is visible restart-pending without activation")
	check(not (await manager.reload_scene_plugin(IDS[0])).get("ok", true), "explicit reload cannot bypass marketplace restart boundary")
	manager._pending_changed_paths[IDS[0]] = ["user://plugins/" + IDS[0] + "/Panel.gd", "user://plugins/" + IDS[0] + "/manifest.json"]
	await manager._on_reload_debounce_expired(IDS[0])
	check(editors.map(func(editor: Editor) -> int: return editor.plugin_scene_root.get_instance_id()) == old_ids
		and FileAccess.get_file_as_bytes(store.selector_path()) == selector, "installed update and mixed watcher keep exact old roots and selector")
	check(manager.get_restart_required_reason(IDS[0]).is_empty(), "opt-in pending update never poisons legacy restart-required flag")
	var protected_path := "user://live-reload-protected.txt"
	_write(protected_path, "unrelated document remains exact")
	var pending_tmp := store.directory.path_join("pending-install.json.tmp")
	var metadata_dir := DirAccess.open(store.directory)
	check(metadata_dir.create_link(ProjectSettings.globalize_path(protected_path), pending_tmp) == OK, "create actual linked pending metadata temp")
	var linked_update: Dictionary = manager.installed_scene_update(IDS[0])
	check(not linked_update.get("ok", true) and FileAccess.get_file_as_string(protected_path) == "unrelated document remains exact", "installed identity refuses temp symlink without truncating unrelated document")
	check(DirAccess.rename_absolute(pending_tmp, pending_tmp + ".retained-link") == OK, "preserve injected symlink outside metadata filename")
	# A plugin never opened still snapshots its previous installed generation.
	var closed_id := "live_integration_closed"
	_fixture(closed_id, 1)
	check(manager.get_db().install("user://plugins/" + closed_id + "/manifest.json") != null, "closed plugin installs")
	check(manager.can_replace_plugin_files(closed_id).get("ok", false), "closed update snapshots prior generation before commit")
	_fixture(closed_id, 98)
	var closed_store := Store.new(closed_id)
	var old_selector := FileAccess.get_file_as_bytes(closed_store.selector_path())
	check(manager.installed_scene_update(closed_id).get("ok", false)
		and FileAccess.get_file_as_bytes(closed_store.selector_path()) == old_selector, "closed installed update retains old selection until restart")
	var boot_script: GDScript = load("res://Scripts/Services/Plugins/PluginLiveReload.gd")
	var boot: Node = boot_script.new()
	boot.configure(manager, broker, Callable())
	add_child(boot)
	var recovered: Dictionary = boot.resolve(closed_id, "main")
	check(recovered.get("ok", false) and boot.status(closed_id).restart_pending
		and FileAccess.get_file_as_bytes(closed_store.selector_path()) == old_selector, "fresh service boot rejects loaded-lifecycle fault and retains selected old build")
	boot.free()
	manager.get_db().remove(closed_id)
	await _marketplace_race()
	for index: int in buffers.size():
		check(buffers[index].text == "unsaved buffer %d" % index and buffers[index].dirty, "newer buffer text remains untouched")
	conn.disconnect_from_server()
	registry.unregister_plugin_tools(IDS[0])
	for editor: Editor in editors:
		Host.invoke_unload(editor.plugin_scene_root)
		broker.unregister_panel(editor.plugin_id, editor.plugin_panel_key)
		manager.unregister_live_panel(editor.plugin_id, editor.plugin_panel_key)
		editor.free()
	for buffer: DocumentBuffer in buffers:
		DocumentRegistry.get_instance().dispose_buffer(buffer.file_path)
	for plugin_id: String in IDS:
		manager.get_db().remove(plugin_id)
	singleton.plugin_manager = old_manager
	singleton.plugin_scene_panel_broker = old_broker
	singleton.plugin_tool_registry = old_registry
	manager.free()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	completed.emit(1 if failed else 0)


func _assert_wiring(version_a: int, version_b: int = -1) -> void:
	if version_b < 0:
		version_b = version_a
	check(broker.panel_registered.get_connections().size() == 3, "one plugin singleton subscription per mounted panel")
	check(manager.get_live_panels(IDS[0]).size() == 2 and manager.get_live_panels(IDS[1]).size() == 1, "manager registry retains exact tab count")
	for index: int in editors.size():
		var editor := editors[index]
		var panel: Control = editor.plugin_scene_root
		var version := version_a if index < 2 else version_b
		check(panel.VERSION == version and panel.operation(10) == 10 + version and panel.get_node("Marker").text == str(version), "new marker and operation in real editor")
		check(panel.document == {"unsaved": index, "undo": [1, 2], "view": {"scroll": 11}, "large": 9007199254740993}, "complete unsaved state with exact integer preserved")
		check(panel.loaded_count == 1 and panel.request.get_connections().size() == 1 and panel.content_changed.get_connections().size() == 1, "loaded lifecycle and request/content handlers exactly once")
		var action: Button = editor.get_node("VBoxContainer/ButtonsHBoxContainer/GenerationAction")
		var previous_hits: int = panel.action_hits
		action.pressed.emit()
		check(action.text == "Action %d" % version and panel.action_hits == previous_hits + 1
			and action.pressed.get_connections().size() == 1, "editor action targets current root exactly once")
		check(broker.is_panel_registered(editor.plugin_panel_key, editor.plugin_id)
			and broker.get_attached_buffer(editor.plugin_id, editor.plugin_panel_key) == buffers[index]
			and buffers[index].text_changed.get_connections().size() == 1 and buffers[index].saved.get_connections().size() == 1, "broker identity and real buffer handlers exactly once")
		var pushes: int = panel.pushes
		buffers[index].apply_edit("changed")
		check(panel.pushes == pushes + 1, "one buffer edit reaches only the current root once")
		buffers[index].apply_edit("unsaved buffer %d" % index)


func _switch_buffer(buffer: DocumentBuffer) -> void:
	broker.attach_buffer_to_panel(IDS[0], editors[0].plugin_panel_key, buffer)


func _publication_fault(plugin_id: String, _key: String) -> void:
	if not block_publication or blocked or plugin_id != IDS[0]:
		return
	var path := Store.new(IDS[0]).selector_path()
	check(DirAccess.rename_absolute(path, path + ".saved") == OK, "move selector aside at publication boundary")
	DirAccess.make_dir_recursive_absolute(path)
	_write(path.path_join("occupied"), "fault")
	blocked = true
	block_publication = false


func _marketplace_race() -> void:
	var plugin_id := "live_install_race"
	var directory := _fixture(plugin_id, 1)
	DirAccess.rename_absolute(directory.path_join("nested/Dependency.gd"), directory.path_join("Dependency.gd"))
	_write(directory.path_join("Panel.gd"), FileAccess.get_file_as_string(directory.path_join("Panel.gd")).replace("nested/Dependency.gd", "Dependency.gd"))
	_write(directory.path_join("late_fail.py"), "from pathlib import Path\nimport sys, time\nPath(sys.argv[1]).write_text(str(time.time()))\ntime.sleep(3)\nraise SystemExit(1)\n")
	var path := directory.path_join("manifest.json")
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var marker_path := ProjectSettings.globalize_path("user://real-backend-started.txt")
	manifest.backend.args = ["late_fail.py", marker_path]
	manifest.ui.panels[0].scripts = ["Panel.gd", "Dependency.gd"]
	_write(path, JSON.stringify(manifest))
	var definition: PluginDefinition = manager.get_db().install(path)
	check(definition != null, "real marketplace-race plugin installs")
	definition.auto_reload = true
	definition.state = PluginDefinition.State.RUNNING
	var editor := Editor.create_plugin_scene(plugin_id, "main")
	add_child(editor)
	await get_tree().process_frame
	var old_root: int = editor.plugin_scene_root.get_instance_id()
	var store := Store.new(plugin_id)
	var selector := FileAccess.get_file_as_bytes(store.selector_path())
	var original_manifest := FileAccess.get_file_as_bytes(path)
	var original_panel := FileAccess.get_file_as_bytes(directory.path_join("Panel.gd"))
	var staged := _fixture(plugin_id, 2, "user://race-archive-source")
	# Keep manifest/backend bytes identical; only scene code changes.
	_write(staged.path_join("manifest.json"), JSON.stringify(manifest))
	_write(staged.path_join("late_fail.py"), FileAccess.get_file_as_string(directory.path_join("late_fail.py")))
	# These autoload-aware fixture classes are loaded after project startup.
	var helpers = load("res://test/marketplace_test_helpers.gd").new(get_tree())
	var serve := ProjectSettings.globalize_path("user://race-archive-http")
	DirAccess.make_dir_recursive_absolute(serve)
	# Shared packer handles flat files. This fixture's one relative dependency
	# is flattened before packaging, preserving the same scene contract.
	DirAccess.rename_absolute(staged.path_join("nested/Dependency.gd"), staged.path_join("Dependency.gd"))
	_write(staged.path_join("Panel.gd"), FileAccess.get_file_as_string(staged.path_join("Panel.gd")).replace("nested/Dependency.gd", "Dependency.gd"))
	manifest.ui.panels[0].scripts = ["Panel.gd", "Dependency.gd"]
	_write(staged.path_join("manifest.json"), JSON.stringify(manifest))
	check(helpers.pack_plugin_dir(ProjectSettings.globalize_path(staged), serve.path_join("plugin.tar.gz")), "pack actual marketplace archive")
	var listener := TCPServer.new()
	check(listener.listen(0, "127.0.0.1") == OK, "reserve free HTTP port")
	var port := listener.get_local_port()
	listener.stop()
	check(await helpers.start_http_server(serve, port), "real HTTP archive server starts")
	var client := MarketplaceClient.new()
	add_child(client)
	var operation = load("res://Scripts/Services/Plugins/PluginInstallOperation.gd").new()
	operation.start_after_install = true
	operation.stage_changed.connect(func(stage: String) -> void:
		# Mirror the real install queue: stop the old process at registration.
		if stage == "register":
			manager.stop_plugin(plugin_id)
		if stage == "start":
			_try_install_watch.call_deferred(plugin_id, editor, old_root, selector))
	if FileAccess.file_exists(marker_path):
		check(DirAccess.remove_absolute(marker_path) == OK, "remove previous backend start marker")
	var install_started := Time.get_unix_time_from_system()
	var installed: Dictionary = await client.install_from_url("http://127.0.0.1:%d/plugin.tar.gz" % port, manager, true, operation)
	var install_returned := Time.get_unix_time_from_system()
	var marker_time := float(FileAccess.get_file_as_string(marker_path)) if FileAccess.file_exists(marker_path) else 0.0
	print("BACKEND_START_RECEIPT: " + JSON.stringify({"start": install_started, "marker": marker_time, "returned": install_returned, "result": installed}))
	check(install_started <= marker_time and install_returned - marker_time >= 2.9,
		"real backend start marker and elapsed delay prove actual process ran")
	check(not installed.get("ok", true) and installed.get("error", "") in ["start_failed", "cancelled"], "actual delayed backend failure rolls installation back")
	check(MarketplaceClient.rollback_complete(installed.get("rollback", {})), "actual rollback restores files, database and data")
	check(FileAccess.get_file_as_bytes(path) == original_manifest
		and FileAccess.get_file_as_bytes(directory.path_join("Panel.gd")) == original_panel, "actual rollback restores exact installed manifest and panel bytes")
	check(editor.plugin_scene_root.get_instance_id() == old_root and FileAccess.get_file_as_bytes(store.selector_path()) == selector, "failed install never publishes new scene or replaces old root")
	check((await manager.reload_scene_plugin(plugin_id)).get("ok", false), "install exclusion releases after real rollback")
	# A reload admitted while installation yielded must win before replacement.
	_fixture(plugin_id, 3)
	var changed_manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	changed_manifest.backend.args = ["late_fail.py", marker_path]
	_write(path, JSON.stringify(changed_manifest))
	var competing = load("res://Scripts/Services/Plugins/PluginInstallOperation.gd").new()
	competing.stage_changed.connect(func(stage: String) -> void:
		if stage == "register":
			# Start the real async reload; the install must observe its busy guard.
			manager.call("reload_scene_plugin", plugin_id))
	var before_competing := FileAccess.get_file_as_bytes(path)
	var refused: Dictionary = await client.install_from_url("http://127.0.0.1:%d/plugin.tar.gz" % port, manager, true, competing)
	check(not refused.get("ok", true) and refused.get("error", "") == "restart_required"
		and FileAccess.get_file_as_bytes(path) == before_competing, "install rechecks admitted reload before replacing any files")
	for frame: int in 4:
		await get_tree().process_frame
	check(editor.plugin_scene_root.VERSION == 3, "admitted development reload completes after install refusal")
	editor.free()
	manager.get_db().remove(plugin_id)
	client.free()
	helpers.teardown()


func _try_install_watch(plugin_id: String, editor: Editor, old_root: int, selector: PackedByteArray) -> void:
	manager._pending_changed_paths[plugin_id] = ["user://plugins/" + plugin_id + "/Panel.gd", "user://plugins/" + plugin_id + "/manifest.json", "user://plugins/" + plugin_id + "/late_fail.py"]
	await manager._on_reload_debounce_expired(plugin_id)
	check(editor.plugin_scene_root.get_instance_id() == old_root
		and FileAccess.get_file_as_bytes(Store.new(plugin_id).selector_path()) == selector, "watcher during actual backend startup retains exact pre-install generation")


func check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)
