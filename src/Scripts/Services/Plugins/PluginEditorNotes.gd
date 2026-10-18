class_name PluginEditorNotes
extends RefCounted
## Generic snapshot-note operation. The host injects current editor/notes services.

static func create_from_editor(plugin_id: String, args: Dictionary, service_context: Callable,
		context: MCPExecutionContext) -> Dictionary:
	for key: Variant in args:
		if key not in ["editor_name", "thread", "title"] or not args[key] is String:
			return PluginErrors.schema_validation_failed(plugin_id, "Expected string editor_name, thread and title arguments")
	var locator: String = str(args.get("editor_name", "")).strip_edges()
	if locator.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "editor_name is required")
	if not service_context.is_valid():
		return PluginErrors.backend_error(plugin_id, "Notes services are unavailable")
	var services: Dictionary = service_context.call()
	var broker: Variant = services.get("broker")
	var editors: Array = services.get("editors", [])
	var resolved: Dictionary = PanelServices.resolve(locator, broker, editors, true)
	if not resolved.get("ok", false):
		return PluginErrors.editor_not_found(plugin_id, locator)
	var raw_editor: Variant = resolved.get("editor")
	var editor: Editor = raw_editor if raw_editor is Editor else null
	var panel: Variant = resolved.get("panel")
	if editor == null or resolved.get("plugin_id") != plugin_id or editor.plugin_id != plugin_id:
		return PluginErrors.permission_denied(plugin_id, "Snapshot notes require an editor owned by this plugin")
	var raw_notes: Variant = services.get("notes")
	var notes: NotesContainer = raw_notes if raw_notes is NotesContainer else null
	if not is_instance_valid(notes):
		return PluginErrors.backend_error(plugin_id, "Notes container is unavailable")
	var raw_tabs: Variant = services.get("tabs")
	var tabs: TabContainer = raw_tabs if raw_tabs is TabContainer else null
	if not is_instance_valid(tabs) or editor.get_parent() != tabs:
		return PluginErrors.backend_error(plugin_id, "Editor tabs are unavailable")
	# The existing note hook captures the selected panel's actual viewport.
	tabs.current_tab = tabs.get_tab_idx_from_control(editor)
	var thread: String = str(args.get("thread", "Notes")).strip_edges()
	if thread.is_empty():
		thread = "Notes"
	var title: String = str(args.get("title", ""))
	var note: Note = await editor._create_plugin_scene_note()
	# Snapshot capture can suspend. Re-resolve ownership before publishing a note.
	var latest: Dictionary = service_context.call() if service_context.is_valid() else {}
	var latest_editors: Array = latest.get("editors", [])
	var current: Dictionary = PanelServices.resolve(locator, latest.get("broker"), latest_editors, true)
	if context.is_stopped() or not is_instance_valid(editor) or not is_instance_valid(notes) \
			or latest.get("notes") != notes or latest.get("broker") != broker or latest.get("tabs") != tabs \
			or not current.get("ok", false) or current.get("plugin_id") != plugin_id \
			or current.get("editor") != editor or current.get("panel") != panel:
		if is_instance_valid(note):
			note.free()
		return context.stopped_result() if context.is_stopped() else PluginErrors.backend_error(plugin_id, "Editor closed or changed during snapshot capture")
	if note == null or note._error:
		if is_instance_valid(note):
			note.free()
		return PluginErrors.backend_error(plugin_id, "Editor could not create a snapshot note")
	if not title.is_empty():
		note.title = title
	notes.find_or_create_tab(thread).add_note(note)
	return PluginErrors.success({"note_uuid": note.uuid, "note_title": note.title, "thread_name": thread,
		"editor_name": editor.tab_title, "snapshot": true})
