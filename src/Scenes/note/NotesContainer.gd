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

	# force readable name
	add_child(scroll, true)

	if uuid.is_empty():
		uuid = SingletonObject.generate_UUID()
		_uuid_map[current_tab] = uuid

	return scroll

## Removes the tab specified with [param tab_idx].
func remove_tab(tab_idx: int):	
	var control: = get_tab_control(tab_idx)

	if control:
		control.queue_free()


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

	# print(notes_data)

	for tab_data in notes_data:
		var tab_title: String = tab_data.get("ThreadName")
		var tab_control: = create_tab(tab_title, tab_data.get("ThreadId", ""))

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
