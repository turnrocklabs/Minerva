extends VBoxContainer

var Memories: Array[MemoryItem] = []
var MainTabContainer
var MainThreadId
var disable_notes_button
## initilize the box
func _init(_parent, _threadId, _mem = null):
	# we add separateionh for the chidren of the HBoxContainer
	add_theme_constant_override("Separation", 12)
	
	#we add a disable notes button
	add_child(initialise_disable_button())
	
	self.MainTabContainer = _parent
	self.MainThreadId = _threadId
	self.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	self.size_flags_vertical = Control.SIZE_EXPAND_FILL

	if _mem != null:
		self.Memories = _mem
		render_items()
	pass

#create a checkbutton for toggling enabled notes 
func initialise_disable_button() -> CheckButton:
	disable_notes_button = CheckButton.new()
	disable_notes_button.text = "Notes Enabled"
	disable_notes_button.button_pressed = false
	disable_notes_button.alignment = 2# we use a constant for the aligmanet (RIGHT)
	disable_notes_button.toggled.connect(_on_toggled_diable_notes_button)
	return disable_notes_button


func _on_toggled_diable_notes_button(toggled_on: bool) -> void:
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
			render_items()  # Re-render items after drag ends

func render_items():
	# Clear existing children
	for child in get_children():
		if child is Note:
			child.queue_free()
			
	# Re-add memory items
	for item in Memories:
		var note_control: Note = load("res://Scenes/Note.tscn").instantiate()
		#checks how the note is going to be rendered
		if item.Type == SingletonObject.note_type.TEXT:
			note_control.new_text_note()
		if item.Type == SingletonObject.note_type.IMAGE:
			note_control.new_image_note()
		if item.Type == SingletonObject.note_type.AUDIO:
			note_control.new_audio_note()
		
		note_control.add_to_group("notes_in_tab")# add to a group for enabling the notes
		self.add_child.call_deferred(note_control)
		await note_control.ready

		note_control.memory_item = item

		# When the note control is deleted, delete the memory item, so it doesn't get re-rendered next time
		note_control.note_deleted.connect(self.MainTabContainer.delete_note.bind(item))

func _memory_thread_find(thread_id: String) -> MemoryThread:
	return SingletonObject.ThreadList.filter(
		func(t: MemoryThread):
			return t.ThreadId == thread_id
	).pop_front()

# We can also drop the Note in a VBoxMemoryList
func _can_drop_data(_at_position: Vector2, data):
	if not data is Note: return false
	return true

func _drop_data(_at_position: Vector2, data):
	if not data is Note: return

	var target_thread = _memory_thread_find(MainThreadId)
	var dragged_note_thread = _memory_thread_find(data.memory_item.OwningThread)

	dragged_note_thread.MemoryItemList.erase(data.memory_item)
	target_thread.MemoryItemList.insert(0, data.memory_item)
	data.memory_item.OwningThread = target_thread.ThreadId
