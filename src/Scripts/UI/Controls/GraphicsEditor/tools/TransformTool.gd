class_name TransformTool
extends BaseTool

var _control_point_type: LayerV2.TransformPoint = LayerV2.TransformPoint.NONE

func _ready() -> void:
	
	# each time the tool is changed to this one, update the custom cursor
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				editor.active_layer.transform_rect_visible = true
	)

func handle_input_event(event: InputEvent) -> void:
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:
		if event.pressed:
			_control_point_type = editor.active_layer.get_rect_by_mouse_position(event.position)
		else:
			_control_point_type = LayerV2.TransformPoint.NONE

	elif event is InputEventMouseMotion:
		match _control_point_type:
			LayerV2.TransformPoint.TOP_LEFT:
				editor.active_layer.position += event.relative
				editor.active_layer.custom_minimum_size -= event.relative
			LayerV2.TransformPoint.TOP:
				editor.active_layer.position.y += event.relative.y
				editor.active_layer.custom_minimum_size.y -= event.relative.y
			LayerV2.TransformPoint.TOP_RIGHT:
				editor.active_layer.custom_minimum_size += event.relative *  Vector2(1, -1)
				editor.active_layer.position.y += event.relative.y
			LayerV2.TransformPoint.RIGHT:
				editor.active_layer.custom_minimum_size.x += event.relative.x
			LayerV2.TransformPoint.BOTTOM_RIGHT:
				editor.active_layer.custom_minimum_size += event.relative
			LayerV2.TransformPoint.BOTTOM:
				editor.active_layer.custom_minimum_size.y += event.relative.y
			LayerV2.TransformPoint.BOTTOM_LEFT:
				editor.active_layer.custom_minimum_size += event.relative * Vector2(-1, 1)
				editor.active_layer.position.x += event.relative.x
			LayerV2.TransformPoint.LEFT:
				editor.active_layer.position.x += event.relative.x
				editor.active_layer.custom_minimum_size.x -= event.relative.x

		editor.queue_redraw()


func _draw():
	pass
	
