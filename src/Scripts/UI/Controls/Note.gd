class_name Note
extends VBoxContainer

signal note_deleted()

@onready var checkbutton_node: CheckButton = %CheckButton
@onready var label_node: LineEdit = %Title
@onready var description_node: RichTextLabel = %NoteTextBody
@onready var drag_texture_rect: TextureRect = $PanelContainer/v/DragTextureRect
@onready var note_image: TextureRect = %NoteImage
@onready var audio_stream_player: AudioStreamPlayer = %AudioStreamPlayer
@onready var image_caption_line_edit: LineEdit = %ImageCaptionLineEdit

@onready var _upper_separator: HSeparator = %UpperSeparator
@onready var _lower_separator: HSeparator = %LowerSeparator

var downscaled_image: Image
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
			if value.MemoryImage:
				set_note_image(value.MemoryImage)
			image_caption_line_edit.text = value.ImageCaption
		if memory_item.Type == SingletonObject.note_type.AUDIO:
			audio_stream_player.stream = value.Audio
		
		# If we create a note, open a editor associated with it and then rerender the memory_item
		# that will create completly new Note node and break the connection between note and the editor.
		# So here we check if there's editor associated with memory_item this note is rendering.
		for editor in SingletonObject.editor_container.editor_pane.Tabs.get_children():
			if editor.has_meta("associated_object") and editor.get_meta("associated_object") == memory_item:
				associate_editor(editor)

#region New notes methods

func new_text_note():
	%NoteTextBody.set_deferred("visible", true)#.visible = true
	%ImageVBoxContainer.visible = false
	%AudioHBoxContainer.visible = false
	%ImageVBoxContainer.call_deferred("queue_free")
	%AudioHBoxContainer.call_deferred("queue_free")
	return self


func new_image_note():
	%ImageVBoxContainer.visible = true
	%AudioHBoxContainer.visible = false
	%NoteTextBody.visible = false
	%AudioHBoxContainer.call_deferred("queue_free")
	%NoteTextBody.call_deferred("queue_free")
	return self


func new_audio_note():
	%AudioHBoxContainer.visible = true
	%NoteTextBody.visible = false
	%EditButton.visible = false
	%ImageVBoxContainer.visible = false
	%NoteTextBody.call_deferred("queue_free")
	%ImageVBoxContainer.call_deferred("queue_free")
	return self

#endregion New notes methods

# FIXME maybe we could move this function to Singleton so all images 
# can be resized and add another paremeter to place the 200 constant
#  this method resizes the image so the texture rec doesn't render images at full res
func downscale_image(image: Image) -> Image:
	if image == null: return
	var image_size = image.get_size()
	if image_size.y > 200:
		var image_ratio = image_size.y/ 200.0
		image_size.y = image_size.y / image_ratio
		image_size.x = image_size.x / image_ratio
		image.resize(image_size.x, image_size.y, Image.INTERPOLATE_LANCZOS)
	return image


# set the image of the note to the given image
func set_note_image(image: Image) -> void:
	# create a copy of a image so we don't downscale the original
	if image == null: return
	downscaled_image = Image.new()
	downscaled_image.copy_from(image)
	
	downscaled_image = downscale_image(downscaled_image)
	
	var image_texture = ImageTexture.new()
	image_texture.set_image(downscaled_image)
	note_image.texture = image_texture



func _ready():
	# connecting signal for changing the dots texture when the main theme changes
	SingletonObject.theme_changed.connect(change_modulate_for_texture)
	change_modulate_for_texture(SingletonObject.get_theme_enum())
	# var new_size: Vector2 = size * 0.15
	# set_size(new_size)
	label_node.text_changed.connect(
		func(text):
			if memory_item: memory_item.Title = text
	)
	
	%ProgressBar.value = audio_progress

#method for changing the dots texture when the main theme changes
func change_modulate_for_texture(theme_enum: int):
	#var theme_enum = SingletonObject.get_theme()
	if theme_enum == SingletonObject.theme.LIGHT_MODE:
		drag_texture_rect.modulate = Color("282828")
	if theme_enum == SingletonObject.theme.DARK_MODE:
		drag_texture_rect.modulate = Color("f0f0f0")


func _to_string():
	return "Notedadsa %s" % memory_item.Title

# check if we are showing the separator.
# if yes that means we were dragging the note above this note
# but if the mouse is not above this note anymore, hide the separators
func _process(_delta):
	if memory_item:
		if memory_item.Type == SingletonObject.note_type.AUDIO:
			if audio_stream_player.is_playing():
				update_progress_bar()
	
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

	preview.custom_minimum_size = size
	preview_note.custom_minimum_size = size

	preview_note.position = -at_position

	var tween = get_tree().create_tween()
	tween.tween_property(preview, "modulate:a", 0.5, 0.2)

	# preview.modulate.a = 0.5

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

## Connects this note and the given [parameter editor]
## by making editor save button update the memory_item and
## reflecting note title chage into the tab title.
func associate_editor(editor: Editor):
	editor.override_save(
		func():
			if editor.type == Editor.Type.NOTE_EDITOR:
				memory_item.Content = editor.code_edit.text
			elif editor.type == Editor.Type.GRAPHICS:
				memory_item.MemoryImage = editor.graphics_editor.image
			
			memory_item = memory_item
	)

	label_node.text_changed.connect(
		func(text):
			editor.name = text
	)

	editor.set_meta("associated_object", memory_item)


func _on_edit_button_pressed():
	var ep: EditorPane = SingletonObject.editor_container.editor_pane

	# show the editor if it's hidden
	SingletonObject.main_ui.set_editor_pane_visible(true)

	# Try to find editor that's already assiciated with memory_item
	# this note is rendering so we don't end up duplicating them.
	for i in range(ep.Tabs.get_tab_count()):
		var tab_control = ep.Tabs.get_tab_control(i)

		if tab_control.has_meta("associated_object"):
			if tab_control.get_meta("associated_object") == memory_item:
				ep.Tabs.current_tab = i # change the current tab to that editor
				return

	var editor: Editor

	if memory_item.MemoryImage:
		SingletonObject.is_graph = true
		editor = ep.add(Editor.Type.GRAPHICS, null, memory_item.Title)
		editor.graphics_editor.setup_from_image(memory_item.MemoryImage)
	else:
		editor = ep.add(Editor.Type.NOTE_EDITOR, null, memory_item.Title)
		editor.code_edit.text = memory_item.Content

	associate_editor(editor)


func _on_hide_button_pressed():
	
	var tween = get_tree().create_tween()
	tween.tween_property(self, "modulate:a", 0, 0.2)
	tween.tween_callback(
		func():
			memory_item.Visible = false
			memory_item = memory_item
	)


func _on_title_text_submitted(new_text: String) -> void:
	label_node.release_focus()
	if memory_item: memory_item.Title = new_text


func _on_image_caption_line_edit_text_submitted(new_text: String) -> void:
	image_caption_line_edit.release_focus()
	if memory_item: memory_item.ImageCaption = new_text


func _on_image_caption_line_edit_text_changed(new_text: String) -> void:
	if memory_item: memory_item.ImageCaption = new_text


#region Audio controls
var audio_progress: = 0.0

func _on_play_button_pressed() -> void:
	%ProgressBar.max_value = audio_stream_player.stream.get_length()
	
	if audio_stream_player.stream_paused:
		audio_stream_player.play(audio_progress)
	else:
		audio_stream_player.play()


func _on_stop_button_pressed() -> void:
	audio_stream_player.stop()
	audio_progress = 0.0
	%ProgressBar.value = audio_progress


func _on_pause_button_pressed() -> void:
	audio_progress = %AudioStreamPlayer.get_playback_position()
	audio_stream_player.stream_paused = true


func _on_audio_stream_player_finished() -> void:
	pass
	#audio_progress = 0.0
	#%ProgressBar.value = audio_progress


func update_progress_bar() -> void:
	%ProgressBar.value = audio_stream_player.get_playback_position()

#endregion Audio controls

#region Paste image 

func _on_image_v_box_container_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				pass
			MOUSE_BUTTON_RIGHT:
				print("right click")
				paste_image_from_clipboard()


# check if display server can paste image from clipboard and does so
func paste_image_from_clipboard():
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		if OS.get_name() == "Windows":
			if DisplayServer.clipboard_has_image():
				var image = DisplayServer.clipboard_get_image()
				memory_item.MemoryImage = image
				set_note_image(image)
		
		if OS.get_name() == "Linux":
			if DisplayServer.clipboard_has():
				var path = DisplayServer.clipboard_get().split("\n")[0]
				var file_format = get_file_format(path)
				if file_format in SingletonObject.supported_image_formats:
					var image = Image.new()
					image.load(path)
					memory_item.MemoryImage = image
					set_note_image(image)
				else:
					print_rich("[b]file format not supported :c[/b]")
			else:
				print("no image to put here")
	else: 
		print("Display Server does not support clipboard feature :c, its a godot thing")


func get_file_format(path: String) -> String:
	return path.split(".")[path.split(".").size() -1]


#endregion Paste image 
