extends BaseTool
class_name SpeechBubbleTool

var _drag_start_position: Vector2
var _drag_point_idx: int


func _tool_selected():
	pass



func handle_input_event(event: InputEvent) -> void:
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:

		if editor.active_layer.type != LayerV2.Type.SPEECH_BUBBLE:
			if event.pressed:
				var layer = LayerV2.create_speech_bubble_layer("Layer")
				layer.custom_minimum_size = Vector2(100, 100)
				editor.add_layer(layer)

		else:
			if event.pressed:
				_drag_start_position = event.position
			else:
				_drag_point_idx = -1

				if _drag_start_position.is_equal_approx(event.position):
					# if we didn't click on any points, add a new one
					if _drag_point_idx == -1:
						# var closest_point: = get_closest_polyline_position(bubble_poly, event.position)

						var idx: = editor.active_layer.speech_bubble.get_closest_ellipse_line(event.position)

						var closest_point = editor.active_layer.speech_bubble.bubble_poly[idx]

						if event.position.distance_to(closest_point) < 60 and not Input.is_physical_key_pressed(KEY_SHIFT):
							# var ratio: = get_closest_point_distance_ratio(bubble_poly, closest_point)
							editor.active_layer.speech_bubble.tail.add_point(idx)
						else:
							editor.active_layer.speech_bubble.tail.add_point(event.position)

	if event is InputEventMouseMotion:			
		# if we're moving the mouse, pressing the mouse button and dragging the point
		# update that points position.
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and _drag_point_idx != -1:
			# var closest_point: = get_closest_polyline_position(bubble_poly, event.position)

			var idx: = editor.active_layer.speech_bubble.get_closest_ellipse_line(event.position)

			var closest_point = editor.active_layer.speech_bubble.bubble_poly[idx]

			if event.position.distance_to(closest_point) < 60 and not Input.is_physical_key_pressed(KEY_SHIFT):
				# var ratio: = get_closest_point_distance_ratio(bubble_poly, closest_point)
				editor.active_layer.speech_bubble.tail.points[_drag_point_idx] = idx
			else:
				editor.active_layer.speech_bubble.tail.points[_drag_point_idx] = event.position

	if editor.active_layer.type == LayerV2.Type.SPEECH_BUBBLE:
		editor.active_layer.speech_bubble.handle_event(event)


func _get_drag_data(at_position: Vector2) -> Variant:
	at_position = at_position - editor.active_layer.position
	
	print("Drag:", at_position)

	# Check if we pressed on existing tail point
	var points_arr: = editor.active_layer.speech_bubble.tail.get_points_vector_array()

	for i in points_arr.size():
		var point: = points_arr[i]

		prints(at_position, point)

		# if yes start dragging it
		if at_position.distance_to(point) < editor.active_layer.speech_bubble.POINT_RADIUS:
			_drag_point_idx = i 
			return null


	if editor.active_layer.speech_bubble.get_rect().grow(15).has_point(at_position):
		editor.active_layer.speech_bubble._dragging = true
	

	return null

func _can_drop_data(_at_position: Vector2, _data: Variant) -> bool:
	return true	


func _on_edit_mode_check_button_toggled(toggled_on: bool) -> void:
	editor.active_layer.speech_bubble.editing = toggled_on
	editor.active_layer.queue_redraw()


func _on_line_edit_text_changed(new_text: String) -> void:
	editor.active_layer.speech_bubble.text = new_text
	editor.active_layer.queue_redraw()
