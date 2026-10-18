extends Node
signal completed(code: int)
var failures: int = 0
var checks: int = 0
const PANEL := 'extends "res://Scripts/Services/Plugins/MinervaPluginPanel.gd"\nvar loads: int = 0\nvar last_action: String = ""\nvar document: Dictionary = {}\nvar buffer_text: String = ""\nfunc _on_panel_loaded(context: Dictionary) -> void:\n\tif context.get("document_action") == "create":\n\t\tloads += 1\n\t\tlast_action = "create"\nfunc _on_panel_load_request(value: Variant) -> void:\n\tloads += 1\n\tlast_action = get_document_action()\n\tif value is Dictionary:\n\t\tdocument = value.duplicate(true)\nfunc _on_panel_save_request() -> Dictionary:\n\treturn document.duplicate(true)\nfunc receive(channel: String, payload: Dictionary) -> void:\n\tif channel in ["attach_buffer", "text_changed"]:\n\t\tbuffer_text = str(payload.get("text", ""))\n'

func _ready() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	checks += 1
	if condition:
		print("PASS: " + label)
	else:
		failures += 1
		printerr("FAIL: " + label)

func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	check("fixture file opens: " + path, file != null)
	if file != null:
		file.store_string(text)
		file.close()

func _install(manager: PluginManager, id: String, extension: String, paired: bool, actions: Array[String] = ["open", "import", "create"]) -> PluginDefinition:
	var directory := "user://plugins/" + id
	var panel := {"name": "main", "kind": "godot_scene", "entry_scene": "Panel.tscn", "scripts": ["Panel.gd"],
		"file_extensions": [extension], "file_actions": actions}
	if paired:
		panel["render_mode"] = "paired_dsl"
	var manifest := {"id": id, "name": id, "version": "1.0.0", "host_api_version": "2",
		"backend": {"transport": "stdio", "entrypoint": "python3"}, "ui": {"panels": [panel]},
		"editor_items": [{"id": id + "_new", "name": id, "panel": "main"}]}
	_write(directory.path_join("manifest.json"), JSON.stringify(manifest))
	_write(directory.path_join("Panel.gd"), PANEL)
	_write(directory.path_join("Panel.tscn"), '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="Panel.gd" id="1"]\n[node name="Panel" type="Control"]\nscript = ExtResource("1")\n')
	var definition := manager.get_db().install(directory.path_join("manifest.json"))
	check("real provider manifest installs: " + id, definition != null)
	if definition != null:
		manager.get_db().update_state(id, PluginDefinition.State.RUNNING)
	return definition

func _run() -> void:
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
	var pane := EditorPane.new()
	var tabs := TabContainer.new()
	get_tree().root.add_child(tabs)
	pane.Tabs = tabs
	pane.buffer_control_editor = Control.new()
	host.editor_pane = pane
	host.creatable_item_registry = CreatableItemRegistry.new()
	host._wire_plugin_editor_extensions(manager)
	var single := _install(manager, "file_contract", ".fixturefmt", false)
	var paired := _install(manager, "paired_contract", ".pairedfmt", true)
	if single != null and paired != null:
		await _exercise(host, manager, pane, broker, single, paired)
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
	print("=== Results: %d passed, %d failed ===" % [checks - failures, failures])
	completed.emit(1 if failures else 0)

func _exercise(host: Node, manager: PluginManager, pane: EditorPane, broker: PluginScenePanelBroker,
		single: PluginDefinition, paired: PluginDefinition) -> void:
	var directory := ProjectSettings.globalize_path("user://file-handoff-contract")
	var open_path := directory.path_join("open.fixturefmt")
	var import_path := directory.path_join("import.fixturefmt")
	var text := JSON.stringify({"value": "opaque payload", "action": "user-owned-action"})
	var tools := MCPGeneralTools.new(null)
	_write(open_path, text)
	_write(import_path, text)
	check("installed running provider owns its extension", manager.get_plugin_status(single.id).running
		and host.plugin_editor_registry.resolve_extension(".fixturefmt").get("plugin_id") == single.id)
	for action: String in ["open", "import"]:
		var path := open_path if action == "open" else import_path
		var before := pane.Tabs.get_tab_count()
		var result: Dictionary
		if action == "import":
			result = await tools.handle("minerva_open_file", {"path": path, "action": action})
		else:
			result = host.open_file_at_path(path, action)
		await get_tree().process_frame
		check(action + " creates exactly one native editor", result.get("ok", result.get("success", false)) and pane.Tabs.get_tab_count() == before + 1)
		if pane.Tabs.get_tab_count() == before + 1:
			var editor: Editor = pane.Tabs.get_child(before)
			var panel: Control = editor.plugin_scene_root
			check(action + " has a real loaded scene", panel != null)
			if panel != null:
				var delivered: Dictionary = panel.get("document")
				check(action + " delivers one hook with opaque fields intact", panel.get("loads") == 1 and panel.get("last_action") == action
					and delivered.get("action") == "user-owned-action" and delivered.get("value") == "opaque payload")
				check("action context is cleared after its hook", panel.call("get_document_action") == "")
				var again: Dictionary = host.open_file_at_path(path, action)
				check(action + " retry returns the same tab without another load", again.get("ok", false)
					and again.editor_name == result.editor_name and pane.Tabs.get_tab_count() == before + 1 and panel.get("loads") == 1)
		check(action + " does not rewrite the input file", FileAccess.get_file_as_string(path) == text)
	var before_refusal := pane.Tabs.get_tab_count()
	for state: int in [PluginDefinition.State.STOPPED, PluginDefinition.State.ERROR]:
		manager.get_db().update_state(single.id, state)
		if state == PluginDefinition.State.STOPPED:
			manager.plugin_stopped.emit(single.id)
		else:
			manager.plugin_crashed.emit(single.id)
		var refused: Dictionary = host.open_file_at_path(open_path, "import")
		check("stopped/crashed provider keeps claim and refuses without mutation", not refused.get("ok", true)
			and str(refused.errors).contains("plugin_not_running") and host.plugin_editor_registry.resolve_extension(".fixturefmt").get("plugin_id") == single.id
			and pane.Tabs.get_tab_count() == before_refusal and FileAccess.get_file_as_string(open_path) == text)
		# This is the real File > Open adapter; its warning is retained in the log.
		var opener = load("res://Scripts/UI/Controls/vboxEditor.gd").new()
		opener.open_file(open_path)
		opener.free()
		check("GUI refusal leaves tabs and source unchanged", pane.Tabs.get_tab_count() == before_refusal
			and FileAccess.get_file_as_string(open_path) == text)
		var create_refused: Dictionary = host.create_plugin_editor({"plugin_id": single.id, "editor_item_id": single.id + "_new"})
		check("stopped/crashed create refuses without tabs", not create_refused.get("success", true) and pane.Tabs.get_tab_count() == before_refusal)
	manager.get_db().update_state(single.id, PluginDefinition.State.RUNNING)
	var invalid: Dictionary = host.open_file_at_path(import_path, "erase")
	check("unknown action refuses before mutation", not invalid.get("ok", true) and pane.Tabs.get_tab_count() == before_refusal)
	var invalid_mcp: Dictionary = await tools.handle("minerva_open_file", {"path": import_path, "action": 1})
	check("malformed MCP action refuses without mutation", not invalid_mcp.get("success", true) and pane.Tabs.get_tab_count() == before_refusal)
	var paired_path := directory.path_join("source.pairedfmt")
	_write(paired_path, text)
	var paired_result: Dictionary = host.open_file_at_path(paired_path, "import")
	await get_tree().process_frame
	check("paired import creates one text/render pair", paired_result.get("ok", false) and pane.Tabs.get_tab_count() == before_refusal + 2)
	if pane.Tabs.get_tab_count() == before_refusal + 2:
		var source: Editor = pane.Tabs.get_child(before_refusal)
		var render: Editor = pane.Tabs.get_child(before_refusal + 1)
		check("paired import shares actual buffer and delivers import once", render.plugin_scene_root != null
			and source.get_document_buffer() == broker.get_attached_buffer(paired.id, render.plugin_panel_key)
			and render.plugin_scene_root.get("loads") == 1 and render.plugin_scene_root.get("last_action") == "import")
	host._register_plugin_editor_items(single.id)
	var item: CreatableItemRegistry.CreatableItem = host.creatable_item_registry.get_item(single.id + "_new")
	var before_create := pane.Tabs.get_tab_count()
	check("real GUI editor item has a callable", item != null and item.create_callback.is_valid())
	if item != null:
		item.create_callback.call()
		await get_tree().process_frame
		check("GUI create uses the handoff exactly once", pane.Tabs.get_tab_count() == before_create + 1)
		if pane.Tabs.get_tab_count() == before_create + 1:
			var created: Editor = pane.Tabs.get_child(before_create)
			check("create hook receives its scoped action", created.plugin_scene_root != null
				and created.plugin_scene_root.get("loads") == 1 and created.plugin_scene_root.get("last_action") == "create")

	var csv_path := directory.path_join("unclaimed.csv")
	_write(csv_path, "name,value\nalpha,1\n")
	var native: Dictionary = host.open_file_at_path(csv_path, "import")
	check("unclaimed CSV imports through builtin spreadsheet", native.get("ok", false) and native.get("editor_kind") == "SPREADSHEET")
	var unknown_path := directory.path_join("unclaimed.unknownfmt")
	_write(unknown_path, "plain unclaimed data")
	var fallback: Dictionary = host.open_file_at_path(unknown_path)
	check("unclaimed ordinary extension retains text fallback", fallback.get("ok", false) and fallback.get("editor_kind") == "TEXT")

	var open_only := _install(manager, "open_only_contract", ".openonly", false, ["open", "create"])
	var restricted_path := directory.path_join("restricted.openonly")
	_write(restricted_path, text)
	var before_restricted := pane.Tabs.get_tab_count()
	if open_only != null:
		var restricted: Dictionary = host.open_file_at_path(restricted_path, "import")
		check("undeclared import refuses visibly without mutation", not restricted.get("ok", true)
			and str(restricted.errors).contains("does not support") and pane.Tabs.get_tab_count() == before_restricted
			and FileAccess.get_file_as_string(restricted_path) == text)
