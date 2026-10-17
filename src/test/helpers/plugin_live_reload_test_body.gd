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
		"ui": {"panels": [{"name": "main", "title": "Main", "kind": "godot_scene",
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
	get_tree().create_timer(90.0).timeout.connect(func() -> void: completed.emit(1))
	manager = PluginManager.new()
	manager._db = PluginDB.new()
	var singleton: Node = get_tree().root.get_node("SingletonObject")
	var old_manager: Variant = singleton.plugin_manager
	var old_broker: Variant = singleton.plugin_scene_panel_broker
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
	# Recursive content hashing admits nested edits even within one mtime tick.
	var service: Node = manager._scene_reload_service()
	var before: Dictionary = service.scan_files(IDS[0], PackedStringArray(["gd", "tscn"]))
	_write("user://plugins/" + IDS[0] + "/nested/Dependency.gd", "extends RefCounted\nstatic func operation(value: int) -> int:\n\treturn value + 5\n")
	var after: Dictionary = service.scan_files(IDS[0], PackedStringArray(["gd", "tscn"]))
	check(before != after and after.size() == 3, "recursive watcher hash sees same-second nested change")
	manager._pending_changed_paths[IDS[0]] = ["user://plugins/" + IDS[0] + "/nested/Dependency.gd"]
	await manager._on_reload_debounce_expired(IDS[0])
	check(editors[0].plugin_scene_root.operation(10) == 15 and manager.get_restart_required_reason(IDS[0]).is_empty(), "watcher debounce uses same swap without restart flag")
	# Staging doesn't register candidates. A committed update can fail activation
	# without rolling back the installed files or disturbing open user documents.
	var staged_dir := _fixture(IDS[0], 99, "user://live_update_staging")
	var stage: Dictionary = manager.stage_live_plugin_update(IDS[0], staged_dir)
	check(stage.get("ok", false) and stage.get("staged", false), "marketplace stage retains immutable build")
	var old_ids: Array = editors.map(func(editor: Editor) -> int: return editor.plugin_scene_root.get_instance_id())
	var store := Store.new(IDS[0])
	var selector := FileAccess.get_file_as_bytes(store.selector_path())
	_fixture(IDS[0], 99)
	var next_definition := PluginDefinition.from_manifest("user://plugins/" + IDS[0] + "/manifest.json")
	check(manager.get_db().update_definition(next_definition), "installed definition commit remains distinct")
	var refused: Dictionary = await manager.activate_live_plugin_update(IDS[0])
	check(not refused.get("ok", true) and str(refused.message).begins_with("Update installed; live reload refused: ")
		and manager.get_plugin_status(IDS[0]).live_reload.restart_pending, "failed post-install activation is visible restart-pending")
	check(editors.map(func(editor: Editor) -> int: return editor.plugin_scene_root.get_instance_id()) == old_ids
		and FileAccess.get_file_as_bytes(store.selector_path()) == selector, "refused installed update keeps exact old roots and selector")
	check(manager.get_restart_required_reason(IDS[0]).is_empty(), "opt-in failure never poisons restart-required flag")
	_fixture(IDS[0], 6)
	check((await manager.reload_scene_plugin(IDS[0])).get("ok", false), "same-process retry succeeds after installed failure")
	_assert_wiring(6, 4)
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
		check(broker.is_panel_registered(editor.plugin_panel_key, editor.plugin_id)
			and broker.get_attached_buffer(editor.plugin_id, editor.plugin_panel_key) == buffers[index]
			and buffers[index].text_changed.get_connections().size() == 1 and buffers[index].saved.get_connections().size() == 1, "broker identity and real buffer handlers exactly once")
		var pushes: int = panel.pushes
		buffers[index].apply_edit("changed")
		check(panel.pushes == pushes + 1, "one buffer edit reaches only the current root once")
		buffers[index].apply_edit("unsaved buffer %d" % index)


func check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)
