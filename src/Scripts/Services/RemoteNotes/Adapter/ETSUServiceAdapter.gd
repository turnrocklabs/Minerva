class_name ETSUNotesServiceAdapter
extends NoteServiceAdapter

static var SERVICE_NAME: StringName:
	get: return get_service_name()

var actions: Dictionary[ACTION_TYPE, Action] = {}

func _init(service_: Service) -> void:
	super(service_)
	
	for action in service.actions:
		if action.topic == "etsu-threads/list":
			actions[ACTION_TYPE.LIST_THREADS] = action
		elif action.topic == "etsu-threads/create":
			actions[ACTION_TYPE.CREATE_THREAD] = action
		elif action.topic == "etsu-threads/update":
			actions[ACTION_TYPE.UPDATE_THREAD] = action
		elif action.topic == "etsu-threads/delete":
			actions[ACTION_TYPE.DELETE_THREAD] = action
		elif action.topic == "etsu-notes/get":
			actions[ACTION_TYPE.GET_NOTES] = action
		elif action.topic == "etsu-notes/save":
			actions[ACTION_TYPE.SAVE_NOTES] = action
		elif action.topic == "etsu-notes/patch":
			actions[ACTION_TYPE.PATCH_NOTES] = action
		elif action.topic == "etsu-notes/delete":
			actions[ACTION_TYPE.DELETE_NOTES] = action

static func get_service_name() -> StringName:
	return &"etsu-notes"

# ============================================================================
# THREAD METHODS
# ============================================================================

func list_threads() -> Array[NoteVBox]:
	var action: Action = actions.get(ACTION_TYPE.LIST_THREADS)
	if not action:
		info("List threads action not found")
		return []
	
	var msg = await Core.send_message(service, action, {}).receive()
	_last_response = msg
	
	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to list threads")
		SingletonObject.ErrorDisplay("List Threads Error", error_msg)
		return []
	
	var threads_data = safe_extract(msg, ["params", "result", "threads"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])
	
	var thread_vboxes: Array[NoteVBox] = []
	for thread in threads_data:
		var vbox = NoteVBox.create()
		vbox.uuid = thread.get("UUID", "")
		vbox.name = thread.get("Name", "")
		vbox.set_meta("order", thread.get("Order", 0))
		vbox.set_meta("created_at", thread.get("CreatedAt", 0.0))
		vbox.set_meta("metadata", thread.get("Metadata", {}))
		thread_vboxes.append(vbox)
	
	return thread_vboxes

func create_thread(thread_name: String, thread_uuid: String = "", order: int = -1, metadata: Dictionary = {}) -> bool:
	var action: Action = actions.get(ACTION_TYPE.CREATE_THREAD)
	if not action:
		info("Create thread action not found")
		return false
	
	var data = {"name": thread_name}
	if thread_uuid: data["uuid"] = thread_uuid
	if order >= 0: data["order"] = order
	if not metadata.is_empty(): data["metadata"] = metadata
	
	var msg = await Core.send_message(service, action, data).receive()
	_last_response = msg
	
	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to create thread")
		SingletonObject.ErrorDisplay("Create Thread Error", error_msg)
		return false
	
	return true

func update_thread(thread_uuid: String, thread_name: String = "", order: int = -1, metadata: Dictionary = {}, display_error: = true) -> bool:
	var action: Action = actions.get(ACTION_TYPE.UPDATE_THREAD)
	if not action:
		info("Update thread action not found")
		return false
	
	var data = {"uuid": thread_uuid}
	if thread_name: data["name"] = thread_name
	if order >= 0: data["order"] = order
	if not metadata.is_empty(): data["metadata"] = metadata
	
	var msg = await Core.send_message(service, action, data).receive()
	_last_response = msg
	
	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to update thread")
		if display_error: SingletonObject.ErrorDisplay("Update Thread Error", error_msg)
		return false
	
	return true

func delete_thread(thread_uuid: String, display_error: = true) -> bool:
	var action: Action = actions.get(ACTION_TYPE.DELETE_THREAD)
	if not action:
		info("Delete thread action not found")
		return false
	
	var msg = await Core.send_message(service, action, {"uuid": thread_uuid}).receive()
	_last_response = msg
	
	if not msg or msg.get("cmd") == "error":
		if display_error: 
			var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to delete thread")
			SingletonObject.ErrorDisplay("Delete Thread Error", error_msg)
		return false
	
	return true

# ============================================================================
# NOTE METHODS
# ============================================================================

func get_notes(thread_id: String = "", filters: Dictionary = {}) -> Array[Note]:
	var action: Action = actions.get(ACTION_TYPE.GET_NOTES)
	if not action:
		info("Get notes action not found")
		return []
	
	var data = {}
	if thread_id: data["thread_id"] = thread_id
	if not filters.is_empty(): data["filters"] = filters
	
	var msg = await Core.send_message(service, action, data).receive()
	_last_response = msg
	
	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to get notes")
		SingletonObject.ErrorDisplay("Get Notes Error", error_msg)
		return []
	
	var notes_data = safe_extract(msg, ["params", "result", "notes"], [TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY], [])
	
	var notes: Array[Note] = []
	for note_data in notes_data:
		var note = Note.deserialize(note_data, false)
		note.set_meta("remote_metadata", note_data.get("Metadata", {}))
		
		if note:
			note.set_meta("remote_thread_id", note_data.get("ThreadID", ""))
			note.set_meta("remote_order", note_data.get("Order", 0))
			notes.append(note)
	
	return notes

func save_notes(notes: Array[Note]) -> bool:
	var action: Action = actions.get(ACTION_TYPE.SAVE_NOTES)
	if not action:
		info("Save notes action not found")
		return false
	
	var notes_data: Array = []
	for note in notes:
		if note.content_type != "text":
			SingletonObject.ErrorDisplay("Invalid Note Type", "Can only save text notes")
			continue
		
		var tab_idx = SingletonObject.notes_container.find_note(note)
		var thread_id = SingletonObject.notes_container.get_tab_id(tab_idx)
		
		notes_data.append({
			"UUID": note.uuid,
			"ThreadID": thread_id,
			"Order": _get_note_order_for_remote(note),
			"Title": note.title,
			"Content": (note.get_controls_container() as NoteTextControls).content,
			"ContentType": note.content_type,
			"Enabled": note.enabled,
			"Visible": note.visible,
			# "Pinned": note.pinned,
			"Expanded": note.expanded,
			"Metadata": note.get_meta("remote_metadata", {}),
		})
	
	if notes_data.is_empty():
		return false
	
	var msg = await Core.send_message(service, action, {"notes": notes_data}).receive()
	_last_response = msg
	
	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to save notes")
		SingletonObject.ErrorDisplay("Save Notes Error", error_msg)
		return false
	
	return true

func patch_notes(notes: Array[Note], fields: Array[String]) -> bool:
	var action: Action = actions.get(ACTION_TYPE.PATCH_NOTES)
	if not action:
		info("Patch notes action not found")
		return await save_notes(notes)  # Fallback to save
	
	var updates: Array = []
	for note in notes:
		var update = {"UUID": note.uuid}
		
		for field in fields:
			match field:
				"Title":
					update["Title"] = note.title
				"Content":
					update["Content"] = (note.get_controls_container() as NoteTextControls).content
				"Order":
					update["Order"] = _get_note_order_for_remote(note)
				"ThreadID":
					var tab_idx = SingletonObject.notes_container.find_note(note)
					update["ThreadID"] = SingletonObject.notes_container.get_tab_id(tab_idx)
				"Enabled":
					update["Enabled"] = note.enabled
				"Visible":
					update["Visible"] = note.visible
				# "Pinned":
				# 	update["Pinned"] = note.pinned
				"Metadata":
					update["Metadata"] = note.get_meta("remote_metadata", {})
		
		updates.append(update)
	
	var msg = await Core.send_message(service, action, {"updates": updates}).receive()
	_last_response = msg
	
	if not msg or msg.get("cmd") == "error":
		info("Patch failed, falling back to save")
		return await save_notes(notes)  # Fallback to save
	
	var result = safe_extract(msg, ["params", "result"], [TYPE_DICTIONARY, TYPE_DICTIONARY], {})
	var errors = result.get("errors", [])
	
	# If any notes failed to patch, fallback to save for those
	if not errors.is_empty():
		info("Some notes failed to patch, falling back to save")
		return await save_notes(notes)
	
	return true

func delete_notes(notes: Array[Note]) -> bool:
	var action: Action = actions.get(ACTION_TYPE.DELETE_NOTES)
	if not action:
		info("Delete notes action not found")
		return false
	
	var notes_data: Array = []
	for note in notes:
		notes_data.append({"note_id": note.uuid})
	
	var msg = await Core.send_message(service, action, {"notes": notes_data}).receive()
	_last_response = msg
	
	if not msg or msg.get("cmd") == "error":
		var error_msg = safe_extract(msg, ["params", "error"], [TYPE_DICTIONARY, TYPE_STRING], "Failed to delete notes")
		SingletonObject.ErrorDisplay("Delete Notes Error", error_msg)
		return false
	
	return true

func handle_action(action: Action, data: Variant) -> bool:
	if action.topic == "etsu-notes/get":
		SingletonObject.notes_sync_manger.sync_with_remote()
		return true
	
	elif action.topic == "etsu-notes/save":
		if not data is Array:
			return false
		var success = await save_notes(data)
		for note in data:
			var controller = SingletonObject.notes_sync_manger.get_sync_controller(note)
			controller.set_state(NoteSyncController.SyncState.SYNCED if success else NoteSyncController.SyncState.LOCAL_CHANGES)
		return success
	
	elif action.topic == "etsu-notes/delete":
		if not data is Array:
			return false
		var success = await delete_notes(data)
		for note in data:
			if success:
				note.queue_free()
			else:
				var controller = SingletonObject.notes_sync_manger.get_sync_controller(note)
				controller.set_state(NoteSyncController.SyncState.SYNCED)
		return success
	
	return false
