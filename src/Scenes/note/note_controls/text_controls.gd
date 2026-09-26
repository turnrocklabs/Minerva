extends VBoxContainer
class_name NoteTextControls

@onready var _label: RichTextLabel = %Label

var note: Note

var sha256: String:
	get: return Note.generate_content_sha256(content.to_utf8_buffer())

## Ordered entries and revision behind [member content]; the body it holds is
## the note's text. Serialized alongside Content by Note.serialize.
var entry_log: NoteEntryLog = NoteEntryLog.new()

## The text content of the note. Setting it replaces the whole body; the log
## keeps the ids of entries the edit left untouched and bumps its revision.
var content: String:
	set(value):
		entry_log.set_body(value)
		_show_body()
	get:
		return entry_log.get_body()


func setup(owner_note: Note, note_content: String):
	note = owner_note
	
	content = note_content


## Appends [param text] as a new entry without rewriting the existing ones.
func append_entry(text: String, author: String) -> NoteEntryLog.Entry:
	var entry: = entry_log.append(text, author)
	_show_body()
	return entry


func _show_body() -> void:
	if is_node_ready():
		_label.text = entry_log.get_body()
	note.changed.emit(&"content")


func _ready() -> void:
	_label.text = entry_log.get_body()
