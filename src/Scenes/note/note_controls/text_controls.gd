extends VBoxContainer
class_name NoteTextControls

@onready var _label: Label = %Label

## The text content of the note.
var content: String:
    set(value):
        _label.text = value
    get:
        return _label.text


func setup(note_content: String):
    content = note_content
