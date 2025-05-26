extends VBoxContainer

var Memories: Array[MemoryItem] = []
var MainTabContainer
var MainThreadId
var disable_notes_button
## initialize the box
func _init(_parent, _threadId, _mem = null):

	# we add separation between the children of the HBoxContainer
	add_theme_constant_override("Separation", 12)
	
	#we add a disable notes button
	add_child(initialize_disable_button())
	
	self.MainTabContainer = _parent
	self.MainThreadId = _threadId
	self.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	self.size_flags_vertical = Control.SIZE_EXPAND_FILL

	if _mem != null:
		self.Memories = _mem
		render_items()
	pass

#create a check button for toggling enabled notes 
func initialize_disable_button() -> CheckButton:
	disable_notes_button = CheckButton.new()
	disable_notes_button.text = "Notes Enabled"
	disable_notes_button.button_pressed = false
	disable_notes_button.size_flags_horizontal = Control.SIZE_SHRINK_END
	disable_notes_button.alignment = 2# we use a constant for the alignment (RIGHT)
	disable_notes_button.toggled.connect(_on_toggled_disable_notes_button)
	return disable_notes_button


func _on_toggled_disable_notes_button(toggled_on: bool) -> void:
	if toggled_on:
		disable_notes_button.text = "Notes Enabled"
		toggle_notes(toggled_on)
	if !toggled_on:
		disable_notes_button.text = "Notes Disabled"
		toggle_notes(toggled_on)


func toggle_notes(toggled_on: bool) -> void:
	var notes = get_children()
	for note in notes:
		if note.is_in_group("notes_in_tab"):
			if toggled_on:
				note.checkbutton_node.button_pressed = true
			if !toggled_on:
				note.checkbutton_node.button_pressed = false

## goes trough note nodes and updates the memory item order accordingly
func _update_memory_item_order():
	var i = 0
	for note in get_children():
		if not note is Note: continue
		note.memory_item.Order = i
		i += 1

func _notification(notification_type):
	match notification_type:
		# Change MemoryItem Order when notes order changes
		NOTIFICATION_CHILD_ORDER_CHANGED:
			if is_inside_tree(): _update_memory_item_order()
		NOTIFICATION_ENTER_TREE:
			_update_memory_item_order()
		# When the drag is over, maybe the order of notes changed, so rerender them
		NOTIFICATION_DRAG_END:
			_update_memory_item_order()
			
			if SingletonObject.notes_draw_state != SingletonObject.NotesDrawState.DRAWING:
				render_items()


func render_items():

	# Clear existing children
	for child in get_children():
		if child is Note:
			child.queue_free()

	# Re-add memory items
	for item in Memories:
		var note_control: Note = SingletonObject.notes_scene.instantiate()
		#checks how the note is going to be rendered
		
		if item.Type == SingletonObject.note_type.TEXT:
			note_control.new_text_note()
		elif item.Type == SingletonObject.note_type.IMAGE:
			note_control.new_image_note()
		elif item.Type == SingletonObject.note_type.AUDIO:
			note_control.new_audio_note()
		elif item.Type == SingletonObject.note_type.VIDEO:
			note_control.new_video_note()
			
		note_control.add_to_group("notes_in_tab")# add to a group for enabling the notes
		self.add_child.call_deferred(note_control)
		await note_control.ready

		note_control.memory_item = item
		
		#note_control.add_to_group("notes_in_tab")# add to a group for enabling the notes
#
		#self.add_child(note_control)

		# When the note control is deleted, delete the memory item, so it doesn't get re-rendered next time
		note_control.deleted.connect(self.MainTabContainer.delete_note.bind(item))
		
		note_control.changed.connect(SingletonObject.note_changed.emit.bind(note_control))

		# can't use bind because of the order of the parameters
		note_control.toggled.connect(
			func(on: bool):
				SingletonObject.note_toggled.emit(note_control, on)
		)

func _memory_thread_find(thread_id: String) -> MemoryThread:
	return SingletonObject.ThreadList.filter(
		func(t: MemoryThread):
			return t.ThreadId == thread_id
	).pop_front()
	
func _drawer_thread_find(thread_id: String) -> MemoryThread:
	return SingletonObject.DrawerThreadList.filter(
		func(t: MemoryThread):
			return t.ThreadId == thread_id
	).pop_front()

# We can also drop the Note in a VBoxMemoryList
func _can_drop_data(_at_position: Vector2, data):
	if not data is Note: return false
	return true

func _drop_data(_at_position: Vector2, data):
	if not data is Note: 
		return

	# 1. Print UUID of the note being dropped
	print("Dropping note UUID: ", data.memory_item.UUID)

	# Find which type of thread we're dropping into
	var target_thread = _memory_thread_find(MainThreadId)
	var target_drawer_thread = _drawer_thread_find(MainThreadId)

	# 2. Print all UUIDs in the target thread
	if target_thread:
		print("UUIDs in target thread:")
		for item in target_thread.MemoryItemList:
			print("- ", item.UUID)
	elif target_drawer_thread:
		print("UUIDs in target drawer thread:")
		for item in target_drawer_thread.MemoryItemList:
			print("- ", item.UUID)

	# Rest of your existing drop logic...
	var dragged_note_thread = _memory_thread_find(data.memory_item.OwningThread)
	var dragged_note_drawer_thread = _drawer_thread_find(data.memory_item.OwningThread)

	if target_thread and dragged_note_thread:
		target_thread.MemoryItemList.insert(0, data.memory_item)
		data.memory_item.OwningThread = target_thread.ThreadId
		dragged_note_thread.MemoryItemList.erase(data.memory_item)
		
	elif target_drawer_thread and dragged_note_drawer_thread:
		target_drawer_thread.MemoryItemList.insert(0, data.memory_item)
		data.memory_item.OwningThread = target_drawer_thread.ThreadId
		dragged_note_drawer_thread.MemoryItemList.erase(data.memory_item)
		
	elif target_thread and dragged_note_drawer_thread:
		SingletonObject.notes_draw_state_changed.emit(SingletonObject.NotesDrawState.DRAWING)
		if data.memory_item.Type == 0:
			SingletonObject.NotesTab.add_note(data.memory_item.Title, data.memory_item.Content)
		elif data.memory_item.Type == 1:
			SingletonObject.NotesTab.add_audio_note(data.memory_item.Title, data.memory_item.Audio)
		elif data.memory_item.Type == 2:
			SingletonObject.NotesTab.add_image_note(data.memory_item.Title, data.memory_item.MemoryImage, data.memory_item.ImageCaption)
			
	elif target_drawer_thread and dragged_note_thread:
		SingletonObject.notes_draw_state_changed.emit(SingletonObject.NotesDrawState.DRAWING)
		if data.memory_item.Type == 0:
			SingletonObject.NotesTab.add_note(data.memory_item.Title, data.memory_item.Content, true)
		elif data.memory_item.Type == 1:
			SingletonObject.NotesTab.add_audio_note(data.memory_item.Title, data.memory_item.Audio, true)
		elif data.memory_item.Type == 2:
			SingletonObject.NotesTab.add_image_note(data.memory_item.Title, data.memory_item.MemoryImage, data.memory_item.ImageCaption, true)
