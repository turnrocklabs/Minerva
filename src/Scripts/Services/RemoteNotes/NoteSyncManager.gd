class_name NoteSyncManager
extends RefCounted

var active_service: Service
var sync_controllers: Dictionary[String, NoteSyncController] = {}
var service_adapters: Dictionary[String, NoteServiceAdapter] = {}

## Array of note UUIDs that were fetched by the adapter class.
## Used to determine the initial state of the note controller.
## If it doesnt't exist here its a fully local note
var _remote_note_uuids: PackedStringArray

func _init() -> void:

	Core.ready.connect(
		func():
			Core.client.connection_established.connect(_on_core_connected)
			Core.client.connection_closed.connect(_on_core_disconnected)
			Core.client.message_received.connect(_on_core_message_received)
	)


func info(input):
	print("#\n#### NoteSyncManager: %s\n#" % str(input))


## Makes the current [member active_service] adapter fetch all notes
## and sync them with the local ones.
func sync_with_remote():
	var adapter: = get_current_adapter()
	
	info("adapter is %s" % adapter)
	info(service_adapters)

	var remote_notes: = await adapter.get_all_notes()

	_remote_note_uuids = PackedStringArray(remote_notes.map(func(note: Note): return note.uuid))

	for remote_note in remote_notes:
		# Access thread info from metadata
		var remote_thread_id = remote_note.get_meta("remote_thread_id", "")
		var remote_thread_name = remote_note.get_meta("remote_thread_name", "ETSU Notes")

		# Remote notes are created and object registration is disabled in the adapter
		# so if a local one exists it will be here, since by default notes register automatically
		var local_note: = SingletonObject.get_registered_object(remote_note.uuid)

		if not local_note:
			info("No local note for %s in thread %s" % [remote_note, remote_thread_name])

			# will make the remote_note exist locally
			var should_update: = _create_remote_note_locally(remote_note, remote_thread_id, remote_thread_name)

			if should_update:
				adapter.save_notes([remote_note])
			
			else:
				info("Note %s created locally, no need for update" % remote_note)
		
		# note exists locally, so check if they are not the same
		# if not update the remote
		else:
			var temp_control: = Control.new()
			temp_control.visible = false
			SingletonObject.get_tree().root.add_child(temp_control)

			temp_control.add_child(remote_note)

			await remote_note.initialized

			# create SyncStateInfo to check if remote and local don't match
			var temp_sync_info: = NoteSyncController.SyncStateInfo.new(remote_note, remote_thread_id, remote_thread_name)
			
			var local_tab_idx: = SingletonObject.notes_container.find_note(local_note)

			var in_sync: = temp_sync_info.is_out_of_sync(
				local_note,
				SingletonObject.notes_container.get_tab_id(local_tab_idx),
				SingletonObject.notes_container.get_tab_name(local_tab_idx)
			)

			if in_sync: continue

			# if not force update the remote
			
			var controller: = get_sync_controller(local_note)

			var success: = await adapter.save_notes([local_note])

			if success:
				controller.set_state(NoteSyncController.SyncState.SYNCED)
			else:
				controller.set_state(NoteSyncController.SyncState.LOCAL_CHANGES)
			
			temp_control.queue_free()


func get_sync_controller(note: Note) -> NoteSyncController:
	if not sync_controllers.has(note.uuid):
		var controller = NoteSyncController.new(note, self)

		var initial_state = determine_initial_sync_state(note)
		controller.set_state(initial_state)
		controller.set_adapter(get_current_adapter())

		sync_controllers[note.uuid] = controller
	
	return sync_controllers[note.uuid]

func cleanup_controller(uuid: String) -> void:
	sync_controllers.erase(uuid)

func determine_initial_sync_state(note: Note) -> NoteSyncController.SyncState:
	# Check if this note exists in the last fetched remote notes
	if note.uuid in _remote_note_uuids:
		return NoteSyncController.SyncState.LOCAL_CHANGES  # Exists on remote, assume synced initially
	else:
		return NoteSyncController.SyncState.LOCAL_ONLY  # New note, doesn't exist on remote


func add_service_adapter(service: Service, adapter: NoteServiceAdapter):
	info("added service addapter for %s" % service.name)
	service_adapters[service.client_id] = adapter

func get_current_adapter() -> NoteServiceAdapter:
	return service_adapters.get(active_service.client_id)

func set_active_service(service: Service):
	info("setting the active service to %s" % [service.name])
	if service.client_id in service_adapters:
		active_service = service
		# Update all controllers with new adapter
		for controller: NoteSyncController in sync_controllers.values():
			controller.set_adapter(get_current_adapter())


## Creates the remote note locally in the specified thread and created the thread if missing.[br]
## Doesn't check if the note is present locally, call this only if it's definitive that it's missing.[br]
## Returns whether the note needs to be updated remotely (if the thread name has changed).[br]
func _create_remote_note_locally(remote_note: Note, thread_id: String, thread_name: String) -> bool:
	var update: = false
	var target_tab_idx: int = -1

	info("Tab count is %s" % SingletonObject.notes_container.get_tab_count())
	
	for i in SingletonObject.notes_container.get_tab_count():
		var tab_id = SingletonObject.notes_container.get_tab_id(i)

		if tab_id == thread_id:
			target_tab_idx = i
			break
	
	if target_tab_idx == -1:
		var tab_control: = SingletonObject.notes_container.create_tab(thread_name, thread_id)

		target_tab_idx = SingletonObject.notes_container.get_tab_idx_from_control(tab_control)
	else:
		# if found a thread, but the name has changed we need to update the remote note
		update = SingletonObject.notes_container.get_tab_name(target_tab_idx) != thread_name
			
	
	SingletonObject.notes_container.add_note(remote_note, target_tab_idx)

	SingletonObject.register_object(remote_note, &"uuid")

	# if that's it mark the note as synced
	if not update:
		
		var controller: = get_sync_controller(remote_note)
		
		controller.set_state(NoteSyncController.SyncState.SYNCED)
	
	return update

func _on_core_connected():
	info("Waiting for registration message...")

	var registration_message = await (
		Core
		.await_message()
		.with_topic("system")
		.with_cmd("registration_confirmed")
		.receive()
	)

	if not registration_message:
		info("No registration message received")
		return
	
	info("Registration message received %s" % [registration_message])

	
	var services: = await Core.fetch_services()

	for service in services:
		
		var adapter: NoteServiceAdapter

		info(service.client_id)

		if service.client_id == "service:%s" % ETSUNotesServiceAdapter.SERVICE_NAME:
			adapter = ETSUNotesServiceAdapter.new(service)

		if adapter:
			add_service_adapter(service, adapter)

			set_active_service(service)

			sync_with_remote()

			SingletonObject.create_toast_notification("Synchronized notes with %s" % service.name)


func _on_core_disconnected():
	info("Core disconnected")


func _on_core_message_received(data):
	# catch service disconnect event

	if data is Dictionary and data.get("cmd", "") == "event" and data.get("entity_type", "") == "core":
		var params = data.get("params", {})
		if params.get("name", "") == "service_disconnected":
			info("Service %s disconnected" % params.get("service_id", "Unknown"))
