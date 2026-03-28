class_name CapabilityBroker
extends RefCounted
## Host capability broker for the Minerva plugin system.
##
## Maps capability names to host code execution.
## All dispatch calls are gated by PluginPolicy — if the policy engine denies
## the capability, the broker returns a permission error without executing anything.
##
## Return format (all public methods):
##   Success: {"success": true, "result": {...}}
##   Failure: {"success": false, "error_code": "...", "error_message": "...", ...}
##
## Design notes:
## - CapabilityBroker is stateless with respect to plugin identity; it delegates
##   all grant checks to PluginPolicy.
## - Stub handlers return capability_not_implemented until the vertical slice
##   wires them to real host objects.
## - notes.create and notes.read have partial real implementations that operate
##   on the live NotesContainer if one is available via SingletonObject.

## Policy engine reference — required for capability gating.
var policy: PluginPolicy = null


func _init(p_policy: PluginPolicy = null) -> void:
	policy = p_policy


# ---------------------------------------------------------------------------
# Public dispatch entry point
# ---------------------------------------------------------------------------

## Dispatch a capability call on behalf of a plugin.
##
## Steps:
## 1. Validate inputs.
## 2. Ask PluginPolicy whether the capability is granted.
## 3. Route to the appropriate handler function.
##
## Returns {"success": true, "result": {...}} or a PluginErrors failure dict.
func dispatch(plugin_id: String, capability: String, args: Dictionary) -> Dictionary:
	if plugin_id.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "plugin_id must not be empty")

	if capability.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "capability must not be empty")

	# Gate: check with policy engine before any execution (deny-by-default)
	if policy != null:
		var check := policy.check_capability(plugin_id, capability)
		if not check.get("allowed", false):
			# Re-wrap as success=false (check_capability already uses PluginErrors format)
			return {
				"success": false,
				"error_code": check.get("error_code", PluginErrors.CODE_CAPABILITY_NOT_GRANTED),
				"error_message": check.get("error_message", "Capability not granted"),
				"plugin_id": plugin_id,
			}
	else:
		# No policy engine — fail closed
		push_warning("[CapabilityBroker] No policy engine set — denying dispatch of '%s' for plugin '%s'" % [capability, plugin_id])
		return PluginErrors.capability_not_granted(plugin_id, capability)

	# Route to handler
	match capability:
		"notes.create":
			return _handle_notes_create(plugin_id, args)
		"notes.read":
			return _handle_notes_read(plugin_id, args)
		"notes.update":
			return _handle_notes_update(plugin_id, args)
		"artifacts.read":
			return _handle_artifacts_read(plugin_id, args)
		"artifacts.write":
			return _handle_artifacts_write(plugin_id, args)
		"webview.create":
			return _handle_webview_create(plugin_id, args)
		"webview.update":
			return _handle_webview_update(plugin_id, args)
		"filesystem.scoped":
			return _handle_filesystem_scoped(plugin_id, args)
		"network.none":
			# network.none is a deny marker — granting it is a configuration error
			return PluginErrors.permission_denied(plugin_id,
				"network.none is a deny marker and cannot be dispatched")
		_:
			return PluginErrors.schema_validation_failed(plugin_id,
				"No handler registered for capability '%s'" % capability)


# ---------------------------------------------------------------------------
# Capability handlers
# ---------------------------------------------------------------------------

## notes.create — Create a new text note in the active notes thread.
##
## Required args:
##   title: String — the note title
##   content: String — the note body text (may be empty)
## Optional args:
##   thread: String — name of the notes tab to create the note in
##                    (default: active tab)
##
## Returns: {"success": true, "result": {"uuid": "...", "title": "...", "thread": "..."}}
func _handle_notes_create(plugin_id: String, args: Dictionary) -> Dictionary:
	var title: String = str(args.get("title", "")).strip_edges()
	var content: String = str(args.get("content", ""))
	var thread_name: String = str(args.get("thread", "")).strip_edges()

	if title.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"notes.create requires a non-empty 'title'")

	var container := _get_notes_container()
	if container == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"notes.create: NotesContainer is not available (UI may not be initialized)")

	# Find or create the target thread tab
	if thread_name.is_empty():
		thread_name = "Plugins"
	var note_vbox: NoteVBox = container.find_or_create_tab(thread_name)

	if note_vbox == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"notes.create: Could not access thread '%s'" % thread_name)

	var note: Note = Note.create_text_note(title, content)
	note_vbox.add_note(note)

	var actual_thread: String = note_vbox.name
	print("[CapabilityBroker] Plugin '%s' created note '%s' in thread '%s' (uuid: %s)" % [
		plugin_id, title, actual_thread, note.uuid
	])

	return PluginErrors.success({
		"uuid": note.uuid,
		"title": title,
		"thread": actual_thread,
	})


## notes.read — Read note metadata from a thread.
##
## Optional args:
##   thread: String — name of the notes tab to read from (default: active tab)
##   uuid: String — if provided, return only the note with this UUID
##
## Returns note metadata (title, uuid, content_type, enabled).
## Does not return raw note body text — that requires a separate capability
## or a future notes.read_content capability.
func _handle_notes_read(plugin_id: String, args: Dictionary) -> Dictionary:
	var thread_name: String = str(args.get("thread", "")).strip_edges()
	var target_uuid: String = str(args.get("uuid", "")).strip_edges()

	var container := _get_notes_container()
	if container == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"notes.read: NotesContainer is not available (UI may not be initialized)")

	var note_vbox: NoteVBox
	if thread_name.is_empty():
		note_vbox = container.get_tab_control(container.current_tab) as NoteVBox
	else:
		# Read-only: do not create a new tab if thread is not found
		note_vbox = _find_tab_by_name(container, thread_name)

	if note_vbox == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"notes.read: Thread '%s' not found" % thread_name)

	var all_notes: Array[Note] = note_vbox.get_notes()
	var result_notes: Array = []

	for n in all_notes:
		if not target_uuid.is_empty() and n.uuid != target_uuid:
			continue
		result_notes.append({
			"uuid": n.uuid,
			"title": n.title,
			"content_type": n.content_type,
			"enabled": n.enabled,
		})

	if not target_uuid.is_empty() and result_notes.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"notes.read: Note with uuid '%s' not found in thread '%s'" % [target_uuid, note_vbox.name])

	print("[CapabilityBroker] Plugin '%s' read %d note(s) from thread '%s'" % [
		plugin_id, result_notes.size(), note_vbox.name
	])

	return PluginErrors.success({
		"thread": note_vbox.name,
		"notes": result_notes,
	})


## notes.update — stub; not yet implemented.
func _handle_notes_update(plugin_id: String, _args: Dictionary) -> Dictionary:
	return PluginErrors.schema_validation_failed(plugin_id,
		"notes.update is not yet implemented")


## artifacts.read — stub; not yet implemented.
func _handle_artifacts_read(plugin_id: String, _args: Dictionary) -> Dictionary:
	return PluginErrors.schema_validation_failed(plugin_id,
		"artifacts.read is not yet implemented")


## artifacts.write — stub; not yet implemented.
func _handle_artifacts_write(plugin_id: String, _args: Dictionary) -> Dictionary:
	return PluginErrors.schema_validation_failed(plugin_id,
		"artifacts.write is not yet implemented")


## webview.create — stub; not yet implemented.
func _handle_webview_create(plugin_id: String, _args: Dictionary) -> Dictionary:
	return PluginErrors.schema_validation_failed(plugin_id,
		"webview.create is not yet implemented")


## webview.update — stub; not yet implemented.
func _handle_webview_update(plugin_id: String, _args: Dictionary) -> Dictionary:
	return PluginErrors.schema_validation_failed(plugin_id,
		"webview.update is not yet implemented")


## filesystem.scoped — stub; not yet implemented.
## Real implementation will validate the requested path against the manifest's
## declared filesystem_paths before performing any I/O.
func _handle_filesystem_scoped(plugin_id: String, _args: Dictionary) -> Dictionary:
	return PluginErrors.schema_validation_failed(plugin_id,
		"filesystem.scoped is not yet implemented")


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Return the primary NotesContainer from the autoload, or null.
func _get_notes_container() -> NotesContainer:
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null or not "notes_container" in so:
		return null
	var container = so.notes_container
	if container == null or not is_instance_valid(container):
		return null
	return container as NotesContainer


## Find a tab in a NotesContainer by node name. Read-only — does not create new tabs.
func _find_tab_by_name(container: NotesContainer, tab_name: String) -> NoteVBox:
	for i in range(container.get_tab_count()):
		var ctrl := container.get_tab_control(i)
		if ctrl != null and ctrl.name == tab_name:
			return ctrl as NoteVBox
	return null
