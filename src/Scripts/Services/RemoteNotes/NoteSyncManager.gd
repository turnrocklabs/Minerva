class_name NoteSyncManager
extends RefCounted

var active_service: Service
var sync_controllers: Dictionary[String, NoteSyncController] = {}
var service_adapters: Dictionary[String, NoteServiceAdapter] = {}

## Array of note UUIDs that were fetched by the adapter class.
## Used to determine the initial state of the note controller.
## If it doesn't exist here it's a fully local note
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

## Makes the current [member active_service] adapter fetch all notes and threads
## and sync them with the local ones. LOCAL ALWAYS WINS.
func sync_with_remote():
	var adapter = get_current_adapter()
	
	if not adapter:
		info("No adapter available")
		return
	
	info("Starting sync with remote using adapter: %s" % adapter)
	
	# STEP 1: Sync threads first
	await _sync_threads_from_remote(adapter)
	
	# STEP 2: Sync notes
	await _sync_notes_from_remote(adapter)
	
	# STEP 3: Connect tab rename listener
	if not SingletonObject.notes_container.tab_renamed.is_connected(_on_notes_tab_renamed):
		SingletonObject.notes_container.tab_renamed.connect(_on_notes_tab_renamed)

## Syncs threads: creates missing remote threads, updates mismatched ones
func _sync_threads_from_remote(adapter: NoteServiceAdapter):
	var remote_threads = await adapter.list_threads()
	
	info("Fetched %d remote threads" % remote_threads.size())
	
	# For each remote thread, check if it exists locally
	for remote_vbox in remote_threads:
		var remote_uuid = remote_vbox.uuid
		var remote_name = remote_vbox.name
		var remote_order = remote_vbox.get_meta("order", 0)
		var remote_metadata = remote_vbox.get_meta("metadata", {})
		
		var found_locally = false
		var local_vbox: NoteVBox = null
		
		# Find local thread by UUID
		for i in SingletonObject.notes_container.get_tab_count():
			var vbox: NoteVBox = SingletonObject.notes_container.get_tab_control(i)
			if vbox.uuid == remote_uuid:
				found_locally = true
				local_vbox = vbox
				break
		
		if found_locally:
			# Thread exists locally - check if name/order/metadata differs
			var local_name = local_vbox.name
			var local_idx = SingletonObject.notes_container.get_tab_idx_from_control(local_vbox)
			var local_metadata = local_vbox.get_meta("remote_metadata", {})
			
			var needs_update = (
				local_name != remote_name or
				local_idx != remote_order or
				not _dict_equals(local_metadata, remote_metadata)
			)
			
			if needs_update:
				info("Local thread %s differs from remote, updating remote" % remote_uuid)
				# LOCAL WINS - Update remote to match local
				await adapter.update_thread(
					remote_uuid,
					local_name,
					local_idx,
					local_metadata
				)
			else:
				info("Local thread %s matches remote" % remote_uuid)
				# Store remote metadata in local
				local_vbox.set_meta("remote_metadata", remote_metadata)
		else:
			# Thread doesn't exist locally - create it
			info("Creating local thread from remote: %s" % remote_name)
			var new_vbox = SingletonObject.notes_container.create_tab(remote_name, remote_uuid)
			new_vbox.set_meta("remote_metadata", remote_metadata)
			
			# Move to correct position if needed
			if remote_order < SingletonObject.notes_container.get_tab_count() - 1:
				SingletonObject.notes_container.move_child(new_vbox, remote_order)

## Syncs notes: creates missing, updates conflicts (local wins)
func _sync_notes_from_remote(adapter: NoteServiceAdapter):
	var remote_notes = await adapter.get_notes()
	
	_remote_note_uuids = PackedStringArray(remote_notes.map(func(note: Note): return note.uuid))
	
	info("Fetched %d remote notes" % remote_notes.size())
	
	var notes_to_create_locally: Array[Note] = []
	
	for remote_note in remote_notes:
		var remote_thread_id = remote_note.get_meta("remote_thread_id", "")
		var remote_order = remote_note.get_meta("remote_order", 0)
		var remote_metadata = remote_note.get_meta("remote_metadata", {})
		
		# Check if note exists locally
		var local_note: Note = SingletonObject.get_registered_object(remote_note.uuid)
		
		if not local_note:
			info("Remote note %s doesn't exist locally, will create" % remote_note.uuid)
			notes_to_create_locally.append(remote_note)
		else:
			# Note exists locally - check if out of sync
			info("Note %s exists locally, checking sync" % remote_note.uuid)
			
			# Create temporary control to initialize remote note for comparison
			var temp_control = Control.new()
			temp_control.visible = false
			SingletonObject.get_tree().root.add_child(temp_control)
			temp_control.add_child(remote_note)
			
			await remote_note.initialized
			
			var local_tab_idx = SingletonObject.notes_container.find_note(local_note)
			var local_thread_id = SingletonObject.notes_container.get_tab_id(local_tab_idx)
			var local_thread_name = SingletonObject.notes_container.get_tab_name(local_tab_idx)
			
			# Create sync info to check if out of sync
			var temp_sync_info = NoteSyncController.SyncStateInfo.new(
				remote_note,
				remote_thread_id,
				"" # Don't compare thread name, only ID
			)
			
			var out_of_sync = temp_sync_info.is_out_of_sync(
				local_note,
				local_thread_id,
				local_thread_name
			)
			
			var controller = get_sync_controller(local_note)
			
			if out_of_sync:
				info("Local note %s is out of sync, LOCAL WINS - updating remote" % local_note.uuid)
				# LOCAL WINS - Upload local version
				var success = await adapter.save_notes([local_note])
				controller.set_state(NoteSyncController.SyncState.SYNCED if success else NoteSyncController.SyncState.LOCAL_CHANGES)
			else:
				info("Local note %s is in sync with remote" % local_note.uuid)
				# Store remote metadata
				local_note.set_meta("remote_metadata", remote_metadata)
				controller.set_state(NoteSyncController.SyncState.SYNCED)
			
			temp_control.queue_free()
	
	# Sort notes by order before creating
	notes_to_create_locally.sort_custom(
		func(note_a: Note, note_b: Note):
			return note_a.get_meta("remote_order", 0) < note_b.get_meta("remote_order", 0)
	)
	
	# Create missing notes locally
	for remote_note in notes_to_create_locally:
		var remote_thread_id = remote_note.get_meta("remote_thread_id", "")
		var remote_metadata = remote_note.get_meta("remote_metadata", {})
		
		var should_update = _create_remote_note_locally(remote_note, remote_thread_id)
		
		# Store metadata
		remote_note.set_meta("remote_metadata", remote_metadata)
		
		if should_update:
			# Thread was created or name changed - update remote
			info("Thread changed for note %s, updating remote" % remote_note.uuid)
			await adapter.save_notes([remote_note])

## Tries to upload provided notes to remote and all others in shared tabs to update their order field.
## If any note is not initialized yet, it waits for it to be.
## In case of failure displays an error message if [param display_error] is `true`.
func sync_notes(notes: Array[Note], display_error = true) -> bool:
	var adapter = get_current_adapter()
	if not adapter:
		if display_error:
			SingletonObject.ErrorDisplay("No Adapter", "No remote service available")
		return false
	
	# Collect all tabs that contain these notes
	var target_tabs: Array[int] = []
	
	for note in notes:
		if not note.is_note_initialized():
			await note.initialized
		
		var tab_idx = SingletonObject.notes_container.find_note(note)
		
		if tab_idx == -1:
			push_error("NoteSyncManager.sync_notes can't update %s as its tab index is -1, skipping..." % note)
			continue
		
		if tab_idx not in target_tabs:
			target_tabs.append(tab_idx)
	
	# For each tab, ensure the thread exists remotely, then upload all notes
	var success = true
	
	for tab_idx in target_tabs:
		var vbox: NoteVBox = SingletonObject.notes_container.get_tab_control(tab_idx)
		var thread_uuid = vbox.uuid
		var thread_name = vbox.name
		var thread_metadata = vbox.get_meta("remote_metadata", {})
		
		# Try to update thread first (creates if missing)
		var thread_updated = await adapter.update_thread(
			thread_uuid,
			thread_name,
			tab_idx,
			thread_metadata,
			false,
		)
		
		if not thread_updated:
			# Thread might not exist, try creating it
			info("Thread update failed, attempting to create: %s" % thread_name)
			thread_updated = await adapter.create_thread(
				thread_name,
				thread_uuid,
				tab_idx,
				thread_metadata
			)
		
		if not thread_updated:
			info("Failed to sync thread %s" % thread_uuid)
			success = false
			continue
		
		# Now upload all notes in this tab
		var tab_notes = SingletonObject.notes_container.get_notes(tab_idx)
		var notes_success = await adapter.save_notes(tab_notes)
		
		if notes_success:
			# Mark all notes as synced
			for note in tab_notes:
				var controller = get_sync_controller(note)
				controller.set_state(NoteSyncController.SyncState.SYNCED)
		else:
			success = false
			# Mark notes as having local changes
			for note in tab_notes:
				var controller = get_sync_controller(note)
				controller.set_state(NoteSyncController.SyncState.LOCAL_CHANGES)
	
	if not success and display_error:
		SingletonObject.ErrorDisplay("Can't upload", "Couldn't sync notes to remote")
	
	return success

## Sync a single note using patch (with fallback to save)
func sync_note_fields(note: Note, fields: Array[String], display_error = true) -> bool:
	var adapter = get_current_adapter()
	if not adapter:
		if display_error:
			SingletonObject.ErrorDisplay("No Adapter", "No remote service available")
		return false
	
	if not note.is_note_initialized():
		await note.initialized
	
	# Use patch for efficiency
	var success = await adapter.patch_notes([note], fields)
	
	var controller = get_sync_controller(note)
	controller.set_state(NoteSyncController.SyncState.SYNCED if success else NoteSyncController.SyncState.LOCAL_CHANGES)
	
	if not success and display_error:
		SingletonObject.ErrorDisplay("Can't update", "Couldn't sync note to remote")
	
	return success

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
		return NoteSyncController.SyncState.SYNCED
	else:
		return NoteSyncController.SyncState.LOCAL_ONLY

func add_service_adapter(service: Service, adapter: NoteServiceAdapter):
	info("Added service adapter for %s" % service.name)
	service_adapters[service.client_id] = adapter

func get_current_adapter() -> NoteServiceAdapter:
	if not active_service:
		return null
	return service_adapters.get(active_service.client_id)

func set_active_service(service: Service):
	info("Setting the active service to %s" % service.name)
	if service.client_id in service_adapters:
		active_service = service
		# Update all controllers with new adapter
		for controller: NoteSyncController in sync_controllers.values():
			controller.set_adapter(get_current_adapter())
	
	var adapter = get_current_adapter()
	SingletonObject.notes_container.set_remote_adapter(adapter)

## Creates the remote note locally in the specified thread and creates the thread if missing.
## Doesn't check if the note is present locally, call this only if it's definitive that it's missing.
## Returns whether the note needs to be updated remotely (if the thread was created or name changed).
func _create_remote_note_locally(remote_note: Note, thread_id: String) -> bool:
	var needs_update = false
	var target_tab_idx = -1
	
	# Find thread by UUID
	for i in SingletonObject.notes_container.get_tab_count():
		var tab_id = SingletonObject.notes_container.get_tab_id(i)
		if tab_id == thread_id:
			target_tab_idx = i
			break
	
	if target_tab_idx == -1:
		# Thread doesn't exist locally - create it
		info("Creating thread locally: %s" % thread_id)
		
		var tab_control = SingletonObject.notes_container.create_tab("Notes", thread_id)
		target_tab_idx = SingletonObject.notes_container.get_tab_idx_from_control(tab_control)
		
		needs_update = true  # Thread was created, need to update remote
	
	# Add note to thread
	SingletonObject.notes_container.add_note(remote_note, target_tab_idx)
	SingletonObject.register_object(remote_note, &"uuid")
	
	# Mark as synced if no update needed
	if not needs_update:
		var controller = get_sync_controller(remote_note)
		controller.set_state(NoteSyncController.SyncState.SYNCED)
	
	return needs_update

func _on_notes_tab_renamed(tab_idx: int):
	var vbox: NoteVBox = SingletonObject.notes_container.get_tab_control(tab_idx)
	var adapter = get_current_adapter()
	
	if not adapter:
		return
	
	# Update the thread name on remote
	var success = await adapter.update_thread(
		vbox.uuid,
		vbox.name,
		tab_idx,
		vbox.get_meta("remote_metadata", {})
	)
	
	if not success:
		SingletonObject.ErrorDisplay("Can't update", "Couldn't update tab name on remote")

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
	
	info("Registration message received")
	
	var services = await Core.fetch_services()
	
	for service in services:
		var adapter: NoteServiceAdapter
		
		info("Found service: %s" % service.client_id)
		
		if service.client_id == "service:%s" % ETSUNotesServiceAdapter.SERVICE_NAME:
			adapter = ETSUNotesServiceAdapter.new(service)
		
		if adapter:
			add_service_adapter(service, adapter)
			set_active_service(service)
			await sync_with_remote()
			SingletonObject.create_toast_notification("Synchronized notes with %s" % service.name)

func _on_core_disconnected():
	info("Core disconnected")

func _on_core_message_received(data):
	if data is Dictionary and data.get("cmd", "") == "event" and data.get("entity_type", "") == "core":
		var params = data.get("params", {})
		if params.get("name", "") == "service_disconnected":
			info("Service %s disconnected" % params.get("service_id", "Unknown"))

## Helper to compare dictionaries deeply
func _dict_equals(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	
	for key in a:
		if not b.has(key):
			return false
		if typeof(a[key]) != typeof(b[key]):
			return false
		if a[key] != b[key]:
			return false
	
	return true
