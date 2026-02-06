extends VBoxContainer
class_name NoteImageControls

@onready var _texture_rect: TextureRect = %TextureRect
@onready var _caption_line_edit: LineEdit = %LineEdit

var note: Note

var sha256: String:
	get: return Note.generate_content_sha256(image.save_png_to_buffer())

var _image_backing: Image
## Cached image to avoid expensive GPU->CPU texture extraction on every access
var _image_cache: Image

## The image content of the note.[br]
## If set image has a [caption] meta attached to it
## it's used as the image caption.[br]
## Like so, if there is a caption available it is set in the retuned image [caption] meta.
var image: Image:
	set(value):
		# Store a cached copy to avoid expensive get_image() calls on every access
		_image_cache = value.duplicate() if value else null

		if is_node_ready():
			# Only set texture if we have a valid, non-empty image
			if value and not value.is_empty():
				_texture_rect.texture = ImageTexture.create_from_image(value)
				if value.has_meta("caption"): # extract caption if available
					caption = value.get_meta("caption")
			else:
				push_warning("[NoteImageControls] Received null or empty image")
		else:
			_image_backing = value

		note.changed.emit(&"image")
	get:
		# Return cached image instead of expensive GPU->CPU texture extraction
		# Note: Returns reference to cached image - callers should duplicate if they need to modify
		if _image_cache:
			_image_cache.set_meta("caption", caption)
			return _image_cache
		elif is_node_ready() and _texture_rect.texture:
			# Fallback: extract from texture if cache is somehow missing
			_image_cache = _texture_rect.texture.get_image()
			_image_cache.set_meta("caption", caption)
			return _image_cache
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
	# Only create texture if we have a valid, non-empty backing image (set before ready)
	if _image_backing and not _image_backing.is_empty():
		_texture_rect.texture = ImageTexture.create_from_image(_image_backing)
		if _image_backing.has_meta("caption"): # extract caption if available
			caption = _image_backing.get_meta("caption")
		# Populate cache from backing image
		_image_cache = _image_backing.duplicate()
		_image_backing = null
	elif _image_backing:
		push_warning("[NoteImageControls] Backing image was empty")
		_image_backing = null

	_caption_line_edit.text = _caption_backing
	_caption_backing = ""


func _exit_tree() -> void:
	# Explicitly release the texture and cache to prevent leaks during shutdown
	if _texture_rect and _texture_rect.texture:
		print("[NoteImageControls] Releasing texture on exit")
		_texture_rect.texture = null
	_image_cache = null
