class_name Note
extends VBoxContainer

signal deleted()
signal toggled(on: bool)

## This signal is emitted each time the underlying memory item has been updated.
signal changed()

var isDrawer:bool = false

@export_range(0.1, 2.0, 0.1) var expand_anim_duration: float = 0.5
@export var expand_transition_type: Tween.TransitionType = Tween.TRANS_SPRING
@export var expand_ease_type: Tween.EaseType = Tween.EASE_OUT
@export var expand_icon_color: Color = Color.WHITE
@export var max_note_size_limit: int = 400
@export var min_note_size_limit: int = 30

@onready var checkbutton_node: CheckButton = %CheckButton
@onready var label_node: LineEdit = %Title
@onready var description_node: RichTextLabel = %NoteTextBody
@onready var drag_texture_rect: TextureRect = %DragTextureRect
@onready var video_label: Label = %VideoLabel
@export var video_player_container: VBoxContainer
@onready var _upper_separator: HSeparator = %UpperSeparator
@onready var _lower_separator: HSeparator = %LowerSeparator
@onready var v_box_container: VBoxContainer = %vBoxContainer
@onready var expand_button: Button = %ExpandButton
@onready var resize_drag_control: Control = %ResizeControl
@onready var h_separator: HSeparator = %HSeparator


var expanded: bool = true:
	set(value):
		expanded = value
		memory_item.Expanded = value

var last_min_size: float = 100.0:
	set(value):
		if value > 0:
			if memory_item:
				memory_item.LastYSize = value
			if control_type and control_type.custom_minimum_size.y != value:
				control_type.custom_minimum_size.y = value
			last_min_size = value


var control_type: Control
var downscaled_image: Image
# this will react each time memory item is changed
var memory_item: MemoryItem:
	set(value):
		memory_item = value

		if not value: return

		if not is_node_ready(): await ready

		label_node.text = value.Title
		checkbutton_node.button_pressed = value.Enabled
		visible = value.Visible
		if memory_item.Type == SingletonObject.note_type.TEXT:
			description_node.text = value.Content
			control_type = description_node
		if memory_item.Type == SingletonObject.note_type.IMAGE:
			
			%EditButton.visible = SingletonObject.experimental_enabled
			if value.MemoryImage:
				var image_controls_inst: = SingletonObject.image_controls_scene.instantiate()
				image_controls_inst.memory_item = value
				v_box_container.add_child(image_controls_inst)
				control_type = image_controls_inst
				last_min_size = image_controls_inst.size.y
		if memory_item.Type == SingletonObject.note_type.AUDIO:
			var audio_control_inst: = SingletonObject.audio_contols_scene.instantiate()
			audio_control_inst.audio = value.Audio
			v_box_container.add_child(audio_control_inst)
			control_type = audio_control_inst
			v_box_container.move_child(resize_drag_control,v_box_container.get_child_count())
		if memory_item.Type == SingletonObject.note_type.VIDEO:
			%EditButton.visible = false
			var video_player_node: = SingletonObject.video_player_scene.instantiate()
			video_label.text = "%s %s" % [value.Title, value.ContentType]
			video_player_node.video_path = value.Content
			video_player_container.add_child(video_player_node)
			control_type = video_player_container
		
		if memory_item.LastYSize > min_note_size_limit:
			last_min_size = memory_item.LastYSize
		else:
			if control_type:
				last_min_size = control_type.custom_minimum_size.y
		
		expanded = memory_item.Expanded
		if !memory_item.Expanded:
			if last_min_size == 0:
				last_min_size = 100
				if control_type:
					control_type.custom_minimum_size.y = last_min_size
				resize_drag_control.custom_minimum_size.y = 10
				expand_button.rotation = deg_to_rad(0.0)
				expand_button.modulate = Color.WHITE
				video_label.show()
				control_type.show()
				resize_drag_control.show()
			else:
				if control_type:
					control_type.custom_minimum_size.y = 0
					resize_drag_control.custom_minimum_size.y = 0
					expand_button.rotation = deg_to_rad(-90.0)
					expand_button.modulate = expand_icon_color
					video_label.hide()
					control_type.hide()
					resize_drag_control.hide()
		expand_button.disabled = false
		
		v_box_container.move_child(resize_drag_control,v_box_container.get_child_count())
		# If we create a note, open a editor associated with it and then rerender the memory_item
		# that will create completely new Note node and break the connection between note and the editor.
		# So here we check if there's editor associated with memory_item this note is rendering.
		for editor in SingletonObject.editor_container.editor_pane.Tabs.get_children():
			if editor.associated_object is MemoryItem:
				if editor.associated_object == memory_item:
					associate_editor(editor)
		
		changed.emit()

#region New notes methods

func new_text_note():
	%NoteTextBody.set_deferred("visible", true)
	return self


func new_image_note():
	%NoteTextBody.visible = false
	return self


func new_audio_note():
	%NoteTextBody.visible = false
	%EditButton.visible = false
	return self


func new_video_note():
	%NoteTextBody.visible = false
	%VideoVBoxContainer.visible = true


#endregion New notes methods

# TODO maybe we could move this function to Singleton so all images 
# can be resized and add another parameter to place the 200 constant
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


func _ready():
	# connecting signal for changing the dots texture when the main theme changes
	SingletonObject.theme_changed.connect(change_modulate_for_texture)
	description_node.text = ""
	#change_modulate_for_texture(SingletonObject.get_theme_enum())
	# var new_size: Vector2 = size * 0.15
	# set_size(new_size)
	label_node.text_changed.connect(
		func(text):
			if memory_item: memory_item.Title = text
	)


func _exit_tree() -> void:
	if has_meta("associated_editor"):
		var editor: Editor = get_meta("associated_editor")
		if is_instance_valid(editor):
			editor.associated_object = null


#method for changing the dots texture when the main theme changes
func change_modulate_for_texture(theme_enum: int):
	#var theme_enum = SingletonObject.get_theme()
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
	var preview_note:  = duplicate(true)

	preview.add_child(preview_note)

	preview.custom_minimum_size = size
	preview_note.custom_minimum_size = size
	preview.rotation_degrees = 3.0
	preview_note.position = -at_position

	var tween = get_tree().create_tween()
	tween.tween_property(preview, "modulate:a", 0.5, 0.2)

	# preview.modulate.a = 0.5

	set_drag_preview(preview)

	#get_parent().remove_child(self)

	return self


func _can_drop_data(at_position: Vector2, data) -> bool:
	if not data is Note: return false
	if data == self: return false

	if at_position.y < size.y / 2:
		_upper_separator.visible = true
		_lower_separator.visible = false
	else:
		_lower_separator.visible = true
		_upper_separator.visible = false
	return true
	

func _memory_thread_find(thread_id: String, note_type) -> MemoryThread:
	return note_type.filter(
		func(t: MemoryThread):
			return t.ThreadId == thread_id
	).pop_front()


func _drop_data(_at_position: Vector2, data) -> void:
	if not data is Note: return
	if data == self: return

	# Combine all possible thread locations
	var all_threads = SingletonObject.ThreadList + SingletonObject.DrawerThreadList
	
	# Find current and target threads
	var target_thread = all_threads.filter(
		func(t): return t.ThreadId == memory_item.OwningThread
	).front()
	var source_thread = all_threads.filter(
		func(t): return t.ThreadId == data.memory_item.OwningThread
	).front()

	if not target_thread or not source_thread:
		return

	# Calculate insert position
	var target_pos = target_thread.MemoryItemList.find(memory_item)
	var insert_index = target_pos
	if _upper_separator.visible:
		insert_index = target_pos
	elif _lower_separator.visible:
		insert_index = target_pos + 1

	# Only remove from source if moving within the same thread
	if source_thread == target_thread:
		var current_index = source_thread.MemoryItemList.find(data.memory_item)
		if current_index >= 0:
			source_thread.MemoryItemList.remove_at(current_index)
			
			# Adjust index if moving within same thread
			if current_index < insert_index:
				insert_index -= 1

	# Insert into target
	if insert_index >= 0 and insert_index <= target_thread.MemoryItemList.size():
		target_thread.MemoryItemList.insert(insert_index, data.memory_item)
		data.memory_item.OwningThread = target_thread.ThreadId

	# Hide separators
	_upper_separator.visible = false
	_lower_separator.visible = false
func _on_check_button_toggled(toggled_on: bool) -> void:
	if memory_item:
		memory_item.Enabled = toggled_on
	toggled.emit(toggled_on)


func _on_remove_button_pressed():
	pivot_offset = size / 2

	var tween = get_tree().create_tween()
	tween.tween_property(self, "scale", Vector2.ZERO, 0.3)
	tween.tween_callback(queue_free)

	deleted.emit()

## Connects this note and the given [parameter editor] and
## reflects note title changes into the tab title.
func associate_editor(editor: Editor):
	editor.associated_object = self

	label_node.text_changed.connect(
		func(text):
			editor.tab_title = text
	)

	# set the editor so we know if we can close the editor if the note is deleted
	set_meta("associated_editor", editor)


func _on_edit_button_pressed():
	var ep: EditorPane = SingletonObject.editor_container.editor_pane

	# Show the editor if it's hidden
	SingletonObject.main_ui.set_editor_pane_visible(true)

	# Try to find editor that's already associated with memory_item
	for i in range(ep.Tabs.get_tab_count()):
		var tab_control = ep.Tabs.get_tab_control(i)
		
		if tab_control is Editor and tab_control.associated_object == self:
			ep.Tabs.current_tab = i # Change the current tab to that editor
			return

	var editor: Editor

	if  memory_item.Type == SingletonObject.note_type.IMAGE:
		SingletonObject.is_graph = true # this lines should be moved to the correct node rather that them being on SingletonObject
		SingletonObject.is_picture = true
		editor = ep.add(Editor.Type.GRAPHICS, memory_item.File, "Graphic Note")
		editor.graphics_editor.setup_from_image(memory_item.MemoryImage)
	else:
		editor = ep.add(Editor.Type.TEXT, memory_item.File, memory_item.Title)
		
		# Get the old text from the code_edit before replacing it
		var old_text: String = editor.code_edit.text
		
		# Set the new text
		editor.code_edit.text = memory_item.Content
		
		# Call check_incomplete_snippet with the correct old_text and new_text
		ep.check_incomplete_snippet(editor, old_text, editor.code_edit.text)
		ep._is_Completed = memory_item.isCompleted
	
	associate_editor(editor)


func _on_hide_button_pressed():
	self.release_focus()
	if memory_item.Type == SingletonObject.note_type.AUDIO:
		control_type._on_stop_button_pressed()
	if memory_item.Type == SingletonObject.note_type.VIDEO:
		control_type.video_stream_player.paused = true
	var tween = get_tree().create_tween()
	tween.tween_property(self, "modulate:a", 0, 0.2)
	tween.tween_callback(
		func():
			memory_item.Visible = false
			memory_item = memory_item
	)
	visible = false


func _on_title_text_submitted(new_text: String) -> void:
	label_node.release_focus()
	if memory_item: memory_item.Title = new_text


var resize_tween: Tween
func expand_note() -> void:
	if control_type == null: return
	if resize_tween and resize_tween.is_running():
		resize_tween.kill()
		return
	resize_tween = create_tween().set_ease(expand_ease_type).set_trans(expand_transition_type)
	resize_tween.finished.connect(enable_expand_button)
	expand_button.disabled = true
	if last_min_size == 0:
		last_min_size = 100
	resize_tween.tween_property(control_type, "custom_minimum_size:y", last_min_size, expand_anim_duration)
	resize_tween.set_parallel()
	resize_tween.tween_property(resize_drag_control, "custom_minimum_size:y", 10, 0.1)
	resize_tween.set_parallel()
	resize_tween.tween_property(expand_button,"rotation", deg_to_rad(0.0), expand_anim_duration)
	resize_tween.set_parallel()
	resize_tween.tween_property(expand_button, "modulate", Color.WHITE, expand_anim_duration)
	
	video_label.show()
	resize_drag_control.show()
	%HSeparator.show()
	%BufferControl.hide()
	control_type.show()


func contract_note() -> void:
	if control_type == null: return
	if resize_tween and resize_tween.is_running():
		resize_tween.kill()
		return
	resize_tween = create_tween().set_ease(expand_ease_type).set_trans(expand_transition_type)
	resize_tween.finished.connect(enable_expand_button)
	expand_button.disabled = true
	last_min_size = control_type.custom_minimum_size.y
	resize_tween.tween_property(control_type, "custom_minimum_size:y", 0, expand_anim_duration)
	resize_tween.set_parallel()
	resize_tween.tween_property(resize_drag_control, "custom_minimum_size:y", 0, 0.1)
	resize_tween.set_parallel()
	resize_tween.tween_property(expand_button,"rotation", deg_to_rad(-90.0), expand_anim_duration)
	resize_tween.set_parallel()
	resize_tween.tween_property(expand_button, "modulate", expand_icon_color, expand_anim_duration)
	
	await resize_tween.finished
	video_label.hide()
	control_type.hide()
	%HSeparator.hide()
	%BufferControl.show()
	resize_drag_control.hide()
	


func enable_expand_button() -> void:
	expand_button.disabled = false

var resize_dragging: bool = false
var _last_mouse_posistion_y: float = 0.0
func _on_resize_control_gui_input(event: InputEvent) -> void:
	if _last_mouse_posistion_y == 0:
		_last_mouse_posistion_y = get_global_mouse_position().y
	if expanded:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT and event.is_pressed():
				resize_dragging = true
			elif event.button_index == MOUSE_BUTTON_LEFT and !event.is_pressed():
				resize_dragging = false
	if resize_dragging:
		_resize_vertical(get_global_mouse_position().y, _last_mouse_posistion_y)
		_last_mouse_posistion_y = get_global_mouse_position().y

func _resize_vertical(current_mouse_pos_y: float, last_mouse_pos_y: float) -> void:
	#if control_type == null: return
	var difference: float = current_mouse_pos_y - last_mouse_pos_y
	
	if control_type.custom_minimum_size.y + difference < min_note_size_limit and min_note_size_limit != 0:
		control_type.custom_minimum_size.y = min_note_size_limit
	elif control_type.custom_minimum_size.y + difference > max_note_size_limit and max_note_size_limit != 0:
		control_type.custom_minimum_size.y = max_note_size_limit
	else:
		control_type.custom_minimum_size.y += difference
		last_min_size = control_type.custom_minimum_size.y


func _on_expand_button_pressed() -> void:
	expanded = !expanded
	if !expanded:
		contract_note()
	else:
		expand_note()
