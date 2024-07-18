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
