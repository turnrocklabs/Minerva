class_name ETSUNotesServiceAdapter
extends NoteServiceAdapter


static var SERVICE_NAME: StringName:
	get: return get_service_name()


var actions: Dictionary[String, Action] = {}

func _init(service_: Service) -> void:
	super(service_)

	for action in service.actions:
		
		if action.topic == "%s/get" % SERVICE_NAME:
			actions["get"] = action
		elif action.topic == "%s/save" % SERVICE_NAME:
			actions["save"] = action
		elif action.topic == "%s/delete" % SERVICE_NAME:
			actions["delete"] = action

	info(actions)

static func get_service_name() -> StringName:
	return &"etsu-notes"

func delete_notes(notes: Array[Note]) -> bool:

	if "delete" not in actions:
		info("delete not found in %s actions" % SERVICE_NAME)
		return false

	var action: = actions["delete"]
	
	var notes_data: = []

	for note in notes:
		notes_data.append({"UUID": note.uuid})

	var msg = await (
		Core
		.send_message(service, action, {"notes": notes_data})
		.receive()
	)

	_last_response = msg
	
	if not msg:
		SingletonObject.ErrorDisplay("Can't delete", "Couldn't delete the note to remote")
		return false

	if msg.get("cmd", "") == "error":
		var error_message: String = safe_extract(
			msg,
			["params", "error"],
			[TYPE_DICTIONARY, TYPE_STRING],
			"Couldn't delete the note to remote"
		)


		var error_code: String = safe_extract(
			msg,
			["params", "error_code"],
			[TYPE_DICTIONARY, TYPE_STRING],
			"Remote Service Error"
		)

		SingletonObject.ErrorDisplay(error_code, error_message)

		return false

	return true


func save_notes(notes: Array[Note]) -> bool:
	if "save" not in actions:
		info("save not found in %s actions" % SERVICE_NAME)
		return false

	var action: = actions["save"]

	var notes_data: = []

	for note in notes:
		if note.type != Note.Type.TEXT:
			SingletonObject.ErrorDisplay("Can't save", "Can't save notes unless they are text notes.")
			continue
	
		# tab_id is int in the TabContainer, and thread_id is UUID
		var tab_id: = SingletonObject.notes_container.find_note(note)
		
		var local_thread_id = SingletonObject.notes_container.get_tab_id(tab_id)
		var local_thread_name: String = SingletonObject.notes_container.get_tab_name(tab_id)

		info("save_note: %s %s %s %s" % [note, tab_id, local_thread_name, local_thread_id])

		notes_data.append({
			"UUID": note.uuid,
			"Enabled": note.enabled,
			"Title": note.title,
			"Content": (note.get_controls_container() as NoteTextControls).content,
			"ThreadName": local_thread_name,
			"OwningThread": local_thread_id,
			"Order": _get_note_order_for_remote(note),
		})

	info(notes_data)

	var msg = await (
		Core
		.send_message(service, action, {"notes": notes_data})
		.receive()
	)

	_last_response = msg
	
	if not msg:
		SingletonObject.ErrorDisplay("Can't save", "Couldn't save the note to remote")
		return false

	if msg.get("cmd", "") == "error":
		var error_message: String = safe_extract(
			msg,
			["params", "error"],
			[TYPE_DICTIONARY, TYPE_STRING],
			"Couldn't save the note to remote"
		)


		var error_code: String = safe_extract(
			msg,
			["params", "error_code"],
			[TYPE_DICTIONARY, TYPE_STRING],
			"Remote Service Error"
		)

		SingletonObject.ErrorDisplay(error_code, error_message)

		return false

	return true

func get_all_notes() -> Array[Note]:
	if "get" not in actions:
		info("get not found in %s actions" % SERVICE_NAME)
		return []

	var action: = actions["get"]

	var msg = await (
		Core
		.send_message(service, action, {})
		.receive()
	)

	_last_response = msg

	if not msg is Dictionary:
		return []

	var notes_data = safe_extract(
		msg,
		["params", "result", "notes"],
		[TYPE_DICTIONARY, TYPE_DICTIONARY, TYPE_ARRAY]
	)

	if not notes_data is Array:
		return []
	
	# TODO: support other note types
	# right now all etsu notes are text notes

	var notes: Array[Note] = []

	for note_data in notes_data:
		var note: = Note.create_text_note(
			note_data.get("Title", "Unknown"),
			note_data.get("Content", ""),
			note_data.get("UUID", ""),
			false, # don't register the note yet
		)

		note.set_meta("remote_thread_id", note_data.get("OwningThread", ""))
		note.set_meta("remote_thread_name", note_data.get("ThreadName", "ETSU Notes"))
		note.set_meta("remote_order", note_data.get("Order", 0))

		notes.append(note)

	return notes


func handle_action(action: Action, data: Variant) -> bool:
	
	prints("HANDLE ACTION", action.topic, "%s/get" % SERVICE_NAME)
	print(data)

	if action.topic == "%s/get" % SERVICE_NAME:
		SingletonObject.notes_sync_manger.sync_with_remote()
		return true
	
	elif action.topic == "%s/save" % SERVICE_NAME:
		if not data is Array:
			return false
		
		var success: = await save_notes(data)

		for note in data:
			var controller: = SingletonObject.notes_sync_manger.get_sync_controller(note)
			controller.set_state(NoteSyncController.SyncState.SYNCED if success else NoteSyncController.SyncState.LOCAL_CHANGES)

		return success
	
	elif action.topic == "%s/delete" % SERVICE_NAME:
		if not data is Array:
			return false
		
		var success: = await delete_notes(data)

		for note in data:
			if success:
				note.queue_free()
			else:
				var controller: = SingletonObject.notes_sync_manger.get_sync_controller(note)
				controller.set_state(NoteSyncController.SyncState.SYNCED)
		
		return success

	
	return false
