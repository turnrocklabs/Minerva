class_name Note
extends VBoxContainer

static var _scene: = preload("res://Scenes/Note.tscn")
static var _text_controls_scene: = preload("res://Scenes/note/note_controls/text_controls.tscn")
static var _image_controls_scene: = preload("res://Scenes/note/note_controls/image_controls.tscn")
static var _audio_controls_scene: = preload("res://Scenes/note/note_controls/audio_controls.tscn")

static var _remove_icon: = preload("res://assets/icons/remove.svg")

## Emitted when the title changes.
signal title_changed

## Emitted when the note eneters a tab container, usually after dropping the note.[br]
## [class NotesContainer] emits this signal only if the Note is initialized
## by checking the [method Note.is_note_initialized].
@warning_ignore("unused_signal")
signal tab_changed(tab_idx: int)

## Emitted when any note content has been changed, both main and controls container
signal changed

## Emitted when the Note has been created and all properties set
signal initialized

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

var sha256: String:
	get: return generate_sha256()

var title: String:
	set(value):
		_title.text = value
		changed.emit()
		title_changed.emit()
		SingletonObject.save_state(false)
	get:
		return _title.text

var enabled: bool:
	set(value):
		_check_button.button_pressed = value
		changed.emit()
		SingletonObject.save_state(false)
	get:
		return _check_button.button_pressed

var expanded: bool = true:
	set(value):
		expanded = value
		_node_expand_toggled()
		changed.emit()
		SingletonObject.save_state(false)

## String representation of this notes [member Note.type], or [code]"Unknown"[/code] if [member Note.type] is not set or found.
var content_type: String:
	get: return _type_names.get(type, "Unknown")


## File path of the file attached to this note.[br]
## Changing this property doesn't reload the note,
## but makes the note load the content from that file on deserialization,
## and save to that file on serialize, taking the [property type] into account.
var file: String


var expanded_height: float = 150

var _error: = false:
	set(value):
		_error = value
		_on_error_changed()

var _initialized: = false

@onready var _title: LineEdit = %Title
@onready var _check_button: CheckButton = %CheckButton
@onready var _edit_button: Button = %EditButton
@onready var _warning_button: Button = %WarningButton
@onready var _hide_button: Button = %HideButton
@onready var _remove_button: Button = %RemoveButton

@onready var sync_controller_button: Button = %SyncControllerButton

@onready var _notes_control_container: Container = %NoteControlsContainer
# container that holds all the content and gives the note its background
@onready var _panel_container: PanelContainer = %PanelContainer
# container with top controls, expand, title, edit, hide, remove, etc
# Has mouse filter set to stop, set to propagate up when dragging notes
@onready var _top_controls: Container = %TopControls
@onready var _expand_button: Button = %ExpandButton
@onready var _resize_control: Control = %ResizeControl


## Allow changing the default remove button handler.[br]
## If the callable is not valid, the note is just freed from the memory.
var remove_handle: Callable

var remove_icon: = _remove_icon:
	set(value):
		if not value:
			_remove_button.icon = _remove_icon
		else:
			_remove_button.icon = value
	get: return _remove_button.icon

static func create_text_note(note_title: String, content: String, note_uuid: String = "", register: = true) -> Note:
	var text_controls: NoteTextControls = _text_controls_scene.instantiate()
	var note_scene: Note = _scene.instantiate()

	note_scene.uuid = note_uuid if not note_uuid.is_empty() else SingletonObject.generate_UUID()

	if register:
		SingletonObject.register_object(note_scene, &"uuid")

	note_scene.ready.connect(
		func():
			await note_scene._set_controls_container(text_controls)
			text_controls.setup(note_scene, content)
			
			note_scene.title = note_title
			note_scene.type = Type.TEXT
			note_scene.initialized.emit()
	)
	

	return note_scene

static func create_error_note(note_title: String, content: String, warning: String = "This note is invalid") -> Note:
	var note: = create_text_note(note_title, content)
	
	note.ready.connect(
		func():
			note._error = true
			note._warning_button.tooltip_text = warning
			note.initialized.emit()
	)

	return note

static func create_dummy_note(note_title: String) -> Note:
	var note_scene: Note = _scene.instantiate()

	note_scene.ready.connect(
		func():
			note_scene.title = note_title
			note_scene.initialized.emit()
	)

	return note_scene

static func create_image_note(note_title: String, image: Image, caption: String = "", note_uuid: String = "", register: = true) -> Note:
	var image_controls: NoteImageControls = _image_controls_scene.instantiate()
	var note_scene: Note = _scene.instantiate()

	note_scene.uuid = note_uuid if not note_uuid.is_empty() else SingletonObject.generate_UUID()

	if register:
		SingletonObject.register_object(note_scene, &"uuid")

	note_scene.ready.connect(
		func():
			await note_scene._set_controls_container(image_controls)
			image_controls.setup(note_scene, image, caption)
			
			note_scene.title = note_title
			note_scene.type = Type.IMAGE
			note_scene.initialized.emit()
	)

	return note_scene

static func create_audio_note(note_title: String, audio: AudioStream, note_uuid: String = "", register: = true) -> Note:
	var audio_controls: NoteAudioControls = _audio_controls_scene.instantiate()
	var note_scene: Note = _scene.instantiate()

	note_scene.uuid = note_uuid if not note_uuid.is_empty() else SingletonObject.generate_UUID()

	if register:
		SingletonObject.register_object(note_scene, &"uuid")

	note_scene.ready.connect(
		func():
			await note_scene._set_controls_container(audio_controls)
			audio_controls.setup(note_scene, audio)
			
			note_scene.title = note_title
			note_scene.type = Type.AUDIO
			note_scene.initialized.emit()
	)

	return note_scene


## Tries to create a note from the given file path.[br]
## [member Note.type] is determined from the [param file_path] extension. On fail a text note with an error is returned.
static func create_file_note(note_title: String, file_path: String, note_uuid: String = "", register: = true) -> Note:

	# determine the note type from the extension
	var ext: = file_path.get_extension()

	var note: Note

	if ext in _file_ext_map[Type.IMAGE]:
		var img: = Image.load_from_file(file_path)
		if img == null:
			push_error("Couldn't open the note file %s. Image object null." % file_path)
			return create_error_note(note_title, "Couldn't open the note file (%s). Image object is null." % file_path)

		note = create_image_note(note_title, img, "", note_uuid, register)

	elif ext in _file_ext_map[Type.AUDIO]:
		var fa: = FileAccess.open(file_path, FileAccess.READ)

		if fa == null:
			var err: = FileAccess.get_open_error()
			push_error("Couldn't open the note file (%s): %s" % [file_path, error_string(err)])
			return create_error_note(note_title, "Couldn't open the note file (%s): %s" % [file_path, error_string(err)])

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

		note = create_audio_note(note_title, audio_stream, note_uuid, register)
	
	else: # treat as text file
		var fa: = FileAccess.open(file_path, FileAccess.READ)

		if fa == null:
			var err: = FileAccess.get_open_error()
			push_error("Couldn't open the note file (%s): %s" % [file_path, error_string(err)])
			return create_error_note(note_title, "Couldn't open the note file (%s): %s" % [file_path, error_string(err)])

		note = create_text_note(note_title, fa.get_as_text(), note_uuid, register)

	note.file = file_path
	
	return note


## Reloads the file content of the note, if not was loaded from a file that's accessable.[br]
## Returns `ERR_UNAVAILABLE` if file is not set, any other error that occured, or `OK`.
func refresh_file_note() -> int:
	if not file: return ERR_UNAVAILABLE


	var fa: = FileAccess.open(file, FileAccess.READ)

	if fa == null:
		return FileAccess.get_open_error()
	
	var ext: = file.get_extension()
	
	if type == Type.IMAGE:

		if not ext in _file_ext_map[Type.IMAGE]:
			return ERR_INVALID_DATA

		var img: = Image.load_from_file(file)
		if img == null:
			push_error("Couldn't open the note file %s. Image object null." % file)
			return ERR_CANT_OPEN
		
		(get_controls_container() as NoteImageControls).image = img

	elif type == Type.AUDIO:
		if not ext in _file_ext_map[Type.AUDIO]:
			return ERR_INVALID_DATA

		if fa == null:
			var err: = FileAccess.get_open_error()
			push_error("Couldn't open the note file (%s): %s" % [file, error_string(err)])

			return err

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

		(get_controls_container() as NoteAudioControls).audio = audio_stream
	
	elif type == Type.TEXT:
		
		if fa == null:
			var err: = FileAccess.get_open_error()
			push_error("Couldn't open the note file (%s): %s" % [file, error_string(err)])

		(get_controls_container() as NoteTextControls).content = fa.get_as_text()

	return OK

## Adds the note controls to the note hierarchy and waits one frame after adding.
func _set_controls_container(controls_container: Control) -> void:
	_notes_control_container.add_child(controls_container)
	await get_tree().process_frame

## Returns the controls container for this note.[br]
## If not found returns `null`, but that shouldn't happen if the note
## was created using the `create_*_note` functions from this class.
func get_controls_container() -> Control:
	for child in _notes_control_container.get_children():
		if (
			child is NoteTextControls or
			child is NoteImageControls or
			child is NoteAudioControls or
			child is NoteVideoControls
		): return child
	
	return null

## When the error property changes, update the note border color
func _on_error_changed():
	
	if _error:
		_panel_container.theme_type_variation = &"ErrorNote"
	else:
		_panel_container.theme_type_variation = &""

	_expand_button.visible = not _error
	_warning_button.visible = _error
	_check_button.visible = not _error
	_hide_button.visible = not _error
	_edit_button.visible = not _error


func _to_string() -> String:
	if not is_node_ready():
		return "%s note (not ready)" % content_type.capitalize()
	
	return "%s note (%s)" % [content_type.capitalize(), title]


func _init() -> void:
	# keep a meta with current timestamp
	set_meta("timestamp", Time.get_unix_time_from_system())
	initialized.connect(_on_note_initialized)

func _on_note_initialized():
	_initialized = true

## Return whether the note is ready and all fields are set
func is_note_initialized() -> bool:
	return _initialized


func _on_remove_button_pressed() -> void:
	remove()


## Removes this note object. Used when user pressed the remove button or the tab is closed.[br]
## [property Note.remove_handle] is used if it's set and valid, to delegate the the process.[br]
## Otherwise `queue_free` is used.[br]
## Returns whether the note has been deleted, or the deletiong was rejected.
func remove() -> bool:
	if remove_handle and remove_handle.is_valid():
		return type_convert(await remove_handle.call(), TYPE_BOOL)
	else:
		queue_free()
	
	return true


func _on_title_text_changed(_new_text: String) -> void:
	title_changed.emit()
	changed.emit()

func _on_edit_button_pressed() -> void:
	# The editor pane will listen to tree exiting signal
	# and remove this note from the associated object ONLY if the note
	# is queue for deletion as the note could be exiting tree
	# just to be dropped to another tab.
	# method content_matches is used to determine
	# if editor content matches to note content.

	var editor_pane: EditorPane = SingletonObject.editor_container.editor_pane

	for editor in editor_pane.get_open_editors():
		if editor.associated_object == self:
			print("Already present")
			return

	# Show the editor if it's hidden
	SingletonObject.main_ui.set_editor_pane_visible(true)

	match type:
		Type.TEXT:
			var editor: = editor_pane.add(Editor.Type.TEXT, null, title, self)
			var controls = get_controls_container() as NoteTextControls
			editor.code_edit.text = controls.content
		Type.IMAGE:
			var editor: = editor_pane.add(Editor.Type.GRAPHICS, null, title, self, false)
			var controls = get_controls_container() as NoteImageControls
			editor.graphics_editor.create_new_image_layer(title, controls.image, true)


func _on_hide_button_pressed() -> void:
	visible = false
	changed.emit()


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
		_tween.tween_property(_expand_button, "rotation_degrees", 90, absf(90 - _expand_button.rotation_degrees) * time_per_degree)
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
		NOTIFICATION_DRAG_BEGIN:
			if not _error:
				_top_controls.mouse_filter = Control.MOUSE_FILTER_PASS
		NOTIFICATION_DRAG_END:
			if not _error:
				_panel_container.theme_type_variation = &"ErrorNote" if _error else &""
				_panel_container.remove_theme_stylebox_override("panel")
				_top_controls.mouse_filter = Control.MOUSE_FILTER_STOP

func _on_mouse_exited() -> void:
	if _error:
		_panel_container.theme_type_variation = &"ErrorNote"
	else:
		_panel_container.theme_type_variation = &""
	
	_panel_container.remove_theme_stylebox_override("panel")
	

func _get_drag_data(at_position: Vector2) -> Variant:
	
	# Invalid notes can't be dragged
	if _error: return null

	var preview_control: = Control.new()

	var note_dup: = create_dummy_note(title)
	preview_control.add_child(note_dup)

	note_dup.ready.connect(
		func():
			note_dup.custom_minimum_size = size
			note_dup.position = -at_position
			note_dup.modulate.a = 0.25
	)

	# set private meta so the drop can be animated correctly
	set_meta("_mouse_drag_offset", at_position)

	set_drag_preview(preview_control)

	return self


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:	
	# maybe check type, so drawer notes can't be dropped into normal ones?

	if data == self: return false

	
	_panel_container.theme_type_variation = &"DropZoneNote"

	var new_stylebox_error: StyleBoxFlat = _panel_container.get_theme_stylebox("panel").duplicate()
	
	if at_position.y > size.y / 2:
		# below the current node
		new_stylebox_error.border_width_bottom = 3
		new_stylebox_error.border_width_left = 1
		new_stylebox_error.border_width_top = 0
		new_stylebox_error.border_width_right = 1
	else:
		new_stylebox_error.border_width_bottom = 0
		new_stylebox_error.border_width_left = 1
		new_stylebox_error.border_width_top = 3
		new_stylebox_error.border_width_right = 1

	new_stylebox_error.border_color = Color.BLUE

	_panel_container.add_theme_stylebox_override("panel", new_stylebox_error)

	return data is Note


func _drop_data(at_position: Vector2, data: Variant) -> void:
	
	var note = data as Note

	var note_dup: = create_dummy_note(note.title)

	var _mouse_drag_offset = note.get_meta("_mouse_drag_offset", Vector2.ZERO)

	var preview_control: = Control.new()
	note_dup.set_size.call_deferred(size)
	note_dup.position = -_mouse_drag_offset
	note_dup.modulate.a = 0.50
	
	preview_control.global_position = get_global_mouse_position()
	preview_control.add_child(note_dup)
	
	get_tree().root.add_child(preview_control)

	var parent: = get_parent()

	if note.get_parent() != parent:
		note.reparent(parent)

	var index: int

	if at_position.y > size.y / 2:
		index = get_index()+1
	else:
		index = get_index()
	
	# if dragged note is before the one we're dropping over
	# we need to subtract one to account for that node
	if note.get_index() < index:
		index -= 1
	
	parent.move_child(note, index)
	note.modulate.a = 0

	# wait for he dragged note to move and get its updated position in the container
	await get_tree().process_frame

	var tween: = create_tween()

	tween.tween_property(note_dup, "global_position", note.global_position, 0.2)
	
	await tween.finished
	note.modulate.a = 1
	preview_control.queue_free()

	var controller: = SingletonObject.notes_sync_manger.get_sync_controller(note)
	if controller.state != NoteSyncController.SyncState.LOCAL_ONLY:
		SingletonObject.notes_sync_manger.sync_notes([note])

# endregion

# region Serialization

## Serializes the [class Note] object into a JSON serializable dictionary.
func serialize() -> Dictionary:
	
	# File field is handled by the _serialize_controls_data method
	
	var note_data: = {
		"Title": title,
		"UUID": uuid,
		"SHA256": sha256,
		"Enabled": enabled,
		"Expanded": expanded,
		"ExpandedHeight": expanded_height,
		"ContentType": content_type,
	}

	# Merge the controls data
	note_data.merge(_serialize_controls_data())

	return note_data

## Serializes the controls (NoteTextControls, NoteImageControls, etc..) container.[br]
## Tries to find the first child that is one of the above containers and returns it's data.[br]
## If the note has file attached, the data will be saved to the file and `File` field
## in the returned data will be populated by this method.
func _serialize_controls_data() -> Dictionary:
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
		var fa: = _get_file_handle()
		if fa:
			fa.store_string(controls_container.content)
			data["File"] = file
		else:
			data["Content"] = controls_container.content
	
	# Generally audio note's content can't be changed in terms of the audio
	# But if the audio was recorded inside the app, we still need to save the data
	# So if there's no file attached, that means we recorded the audio ourselves
	# and we need to save it. Recorded audio is always in WAV format, see AudioEffectRecord.get_recording()
	elif controls_container is NoteAudioControls:
		if file:
			data["File"] = file
		else:
			data["Audio"] = controls_container.get_audio_data()
			
	elif controls_container is NoteImageControls:
		var fa: = _get_file_handle()
		if fa:
			fa.store_buffer(controls_container.image.save_png_to_buffer())
			data["File"] = file
		else:
			data["MemoryImage"] = Marshalls.raw_to_base64(controls_container.image.save_png_to_buffer())
		
		data["ImageCaption"] = controls_container.caption

	return data

## Tries to retrieve a file handle for this Notes [property file].[br]
## Returns `null` if there's no file attached or it couldn't be open.
func _get_file_handle() -> FileAccess:
	# if this note doesn't have a file attached return immediately
	if not file: return null

	var fa: = FileAccess.open(file, FileAccess.WRITE)

	if fa == null:
		var err: = FileAccess.get_open_error()
		push_error("Couldn't retrieve a file handle for the Note object (%s) @ %s. %s" % [self, file, error_string(err)])
		return null
	
	return fa


## Call the controls container to generate the SHA256 hash for the content stored in this note.[br]
## Controls container mush expose a property name "sha256" or this function returns an empty string.
func generate_sha256() -> String:
	var controls_container: Control

	for child in _notes_control_container.get_children():
		if (
			child is NoteTextControls or
			child is NoteImageControls or
			child is NoteAudioControls or
			child is NoteVideoControls
		): controls_container = child

	if not controls_container:
		push_warning("Couldn't generate sha256 for Note object (%s) from controls container as a valid child wasn't found." % self)
		return ""
	
	var hash_string = controls_container.get("sha256")

	if hash_string == null:
		push_error("Can't generate Notes (%s) SHA256 hash. Controls container (%s) returned null for property 'sha256'" % [self, controls_container])
		return ""

	return hash_string


## This functions takes the [param input] and returns the SHA256 string.[br]
## Returns empty string if input is invalid.
static func generate_content_sha256(input: PackedByteArray) -> String:
	if input.is_empty(): return ""

	var ctx = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	
	ctx.update(input)
	
	var hashed = ctx.finish()
	return hashed.hex_encode()

## Deserializes the [param note_data] dictionary into a [class Note] object.
static func deserialize(note_data: Dictionary) -> Note:
	# print(note_data)

	var note: Note

	# If a file is attached to a note, if takes priority
	# over other content fileds in the data. If the file is not valid,
	# the note will be loaded with an error message.
	if note_data.has("File") and note_data["File"]:
		note = Note.create_file_note(note_data.get("Title", "Unknown"), note_data["File"])

	else:
		match note_data.get("ContentType", "text"):
			"": # assume empty could be a text file
				note = create_text_note(
					note_data.get("Title", "Unknown"),
					note_data.get("Content", ""),
					note_data.get("UUID", ""),
				)
			"text":
				note = create_text_note(
					note_data.get("Title", "Unknown"),
					note_data.get("Content", ""),
					note_data.get("UUID", ""),
				)
			"audio":
				var audio_data = note_data.get("Audio", "")
				var audio_stream: = NoteAudioControls.load_audio_from_data(audio_data)

				note = create_audio_note(
					note_data.get("Title", "Unknown"),
					audio_stream,
					note_data.get("UUID", ""),
				)
			"image":
				# embedded images are saved as PNG
				var image_data = note_data.get("MemoryImage", "")
				var image: = Image.new()
				image.load_png_from_buffer(Marshalls.base64_to_raw(image_data))

				note = create_image_note(
					note_data.get("Title", "Unknown"),
					image,
					note_data.get("ImageCaption", ""),
					note_data.get("UUID", ""),
				)
			_:
				push_error("Couldn't deserialize note with content type: %s" % note_data.get("ContentType"))
				return

	# can't edit until the node is ready
	note.ready.connect(
		func():
			note.enabled = note_data.get("Enabled", true)
			note.expanded = note_data.get("Expanded", true)
			note.visible = note_data.get("Visible", true)
	)

	return note

# { "Audio": <null>, "Content": "BRE", "ContentType": "text", "Enabled": false, "Expanded": true, "File": "", "ImageCaption": "", "LastYSize": 100.0,
# "Locked": false, "MemoryImage": <null>, "Order": 0.0, "OwningThread": "fb8bcc6be53ed9fe4a15de8a1a959cfaa9c0bb441705004edd0e1bbf599fe0d1", "Pinned": false,
# "Title": "test BRE", "Type": 0.0, "UUID": "345e77bebfb7efbb1206ab3b1bc19c9c8bace80490a2d8471533cb2d7893b492", "Visible": true, "isDrawer": false }

# endregion


## Checks if provided content matches the content of this note.[br]
## For text notes it compares the `content` field.[br]
## For image notes if compares the `image` field.[br]
func content_matches(input: Variant):

	var content_container = get_controls_container()

	match type:
		Type.TEXT:
			content_container = content_container as NoteTextControls
			return str(input) == content_container.content

	return true
