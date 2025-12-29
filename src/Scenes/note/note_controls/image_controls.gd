extends VBoxContainer
class_name NoteImageControls

@onready var _texture_rect: TextureRect = %TextureRect
@onready var _caption_line_edit: LineEdit = %LineEdit

var note: Note

var sha256: String:
	get: return Note.generate_content_sha256(image.save_png_to_buffer())

var _image_backing: Image
## The image content of the note.[br]
## If set image has a [caption] meta attached to it
## it's used as the image caption.[br]
## Like so, if there is a caption available it is set in the retuned image [caption] meta.
var image: Image:
	set(value):
		if is_node_ready():
			_texture_rect.texture = ImageTexture.create_from_image(value)
			if value.has_meta("caption"): # extract caption if available
				caption = value.get_meta("caption")
		else:
			_image_backing = value

		note.changed.emit()
	get:
		if is_node_ready():
			var img: = _texture_rect.texture.get_image()
			img.set_meta("caption", caption)
			return img
		else:
			return _image_backing

var _caption_backing: String
## Image caption.
var caption: String:
	set(value):
		if is_node_ready():
			_caption_line_edit.text = value
		else:
			_caption_backing = value
		
		note.changed.emit() # maybe need a separate line edit signal to catch changed from the UI
	get:
		return _caption_line_edit.text if is_node_ready() else _caption_backing

func setup(owner_note: Note, note_image: Image, image_caption: String = ""):
	note = owner_note
	
	image = note_image
	caption = image_caption


func _ready() -> void:
	# Only create texture if we have a backing image (set before ready)
	if _image_backing:
		_texture_rect.texture = ImageTexture.create_from_image(_image_backing)
		if _image_backing.has_meta("caption"): # extract caption if available
			caption = _image_backing.get_meta("caption")
		_image_backing = null

	_caption_line_edit.text = _caption_backing
	_caption_backing = ""


func _exit_tree() -> void:
	# Explicitly release the texture to prevent leaks during shutdown
	if _texture_rect and _texture_rect.texture:
		print("[NoteImageControls] Releasing texture on exit")
		_texture_rect.texture = null
