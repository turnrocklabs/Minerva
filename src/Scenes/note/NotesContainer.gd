class_name NotesContainer
extends TabContainer


## A dictionary that maps tab index to a corresponding uuid
var _uuid_map: Dictionary[int, String] = {}

func _ready() -> void:
	# make tabs closeable
	get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS

	get_tab_bar().tab_close_pressed.connect(remove_tab)

	# tab bar need mouse_filter set to pass to allow the tab container to catch drag event and call _can_drop_data
	get_tab_bar().mouse_filter = MOUSE_FILTER_PASS


## Creates a new tab with given name.[br]
## If the name is already taken godot will autimatically assing a new one.[br]
## Retuns the scroll container added as the new tab.
func create_tab(tab_name: String = "Notes", uuid: String = "") -> Control:
	if tab_name.is_empty():
		tab_name = "Notes"

	var scroll: = ScrollContainer.new()

	var vbox: = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	scroll.add_child(vbox)
	scroll.name = tab_name

	print(uuid)

	if uuid.is_empty():
		print("uuid is empty")
		uuid = SingletonObject.generate_UUID()
	
	_uuid_map[get_tab_count()] = uuid

	# force readable name
	add_child(scroll, true)

	return scroll

## Removes the tab specified with [param tab_idx].
func remove_tab(tab_idx: int):	
	var control: = get_tab_control(tab_idx)

	if control:
		# doing this so the notes is_queued_for_deletion returns true
		for note in get_notes(tab_idx):
			note.queue_free()

		control.queue_free()


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
func add_note(note: Note, tab_idx: int = -1, force: = true, index: int = 0) -> bool:
	if tab_idx == -1:
		tab_idx = current_tab

	# if still -1 there is no selected tab to add to
	if tab_idx == -1:
		if force:
			var created_scroll: = create_tab()
			var vbox_ = created_scroll.get_child(0)
			if not vbox_:
				push_error("Couldn't get the VBoxContainer to add the note to")

			vbox_.add_child(note)

			return true
		
		return false

	var current_scroll: ScrollContainer = get_tab_control(tab_idx)
	var vbox = current_scroll.get_child(0)

	if not vbox:
		push_error("Couldn't get the VBoxContainer to add the note to")

	vbox.add_child(note)
	vbox.move_child(note, index)

	return true

## Returns an array of notes in the specified tab[br].
## If not tab is specified ([-1]) returns notes from the currently selected tab or empty array.
func get_notes(tab_idx: = -1) -> Array[Note]:
	tab_idx = tab_idx if tab_idx != -1 else current_tab

	if tab_idx == -1: return []

	var current_scroll: ScrollContainer = get_tab_control(current_tab)
	var vbox = current_scroll.get_child(0)

	if not vbox:
		push_error("Couldn't get the VBoxContainer to get the notes")
		return []
	
	var notes: Array[Note] = []

	for child in vbox.get_children():
		if child is Note:
			notes.append(child)

	return notes

## Returns the UUID of the specified tab, or `null` if it doesn't exist
func get_tab_id(idx: int):
	return _uuid_map.get(idx)

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

## Calls the [param provider] wrap_memory for each active node
## in the notes and drawer notes container, and returns an array of all the return values.
func to_prompt(provider: BaseProvider) -> Array[Variant]:
	var output: Array[Variant] = []
	
	var notes: Array[Note]

	for i in SingletonObject.notes_container.get_tab_count():
		notes.append_array(SingletonObject.notes_container.get_notes())

	for i in SingletonObject.drawer_notes_container.get_tab_count():
		notes.append_array(SingletonObject.drawer_notes_container.get_notes())

	for note in notes:
		if note.enabled:
			output.append(provider.wrap_memory(note))


	# loop through detached notes also
	# for item in SingletonObject.DetachedNotes:
	# 	if item.Enabled:
	# 		output.append(provider.wrap_memory(item))
	
	return output


func serialize() -> Array[Dictionary]:
	var data: Array[Dictionary]

	for i in range(get_tab_count()):
		var notes_data: Array[Dictionary]

		var notes: = get_notes(i)
		for note in notes:
			notes_data.append(note.serialize())

		var tab_data: = {
			"ThreadName": get_tab_control(i).name,
			"ThreadId": _uuid_map.get(i),
			"MemoryItemList": notes_data
		}

		data.append(tab_data)

	return data

func deserialize(notes_data: Array) -> void:

	for tab_data in notes_data:
		var tab_title: String = tab_data.get("ThreadName")
		var tab_id = tab_data.get("ThreadId")

		# it could be explicit null or empty string so check here
		if not tab_id:
			tab_id = ""

		var tab_control: = create_tab(tab_title, tab_id)

		var tab_idx: = get_tab_idx_from_control(tab_control)

		for mem_item_data in tab_data.get("MemoryItemList", []):
			add_note(
				Note.deserialize(mem_item_data),
				tab_idx
			)


# region Drop

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is Note:
		return false

	# if drag_to_rearrange_enabled is enabled this won't work as expected

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
