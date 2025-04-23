@tool
class_name SliderContainer
extends Container

signal active_child_changed(index: int)

@export var active_child_index: int = 0:
	set(value):
		var old_index = active_child_index
		active_child_index = wrap(value, 0, get_child_count())
		if old_index != active_child_index:
			_animate_children()
			active_child_changed.emit(active_child_index)

@export var offset_distance: float = 30.0  # Distance between cards
@export var transition_duration: float = 0.3
@export var inactive_scale: float = 0.8  # Scale for inactive children

var _current_tween: Tween

func _init() -> void:
	sort_children.connect(_on_sort_children)

func _ready() -> void:
	_position_children_immediately()

func _position_children_immediately() -> void:
	for i in get_child_count():
		var child = get_child(i)
		if child is Control:
			var target_pos = _calculate_child_position(i)
			var target_scale = _calculate_child_scale(i)
			child.position = target_pos
			child.scale = Vector2(target_scale, target_scale)
			child.pivot_offset = child.size / 2
			if i == active_child_index:
				child.modulate = Color(1.0, 1.0, 1.0, 1.0)
				child.z_index = 10
			else:
				child.modulate = Color(0.8, 0.8, 0.8, 1.0)
				child.z_index = 0

func _calculate_child_position(child_index: int) -> Vector2:
	var relative_index = child_index - active_child_index
	# Center position calculation
	var center_x = (size.x - get_child(child_index).size.x) / 2
	var center_y = (size.y - get_child(child_index).size.y) / 2
	
	# Apply offset based on relative position to active child
	var x_offset = relative_index * offset_distance
	
	return Vector2(center_x + x_offset, center_y)

func _calculate_child_scale(child_index: int) -> float:
	return 1.0 if child_index == active_child_index else inactive_scale

func _animate_children() -> void:
	if _current_tween:
		_current_tween.kill()
	
	_current_tween = create_tween()
	_current_tween.set_parallel(true)
	
	for i in get_child_count():
		var child = get_child(i)
		if child is Control:
			var target_pos = _calculate_child_position(i)
			var target_scale = _calculate_child_scale(i)
			if i == active_child_index:
				child.modulate = Color(1.0, 1.0, 1.0, 1.0)
				child.z_index = 10
			else:
				child.modulate = Color(0.8, 0.8, 0.8, 1.0)
				child.z_index = 0
			# Position animation
			_current_tween.tween_property(
				child,
				"position",
				target_pos,
				transition_duration
			).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			
			# Scale animation
			_current_tween.tween_property(
				child,
				"scale",
				Vector2(target_scale, target_scale),
				transition_duration
			).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _on_sort_children() -> void:
	for i in get_child_count():
		var child = get_child(i)
		if child is Control:
			child.pivot_offset = child.size / 2
	
	if not Engine.is_editor_hint():
		_position_children_immediately()

func _get_minimum_size() -> Vector2:
	var min_size := Vector2.ZERO
	for child in get_children():
		if child is Control:
			var child_min_size = child.get_combined_minimum_size()
			min_size.x = max(min_size.x, child_min_size.x)
			min_size.y = max(min_size.y, child_min_size.y)
	return min_size

func next_child() -> void:
	active_child_index += 1

func previous_child() -> void:
	active_child_index -= 1

func wrap(value: int, min_value: int, max_value: int) -> int:
	var range_size = max_value - min_value
	if range_size == 0:
		return min_value
	var result = value - min_value
	result = result % range_size
	if result < 0:
		result += range_size
	return result + min_value
