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
		"file_extensions": [extension, ".minsheet", ".csv"] if id == "file_contract" else [extension], "file_actions": actions}
	if paired:
		panel["render_mode"] = "paired_dsl"
	var manifest := {"id": id, "name": id, "version": "1.0.0", "host_api_version": "2",
		"backend": {"transport": "stdio", "entrypoint": "python3"}, "ui": {"panels": [panel]},
		"editor_items": [{"id": id + "_new", "name": id, "panel": "main"}]}
	_write(directory.path_join("manifest.json"), JSON.stringify(manifest))
	_write(directory.path_join("Panel.gd"), PANEL)
	_write(directory.path_join("Panel.tscn"), '[gd_scene load_steps=2 format=3]\n[ext_resource type="Script" path="Panel.gd" id="1"]\n[node name="Panel" type="Control"]\nscript = ExtResource("1")\n')
	var definition: PluginDefinition = manager.get_db().install(directory.path_join("manifest.json"))
	check("real provider manifest installs: " + id, definition != null)
	if definition != null:
		manager.get_db().update_state(id, PluginDefinition.State.RUNNING)
		manager._ensure_runtime(id)["ready"] = true # Panel-only fixture; real discovery lives in dependency tests.
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
	host.plugin_editor_registry = PluginEditorRegistry.new(["required_contract", "required_first_contract", "late_required_contract"])
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
	for extension: String in ["minsheet", "csv"]:
		var claimed_path := directory.path_join("claimed." + extension)
		_write(claimed_path, text)
		var claimed: Dictionary = host.open_file_at_path(claimed_path)
		check("runtime plugin overrides builtin " + extension, claimed.get("ok", false)
			and claimed.get("plugin_id") == single.id and claimed.get("editor_kind") == "PLUGIN_SCENE")
	var drop_adapter := Control.new()
	get_tree().root.add_child(drop_adapter)
	# Attach the production handler after the bare Control is ready; the
	# unrelated full MainScene UI is not part of this file-drop contract.
	drop_adapter.set_script(load("res://Scripts/UI/Views/MainScene.gd"))
	pane.position = Vector2(-1000, -1000)
	pane.size = Vector2(2000, 2000)
	var dropped_claim := directory.path_join("dropped.csv")
	_write(dropped_claim, text)
	var before_drop := pane.Tabs.get_tab_count()
	drop_adapter.call("_on_files_dropped", PackedStringArray([dropped_claim]))
	check("dropped claimed CSV routes to its provider", pane.Tabs.get_tab_count() == before_drop + 1
		and pane.Tabs.get_child(before_drop).plugin_id == single.id)
	var existing_tabs := pane.Tabs
	var empty_tabs := TabContainer.new()
	get_tree().root.add_child(empty_tabs)
	pane.Tabs = empty_tabs
	drop_adapter.call("_on_files_dropped", PackedStringArray([dropped_claim]))
	check("empty-pane real CSV drop creates its owner", empty_tabs.get_tab_count() == 1
		and empty_tabs.get_child(0).plugin_id == single.id)
	if empty_tabs.get_tab_count() == 1:
		empty_tabs.get_child(0).free()
	var image_path := directory.path_join("dropped.webp")
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	check("real webp fixture is saved", image.save_webp(image_path) == OK)
	before_drop = pane.Tabs.get_tab_count()
	drop_adapter.call("_on_files_dropped", PackedStringArray([image_path]))
	check("dropped webp retains graphics editor", pane.Tabs.get_tab_count() == before_drop + 1
		and pane.Tabs.get_child(before_drop).type == Editor.Type.GRAPHICS)
	var binary_path := directory.path_join("dropped.zip")
	_write(binary_path, "PK-binary-fixture")
	before_drop = pane.Tabs.get_tab_count()
	drop_adapter.call("_on_files_dropped", PackedStringArray([binary_path]))
	check("unsupported binary drop refuses without an editor", pane.Tabs.get_tab_count() == before_drop
		and FileAccess.get_file_as_string(binary_path) == "PK-binary-fixture")
	if empty_tabs.get_tab_count() == 1:
		var graphics: Editor = empty_tabs.get_child(0)
		var layer_count := graphics.graphics_editor.layers.size()
		drop_adapter.call("_on_files_dropped", PackedStringArray([image_path]))
		check("occupied graphics drop adds an image layer", empty_tabs.get_tab_count() == 1
			and graphics.graphics_editor.layers.size() == layer_count + 1)
		var next_claim := directory.path_join("mixed-drop.csv")
		_write(next_claim, text)
		layer_count = graphics.graphics_editor.layers.size()
		drop_adapter.call("_on_files_dropped", PackedStringArray([next_claim, image_path]))
		check("mixed claimed/image drop retains its initial graphics target", empty_tabs.get_tab_count() == 2
			and graphics.graphics_editor.layers.size() == layer_count + 1)
	_clear_tabs(empty_tabs)
	drop_adapter.call("_on_files_dropped", PackedStringArray([binary_path]))
	check("empty-pane binary drop refuses", empty_tabs.get_tab_count() == 0)
	var second_image := directory.path_join("second.webp")
	check("second real webp fixture is saved", image.save_webp(second_image) == OK)
	drop_adapter.call("_on_files_dropped", PackedStringArray([image_path, second_image]))
	check("multi-image empty drop opens two graphics editors", empty_tabs.get_tab_count() == 2
		and empty_tabs.get_child(0).type == Editor.Type.GRAPHICS and empty_tabs.get_child(1).type == Editor.Type.GRAPHICS)
	_clear_tabs(empty_tabs)
	var first_text := directory.path_join("first.txt")
	var second_text := directory.path_join("second.txt")
	_write(first_text, "first")
	_write(second_text, "second")
	drop_adapter.call("_on_files_dropped", PackedStringArray([first_text, second_text]))
	check("multi-text empty drop opens two text editors", empty_tabs.get_tab_count() == 2
		and empty_tabs.get_child(0).type == Editor.Type.TEXT and empty_tabs.get_child(1).type == Editor.Type.TEXT)
	var occupied_count := empty_tabs.get_tab_count()
	drop_adapter.call("_on_files_dropped", PackedStringArray([image_path, first_text]))
	check("ordinary image/text drops into text retain legacy ignore behavior", empty_tabs.get_tab_count() == occupied_count)
	drop_adapter.call("_on_files_dropped", PackedStringArray([binary_path]))
	check("binary drop into text refuses", empty_tabs.get_tab_count() == occupied_count)
	pane.position = Vector2(10000, 10000)
	drop_adapter.call("_on_files_dropped", PackedStringArray([dropped_claim]))
	check("drop outside the pane does nothing", empty_tabs.get_tab_count() == occupied_count)
	pane.position = Vector2(-1000, -1000)
	host.editor_pane = null
	drop_adapter.call("_on_files_dropped", PackedStringArray([dropped_claim]))
	host.editor_pane = pane
	check("drop without a pane does nothing", empty_tabs.get_tab_count() == occupied_count)
	empty_tabs.free()
	pane.Tabs = existing_tabs
	drop_adapter.free()
	var saved_editor: Editor = pane.Tabs.get_child(0)
	check("real bound editor saves successfully", await saved_editor.save_file_to_disc(open_path))
	text = FileAccess.get_file_as_string(open_path)
	pane.Tabs.remove_child(saved_editor)
	saved_editor.free()
	var reopened: Dictionary = host.open_file_at_path(open_path)
	check("saved document reopens through its owner", reopened.get("ok", false) and reopened.get("plugin_id") == single.id
		and JSON.parse_string(FileAccess.get_file_as_string(open_path)).get("value") == "opaque payload")
	var before_refusal := pane.Tabs.get_tab_count()
	for state: int in [PluginDefinition.State.STOPPED, PluginDefinition.State.ERROR]:
		manager.get_db().update_state(single.id, state)
		if state == PluginDefinition.State.STOPPED:
			manager.plugin_stopped.emit(single.id)
		else:
			manager.plugin_crashed.emit(single.id)
		var first_path := directory.path_join("never-opened-%s.fixturefmt" % state)
		_write(first_path, text)
		var first: Dictionary = host.open_file_at_path(first_path)
		check("stopped/crashed first open refuses with no new editor", not first.get("ok", true)
			and str(first.errors).contains("plugin_not_running") and pane.Tabs.get_tab_count() == before_refusal)
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
	var pair_count := pane.Tabs.get_tab_count()
	var pair_retry: Dictionary = host.open_file_at_path(paired_path, "import")
	check("paired retry preserves the existing pair", pair_retry.get("ok", false)
		and pane.Tabs.get_tab_count() == pair_count and pair_retry.get("editor_name") == paired_result.get("editor_name"))
	if pane.Tabs.get_tab_count() == before_refusal + 2:
		var source: Editor = pane.Tabs.get_child(before_refusal)
		var render: Editor = pane.Tabs.get_child(before_refusal + 1)
		check("paired file saves through its real source editor", await source.save_file_to_disc(paired_path))
		pane.Tabs.remove_child(render)
		render.free()
		pane.Tabs.remove_child(source)
		source.free()
		var again: Dictionary = host.open_file_at_path(paired_path)
		check("saved pair reopens through the integrated route", again.get("ok", false)
			and again.get("plugin_id") == paired.id and pane.Tabs.get_tab_count() == before_refusal + 2)
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

	await _exercise_readiness(host, manager, pane, single, directory, text)
	await _exercise_conflicts(host, manager, pane, directory, text)
	check("DB removal releases the sheet claims", manager.get_db().remove(single.id)
		and host.plugin_editor_registry.resolve_extension(".csv").is_empty())
	var csv_path := directory.path_join("unclaimed.csv")
	_write(csv_path, "name,value\nalpha,1\n")
	# Assert both occupied and empty builtin drop routes independently.
	var builtin_drop_adapter := Control.new()
	get_tree().root.add_child(builtin_drop_adapter)
	builtin_drop_adapter.set_script(load("res://Scripts/UI/Views/MainScene.gd"))
	var before_builtin := pane.Tabs.get_tab_count()
	builtin_drop_adapter.call("_on_files_dropped", PackedStringArray([csv_path]))
	check("real occupied unclaimed CSV drop uses builtin spreadsheet", pane.Tabs.get_tab_count() == before_builtin + 1
		and pane.Tabs.get_child(before_builtin).type == Editor.Type.SPREADSHEET)
	var occupied_tabs := pane.Tabs
	var builtin_empty := TabContainer.new()
	get_tree().root.add_child(builtin_empty)
	pane.Tabs = builtin_empty
	builtin_drop_adapter.call("_on_files_dropped", PackedStringArray([csv_path]))
	check("real empty unclaimed CSV drop uses builtin spreadsheet", builtin_empty.get_tab_count() == 1
		and builtin_empty.get_child(0).type == Editor.Type.SPREADSHEET)
	builtin_empty.free()
	pane.Tabs = occupied_tabs
	builtin_drop_adapter.free()
	var unknown_path := directory.path_join("unclaimed.ordinaryfmt")
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

	var import_only := _install(manager, "import_only_contract", ".importonly", false, ["import"])
	var import_only_path := directory.path_join("restricted.importonly")
	_write(import_only_path, text)
	if import_only != null:
		var before := pane.Tabs.get_tab_count()
		var no_open: Dictionary = host.open_file_at_path(import_only_path)
		var no_create: Dictionary = host.create_plugin_editor({"plugin_id": import_only.id, "editor_item_id": import_only.id + "_new"})
		check("undeclared open/create refuse without mutation", not no_open.get("ok", true)
			and not no_create.get("success", true) and pane.Tabs.get_tab_count() == before
			and FileAccess.get_file_as_string(import_only_path) == text)

func _exercise_readiness(host: Node, manager: PluginManager, pane: EditorPane, provider: PluginDefinition,
		directory: String, text: String) -> void:
	var ready_listeners := manager.plugin_ready.get_connections().size()
	var status_listeners := manager.plugin_status_changed.get_connections().size()
	var release := func() -> void:
		manager._ensure_runtime(provider.id)["ready"] = true
		manager.plugin_ready.emit(provider.id)
	for action: String in ["open", "import"]:
		var path := directory.path_join("ready-" + action + ".fixturefmt")
		_write(path, text)
		var before_open := pane.Tabs.get_tab_count()
		manager._ensure_runtime(provider.id)["ready"] = false
		var immediate: Variant = host.open_file_at_path(path, action)
		check("sync " + action + " returns a Dictionary refusal without allocating", immediate is Dictionary
			and str(immediate).contains("provider_not_ready") and pane.Tabs.get_tab_count() == before_open)
		get_tree().create_timer(0.02).timeout.connect(release)
		var result: Dictionary = await MCPGeneralTools.new(null).handle_with_context("minerva_open_file", {"path": path, "action": action}, MCPExecutionContext.create("fixture"))
		check("async " + action + " waits and allocates exactly once", result.get("success", false) and pane.Tabs.get_tab_count() == before_open + 1)
		if pane.Tabs.get_tab_count() == before_open + 1:
			var editor: Editor = pane.Tabs.get_child(before_open)
			check("async handoff sends one action without writing source bytes", editor.plugin_scene_root.get("loads") == 1
				and editor.plugin_scene_root.get("last_action") == action and FileAccess.get_file_as_string(path) == text)
	var args := {"plugin_id": provider.id, "editor_item_id": provider.id + "_new"}
	manager._ensure_runtime(provider.id)["ready"] = false
	var before := pane.Tabs.get_tab_count()
	var sync_create: Variant = host.create_plugin_editor(args)
	check("sync create refuses immediately without a coroutine", sync_create is Dictionary and str(sync_create).contains("provider_not_ready") and pane.Tabs.get_tab_count() == before)
	get_tree().create_timer(0.02).timeout.connect(release)
	var created: Dictionary = await MCPGeneralTools.new(null).handle_with_context("minerva_create_plugin_editor", args, MCPExecutionContext.create("fixture"))
	check("async create allocates once after ready", created.get("success", false) and pane.Tabs.get_tab_count() == before + 1)
	if pane.Tabs.get_tab_count() == before + 1:
		var editor: Editor = pane.Tabs.get_child(before)
		check("async create invokes one create hook", editor.plugin_scene_root.get("loads") == 1 and editor.plugin_scene_root.get("last_action") == "create")
	manager._ensure_runtime(provider.id)["ready"] = false
	before = pane.Tabs.get_tab_count()
	var refused_path := directory.path_join("refused-ready.fixturefmt")
	_write(refused_path, text)
	var deadline := MCPExecutionContext.create("fixture", "", "", 0.02)
	var expired: Dictionary = await host.open_file_when_ready(refused_path, "import", deadline)
	check("bounded document timeout refuses without allocating", (str(expired).contains("provider_ready_timeout") or str(expired).contains("deadline_exceeded")) and pane.Tabs.get_tab_count() == before)
	var context := MCPExecutionContext.create("fixture")
	get_tree().create_timer(0.02).timeout.connect(context.cancel)
	var cancelled: Dictionary = await host.open_file_when_ready(refused_path, "open", context)
	check("caller cancellation releases its wait", str(cancelled.get("error")).contains("cancelled") and pane.Tabs.get_tab_count() == before)
	release.call()
	await get_tree().process_frame
	check("later ready never replays refused document mutations", pane.Tabs.get_tab_count() == before and FileAccess.get_file_as_string(refused_path) == text)
	manager._ensure_runtime(provider.id)["ready"] = false
	get_tree().create_timer(0.02).timeout.connect(func() -> void:
		host.plugin_editor_registry.unregister_plugin(provider.id)
		release.call())
	var changed: Dictionary = await host.open_file_when_ready(refused_path)
	check("changed owner refuses before allocation", str(changed).contains("document_owner_changed") and pane.Tabs.get_tab_count() == before)
	host.plugin_editor_registry.register_plugin(provider)
	manager._ensure_runtime(provider.id)["ready"] = false
	var lost_pane := EditorPane.new()
	host.editor_pane = lost_pane
	get_tree().create_timer(0.02).timeout.connect(func() -> void:
		lost_pane.free()
		release.call())
	var pane_loss: Dictionary = await host.open_file_when_ready(refused_path)
	host.editor_pane = pane
	check("lost pane refuses without allocating", str(pane_loss).contains("editor_pane not available") and pane.Tabs.get_tab_count() == before)
	manager._ensure_runtime(provider.id)["ready"] = false
	get_tree().create_timer(0.02).timeout.connect(func() -> void: get_tree().root.remove_child(manager))
	var manager_loss: Dictionary = await host.open_file_when_ready(refused_path)
	check("manager loss releases document admission", str(manager_loss).contains("provider_unavailable") and pane.Tabs.get_tab_count() == before)
	await get_tree().process_frame # tree_exiting resumes the waiter before remove_child returns.
	get_tree().root.add_child(manager)
	manager._ensure_runtime(provider.id)["tools_notice"] = "provider tools unavailable: tools/list failed. Restart the plugin to retry."
	check("sync refusal carries the restart cause", str(host.open_file_at_path(refused_path)).contains("Restart the plugin to retry"))
	manager._ensure_runtime(provider.id).erase("tools_notice")
	var item: CreatableItemRegistry.CreatableItem = host.creatable_item_registry.get_item(provider.id + "_new")
	check("delayed GUI fixture has a native callback", item != null and item.create_callback.is_valid())
	if item != null:
		get_tree().create_timer(0.02).timeout.connect(func() -> void:
			check("GUI callback has not allocated before ready", pane.Tabs.get_tab_count() == before)
			release.call())
		await item.create_callback.call()
		check("GUI callback waits and creates one editor", pane.Tabs.get_tab_count() == before + 1)
	for surface: String in ["menu", "drop"]:
		var adapter: Control = VBoxContainer.new() if surface == "menu" else Control.new()
		get_tree().root.add_child(adapter)
		adapter.set_script(load("res://Scripts/UI/Controls/vboxEditor.gd" if surface == "menu" else "res://Scripts/UI/Views/MainScene.gd"))
		var path := directory.path_join(surface + "-ready.fixturefmt")
		_write(path, text)
		var surface_before := pane.Tabs.get_tab_count()
		manager._ensure_runtime(provider.id)["ready"] = false
		get_tree().create_timer(0.02).timeout.connect(func() -> void:
			check(surface + " stays pending before ready", pane.Tabs.get_tab_count() == surface_before)
			release.call())
		if surface == "menu":
			await adapter.call("open_file", path)
		else:
			await adapter.call("_open_dropped_files", PackedStringArray([path]))
		check(surface + " allocates once after ready", pane.Tabs.get_tab_count() == surface_before + 1 and FileAccess.get_file_as_string(path) == text)
		adapter.free()
	before = pane.Tabs.get_tab_count()
	manager._ensure_runtime(provider.id)["ready"] = false
	get_tree().create_timer(0.02).timeout.connect(release)
	check("project restore waiter requires ready, not merely RUNNING", await EditorContainer._wait_for_plugin_ready(provider.id, 500))
	manager._ensure_runtime(provider.id)["ready"] = false
	get_tree().create_timer(0.02).timeout.connect(func() -> void: manager.stop_plugin(provider.id))
	var stopped: Dictionary = await host.open_file_when_ready(refused_path)
	await get_tree().process_frame
	check("stop releases a pending wait with no allocation", str(stopped.get("error")).contains("provider_stopped") and pane.Tabs.get_tab_count() == before)
	check("completed waits disconnect listeners and release timers", manager.plugin_ready.get_connections().size() == ready_listeners
		and manager.plugin_status_changed.get_connections().size() == status_listeners
		and context.lifetime.cancelled.get_connections().is_empty() and not manager.get_children().any(func(child: Node) -> bool: return child is Timer))
	manager.get_db().update_state(provider.id, PluginDefinition.State.RUNNING)
	manager._ensure_runtime(provider.id)["ready"] = true


func _exercise_conflicts(host: Node, manager: PluginManager, pane: EditorPane, directory: String, text: String) -> void:
	var other := _install(manager, "z_conflict_contract", ".oldfmt", false)
	if other == null:
		return
	var connection := MCPServerConnection.new(other.id)
	connection.configure_stdio("python3", PackedStringArray([ProjectSettings.globalize_path("res://test/fixtures/stdio_timing_probe/stdio_timing_probe.py"), "--profile", "legacy"]))
	check("conflict fixture has a real backend", await connection.connect_to_server() == OK)
	manager._ensure_runtime(other.id)["connection"] = connection
	var backend_tools: Array = await connection.list_tools()
	check("real backend advertises tools before conflict", not backend_tools.is_empty())
	var capture = load("res://test/helpers/log_capture.gd").new()
	OS.add_logger(capture)
	other.ui_panels[0]["file_extensions"] = [".oldfmt", ".fixturefmt"]
	var rejected_panel: Dictionary = other.ui_panels[0].duplicate(true)
	rejected_panel["name"] = "rejected"
	other.ui_panels.append(rejected_panel)
	other.editor_items[0]["panel"] = "rejected"
	check("conflicting definition update reaches the DB", manager.get_db().update_definition(other))
	var registry: PluginEditorRegistry = host.plugin_editor_registry
	var status: Dictionary = manager.get_plugin_status(other.id)
	check("refused update preserves its old accepted claim", registry.resolve_extension(".oldfmt").get("plugin_id") == other.id
		and registry.resolve_extension(".fixturefmt").get("plugin_id") == "file_contract"
		and not status.editor_registration.ok and str(status.editor_registration.error).contains("file_contract"))
	check("editor refusal is logged with its copyable status message", str(status.editor_registration.error) in capture.combined())
	var before_create := pane.Tabs.get_tab_count()
	var rejected_create: Dictionary = host.create_plugin_editor({"plugin_id": other.id, "editor_item_id": other.id + "_new"})
	check("refused update cannot redirect an accepted editor kind", not rejected_create.get("success", true)
		and pane.Tabs.get_tab_count() == before_create)
	var logged: int = capture.size()
	var notices: Array = host._plugin_editor_notices.duplicate()
	manager.get_db().plugins_changed.emit()
	check("unrelated reconciliation retains the same notice set", host._plugin_editor_notices == notices
		and not capture.since(logged).contains(str(status.editor_registration.error)))
	OS.remove_logger(capture)
	var backend: MCPServerConnection = manager.get_connection(other.id)
	var reply: Dictionary = await backend.call_tool("echo", {"value": "still running"}, 5.0)
	check("editor refusal leaves backend tools running", manager.get_plugin_status(other.id).running
		and reply.get("success", false) and reply.get("echo", {}).get("value") == "still running")
	connection.disconnect_from_server()
	manager._ensure_runtime(other.id).erase("connection")
	var changed_path := directory.path_join("already-open.unknownfmt")
	_write(changed_path, text)
	var old: Dictionary = host.open_file_at_path(changed_path)
	check("ownership-change fixture starts as text", old.get("editor_kind") == "TEXT")
	var new_owner := _install(manager, "new_owner_contract", ".unknownfmt", false)
	if new_owner != null:
		var before := pane.Tabs.get_tab_count()
		var changed: Dictionary = host.open_file_at_path(changed_path)
		check("new owner cannot reuse a text editor", not changed.get("ok", true)
			and str(changed.errors).contains("document_owner_changed") and pane.Tabs.get_tab_count() == before)
	var required := _install(manager, "required_contract", ".fixturefmt", false)
	if required != null:
		check("required provider wins through installed DB binding", registry.resolve_extension(".fixturefmt").get("plugin_id") == required.id)
		manager.get_db().plugins_changed.emit()
		var retained_create: Dictionary = host.create_plugin_editor({"plugin_id": "file_contract", "editor_item_id": "file_contract_new"})
		check("optional-first keeps unrelated creates after a second reconciliation", retained_create.get("success", false)
			and manager.get_plugin_status("file_contract").editor_registration.ok)

		var before := pane.Tabs.get_tab_count()
		var changed: Dictionary = host.open_file_at_path(directory.path_join("open.fixturefmt"))
		check("required owner cannot reuse optional owner's tab", not changed.get("ok", true)
			and str(changed.errors).contains("document_owner_changed") and pane.Tabs.get_tab_count() == before)

	var required_first := _install(manager, "required_first_contract", ".requiredfirst", false)
	var optional_second := _install(manager, "optional_second_contract", ".requiredfirst", false)
	if required_first != null and optional_second != null:
		optional_second.ui_panels[0]["file_extensions"] = [".requiredfirst", ".retainedoptional"]
		check("required-first optional update reaches real DB", manager.get_db().update_definition(optional_second))
		manager.get_db().plugins_changed.emit()
		var retained_create: Dictionary = host.create_plugin_editor({"plugin_id": optional_second.id, "editor_item_id": optional_second.id + "_new"})
		check("required-first optional keeps other claims and creates after reconciliation", retained_create.get("success", false)
			and registry.resolve_extension(".requiredfirst").get("plugin_id") == required_first.id
			and registry.resolve_extension(".retainedoptional").get("plugin_id") == optional_second.id
			and manager.get_plugin_status(optional_second.id).editor_registration.ok)

	check("three-provider extension starts unclaimed", registry.resolve_extension(".tri").is_empty())
	var optional_a := _install(manager, "tri_optional_a", ".tri", false)
	var optional_b := _install(manager, "tri_optional_b", ".triold", false)
	if optional_a != null and optional_b != null:
		optional_b.ui_panels[0]["file_extensions"] = [".tri", ".triretained"]
		check("second optional collides before required install", manager.get_db().update_definition(optional_b)
			and not manager.get_plugin_status(optional_b.id).editor_registration.ok
			and registry.resolve_extension(".triretained").is_empty())
		var required_last := _install(manager, "late_required_contract", ".tri", false)
		check("required-last releases optional's other claims in the FIRST reconciliation", required_last != null
			and registry.resolve_extension(".tri").get("plugin_id") == "late_required_contract"
			and registry.resolve_extension(".triretained").get("plugin_id") == optional_b.id
			and registry.resolve_editor_kind(optional_b.id + "_new").get("plugin_id") == optional_b.id)


func _clear_tabs(tabs: TabContainer) -> void:
	for child: Node in tabs.get_children():
		child.free()
