class_name Note
extends PanelContainer

@onready var label_node: LineEdit = $h/v/HBoxContainer/Title
@onready var description_node: TextEdit = $h/v/Description
@onready var checkbutton_node: CheckButton = $h/v/HBoxContainer/CheckButton

@export var title: String
@export var description: String


var memory_item: MemoryItem = MemoryItem.new("TEST NOTE BREE"):
	set(value):
		if not value: return value
		label_node.text = value.Title
		description_node.text = value.Content
		checkbutton_node.toggle_mode = value.Enabled

		return value


func _ready():
	memory_item.Title = title
	memory_item.Content = description

	label_node.text = title
	description_node.text = description


func _notification(notification_type):
	match notification_type:
		NOTIFICATION_DRAG_END:
			modulate.a = 1

## Replaces the children nodes of same parent by changing their index
func _replace_nodes(node1: Node, node2: Node) -> void:
	var dragged_node_index = node1.get_index()

	# var tween = get_tree().create_tween()
	# tween.tween_property(node2, "position:y", node1.position.y, 0.1)

	get_parent().move_child(node1, get_index())
	get_parent().move_child(node2, dragged_node_index)


func _get_drag_data(at_position: Vector2) -> Note:

	var preview = Container.new()
	var preview_note: Note = self.duplicate()

	preview.add_child(preview_note)
	preview.size = size
	preview_note.global_position = -at_position

	set_drag_preview(preview)

	modulate.a = 0

	return self

func _can_drop_data(_at_position: Vector2, data):
	if not data is Note: return false
	
	for node in get_parent().get_children():
		if node is Note and node.get_rect().has_point(_at_position):
			_replace_nodes(data, self)

	return true

func _drop_data(at_position: Vector2, data):
	data = data as Note

	_replace_nodes(data, self)
	


func _on_check_button_toggled(toggled_on: bool) -> void:
	memory_item.Enabled = toggled_on
