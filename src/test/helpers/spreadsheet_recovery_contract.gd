extends RefCounted
## Uses real menu, dialogs, process startup and native scene handoff.
func dialogs(root: Window) -> Array[SpreadsheetRecoveryDialog]:
	var found: Array[SpreadsheetRecoveryDialog] = []
	for child: Node in root.get_children():
		if child is SpreadsheetRecoveryDialog and not child.is_queued_for_deletion():
			found.append(child)
	return found

func run(test: Node, host: Node, manager: PluginManager, pane: EditorPane, directory: String) -> void:
	var tree := test.get_tree()
	var previous_tools: Variant = host.get("plugin_tool_registry")
	var tools := PluginToolRegistry.new(manager, null, null)
	manager.configure_dependency_tools(tools)
	host.set("plugin_tool_registry", tools)
	var container = load("res://Scripts/UI/Controls/vboxEditor.gd").new()
	container.editor_pane = pane
	var previous: Variant = host.get("editor_container")
	host.set("editor_container", container)
	host.call("_init_creatable_items")
	host.set("editor_container", previous)
	container.free()
	var menu: CreatableItemRegistry = host.get("creatable_item_registry")
	var item := menu.get_item("new_minsheet")
	test.check("New Spreadsheet remains visible without Sheets", item != null and item.display_name == "New Spreadsheet")
	var before := pane.Tabs.get_tab_count()
	await item.create_callback.call()
	var pending := dialogs(tree.root)
	test.check("actual New menu produces one copyable recovery and no editor", pending.size() == 1 and pane.Tabs.get_tab_count() == before
		and pending[0].message.selection_enabled and pending[0].message.text.contains("Start/install sheets"))
	pending[0]._on_close()
	var opener = load("res://Scripts/UI/Controls/vboxEditor.gd").new()
	for extension: String in ["minsheet", "csv", "tsv", "xlsx"]:
		var path := directory.path_join("missing." + extension)
		test._write(path, "unchanged " + extension)
		await opener.open_file(path)
		pending = dialogs(tree.root)
		test.check("missing " + extension + " is recoverable without fallback or source writes", pending.size() == 1
			and pane.Tabs.get_tab_count() == before and FileAccess.get_file_as_string(path) == "unchanged " + extension)
		pending[0]._on_close()
	opener.free()
	await item.create_callback.call()
	var create_dialog := dialogs(tree.root)[0]
	var first_path := directory.path_join("retry-first.tsv")
	var second_path := directory.path_join("retry-second.tsv")
	test._write(first_path, "first source")
	test._write(second_path, "second source")
	await host.call("request_spreadsheet_gui", "open", {"path": first_path})
	await host.call("request_spreadsheet_gui", "open", {"path": second_path})
	pending = dialogs(tree.root)
	test.check("independent requests retain three separate recovery dialogs", pending.size() == 3)
	var plugin_directory := "user://plugins/sheets"
	var manifest := {"id": "sheets", "name": "Sheets", "version": "1.0.0", "host_api_version": "2",
		"backend": {"transport": "stdio", "entrypoint": "python3", "args": [ProjectSettings.globalize_path("res://test/fixtures/bulk_snapshot_probe.py")]},
		"ui": {"panels": [{"name": "sheets_panel", "kind": "godot_scene", "entry_scene": "Panel.tscn", "scripts": ["Panel.gd"],
			"file_extensions": [".minsheet", ".csv", ".tsv", ".xlsx"], "file_actions": ["open", "import", "create"]}]},
		"editor_items": [{"id": "new_minsheet", "name": "New Spreadsheet", "panel": "sheets_panel"}]}
	test._write(plugin_directory.path_join("manifest.json"), JSON.stringify(manifest))
	test._write(plugin_directory.path_join("Panel.gd"), test.PANEL)
	test._write(plugin_directory.path_join("Panel.tscn"), '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="Panel.gd" id="1"]\n[node name="Panel" type="Control"]\nscript = ExtResource("1")\n')
	var definition: PluginDefinition = manager.get_db().install(plugin_directory.path_join("manifest.json"))
	test.check("real stopped Sheets provider installs", definition != null and not manager.get_plugin_status("sheets").get("ready", false))
	create_dialog._on_retry()
	create_dialog._on_retry()
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(create_dialog) and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	test.check("Start Retry launches real backend and double click creates exactly once", manager.get_plugin_status("sheets").get("ready", false)
		and pane.Tabs.get_tab_count() == before + 1 and pane.Tabs.get_child(before).plugin_id == "sheets")
	await pending[2]._on_retry()
	await pending[1]._on_retry()
	test.check("reverse retries retain file identity and do not cross requests", pane.Tabs.get_tab_count() == before + 3
		and pane.Tabs.get_child(before + 1).file == second_path and pane.Tabs.get_child(before + 2).file == first_path)
	await host.call("request_spreadsheet_gui", "open", {"path": first_path})
	test.check("repeated native open reuses existing editor", pane.Tabs.get_tab_count() == before + 3)
	test.check("retries preserve both source files", FileAccess.get_file_as_string(first_path) == "first source"
		and FileAccess.get_file_as_string(second_path) == "second source")
	var panel: Dictionary = definition.ui_panels[0]
	var original_scene: String = panel.entry_scene
	panel.entry_scene = "MissingScene.tscn"
	var stable_count := pane.Tabs.get_tab_count()
	await item.create_callback.call()
	var broken := dialogs(tree.root)
	test.check("ready backend with missing scene New refuses before tab adoption", broken.size() == 1
		and pane.Tabs.get_tab_count() == stable_count and manager.get_plugin_status("sheets").get("ready", false))
	await broken[0]._on_retry()
	test.check("missing-scene Retry stays recoverable without a tab", is_instance_valid(broken[0]) and broken[0].visible
		and not broken[0].busy and pane.Tabs.get_tab_count() == stable_count)
	broken[0]._on_close()
	var broken_path := directory.path_join("broken-scene.tsv")
	test._write(broken_path, "must not change")
	await host.call("request_spreadsheet_gui", "open", {"path": broken_path})
	broken = dialogs(tree.root)
	test.check("missing-scene open refuses before tab adoption and source mutation", broken.size() == 1
		and pane.Tabs.get_tab_count() == stable_count and FileAccess.get_file_as_string(broken_path) == "must not change")
	panel.entry_scene = original_scene
	await broken[0]._on_retry()
	test.check("repairing scene and Retry opens exactly its retained file", pane.Tabs.get_tab_count() == stable_count + 1
		and pane.Tabs.get_child(stable_count).file == broken_path)
	pane.Tabs.get_child(stable_count).free()
	manager.stop_plugin("sheets")
	host.call("_unregister_plugin_editor_items", "sheets")
	test.check("stopping Sheets retains host recovery menu entry", menu.get_item("new_minsheet") == item)
	await item.create_callback.call()
	var closing := dialogs(tree.root)[0]
	# Existing real readiness owner is held pending; closing must cancel it.
	manager.get_db().update_state("sheets", PluginDefinition.State.RUNNING)
	manager._ensure_runtime("sheets")["ready"] = false
	closing._on_retry()
	closing._on_close()
	await tree.process_frame
	manager._ensure_runtime("sheets")["ready"] = true
	manager.plugin_ready.emit("sheets")
	await tree.process_frame
	test.check("closing pending recovery prevents later ready from creating an editor", pane.Tabs.get_tab_count() == before + 3
		and dialogs(tree.root).is_empty())
	manager.get_db().update_state("sheets", PluginDefinition.State.STOPPED)
	host.set("plugin_tool_registry", previous_tools)
