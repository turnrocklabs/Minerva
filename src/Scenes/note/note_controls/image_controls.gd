extends VBoxContainer
class_name NoteImageControls

@onready var _texture_rect: TextureRect = %TextureRect
@onready var _caption_line_edit: LineEdit = %LineEdit

var note: Note

var sha256: String:
	get: return Note.generate_content_sha256(image.save_png_to_buffer())

## The image content of the note.[br]
## If set image has a [caption] meta attached to it
## it's used as the image caption.[br]
## Like so, if there is a caption available it is set in the retuned image [caption] meta.
var image: Image:
	set(value):
		_texture_rect.texture = ImageTexture.create_from_image(value)
		if value.has_meta("caption"): # extract caption if available
			caption = value.get_meta("caption")
		
		note.changed.emit()
	get:
		var img: = _texture_rect.texture.get_image()
		img.set_meta("caption", caption)
		return img

## Image caption.
var caption: String:
	set(value):
		_caption_line_edit.text = value
		note.changed.emit() # maybe need a separate line edit signal to catch changed from the UI
	get:
		return _caption_line_edit.text

func setup(owner_note: Note, note_image: Image, image_caption: String = ""):
	note = owner_note
	
	image = note_image
	caption = image_caption

