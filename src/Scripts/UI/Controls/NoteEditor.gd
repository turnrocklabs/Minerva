class_name NoteEditor
extends VBoxContainer

signal on_memory_item_changed()

@onready var code_edit: CodeEdit = get_node("CodeEdit")

var memory_item: MemoryItem
var type = Editor.TYPE.Text

func _ready():
	code_edit.text = memory_item.Content

static func create(memory_item_: MemoryItem) -> NoteEditor:
	var node = preload("res://Scenes/NoteEditor.tscn").instantiate()
	
	node.memory_item = memory_item_

	return node


func _on_save_button_pressed():
	memory_item.Content = code_edit.text
	on_memory_item_changed.emit()


func delete_chars() -> void:
	code_edit.backspace()
	code_edit.grab_focus()
	
	#if code_edit.get_selected_text().length()  < 1:
		#var caret_col = code_edit.get_caret_column()
		#var caret_line = code_edit.get_caret_line()
		#var first_half = code_edit.text.substr(0, caret_pos)
		#var snd_half = code_edit.text.substr(caret_pos, code_edit.text.length())
		#code_edit.text = first_half.erase(first_half.length() - 1, 1) + snd_half
		#code_edit.set_caret_column(caret_pos - 1)
		#
		#code_edit.grab_focus()
		#return


func add_new_line() -> void:
	code_edit.insert_text_at_caret("\n")
	code_edit.grab_focus()


func undo_action():
	code_edit.undo()
	code_edit.grab_focus()


func clear_text():
	code_edit.clear()
	code_edit.grab_focus()
