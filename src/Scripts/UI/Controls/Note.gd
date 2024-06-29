class_name Note
extends VBoxContainer

signal note_deleted()

@onready var checkbutton_node: CheckButton = %CheckButton
@onready var label_node: LineEdit = %Title
@onready var description_node: RichTextLabel = %NoteTextBody
@onready var drag_texture_rect: TextureRect = $PanelContainer/v/DragTextureRect
@onready var note_image: TextureRect = %NoteImage
@onready var audio_stream_player: AudioStreamPlayer = %AudioStreamPlayer

@onready var _upper_separator: HSeparator = %UpperSeparator
@onready var _lower_separator: HSeparator = %LowerSeparator


# this will react each time memory item is changed
var memory_item: MemoryItem:
	set(value):
		memory_item = value

		if not value: return

		label_node.text = value.Title
		checkbutton_node.button_pressed = value.Enabled
		visible = value.Visible
		if memory_item.Type == SingletonObject.note_type.TEXT:
			description_node.text = value.Content
		if memory_item.Type == SingletonObject.note_type.IMAGE:
			var image_texture = ImageTexture.new()
			image_texture.set_image(value.image)
			note_image.texture = image_texture
		if memory_item.Type == SingletonObject.note_type.AUDIO:
			audio_stream_player.stream = value.audio

func new_text_note():
	%NoteTextBody.visible = true
	%ImageVBoxContainer.visible = false
	%AudioHBoxContainer.visible = false
	return self


func new_image_note():
	%ImageVBoxContainer.visible = true
	%AudioHBoxContainer.visible = false
	%NoteTextBody.visible = false
	return self


func new_audio_note():
	%AudioHBoxContainer.visible = true
	%NoteTextBody.visible = false
	%ImageVBoxContainer.visible = false
	return self



func _ready():
	# connecting signal for changing the dots texture when the main theme changes
	SingletonObject.theme_changed.connect(change_modulate_for_texture)
	change_modulate_for_texture()
	
	var new_size: Vector2 = size * 0.15
	set_size(new_size)
	label_node.text_changed.connect(
		func(text):
			if memory_item: memory_item.Title = text
	)

#method for changing the dots texture when the main theme changes
func change_modulate_for_texture():
	var theme_enum = SingletonObject.get_theme()
	if theme_enum == SingletonObject.theme.LIGHT_MODE:
		drag_texture_rect.modulate = Color("282828")
	if theme_enum == SingletonObject.theme.DARK_MODE:
		drag_texture_rect.modulate = Color("f0f0f0")


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


func _on_hide_button_pressed():
	
	var tween = get_tree().create_tween()
	tween.tween_property(self, "modulate:a", 0, 0.2)
	tween.tween_callback(
		func():
			memory_item.Visible = false
			memory_item = memory_item
	)


func _on_title_text_submitted(_new_text: String) -> void:
	%Title.release_focus()


func _on_image_caption_line_edit_text_submitted(_new_text: String) -> void:
	%ImageCaptionLineEdit.release_focus()



func _on_play_pause_button_pressed() -> void:
	if audio_stream_player.playing:
		audio_stream_player.stop()
	else: 
		audio_stream_player.play()
