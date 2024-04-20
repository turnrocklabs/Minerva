class_name Note
extends PanelContainer

@onready var label_node: LineEdit = $h/v/HBoxContainer/Title
@onready var description_node: TextEdit = $h/v/Description
@onready var checkbutton_node: CheckButton = $h/v/HBoxContainer/CheckButton

@export var title: String
@export var description: String

# this will react each time memory item is changed
var memory_item: MemoryItem:
	set(value):
		if not value: return value
		label_node.text = value.Title
		description_node.text = value.Content
		checkbutton_node.button_pressed = value.Enabled

		memory_item = value

# when the drop is finished, show the dragged item again
func _notification(notification_type):
	match notification_type:
		NOTIFICATION_DRAG_END:
			modulate.a = 1

## Replaces the children nodes of same parent by changing their index
func _replace_nodes(node1: Node, node2: Node) -> void:
	var dragged_node_index = node1.get_index()

	get_parent().move_child(node1, get_index())
	get_parent().move_child(node2, dragged_node_index)

# will create a preview of the node that we are draggind and hide the original node
# the preview is just a duplicate of the original
func _get_drag_data(at_position: Vector2) -> Note:

	var preview = Container.new()
	var preview_note: Note = self.duplicate()

	preview.add_child(preview_note)
	preview.size = size
	preview_note.global_position = -at_position

	set_drag_preview(preview)

	# hide the original, and show it again on drag end
	modulate.a = 0

	return self

# this will check if we dragged the node above another Note node
# if yes, swich places with the original(hidden) node
func _can_drop_data(_at_position: Vector2, data):
	if not data is Note: return false
	
	for node in get_parent().get_children():
		if node is Note and node.get_rect().has_point(_at_position):
			_replace_nodes(data, self)

	return true

# if we dropped the node above another replace them with each other
func _drop_data(at_position: Vector2, data):
	data = data as Note

	_replace_nodes(data, self)
	

# if the check button is clicked update the MemoryItem state to reflect that
func _on_check_button_toggled(toggled_on: bool) -> void:
	if memory_item: memory_item.Enabled = toggled_on
