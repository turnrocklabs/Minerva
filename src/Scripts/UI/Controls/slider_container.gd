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

@export var offset_distance: float = 100.0  # Distance between cards
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
			child.pivot_offset = Vector2(child.size.x/2, 0)
			if i == active_child_index:
				child.modulate = Color(1.0, 1.0, 1.0, 1.0)
				child.z_index = 10
				child.mouse_filter = Control.MOUSE_FILTER_STOP
				if child is MessageMarkdown:
					child._enable_input()
			else:
				child.mouse_filter = Control.MOUSE_FILTER_PASS
				child.modulate = Color(0.8, 0.8, 0.8, 1.0)
				child.z_index = 0
				if child is MessageMarkdown:
					child._block_input()


func _calculate_child_position(child_index: int) -> Vector2:
	var relative_index = child_index - active_child_index
	# Center position calculation for X
	var center_x = (size.x - get_child(child_index).size.x) / 2
	
	# For Y, active child should be at the top
	var y_position = 0.0
	if child_index != active_child_index:
		# Inactive children positioned below the active child
		y_position = offset_distance / 3
	
	# Apply offset based on relative position to active child
	var x_offset = relative_index * offset_distance
	
	return Vector2(center_x + x_offset, y_position)


func _calculate_child_scale(child_index: int) -> float:
	return 1.0 if child_index == active_child_index else inactive_scale


func _animate_children() -> void:
	if _current_tween:
		_current_tween.kill()
	
	_current_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_current_tween.set_parallel(true)
	
	for i in get_child_count():
		var child = get_child(i)
		if child is Control:
			var target_pos = _calculate_child_position(i)
			var target_scale = _calculate_child_scale(i)
			if i == active_child_index:
				child.modulate = Color(1.0, 1.0, 1.0, 1.0)
				child.z_index = 10
				child.mouse_filter = Control.MOUSE_FILTER_STOP
				if child is MessageMarkdown:
					child._enable_input()
			else:
				child.modulate = Color(0.8, 0.8, 0.8, 1.0)
				child.z_index = 0
				child.mouse_filter = Control.MOUSE_FILTER_PASS
				if child is MessageMarkdown:
					child._block_input()
			# Position animation
			_current_tween.tween_property(
				child,
				"position",
				target_pos,
				transition_duration)
			
			# Scale animation
			_current_tween.tween_property(
				child,
				"scale",
				Vector2(target_scale, target_scale),
				transition_duration)


func _on_sort_children() -> void:
	for i in get_child_count():
		var child = get_child(i)
		if child is Control:
			child.pivot_offset = Vector2(child.size.x/2, 0)
	
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


func _on_child_entered_tree(node: Node) -> void:
	if node is Control:
		node.resized.connect(_animate_children)
