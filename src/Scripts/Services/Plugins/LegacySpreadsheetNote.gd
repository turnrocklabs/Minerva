extends RefCounted
## Legacy notes keep their body/key. Opening is a synchronous snapshot import.
const Session := preload("res://Scripts/Services/Plugins/SpreadsheetSession.gd")
const REFERENCE: StringName = &"legacy_spreadsheet_reference"

static func open(reference_key: String, markdown: String, pane: EditorPane, manager: PluginManager) -> void:
	if not is_instance_valid(pane) or not is_instance_valid(pane.Tabs):
		return
	var exact: Array[Editor] = []
	var titled: Array[Editor] = []
	var diagnosis: Editor = null
	for editor: Editor in pane.get_open_editors():
		if editor.type != Editor.Type.PLUGIN_SCENE or editor.plugin_id != "sheets" or editor.panel_name != "sheets_panel":
			continue
		if editor.get_meta("legacy_spreadsheet_diagnosis", "") == reference_key:
			diagnosis = editor
			continue
		if editor.get_meta(REFERENCE, "") == reference_key:
			exact.append(editor)
		elif editor.tab_title == reference_key and not editor.has_meta(REFERENCE):
			titled.append(editor)
	var matches: Array[Editor] = exact if not exact.is_empty() else titled
	if matches.size() > 1:
		push_warning("Couldn't open legacy spreadsheet note: multiple Sheets match '%s'. Rename the tabs before retrying." % reference_key)
		if diagnosis == null:
			diagnosis = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, "Ambiguous spreadsheet note")
			diagnosis.set_meta("legacy_spreadsheet_diagnosis", reference_key)
		pane.focus_editor(diagnosis)
		_failure(diagnosis, manager, reference_key, markdown, pane, "Multiple Sheets match this note; rename them, then Retry.")
		return
	var editor: Editor = matches[0] if not matches.is_empty() else null
	if editor != null:
		pane.focus_editor(editor)
		if editor.plugin_restore_busy:
			return
		if not editor.pending_plugin_entry.is_empty() and not _is_seed(editor.pending_plugin_entry, reference_key):
			return # A note cannot replace an unresolved original sheet session.
		if editor.plugin_scene_root != null and editor.plugin_scene_root.get_meta("_minerva_plugin_panel_load_ok", false):
			editor.set_meta(REFERENCE, reference_key)
			return # Repeated Edit never overwrites a live model with the old snapshot.
		Session.retire_surface(editor, manager)
		editor.mount_plugin_scene(manager)
	else:
		editor = pane.add_plugin_scene_editor("sheets", "sheets_panel", null, reference_key)
	if editor == null:
		return
	editor.set_meta(REFERENCE, reference_key)
	var panel: Control = editor.plugin_scene_root
	if panel == null or not panel.get_meta("_minerva_plugin_panel_load_ok", false):
		_failure(editor, manager, reference_key, markdown, pane, "Sheets isn't available. Your original note is unchanged; install/start Sheets, then Retry.")
		return
	if not PluginScenePanelHost.invoke_restore_from_note(panel, {"version": 1, "legacy_markdown": markdown}):
		_failure(editor, manager, reference_key, markdown, pane, "Sheets couldn't read this note. The original note is unchanged.")
	else:
		editor.pending_plugin_entry.clear()

static func _failure(editor: Editor, manager: PluginManager, reference_key: String, markdown: String, pane: EditorPane, message: String) -> void:
	push_warning(message)
	if editor.has_meta(REFERENCE):
		# The same typed seed survives a project save while Sheets is absent.
		editor.pending_plugin_entry = {"type": Editor.Type.PLUGIN_SCENE, "name": editor.tab_title, "file": null,
			"plugin_id": "sheets", "panel_name": "sheets_panel", "plugin_version": "",
			"legacy_spreadsheet_reference": reference_key,
			"plugin_state": {"version": 1, "payload": {"__panel_state": {"version": 1, "legacy_markdown": markdown}}}}
	Session.retire_surface(editor, manager)
	var pane_ref: WeakRef = weakref(pane)
	var manager_ref: WeakRef = weakref(manager) if manager != null else null
	var retry := func() -> void:
		var current: EditorPane = pane_ref.get_ref()
		var provider: PluginManager = manager_ref.get_ref() if manager_ref != null else null
		if current != null:
			open(reference_key, markdown, current, provider)
	var placeholder: Control = PluginScenePanelHost._build_placeholder(message, retry, true)
	editor.get_node("VBoxContainer").add_child(placeholder)
	editor.remount_plugin_surface(placeholder)

static func _is_seed(entry: Dictionary, reference_key: String) -> bool:
	if entry.get("legacy_spreadsheet_reference") != reference_key:
		return false
	var value: Variant = Session.payload(entry).get("__panel_state")
	if not value is Dictionary:
		return false
	var snapshot_seed: Dictionary = value
	return snapshot_seed.size() == 2 and snapshot_seed.get("version") == 1 and snapshot_seed.get("legacy_markdown") is String
