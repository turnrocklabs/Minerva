class_name Note
extends VBoxContainer

static var _scene: = preload("res://Scenes/Note.tscn")
static var _text_controls_scene: = preload("res://Scenes/note/note_controls/text_controls.tscn")
static var _image_controls_scene: = preload("res://Scenes/note/note_controls/image_controls.tscn")
static var _audio_controls_scene: = preload("res://Scenes/note/note_controls/audio_controls.tscn")

enum Type {
	TEXT,
	IMAGE,
	VIDEO,
	AUDIO,
}

static var _type_names: = {
	Type.TEXT: "text",
	Type.IMAGE: "image",
	Type.AUDIO: "audio",
	Type.VIDEO: "video",
}

## Mapping of file extensions and their respective note type.[br]
## For now, everything that doesn't match any of below is treated as a text file.
static var _file_ext_map: = {
	Type.AUDIO: ["mp3", "ogg", "wav"],
	# https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_images.html#supported-image-formats
	Type.IMAGE: ["png", "jpg", "jpeg", "bmp", "dds", "ktx", "exr", "hdr", "tga", "svg", "webp", "ico"],
	Type.VIDEO: [],
}

@export var minimum_expanded_height: float = 150

var type: Type

var uuid: String:
	set(value):
		if uuid.is_empty():
			uuid = value
			SingletonObject.save_state(false)
		else:
			push_warning("Tried to change the Note object uuid when the value is already set")

var title: String:
	set(value):
		_title.text = value
		SingletonObject.save_state(false)
	get:
		return _title.text

var enabled: bool:
	set(value):
		_enabled.disabled = not value
		SingletonObject.save_state(false)
	get:
		return not _enabled.disabled

var expanded: bool = true:
	set(value):
		expanded = value
		_node_expand_toggled()
		SingletonObject.save_state(false)

## String representation of this notes [member Note.type], or [code]"Unknown"[/code] if [member Note.type] is not set or found.
var content_type: String:
	get: return _type_names.get(type, "Unknown")


## File path of the file attached to this note.[br]
## Changing this property doesn't reload the note,
## but makes the note load the content from that file on deserialization,
## taking the [property type] into account.
var file: String


var expanded_height: float = 150


@onready var _title: LineEdit = %Title
@onready var _enabled: CheckButton = %CheckButton

@onready var _notes_control_container: Container = %NoteControlsContainer
# container that holds all the content and gives the note its background
@onready var _panel_container: PanelContainer = %PanelContainer
@onready var _expand_button: Button = %ExpandButton
@onready var _resize_control: Control = %ResizeControl

@onready var _upper_drop_separator: HSeparator = %UpperSeparator
@onready var _lower_drop_separator: HSeparator = %LowerSeparator

static func create_text_note(note_title: String, content: String) -> Note:
	var text_controls: NoteTextControls = _text_controls_scene.instantiate()
	var note_scene: Note = _scene.instantiate()

	note_scene.ready.connect(
		func():
			await note_scene._set_controls_container(text_controls)
			text_controls.setup(content)
			
			note_scene.title = note_title
			note_scene.type = Type.TEXT
	)

	return note_scene

static func create_dummy_note(note_title: String) -> Note:
	var note_scene: Note = _scene.instantiate()

	note_scene.ready.connect(
		func():
			note_scene.title = note_title
	)

	return note_scene

static func create_image_note(note_title: String, image: Image, caption: String = "") -> Note:
	var image_controls: NoteImageControls = _image_controls_scene.instantiate()
	var note_scene: Note = _scene.instantiate()

	note_scene.ready.connect(
		func():
			await note_scene._set_controls_container(image_controls)
			image_controls.setup(image, caption)
			
			note_scene.title = note_title
			note_scene.type = Type.IMAGE
	)

	return note_scene

static func create_audio_note(note_title: String, audio: AudioStream) -> Note:
	var audio_controls: NoteAudioControls = _audio_controls_scene.instantiate()
	var note_scene: Note = _scene.instantiate()

	note_scene.ready.connect(
		func():
			await note_scene._set_controls_container(audio_controls)
			audio_controls.setup(audio)
			
			note_scene.title = note_title
			note_scene.type = Type.IMAGE
	)

	return note_scene


## Tries to create a note from the given file path.[br]
## [member Note.type] is determined from the [param file_path] extension. On fail a text note with an error is returned.
static func create_file_note(note_title: String, file_path: String) -> Note:

	# determin the note type from the extension
	var ext: = file_path.get_extension()

	var note: Note

	if ext in _file_ext_map[Type.IMAGE]:
		var img: = Image.load_from_file(file_path)
		if img == null:
			push_error("Couldn't open the note file %s. Image object null." % file_path)
			return create_text_note(note_title, "Couldn't open the note file %s. Image object null." % file_path)

		note = create_image_note(note_title, img)

	elif ext in _file_ext_map[Type.AUDIO]:
		var fa: = FileAccess.open(file_path, FileAccess.READ)

		if fa == null:
			var err: = FileAccess.get_open_error()
			push_error("Couldn't open the note file: %s" % error_string(err))
			return create_text_note(note_title, "Couldn't open the note file: %s" % error_string(err))

		var audio_stream: AudioStream	
	
		match ext:
			"mp3":
				audio_stream = AudioStreamMP3.new()
				audio_stream.data = fa.get_buffer(fa.get_length())
			"ogg":
				audio_stream = AudioStreamOggVorbis.new()
				audio_stream.load_from_buffer(fa.get_buffer(fa.get_length()))
			"wav":
				audio_stream = AudioStreamWAV.new()
				audio_stream.data = fa.get_buffer(fa.get_length())

		note = create_audio_note(note_title, audio_stream)
	
	else: # treat as text file
		var fa: = FileAccess.open(file_path, FileAccess.READ)

		if fa == null:
			var err: = FileAccess.get_open_error()
			push_error("Couldn't open the note file: %s" % error_string(err))
			return create_text_note(note_title, "Couldn't open the note file: %s" % error_string(err))

		note = create_text_note(note_title, fa.get_as_text())

	
	return note



## Adds the note controls to the note hierarchy and waits one frame after adding.
func _set_controls_container(controls_container: Control) -> void:
	_notes_control_container.add_child(controls_container)
	await get_tree().process_frame

func _to_string() -> String:
	return "%s note (%s)" % [content_type.capitalize(), title]

func _on_remove_button_pressed() -> void:
	queue_free()

func _on_edit_button_pressed() -> void:
	pass # Replace with function body.

func _on_hide_button_pressed() -> void:
	visible = false


# region Expand

var _tween: Tween
# how fast the node height changes on expand
var _anim_duration: = 0.2
# how many seconds to rotate a degree of the expand button arrow
var time_per_degree: = 0.0011 

func _node_expand_toggled():

	if expanded:
		_resize_control.mouse_default_cursor_shape = Control.CURSOR_VSIZE
		_resize_control.mouse_filter = Control.MOUSE_FILTER_STOP
	else:
		_resize_control.mouse_default_cursor_shape = Control.CURSOR_FORBIDDEN
		_resize_control.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if is_instance_valid(_tween) and _tween.is_running():
		_tween.stop()

	_tween = create_tween()
	_tween.set_parallel(true)

	if expanded:
		# custom_minimum_size.y = minimum_expanded_height
		_tween.tween_property(self, "custom_minimum_size:y", max(minimum_expanded_height, expanded_height), _anim_duration)
		_tween.tween_property(_expand_button, "rotation_degrees", 180, absf(180 - _expand_button.rotation_degrees) * time_per_degree)
		_notes_control_container.visible = true

	else:
		_tween.tween_property(self, "custom_minimum_size:y", 0, _anim_duration)
		_tween.tween_property(_expand_button, "rotation_degrees", 0, absf(_expand_button.rotation_degrees) * time_per_degree)
		_notes_control_container.visible = false



func _on_expand_button_pressed() -> void:
	expanded = not expanded

var _dragging: = false
func _on_resize_control_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_mask == MOUSE_BUTTON_MASK_LEFT:
			_dragging = event.pressed
		
		return
	
	if not _dragging: return

	if event is InputEventMouseMotion:
		# sometimes the controls is not catching the release event
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_dragging = false
			return

		var current_min_y: = get_combined_minimum_size().y

		custom_minimum_size.y = max(minimum_expanded_height, current_min_y + event.relative.y)
		expanded_height = size.y

# endregion

# region Drag

func _notification(what: int) -> void:
	
	match what:
		NOTIFICATION_DRAG_BEGIN: pass
		NOTIFICATION_DRAG_END: pass
			# _upper_drop_separator.visible = false
			# _lower_drop_separator.visible = false


func _get_drag_data(at_position: Vector2) -> Variant:
	
	var preview_control: = Control.new()

	var note_dup: = create_dummy_note(title)

	note_dup.set_size.call_deferred(size)
	note_dup.position = -at_position
	note_dup.modulate.a = 0.5

	preview_control.add_child(note_dup)

	set_drag_preview(preview_control)

	return self


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:	
	# maybe check type, so drawer notes can't be dropped into normal ones?

	# if at_position.y > size.y / 2:
	# 	_upper_drop_separator.visible = false
	# 	_lower_drop_separator.visible = true
	# else:
	# 	_upper_drop_separator.visible = true
	# 	_lower_drop_separator.visible = false

	return data is Note


func _drop_data(at_position: Vector2, data: Variant) -> void:
	pass


# endregion

# region Serialization

## Serializes the [class Note] object into a JSON serializable dictionary.
func serialize() -> Dictionary:
	var note_data: = {}

	match type:
		Type.TEXT:
			# note_data["Content"] = content
			pass
		
		Type.IMAGE:
			pass
		
		Type.AUDIO:
			pass

		_:
			push_error("Can't serialize a Note object (%s) without a valid type" % self)


	return note_data

# { "Audio": <null>, "Content": "BRE", "ContentType": "text", "Enabled": false, "Expanded": true, "File": "", "ImageCaption": "", "LastYSize": 100.0,
# "Locked": false, "MemoryImage": <null>, "Order": 0.0, "OwningThread": "fb8bcc6be53ed9fe4a15de8a1a959cfaa9c0bb441705004edd0e1bbf599fe0d1", "Pinned": false,
# "Title": "test BRE", "Type": 0.0, "UUID": "345e77bebfb7efbb1206ab3b1bc19c9c8bace80490a2d8471533cb2d7893b492", "Visible": true, "isDrawer": false }


## Serializes the controls (NoteTextControls, NoteImageControls, etc..) container.[br]
## Tries to find the first child that is one of the above containers and returns it's data.
func _serialize_controls_data():
	var data: = {}
	var controls_container

	for child in _notes_control_container.get_children():
		if (
			child is NoteTextControls or
			child is NoteImageControls or
			child is NoteAudioControls or
			child is NoteVideoControls
		): controls_container = child

	if not controls_container:
		push_warning("Couldn't serialize Note object (%s) controls container as a valid child wasn't found." % self)
		return {}
	
	if controls_container is NoteTextControls:
		data["Content"] = controls_container.content
	
	elif controls_container is NoteAudioControls:
		data["Audio"] = controls_container.audio
	
	elif controls_container is NoteImageControls:
		pass



## Deserializes the [param note_data] dictionary into a [class Note] object.
static func deserialize(note_data: Dictionary) -> Note:
	print(note_data)

	var note: Note

	# TODO:
	# If a file is attached to a note, if takes priority
	# over other content fileds in the data. If the file is not valid,
	# the note will be loaded with an error message.

	match note_data.get("ContentType", "text"):
		"text":
			note = create_text_note(
				note_data.get("Title", "Unknown"),
				note_data.get("Content", ""),
			)
		"audio":
			var audio_data = note_data.get("Audio", "")
			note = create_audio_note(
				note_data.get("Title", "Unknown"),
				Marshalls.base64_to_variant(audio_data),
			)
		"image":
			var image_data = note_data.get("MemoryImage", "")
			note = create_image_note(
				note_data.get("Title", "Unknown"),
				Marshalls.base64_to_variant(image_data),
				note_data.get("ImageCaption", ""),
			)
		_:
			push_error("Couldn't deserialize note with content type: %s" % note_data.get("ContentType"))
			return

	note.enabled = note_data.get("Enabled", true)
	note.expanded = note_data.get("Expanded", true)
	note.visible = note_data.get("Visible", true)

	return note

# { "Audio": <null>, "Content": "BRE", "ContentType": "text", "Enabled": false, "Expanded": true, "File": "", "ImageCaption": "", "LastYSize": 100.0,
# "Locked": false, "MemoryImage": <null>, "Order": 0.0, "OwningThread": "fb8bcc6be53ed9fe4a15de8a1a959cfaa9c0bb441705004edd0e1bbf599fe0d1", "Pinned": false,
# "Title": "test BRE", "Type": 0.0, "UUID": "345e77bebfb7efbb1206ab3b1bc19c9c8bace80490a2d8471533cb2d7893b492", "Visible": true, "isDrawer": false }

# endregion
