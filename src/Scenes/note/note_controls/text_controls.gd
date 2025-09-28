extends VBoxContainer
class_name NoteTextControls

@onready var _label: Label = %Label

var note: Note

var sha256: String:
	get: return Note.generate_content_sha256(content.to_utf8_buffer())

## The text content of the note.
var content: String:
	set(value):
		_label.text = value
		note.changed.emit()
	get:
		return _label.text


func setup(owner_note: Note, note_content: String):
	note = owner_note
	
	content = note_content
