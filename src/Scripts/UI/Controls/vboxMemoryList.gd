extends VBoxContainer

var Memories: Array[MemoryItem] = []
var MainTabContainer
var MainThreadId

## initilize the box
func _init(_parent, _threadId, _mem = null):
	self.MainTabContainer = _parent
	self.MainThreadId = _threadId
	self.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	self.size_flags_vertical = Control.SIZE_EXPAND_FILL

	if _mem != null:
		self.Memories = _mem
		render_items()
	pass


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

func render_items():
	for item in Memories:
		var note_control: Note = load("res://Scenes/Note.tscn").instantiate()
		
		self.add_child.call_deferred(note_control)
		await note_control.ready

		note_control.memory_item = item

		# when the note control is deleted, delete the memory item, so it doesnt get rerendered next time
		note_control.note_deleted.connect(self.MainTabContainer.delete_note.bind(item))


func _memory_thread_find(thread_id: String) -> MemoryThread:
	return SingletonObject.ThreadList.filter(
		func(t: MemoryThread):
			return t.ThreadId == thread_id
	).pop_front()

# we can also drop the Note in a vBoxMemoryList
func _can_drop_data(_at_position: Vector2, data):
	if not data is Note: return
	return true


func _drop_data(_at_position: Vector2, data):
	if not data is Note: return

	var target_thread = _memory_thread_find(MainThreadId)

	var dragged_note_thread = _memory_thread_find(data.memory_item.OwningThread)

	dragged_note_thread.MemoryItemList.erase(data.memory_item)

	target_thread.MemoryItemList.append(data.memory_item)

	data.memory_item.OwningThread = target_thread.ThreadId
