extends Node
signal completed(code: int)
## Characterize the existing paired MCP create and UI panel-open paths before
## extracting their orchestration. All records and buffers use the test profile.
var failed: int = 0
var passed: int = 0

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	await get_tree().process_frame
	await get_tree().create_timer(3.0).timeout
	var host := get_tree().root.get_node("SingletonObject")
	var ui := preload("res://test/helpers/chat_host_render_fixture.gd").new()
	ui.install(host)
	var previous: Array = [host.plugin_manager, host.plugin_scene_panel_broker, host.editor_pane, host.plugin_editor_registry, host.creatable_item_registry]
	var manager := PluginManager.new()
	manager._db = PluginDB.new()
	var policy := PluginPolicy.new(manager.get_db(), null, false)
	var broker := PluginScenePanelBroker.new(manager, policy, CapabilityBroker.new(policy))
	host.plugin_manager = manager
	host.plugin_scene_panel_broker = broker
	get_tree().root.add_child(manager)
	manager.set_process(false)
	var definition: PluginDefinition = manager.get_db().install("res://plugins/test_paired_dsl/manifest.json")
	check("real paired fixture installs", definition != null)
	if definition == null:
		host.plugin_manager = previous[0]
		host.plugin_scene_panel_broker = previous[1]
		host.editor_pane = previous[2]
		host.plugin_editor_registry = previous[3]
		manager.free()
		ui.restore()
		completed.emit(1)
		return
	definition.state = PluginDefinition.State.RUNNING
	manager._ensure_runtime(definition.id)["ready"] = true # This fixture isolates native editor creation.
	# These UI/module scripts depend on autoloads, so resolve their classes at runtime.
	var pane = load("res://Scripts/UI/Views/EditorPane.gd").new()
	var tabs := TabContainer.new()
	get_tree().root.add_child(tabs)
	pane.Tabs = tabs
	pane.buffer_control_editor = Control.new()
	host.editor_pane = pane
	host._wire_plugin_editor_extensions(manager)
	var module = load("res://Scripts/Services/MCP/Modules/MCPGeneralTools.gd").new(null)
	var result: Dictionary = await module._create_plugin_editor({"plugin_id": definition.id,
		"editor_item_id": "new_test_paired_dsl", "tab_title": "Paired characterization"})
	await get_tree().process_frame
	check("MCP paired create returns success and exactly two tabs", result.get("success", false) and tabs.get_tab_count() == 2)
	if tabs.get_tab_count() == 2:
		var text: Editor = tabs.get_child(0)
		var render: Editor = tabs.get_child(1)
		var buffer: DocumentBuffer = text.get_document_buffer()
		check("paired tabs have different names and the same unbacked buffer",
			text.tab_title != render.tab_title and buffer != null
			and buffer == broker.get_attached_buffer(definition.id, render.plugin_panel_key)
			and DocumentRegistry.is_unbacked_path(buffer.file_path))
		check("MCP response identifies the actual tabs and buffer", not text.tab_title.is_empty()
			and not render.tab_title.is_empty() and result.get("editor_name") == render.tab_title
			and result.get("text_editor_name") == text.tab_title
			and buffer != null and result.get("buffer_path") == buffer.file_path)
		if buffer != null and render.plugin_scene_root != null:
			buffer.apply_edit("characterized shared document")
			await get_tree().process_frame
			var label := render.plugin_scene_root.get_node_or_null("Vbox/EchoLabel") as Label
			check("real render panel receives the shared document", label != null and label.text == "characterized shared document")
		else:
			check("paired delivery requires an attached buffer and real root", false)

	host.creatable_item_registry = CreatableItemRegistry.new()
	var before_ui := tabs.get_tab_count()
	host._register_plugin_editor_items(definition.id)
	var item: CreatableItemRegistry.CreatableItem = host.creatable_item_registry.get_item("new_test_paired_dsl")
	check("native paired GUI item has a real callback", item != null and item.create_callback.is_valid())
	if item != null:
		item.create_callback.call()
	await get_tree().process_frame
	check("native GUI create uses the handoff and adds one pair", tabs.get_tab_count() == before_ui + 2)
	if tabs.get_tab_count() == before_ui + 2:
		var ui_editor: Editor = tabs.get_child(tabs.get_child_count() - 1)
		check("UI panel is the declared scene", ui_editor.plugin_id == definition.id
			and ui_editor.panel_name == "test_paired_dsl_panel" and ui_editor.plugin_scene_root != null)

	tabs.free()
	pane.buffer_control_editor.free()
	pane.free()
	host.plugin_manager = previous[0]
	host.plugin_scene_panel_broker = previous[1]
	host.editor_pane = previous[2]
	host.plugin_editor_registry = previous[3]
	host.creatable_item_registry = previous[4]
	manager.free()
	ui.restore()
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	completed.emit(1 if failed else 0)
