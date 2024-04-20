class_name Draggable
extends Control



func _ready():
	for child in get_children():
		child.mouse_filter = MOUSE_FILTER_IGNORE




# var drag = false


# func _process(delta):
# 	if drag:
# 		global_position.y = get_viewport().get_mouse_position().y


# func _input(event):
# 	print(event)
# 	if event is InputEventMouseButton:
# 		if event.button_index == MOUSE_BUTTON_LEFT:
# 			drag = event.pressed