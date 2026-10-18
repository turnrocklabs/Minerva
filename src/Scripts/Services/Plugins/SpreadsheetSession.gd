extends RefCounted
## Compatibility boundary for retired type 6; Sheets owns snapshot interpretation.

static func is_sheet(entry: Dictionary) -> bool:
	return entry.get("type") == Editor.Type.PLUGIN_SCENE and entry.get("plugin_id") == "sheets" and entry.get("panel_name") == "sheets_panel"

static func convert_entries(entries: Array) -> Array:
	var converted: Array = []
	for entry: Dictionary in entries:
		var value: Dictionary = entry.duplicate(true)
		if value.get("type") == Editor.LEGACY_SPREADSHEET_TYPE:
			value["type"] = Editor.Type.PLUGIN_SCENE
			value["plugin_id"] = "sheets"
			value["panel_name"] = "sheets_panel"
			value["plugin_state"] = {"version": 1, "payload": {"__panel_state": value.get("content")}}
			value.erase("content")
		converted.append(value)
	return converted

static func state(entry: Dictionary) -> Dictionary:
	var value: Variant = entry.get("plugin_state")
	return value if value is Dictionary else {}

static func payload(entry: Dictionary) -> Dictionary:
	var value: Variant = state(entry).get("payload")
	return value if value is Dictionary else {}

static func restore(editor: Editor, entry: Dictionary, manager: PluginManager) -> void:
	var panel: Control = editor.plugin_scene_root
	if panel == null or not panel.get_meta("_minerva_plugin_panel_load_ok", false):
		show_failure(editor, manager, "Sheets is absent or its panel could not load.")
		return
	var saved: Variant = payload(entry).get("__panel_state")
	if state(entry).get("version") != 1 or not saved is Dictionary:
		show_failure(editor, manager, "The saved Sheets state is malformed or unsupported.")
		return
	var snapshot: Dictionary = saved
	var owner: WeakRef = weakref(editor)
	var accept := func() -> void:
		var live: Editor = owner.get_ref()
		if live == null or not is_instance_valid(panel) or live.plugin_scene_root != panel:
			return
		# Existing boolean snapshot hook; the provider validates its own format.
		if PluginScenePanelHost.invoke_restore_from_note(panel, snapshot):
			live.pending_plugin_entry.clear()
		else:
			show_failure(live, manager, "Sheets refused the saved model/version; original entry retained.")
	if panel.is_node_ready():
		accept.call()
	else:
		panel.ready.connect(accept, CONNECT_ONE_SHOT)

static func show_failure(editor: Editor, manager: PluginManager, reason: String) -> void:
	var message: String = "%s\nOriginal spreadsheet state is retained. Start/install Sheets, then Retry." % reason
	push_warning(message)
	retire_surface(editor, manager)
	var owner: WeakRef = weakref(editor)
	var placeholder: Control = PluginScenePanelHost._build_placeholder(message, func() -> void: retry(owner, manager))
	editor.get_node("VBoxContainer").add_child(placeholder)
	editor.remount_plugin_surface(placeholder)

static func retire_surface(editor: Editor, manager: PluginManager) -> void:
	var old: Control = editor.plugin_scene_root
	if is_instance_valid(old):
		PluginScenePanelHost.invoke_unload(old)
		PluginScenePanelHost.unregister_from_broker(editor.plugin_id, editor.plugin_panel_key)
		if is_instance_valid(manager):
			manager.unregister_live_panel(editor.plugin_id, editor.plugin_panel_key)
		editor.remount_plugin_surface(null)
		old.get_parent().remove_child(old)
		old.queue_free()

static func retry(owner: WeakRef, manager: PluginManager) -> void:
	var editor: Editor = owner.get_ref()
	if editor == null or editor.is_queued_for_deletion() or editor.plugin_restore_busy or editor.pending_plugin_entry.is_empty():
		return
	editor.plugin_restore_busy = true
	var database: PluginDB = manager.get_db() if is_instance_valid(manager) else null
	if database != null and database.get_by_id("sheets") != null:
		# The editor may close during provider startup; never retain it across await.
		editor = null
		await manager.start_plugin("sheets")
		editor = owner.get_ref()
		if editor == null or editor.is_queued_for_deletion() or not editor.is_inside_tree():
			return
	if not is_instance_valid(manager):
		manager = null
	retire_surface(editor, manager)
	editor.mount_plugin_scene(manager)
	var converted: Array = convert_entries([editor.pending_plugin_entry])
	var entry: Dictionary = converted[0]
	restore(editor, entry, manager)
	editor.plugin_restore_busy = false
