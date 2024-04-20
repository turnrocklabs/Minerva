class_name Note
extends PanelContainer

@onready var label_node: LineEdit = $VBoxContainer/Title
@onready var description_node: TextEdit = $VBoxContainer/Description

@export var title: String
@export var description: String


var memory_item: MemoryItem:
	set(value):
		if not value: return value
		
		label_node.text = value.Title
		description_node.text = value.Content

		memory_item = value


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

		if node.get_rect().has_point(_at_position) and node is Note:
			_replace_nodes(data, self)

	return true

func _drop_data(_at_position: Vector2, data):
	data = data as Note

	print("%s -> %s" % [data.get_index(), get_index()])

	_replace_nodes(data, self)
	
