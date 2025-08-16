class_name BaseTabContainer
extends TabContainer

## Base class for tab containers that manage memory threads and notes
## Provides common functionality for both regular and drawer tabs

## Emitted when theres a change in the memory items list (item added, removed).
signal memories_updated(thread: MemoryThread)
signal note_rendered(note: Note)

# If lock is set to true, notes WONT be saved.
# used when the app is exiting so the saved notes dont get cleared
# and nothing gets saved
var lock: = false

@onready var buffer_control_notes: Control = %BufferControlNotes
var _drag_active := true

# Abstract methods - must be implemented by derived classes
func get_thread_list() -> Array[MemoryThread]:
	assert(false, "get_thread_list() must be implemented in derived class")
	return []

func get_tab_container() -> TabContainer:
	assert(false, "get_tab_container() must be implemented in derived class")
	return null

func get_vbox_scene():
	assert(false, "get_vbox_scene() must be implemented in derived class")
	return null

func save_data_if_needed():
	# Override in derived classes if needed
	print("SAVED HERE??")

func create_vbox_memory_list(thread: MemoryThread) -> BaseVBoxMemoryList:
	assert(false, "create_vbox_memory_list() must be implemented in derived class")
	return null

func _ready() -> void:
	var container: = get_tab_container()
	
	container.child_exiting_tree.connect(_on_child_exiting_tree)

	memories_updated.connect(
		func(_thread: MemoryThread):
			save_data_if_needed()
	)

# when a thread is deleted, emit the note deleted manually for each note that was deleted
func _on_child_exiting_tree(node: Node):	
	if node.get_meta("thread"):
		var thread: MemoryThread = node.get_meta("thread")

		var notes_container: BaseVBoxMemoryList = node.get_node(thread.ThreadId)
		
		for note in notes_container.get_children():
			if note is Note:
				note.deleted.emit()


## Return a single large string of all active memories for the given provider.
func to_prompt(provider: BaseProvider) -> Array[Variant]:
	var output: Array[Variant] = []
	
	for this_thread: MemoryThread in get_thread_list():
		for item: MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				output.append(provider.wrap_memory(item))
	
	# loop through detached notes also
	for item in SingletonObject.DetachedNotes:
		if item.Enabled:
			output.append(provider.wrap_memory(item))
	
	return output

#region Notes toggle

func disable_all():
	for this_thread: MemoryThread in get_thread_list():
		for item: MemoryItem in this_thread.MemoryItemList:
			if item.Enabled:
				item.Enabled = false
	
	for item: MemoryItem in SingletonObject.DetachedNotes:
		item.Enabled = false

func enable_all():
	for this_thread: MemoryThread in get_thread_list():
		for item: MemoryItem in this_thread.MemoryItemList:
			if !item.Enabled:
				item.Enabled = true
	
	for item: MemoryItem in SingletonObject.DetachedNotes:
		item.Enabled = true

## Enables all notes in the current active tab.
func enable_notes_in_tab():
	var thread_list = get_thread_list()
	if current_tab >= 0 and current_tab < thread_list.size():
		var currentNotesTab = thread_list[current_tab]
		for item: MemoryItem in currentNotesTab.MemoryItemList:
			if !item.Enabled:
				item.Enabled = true

## Disables all notes in the current active tab.
func disable_notes_in_tab():
	var thread_list = get_thread_list()
	if current_tab >= 0 and current_tab < thread_list.size():
		var currentNotesTab = thread_list[current_tab]
		for item: MemoryItem in currentNotesTab.MemoryItemList:
			if item.Enabled:
				item.Enabled = false

#endregion

func open_threads_popup(tab_name: String = "", tab = null):
	var update = tab != null
	
	# set metadata so we can determine should we create new or update existing and which tab, when we click the button in the popup
	if update:
		SingletonObject.associated_notes_tab.emit(tab_name, get_child(tab))
	else: 
		SingletonObject.pop_up_new_tab.emit()

func _on_btn_create_thread_pressed(tab_name: String, tab_ref: Control = null):
	var thread_for_tab = get_tab_container()
		
	if tab_name.is_empty():
		tab_name = "notes " + str(thread_for_tab.get_tab_count() + 1)
	
	if tab_ref:
		tab_ref.get_meta("thread").ThreadName = tab_name
		# Don't call render_threads() - not needed with new approach
	else:
		create_new_notes_tab(tab_name)
			
	if get_tab_count() > 0:
		buffer_control_notes.hide()

func create_new_notes_tab(tab_name: String = "Notes"):
	print("CREATE NOTES TAB")
	var thread = MemoryThread.new()
	thread.ThreadName = tab_name_to_use(tab_name)
	var thread_memories: Array[MemoryItem] = []
	thread.MemoryItemList = thread_memories
	get_thread_list().append(thread)
	
	setup_thread_container(thread)

## Finds first available name for the tab, appending a number suffix if the name is occupied
func tab_name_to_use(proposed_name: String) -> String:
	var thread_to_use = get_tab_container()
	
	var suffix: = 0
	var available_name: = proposed_name
	var found: = false
	
	while not found: # will break as soon as we find a available name
		if thread_to_use.get_tab_count() == 0:
			break
		
		for i in range(thread_to_use.get_tab_count()):
			if thread_to_use.get_tab_title(i) == available_name:
				found = false
				suffix += 1
				available_name = "%s (%s)" % [proposed_name, suffix]
				break
			else:
				if i == thread_to_use.get_tab_count()-1:
					found = true

	return available_name

func clear_all_tabs():
	var children = get_tab_container().get_children()
	for child in children:
		get_tab_container().remove_child(child)
		child.queue_free()

#region Add notes methods

func add_note(user_title: String, user_content: String, is_completed: bool = true, _source: String = "") -> MemoryItem:
	# get the active thread.
	var active_thread: MemoryThread 
	var current_tab_idx: int
	var thread_list = get_thread_list()

	prints("thread_list", thread_list.size())
	print("=== ADD_NOTE CALLED ===")
	print("Call stack:")
	print(get_stack())
	print("Thread list size: ", get_thread_list().size())

	if thread_list.is_empty():
		create_new_notes_tab()
		
	current_tab_idx = current_tab
	if current_tab_idx < 0:  # If no tab is selected, use the first one
		current_tab_idx = 0
		
	active_thread = thread_list[current_tab_idx]
	
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.UUID = SingletonObject.generate_UUID()
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.TEXT
	new_memory.ContentType = "text"
	new_memory.Title = user_title
	new_memory.Content = user_content
	new_memory.Visible = true
	new_memory.isCompleted = is_completed
	new_memory.isDrawer = false

	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	# Don't call render_threads() - let the VBox handle rendering

	# Explicitly set the current tab after rendering
	current_tab = current_tab_idx
	
	memories_updated.emit(active_thread)
	save_data_if_needed()

	print("HERE HERE")

	return new_memory

func add_audio_note(note_title: String, note_audio: AudioStreamWAV, isDrawer: bool = false) -> MemoryItem:
	# get the active thread.
	var active_thread: MemoryThread 
	var current_tab_idx: int
	var thread_list = get_thread_list()
	
	if thread_list.is_empty():
		create_new_notes_tab("Notes 1")
		
	current_tab_idx = current_tab
	if current_tab_idx < 0:  # If no tab is selected, use the first one
		current_tab_idx = 0
		
	active_thread = thread_list[current_tab_idx]
		
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.UUID = SingletonObject.generate_UUID()
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.AUDIO
	new_memory.ContentType = "audio"
	new_memory.Title = note_title
	new_memory.Audio = note_audio
	new_memory.Visible = true
	
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	# Don't call render_threads() - let the VBox handle rendering

	memories_updated.emit(active_thread)

	# Explicitly set the current tab after rendering
	current_tab = current_tab_idx
	save_data_if_needed()

	return new_memory

func add_image_note(note_title: String, note_image: Image, imageCaption: String = "", isDrawer: bool = false) -> MemoryItem:
	# get the active thread.
	var active_thread: MemoryThread 
	var current_tab_idx: int
	var thread_list = get_thread_list()
	
	if thread_list.is_empty():
		create_new_notes_tab("Notes 1")
		
	current_tab_idx = current_tab
	if current_tab_idx < 0:  # If no tab is selected, use the first one
		current_tab_idx = 0
		
	active_thread = thread_list[current_tab_idx]
		
	# Create a memory item.
	var new_memory: MemoryItem = MemoryItem.new(active_thread.ThreadId)
	new_memory.UUID = SingletonObject.generate_UUID()
	new_memory.Enabled = false
	new_memory.Type = SingletonObject.note_type.IMAGE
	new_memory.ContentType = "image"
	new_memory.Title = note_title
	new_memory.MemoryImage = note_image
	new_memory.ImageCaption = imageCaption
	new_memory.Visible = true

	print(note_image.get_size())
	
	# append the new memory item to the active thread memory list
	active_thread.MemoryItemList.append(new_memory)
	# Don't call render_threads() - let the VBox handle rendering

	memories_updated.emit(active_thread)

	# Explicitly set the current tab after rendering
	current_tab = current_tab_idx
	save_data_if_needed()

	return new_memory

func _wait_for_rendered_note(memory_item: MemoryItem, timeout: = 1.0) -> Note:
	
	var timer: = get_tree().create_timer(timeout)

	while true:
		var note: Note = await note_rendered

		if note.memory_item == memory_item:
			return note

		if timer.time_left == 0:
			break

		await get_tree().process_frame

	return null

## Creates a note without adding it to any thread.
func create_note(title: String, type: SingletonObject.note_type = SingletonObject.note_type.TEXT) -> MemoryItem:
	var new_memory: MemoryItem = MemoryItem.new()
	new_memory.UUID = SingletonObject.generate_UUID()
	new_memory.Enabled = false
	new_memory.Type = type
	new_memory.Title = title
	new_memory.Visible = true

	return new_memory

#endregion Add notes methods

#region Update Notes methods

func update_note(note_UUID: String, new_data: Variant) -> MemoryItem:
	# we check for the note in the current thread so that we dont loop over all the tabs
	if note_UUID == "" or new_data == null:
		return null
		
	var thread_list = get_thread_list()
	if current_tab >= 0 and current_tab < thread_list.size():
		var current_thread: MemoryThread = thread_list[current_tab]
		if current_thread:
			for item in current_thread.MemoryItemList:
				if item.UUID == note_UUID:
					print("found the item in the current thread")
					return update_note_handler(item, new_data)
	
	# if the note is not found in the current thread we loop over all the tabs
	var item: MemoryItem = get_memory_item(note_UUID)
	if item:
		return update_note_handler(item, new_data)
		
	printerr("memory item not found :c")
	return null

func get_memory_item(memory_item_UUID: String) -> MemoryItem:
	for thread: MemoryThread in get_thread_list():
		for item: MemoryItem in thread.MemoryItemList:
			if item.UUID == memory_item_UUID:
				return item
	return null

func update_note_handler(item: MemoryItem, new_data: Variant) -> MemoryItem:
	if item.Type == SingletonObject.note_type.TEXT:
		item.Content = new_data as String
	elif item.Type == SingletonObject.note_type.IMAGE:
		item.MemoryImage = new_data as Image
	elif item.Type == SingletonObject.note_type.AUDIO:
		item.Audio = new_data as AudioStreamWAV
	# Don't call render_threads() - let the VBox handle rendering
	return item

#endregion Update Notes methods

## Will delete the memory_item from the memory list
func delete_note(memory_item: MemoryItem):
	var thread_list = get_thread_list()
	if current_tab >= 0 and current_tab < thread_list.size():
		var active_thread: MemoryThread = thread_list[self.current_tab]
		var idx = active_thread.MemoryItemList.find(memory_item)
		if idx == -1: 
			return
		active_thread.MemoryItemList.remove_at(idx)


func render_threads():
	# Empty - we don't use this approach anymore
	# Notes are rendered through the improved VBox system
	pass

func setup_thread_container(thread_item: MemoryThread):
	prints("setup_thread_container", thread_item)
	# Create the ScrollContainer
	var scroll_container = ScrollContainer.new()
	scroll_container.scroll_vertical = 4060
	scroll_container.follow_focus = true
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Create a custom VBoxContainer derived class
	var vbox_memory_list: = create_vbox_memory_list(thread_item)
	vbox_memory_list.name = thread_item.ThreadId

	# vbox_memory_list.tree_exiting.connect(_on_child_exiting_tree.bind(vbox_memory_list))

	# Add VBoxContainer as a child of the ScrollContainer
	scroll_container.add_child(vbox_memory_list)
	
	scroll_container.set_meta("thread", thread_item) # when the tab is deleted we need to know which thread item to delete
	
	var tab_container = get_tab_container()
	tab_container.add_child(scroll_container)
	
	var tab_idx = tab_container.get_tab_idx_from_control(scroll_container)
	tab_container.set_tab_title(tab_idx, thread_item.ThreadName)

	thread_item.changed.connect(
		func(prop_name: StringName):
			if prop_name == &"ThreadName":
				tab_container.set_tab_title(tab_idx, thread_item.ThreadName)
	)



func _on_close_tab(tab: int, container: TabContainer):
	var control = container.get_tab_control(tab)
	var thread_list = get_thread_list()
	
	# This is the thread index in the list, not it's id
	var thread_idx = thread_list.find(control.get_meta("thread"))
	
	if thread_idx != -1:
		# Remove the thread from the list
		thread_list.remove_at(thread_idx)

		# Store deleted tab for potential undo
		SingletonObject.undo.store_deleted_tab_right(tab, control, "right")
	
	# Remove the tab control from the TabContainer
	container.remove_child(control)
	
	if get_tab_count() < 1:
		buffer_control_notes.show()
	
	print("\nDELETED A TAB DRAWER")

	print("evo ga opet")
	prints(SingletonObject.DrawerTab, self)

	save_data_if_needed()

func restore_deleted_tab(tab_name: String):
	if tab_name in SingletonObject.undo.deleted_tabs:
		var data = SingletonObject.undo.deleted_tabs[tab_name]
		
		var control = data["control"]
		data["timer"].stop()
		# Get the MemoryThread associated with the tab.
		var thread: MemoryThread = control.get_meta("thread")

		# Re-add the MemoryThread to the ThreadList if it's not already present.
		var thread_list = get_thread_list()
		if thread_list.find(thread) == -1:
			thread_list.append(thread)

		# Remove the data from the deleted_tabs dictionary.
		SingletonObject.undo.deleted_tabs.erase(tab_name)
	
func _memory_thread_find(thread_id: String) -> MemoryThread:
	return get_thread_list().filter(
		func(t: MemoryThread):
			return t.ThreadId == thread_id
	).pop_front()

# if we are dragging a note above a tab, we can drop it there
func _can_drop_data(_at_position: Vector2, data):
	return data is Note

# find out which tab we are above
# and get it's vboxMemoryList control (which is the only child of the scroll container)
# then call it's _drop_data so it handles the Note by just appending it and removing it from the old thread
func _drop_data(at_position: Vector2, data):
	if not data is Note: 
		return
	# If no tabs exist, create a new one
	if get_tab_count() <= 0:
		create_new_notes_tab()
	
	# Get tab index - if no tab at position, use current tab
	var tab_idx = get_tab_idx_at_point(at_position)
	if tab_idx == -1:
		tab_idx = current_tab
	
	# Safety check - should never happen but just in case
	if tab_idx == -1 or tab_idx >= get_tab_count():
		return
	
	var control = get_tab_control(tab_idx)
	if not control:
		return
	
	# Get the VBox container - add safety check
	var vbox_memory_list = control.get_child(0) if control.get_child_count() > 0 else null
	if not vbox_memory_list or not vbox_memory_list.has_method("_drop_data"):
		return
	
	# Call the drop method
	vbox_memory_list._drop_data(at_position, data)
	current_tab = tab_idx
	
func _notification(what):
	match what:
		NOTIFICATION_DRAG_BEGIN: _drag_active = true
		NOTIFICATION_DRAG_END: _drag_active = false

#region Tab signal methods

var clicked := -1
var temp_current_tab := -1
var last_clicked_container: TabContainer = null

func _on_tab_clicked(tab: int, container: TabContainer = null):
	if container == null:
		container = get_tab_container()
	last_clicked_container = container
	
	if clicked > -1 and temp_current_tab == tab:
		var tab_title = container.get_tab_bar().get_tab_title(tab)
		open_threads_popup(tab_title, tab)
		return
	
	clicked = tab
	temp_current_tab = tab
	 
	get_tree().create_timer(0.4).timeout.connect(func(): clicked = -1)

func _on_active_tab_rearranged(idx_to: int) -> void:
	var thread_list = get_thread_list()
	var chat_history_to_move: MemoryThread = thread_list[temp_current_tab]
	thread_list.pop_at(temp_current_tab)
	thread_list.insert(idx_to, chat_history_to_move)
	temp_current_tab = current_tab

#endregion Tab signal methods
