extends VBoxContainer
class_name NoteTextControls

@onready var _label: RichTextLabel = %Label

var note: Note

var sha256: String:
	get: return Note.generate_content_sha256(content.to_utf8_buffer())

var _content_backing: String
## The text content of the note.
var content: String:
	set(value):
		if is_node_ready():
			_label.text = value
		else:
			_content_backing = value
		
		note.changed.emit()
	get:
		return _label.text if is_node_ready() else _content_backing


func setup(owner_note: Note, note_content: String):
	note = owner_note
	
	content = note_content


func _ready() -> void:
	_label.text = _content_backing

	_content_backing = ""
