extends VBoxContainer
class_name NoteImageControls

@onready var _texture_rect: TextureRect = %TextureRect
@onready var _caption_line_edit: LineEdit = %LineEdit

## The image content of the note.[br]
## If set image has a [caption] meta attached to it
## it's used as the image caption.[br]
## Like so, if there is a caption available it is set in the retuned image [caption] meta.
var image: Image:
	set(value):
		_texture_rect.texture = ImageTexture.create_from_image(value)
		if value.has_meta("caption"): # extract caption if available
			caption = value.get_meta("caption")
	get:
		var img: = _texture_rect.texture.get_image()
		img.set_meta("caption", caption)
		return img

## Image caption.
var caption: String:
	set(value):
		_caption_line_edit.text = value
	get:
		return _caption_line_edit.text

func setup(note_image: Image, image_caption: String = ""):
	image = note_image
	caption = image_caption
