class_name Note
extends VBoxContainer

signal note_deleted()

@onready var checkbutton_node: CheckButton = %CheckButton
@onready var label_node: LineEdit = %Title
@onready var description_node: RichTextLabel = %Description

@onready var _upper_separator: HSeparator = %UpperSeparator
@onready var _lower_separator: HSeparator = %LowerSeparator


# this will react each time memory item is changed
var memory_item: MemoryItem:
	set(value):
		memory_item = value

		if not value: return

		label_node.text = value.Title
		description_node.text = value.Content
		checkbutton_node.button_pressed = value.Enabled


func _ready():
	var new_size: Vector2 = size * 0.15
	set_size(new_size)
	label_node.text_changed.connect(
		func(text):
			if memory_item: memory_item.Title = text
	)


func _to_string():
	return "Note %s" % memory_item.Title

# check if we are showing the separator.
# if yes that means we were dragging the note above this note
# but if the mouse is not above this note anymore, hide the separators
func _process(_delta):
	if not _upper_separator.visible and not _lower_separator.visible: return

	if not get_global_rect().has_point(get_global_mouse_position()):
		_upper_separator.visible = false
		_lower_separator.visible = false

func _notification(notification_type):
	match notification_type:
		NOTIFICATION_DRAG_END:
			description_node.mouse_filter = Control.MOUSE_FILTER_STOP

			_lower_separator.visible = false
			_upper_separator.visible = false

			SingletonObject.NotesTab.render_threads()
		
		NOTIFICATION_DRAG_BEGIN:
			description_node.mouse_filter = Control.MOUSE_FILTER_PASS

# create a preview which is just duplicated Note node
# and make the original node transparent
func _get_drag_data(at_position: Vector2) -> Note:
	var preview = Control.new()
	var preview_note: Note = duplicate()

	preview.add_child(preview_note)

	preview_note.size = size
	preview.size = size

	preview_note.position = -at_position

	preview.modulate.a = 0.5

	set_drag_preview(preview)

	get_parent().remove_child(self)

	return self

func _can_drop_data(at_position: Vector2, data):
	if not data is Note: return false

	if data == self: return false

	if at_position.y < size.y / 2:
		_upper_separator.visible = true
		_lower_separator.visible = false
	else:
		_lower_separator.visible = true
		_upper_separator.visible = false

	return true

func _memory_thread_find(thread_id: String) -> MemoryThread:
	return SingletonObject.ThreadList.filter(
		func(t: MemoryThread):
			return t.ThreadId == thread_id
	).pop_front()


func _drop_data(_at_position: Vector2, data):
	data = data as Note

	# dragged note should be moved to thread where 'self' is 
	# at 'insert_index'
	var insert_index: int

	if data == self: return

	# thread where dragged note is currently
	var dragged_note_thread := _memory_thread_find(data.memory_item.OwningThread)
	
	# if dragged note and the note we're dropping on to are not in same tabs
	# it meands we have to deal with two different MemoryThreads
	if memory_item.OwningThread != data.memory_item.OwningThread:
		
		var target_note_thread := _memory_thread_find(memory_item.OwningThread)

		if _upper_separator.visible:
			insert_index = target_note_thread.MemoryItemList.find(memory_item)
		elif _lower_separator.visible:
			insert_index = target_note_thread.MemoryItemList.find(memory_item)+1
		
		dragged_note_thread.MemoryItemList.erase(data.memory_item)
		target_note_thread.MemoryItemList.insert(insert_index, data.memory_item)

		data.memory_item.OwningThread = target_note_thread.ThreadId
	
	else:
		dragged_note_thread.MemoryItemList.erase(data.memory_item)

		if _upper_separator.visible:
			insert_index = dragged_note_thread.MemoryItemList.find(memory_item)
		elif _lower_separator.visible:
			insert_index = dragged_note_thread.MemoryItemList.find(memory_item)+1

		dragged_note_thread.MemoryItemList.insert(insert_index, data.memory_item)



func _on_check_button_toggled(toggled_on: bool) -> void:
	if memory_item:
		memory_item.Enabled = toggled_on


func _on_remove_button_pressed():
	pivot_offset = size / 2

	var tween = get_tree().create_tween()
	tween.tween_property(self, "scale", Vector2.ZERO, 0.3)
	tween.tween_callback(queue_free)

	note_deleted.emit()



func _on_edit_button_pressed():
	var ep: EditorPane = $"/root/RootControl/VBoxRoot/MainUI/HSplitContainer/HSplitContainer2/MiddlePane/VBoxContainer/vboxEditorMain/EditorPane"

	for i in range(ep.Tabs.get_tab_count()):
		var tab_control = ep.Tabs.get_tab_control(i)

		if tab_control.get_meta("associated_object") == memory_item:
			ep.Tabs.current_tab = i
			return

	var note_editor = NoteEditor.create(memory_item)

	note_editor.on_memory_item_changed.connect(func(): memory_item = note_editor.memory_item)

	var container = ep.add_control(note_editor, memory_item.Title)

	container.set_meta("associated_object", memory_item)

	# also change tab title if title has changed
	label_node.text_changed.connect(
		func(text):
			container.name = text
	)

	# show the editor if it's hidden
	SingletonObject.main_ui.set_editor_pane_visible(true)
