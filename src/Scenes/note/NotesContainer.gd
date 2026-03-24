class_name NotesContainer
extends TabContainer

signal tab_renamed(tab_idx: int)

@onready var _new_thread_popup: PersistentWindow = %NewThreadPopup

var supports_remote: = true:
	set(value):
		supports_remote = value
		_update_adapter_info() # update to show/hide remote control buttons

## Callable to be called when add note button is pressed. Not set by default
var create_note_callback: Callable

var remote_adapter: NoteServiceAdapter = null:
	set(value):
		remote_adapter = value
		_update_adapter_info()

func _ready() -> void:
	# make tabs closeable
	get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS

	get_tab_bar().tab_close_pressed.connect(remove_tab)

	get_tab_bar().gui_input.connect(_on_tab_bar_gui_input)

	# Enable tab rearrangement by dragging
	get_tab_bar().drag_to_rearrange_enabled = true

	# tab bar need mouse_filter set to pass to allow the tab container to catch drag event and call _can_drop_data
	get_tab_bar().mouse_filter = MOUSE_FILTER_PASS

	get_tab_bar().active_tab_rearranged.connect(_on_active_tab_rearranged)

	get_tab_bar().set_drag_forwarding(Callable(), _can_drop_data, _drop_data)

## Creates a new tab with given name.[br]
## If the name is already taken godot will autimatically assing a new one.[br]
## Retuns the scroll container added as the new tab.
func create_tab(tab_name: String = "Notes", uuid: String = "") -> NoteVBox:
	if tab_name.is_empty():
		tab_name = "Notes"

	var notes_vbox: = NoteVBox.create()

	var new_tab_index: = get_tab_count()

	notes_vbox.note_added.connect(
		func(note: Node):
			if note.is_note_initialized():
				note.tab_changed.emit(new_tab_index)
	)

	notes_vbox.name = tab_name

	if uuid.is_empty():
		uuid = SingletonObject.generate_UUID()
	
	notes_vbox.uuid = uuid

	notes_vbox.supports_remote = supports_remote

	# force readable name
	add_child(notes_vbox, true)

	notes_vbox.renamed.connect(func(): tab_renamed.emit(new_tab_index))
	notes_vbox.add_note_requested.connect(func(): if create_note_callback.is_valid(): create_note_callback.call())

	_update_adapter_info()

	current_tab = new_tab_index

	return notes_vbox


## Find a tab by name, or create it if it doesn't exist.
## Returns the NoteVBox for that tab.
func find_or_create_tab(tab_name: String) -> NoteVBox:
	# Search existing tabs. Compare against both the raw name and the
	# Godot-sanitized name (e.g. "X.com" becomes "X_com" as a node name).
	var sanitized := tab_name.validate_node_name()
	for i in get_tab_count():
		var title := get_tab_title(i)
		if title == tab_name or title == sanitized:
			return get_tab_control(i) as NoteVBox

	# Not found, create new tab
	return create_tab(tab_name)


## Get a tab by name if it exists, otherwise return null
func find_tab_by_name(tab_name: String) -> NoteVBox:
	for i in get_tab_count():
		if get_tab_title(i) == tab_name:
			return get_tab_control(i) as NoteVBox
	return null


func add_note_vbox(notes_vbox: NoteVBox) -> void:
	var new_tab_index: = get_tab_count()

	notes_vbox.note_added.connect(
		func(note: Node):
			if note.is_note_initialized():
				note.tab_changed.emit(new_tab_index)
	)

	if notes_vbox.uuid.is_empty():
		notes_vbox.uuid = SingletonObject.generate_UUID()
	
	notes_vbox.supports_remote = supports_remote

	# force readable name
	add_child(notes_vbox, true)

	notes_vbox.renamed.connect(func(): tab_renamed.emit(new_tab_index))
	notes_vbox.add_note_requested.connect(func(): if create_note_callback.is_valid(): create_note_callback.call())

	_update_adapter_info()

	current_tab = new_tab_index

## Removes the tab specified with [param tab_idx].
## If [param user_action] is `true` that means that the user
## deliberatly wanted to try and delete the tab which will
## call each notes [method Note.remove] method and show a confirmation dialog.[br]
## Else the tab and it's notes will be deleted only if they are local notes.[br]
func remove_tab(tab_idx: int, user_action: = true):
	if user_action:
		var cd: = ConfirmationDialog.new()
		cd.dialog_text = "Are you sure you want to remove tab: %s" % get_tab_name(tab_idx)
	
		cd.get_ok_button().pressed.connect(
			func():
				_handle_remove_tab(tab_idx, user_action)
				cd.queue_free()	
		)

		cd.get_cancel_button().pressed.connect(
			func():
				cd.queue_free()
		)
		
		add_child(cd)
		cd.popup_centered()
	
	else:
		_handle_remove_tab(tab_idx, user_action)


func _handle_remove_tab(tab_idx: int, user_action) -> void:
	var control: NoteVBox = get_tab_control(tab_idx)

	# if at least one note deletion was rejected, don't delete the tab
	var all_deleted: = true
	if control:
		# doing this so the notes is_queued_for_deletion returns true
		for note in get_notes(tab_idx):
			if user_action:
				all_deleted = await note.remove() and all_deleted
			else:
				var controller: = SingletonObject.notes_sync_manger.get_sync_controller(note)
				if controller.state == NoteSyncController.SyncState.LOCAL_ONLY:
					note.queue_free()
				else:
					all_deleted = false

		if all_deleted:
			# if all notes we're deleted remove the thread from remote
			if not remote_adapter or (user_action and await remote_adapter.delete_thread(control.uuid, false)):
				control.queue_free()
			else:
				SingletonObject.ErrorDisplay("Threads Error", "Couldn't remove remote tab (Notes deleted)")
			
		else:
			print("Not all notes deleted, not removing the tab")

## Tries to find the index of tab that contains the provided [param note].[br]
## Returns `-1` on failure.
func find_note(note: Note) -> int:
	for i in get_tab_count():
		if get_notes(i).has(note):
			return i

	return -1

## Adds the provided [parameter note] to the [parameter tab_idx] tab.[br]
## If [parameter tab_idx] is -1, currently selected tab is used, or it fails if no tab is selected.[br]
## If [parameter force] is true, and appropriate tab wasn't found, new one will be created.[br] 
## Returns true on success.
func add_note(note: Note, tab_idx: int = -1, force: = true, index: int = -1) -> bool:
	if tab_idx == -1:
		tab_idx = current_tab

	# if still -1 there is no selected tab to add to
	if tab_idx == -1:
		if force:
			var new_note_vbox: = create_tab()
			
			new_note_vbox.add_note(note)

			if new_note_vbox.auto_upload: _sync_new_note(note)
			return true
		
		return false

	var note_vbox: NoteVBox = get_tab_control(tab_idx)
	
	note_vbox.add_note(note, index)

	if note_vbox.auto_upload: _sync_new_note(note)
	return true


## Synchronizes the new note
func _sync_new_note(note: Note):
	if not SingletonObject.notes_sync_manger.active_service:
		SingletonObject.ErrorDisplay(
			"Failed",
			"No service for remote notes active.\nCheck if you are connected to the Core and if remote note service is available."
		)
		return

	var success: = await SingletonObject.notes_sync_manger.sync_notes([note], false)
	
	if not success:
		SingletonObject.ErrorDisplay("Failed", "Couldn't upload the following:\n %s" % note)


## Returns an array of notes in the specified tab.[br]
## If not tab is specified ([-1]) returns notes from the currently selected tab or empty array.
func get_notes(tab_idx: = -1) -> Array[Note]:
	tab_idx = tab_idx if tab_idx != -1 else current_tab

	if tab_idx == -1: return []

	var note_vbox: NoteVBox = get_tab_control(tab_idx)
	if note_vbox != null:
		return note_vbox.get_notes()
	return []

## Returns the UUID of the specified tab, or `null` if it doesn't exist
func get_tab_id(idx: int):
	var control = get_tab_control(idx)
	if control is NoteVBox: return control.uuid
	return null

## Returns the name of the specified tab, or `null` if it doesn't exist
func get_tab_name(idx: int):
	if idx < get_tab_count():
		return get_tab_control(idx).name

	return null

## Sets the name of the specified tab, or silently fails if it doesn't exist.
func set_tab_name(idx: int, new_name: String):
	var control: = get_tab_control(idx)

	if control:
		control.name = new_name


## Disables all notes in the specified or currently active tab.
func disable_notes(tab_idx: = -1):
	tab_idx = tab_idx if tab_idx != -1 else current_tab
	if tab_idx == -1: return

	for note in get_notes(tab_idx):
		note.enabled = false


## Enables all notes in the specified or currently active tab.
func enable_notes(tab_idx: = -1):
	tab_idx = tab_idx if tab_idx != -1 else current_tab
	if tab_idx == -1: return

	for note in get_notes(tab_idx):
		note.enabled = true

## Makes all notes in the specified or currently active tab.
func show_notes(tab_idx: = -1):
	tab_idx = tab_idx if tab_idx != -1 else current_tab
	if tab_idx == -1: return

	for note in get_notes(tab_idx):
		note.visible = true

## Hides all notes in the specified or currently active tab.
func hide_notes(tab_idx: = -1):
	tab_idx = tab_idx if tab_idx != -1 else current_tab
	if tab_idx == -1: return

	for note in get_notes(tab_idx):
		note.visible = true


func set_remote_adapter(adapter: NoteServiceAdapter):
	remote_adapter = adapter

## Updates [class NoteVBox] note tab controls with the active adapter.[br]
## Used when the adapter changes or new tab is created
func _update_adapter_info():
	# if not remote_adapter:
	# 	return

	for i in get_tab_count():
		var note_vbox: NoteVBox = get_tab_control(i)
		if not supports_remote or not remote_adapter:
			note_vbox._remote_option_container.visible = false
		else:
			note_vbox._remote_option_container.visible = true
			note_vbox._remote_service_label.text = remote_adapter.service.name



## Calls the [param provider] wrap_memory for each active node
## in the notes and drawer notes container, and returns an array of all the return values.[br]
## If [param refresh_detached] is `true`, detached notes will be regenerated to match current editor content.
func to_prompt(provider: BaseProvider, refresh_detached: = false, history_id: String = "") -> Array[Variant]:
	var output: Array[Variant] = []

	var notes: Array[Note]

	for i in SingletonObject.notes_container.get_tab_count():
		notes.append_array(SingletonObject.notes_container.get_notes(i).filter(
			func(note: Note): return note.enabled and (history_id.is_empty() or note.is_linked_to_chat(history_id))
		))

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		notes.append_array(SingletonObject.drawer_notes_container.get_notes(i).filter(
			func(note: Note): return note.enabled and (history_id.is_empty() or note.is_linked_to_chat(history_id))
		))

	for proxy_note in SingletonObject.detached_note_proxies:
		# Filter: only include proxies targeting this chat (or untargeted)
		if not proxy_note.matches_chat(history_id):
			continue
		var use_cached := not refresh_detached
		var note: = await proxy_note.create_note(use_cached)

		if note:
			notes.append(note)
			if refresh_detached:
				note.enabled = false
		else:
			SingletonObject.ErrorDisplay("Note Error", "Couldn't generate a Note object")

	# notes are filtered for enabled ones, except for detached note
	# if detached notes are present
	print("[NotesContainer] Wrapping %d notes for prompt" % notes.size())
	for note in notes:
		var wrapped = provider.wrap_memory(note)
		print("[NotesContainer] Wrapped note type=%s, result_type=%s" % [note.type, typeof(wrapped)])
		# Skip null/invalid wrapped results (e.g., from empty images)
		if wrapped == null:
			push_warning("[NotesContainer] Skipping null wrapped note (type=%s)" % note.type)
			continue
		output.append(wrapped)

	return output


static var _agent_tab_icon: Texture2D = preload("res://assets/icons/robot_AI_48.png")

## Lock a tab to an agent. Shows a robot icon on the tab header.
func lock_tab_to_agent(tab_idx: int, agent_id: String) -> void:
	var note_vbox: NoteVBox = get_tab_control(tab_idx)
	if note_vbox:
		note_vbox.locked_agent_id = agent_id
		set_tab_icon(tab_idx, _agent_tab_icon)


## Check if a tab is locked to an agent.
func is_tab_agent_locked(tab_idx: int) -> bool:
	var note_vbox: NoteVBox = get_tab_control(tab_idx)
	return note_vbox != null and not note_vbox.locked_agent_id.is_empty()


## Show or hide all agent-locked tabs.
func set_agent_tabs_visible(p_visible: bool) -> void:
	for i in get_tab_count():
		if is_tab_agent_locked(i):
			set_tab_hidden(i, not p_visible)


## Find or create a tab locked to a specific agent.
func find_or_create_agent_tab(tab_name: String, agent_id: String) -> NoteVBox:
	# Check existing tabs for one already locked to this agent with this name
	var sanitized := tab_name.validate_node_name()
	for i in get_tab_count():
		var existing_vbox: NoteVBox = get_tab_control(i)
		if existing_vbox.locked_agent_id == agent_id:
			var title := get_tab_title(i)
			if title == tab_name or title == sanitized:
				return existing_vbox

	# Not found, create and lock
	var vbox = create_tab(tab_name)
	var idx = get_tab_idx_from_control(vbox)
	lock_tab_to_agent(idx, agent_id)
	return vbox


func serialize() -> Array[Dictionary]:
	var data: Array[Dictionary]

	for i in range(get_tab_count()):
		var note_vbox: NoteVBox = get_tab_control(i)

		var notes_data: Array[Dictionary]

		var notes: = get_notes(i)
		for note in notes:
			notes_data.append(note.serialize())

		var tab_data: = {
			"ThreadName": note_vbox.name,
			"ThreadId": note_vbox.uuid,
			"MemoryItemList": notes_data,
			"AutoUpload": note_vbox.auto_upload,
			"LockedAgentId": note_vbox.locked_agent_id,
			"DefaultLinkedChatIds": note_vbox.default_linked_chat_ids,
		}

		data.append(tab_data)

	return data

func deserialize(notes_data: Array) -> void:

	for tab_data in notes_data:
		var tab_title: String = tab_data.get("ThreadName")
		var tab_id = tab_data.get("ThreadId")
		var auto_upload = tab_data.get("AutoUpload", false)

		# it could be explicit null or empty string so check here
		if not tab_id:
			tab_id = ""

		# check if this tab doesnt exist already
		var note_vbox: NoteVBox

		for i in SingletonObject.notes_container.get_tab_count():
			if SingletonObject.notes_container.get_tab_id(i) == tab_id:
				note_vbox = SingletonObject.notes_container.get_tab_control(i)

		if not note_vbox:
			note_vbox = create_tab(tab_title, tab_id)


		note_vbox.auto_upload = auto_upload
		note_vbox.locked_agent_id = tab_data.get("LockedAgentId", "")

		var saved_links: Array = tab_data.get("DefaultLinkedChatIds", [])
		var typed_links: Array[String] = []
		for lid in saved_links:
			typed_links.append(str(lid))
		note_vbox.default_linked_chat_ids = typed_links

		var tab_idx: = get_tab_idx_from_control(note_vbox)

		# Show robot icon on agent-locked tabs
		if not note_vbox.locked_agent_id.is_empty():
			set_tab_icon(tab_idx, _agent_tab_icon)

		# NOTICE: this may not be the best place to check for sync of remote notes
		var notes_to_update: Array[Note]

		for mem_item_data in tab_data.get("MemoryItemList", []):

			var note_uuid: String = mem_item_data.get("UUID", "")

			var existing_note: = SingletonObject.get_registered_object(note_uuid)

			if not existing_note:
				add_note(
					Note.deserialize(mem_item_data),
					tab_idx
				)
				continue
			
			# if note is already there, it may be the remote note.
			# check if it's remote and update if so

			# NOTICE: this part doesn't check if the thread actually needs the update
			# but the thread update is not data heavy
			# example: { "uuid": "67e06497867de0023fce35e519c7ca3eb82310274858d6da4d93439de57760b2", "name": "Rules", "order": 1 }
			
			var controller: = SingletonObject.notes_sync_manger.get_sync_controller(existing_note)

			# if this is somehow just a local note, just leave it as is
			if controller.state == NoteSyncController.SyncState.LOCAL_ONLY: continue

			# else update the remote just in case
			notes_to_update.append(existing_note)

		if not notes_to_update.is_empty():
			SingletonObject.notes_sync_manger.sync_notes(notes_to_update)


# region Drop

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is Note:
		return false

	if at_position.x < 42: # move left
		current_tab = current_tab-1 if current_tab > 0 else 0

	elif get_tab_bar().size.x - at_position.x < 42: # move right
		current_tab = current_tab+1 if current_tab < get_tab_count()-1 else current_tab
		
	if get_tab_idx_at_point(at_position) == -1:
		return false

	current_tab = get_tab_idx_at_point(at_position)

	return true

func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not data is Note: return
	
	var note = data as Note

	if note.get_parent() != null:
		note.get_parent().remove_child(note)

	add_note(note, get_tab_idx_at_point(at_position), false, 0)
	


# endregion

# region rename

var last_click: float = -1

func _on_tab_bar_gui_input(event: InputEvent) -> void:

	if event is InputEventMouseButton:
		var tab_idx: = get_tab_idx_at_point(event.position)

		if event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			if tab_idx != -1:
				_show_tab_context_menu(tab_idx, get_global_mouse_position())
			return

		if not (event.pressed and event.button_index == MOUSE_BUTTON_LEFT): return

		if tab_idx == -1: return

		if last_click == -1:
			last_click = Time.get_unix_time_from_system()
			return

		if Time.get_unix_time_from_system() - last_click < 0.2:
			_new_thread_popup.set_values(get_tab_name(tab_idx), get_tab_control(tab_idx))

		last_click = Time.get_unix_time_from_system()

# endregion

# region tab context menu

func _show_tab_context_menu(tab_idx: int, pos: Vector2) -> void:
	var vbox: NoteVBox = get_tab_control(tab_idx)
	if not vbox:
		return

	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_item("Rename...", 0)

	menu.id_pressed.connect(func(id: int):
		match id:
			0:
				_new_thread_popup.set_values(get_tab_name(tab_idx), vbox)
		menu.queue_free()
	)

	menu.popup(Rect2i(Vector2i(pos), Vector2i.ZERO))

# endregion


func _on_active_tab_rearranged(_idx_to: int) -> void:
	var adapter = remote_adapter
	
	if not adapter: return

	# Update ALL tabs to reflect new order
	for i in get_tab_count():
		var vbox: NoteVBox = get_tab_control(i)
		
		var success = await adapter.update_thread(
			vbox.uuid,
			vbox.name,
			i,  # Current position in UI
			vbox.get_meta("remote_metadata", {})
		)
		if not success:
			SingletonObject.ErrorDisplay("Can't update", "Couldn't update tab order on remote")
			return  # Stop on first failure
