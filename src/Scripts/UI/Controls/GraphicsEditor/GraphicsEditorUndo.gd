class_name GraphicsEditorUndo

# Base command class
class Command extends RefCounted:
	func execute() -> void:
		pass
	
	func undo() -> void:
		pass
	
	func redo() -> void:
		pass
	
	func get_description() -> String:
		return "Unknown Action"

# Transform command for position, rotation, scale
class TransformCommand extends Command:
	var layer: LayerV2
	
	func get_target_layer() -> LayerV2:
		return layer
	var old_position: Vector2
	var new_position: Vector2
	var old_rotation: float
	var new_rotation: float
	var old_scale: Vector2
	var new_scale: Vector2
	
	func _init(target_layer: LayerV2):
		layer = target_layer
		# Capture current state as "old"
		old_position = layer.position
		old_rotation = layer.rotation
		old_scale = layer.scale
	
	func set_new_transform(pos: Vector2, rot: float, scale_vec: Vector2):
		new_position = pos
		new_rotation = rot
		new_scale = scale_vec
	
	func execute() -> void:
		layer.position = new_position
		layer.rotation = new_rotation
		layer.scale = new_scale
	
	func undo() -> void:
		layer.position = old_position
		layer.rotation = old_rotation
		layer.scale = old_scale
	
	func redo() -> void:
		execute()
	
	func get_description() -> String:
		return "Transform LayerV2"

# Resize/expand command for layer image changes
class ResizeCommand extends Command:
	var layer: LayerV2
	
	func get_target_layer() -> LayerV2:
		return layer
	var old_image: Image
	var new_image: Image
	var old_position: Vector2
	var new_position: Vector2
	
	func _init(target_layer: LayerV2, new_pos: Vector2 = Vector2.ZERO):
		layer = target_layer
		old_image = layer.image.duplicate()
		old_position = layer.position
		new_position = new_pos if new_pos != Vector2.ZERO else layer.position
	
	func set_new_image(image: Image):
		new_image = image.duplicate()
	
	func execute() -> void:
		if new_image:
			layer.image = new_image.duplicate()
		layer.position = new_position
	
	func undo() -> void:
		layer.image = old_image.duplicate()
		layer.position = old_position
	
	func redo() -> void:
		execute()
	
	func get_description() -> String:
		return "Resize LayerV2"

# Drawing command for brush strokes
class DrawStrokeCommand extends Command:
	var layer: LayerV2
	
	func get_target_layer() -> LayerV2:
		return layer
	var before_image: Image
	var after_image: Image
	var stroke_bounds: Rect2i
	var use_full_image: bool = false
	
	func _init(target_layer: LayerV2, bounds: Rect2i = Rect2i()):
		layer = target_layer
		stroke_bounds = bounds
		
		# Decide whether to save full image or just region
		var layer_size = layer.image.get_size()
		var bounds_area = bounds.size.x * bounds.size.y if bounds != Rect2i() else layer_size.x * layer_size.y
		var total_area = layer_size.x * layer_size.y
		
		# If stroke affects more than 25% of layer, save full image
		use_full_image = bounds_area > (total_area * 0.25) or bounds == Rect2i()
		
		if use_full_image:
			before_image = layer.image.duplicate()
		else:
			# Save only the affected region
			before_image = layer.image.get_region(bounds)
	
	func finalize_stroke():
		# Call this after drawing is complete
		if use_full_image:
			after_image = layer.image.duplicate()
		else:
			after_image = layer.image.get_region(stroke_bounds)
	
	func execute() -> void:
		# Drawing already happened, just restore after state
		redo()
	
	func undo() -> void:
		if use_full_image:
			layer.image = before_image.duplicate()
		else:
			layer.image.blit_rect(before_image, Rect2i(Vector2i.ZERO, before_image.get_size()), stroke_bounds.position)
	
	func redo() -> void:
		if after_image:
			if use_full_image:
				layer.image = after_image.duplicate()
			else:
				layer.image.blit_rect(after_image, Rect2i(Vector2i.ZERO, after_image.get_size()), stroke_bounds.position)
	
	func get_description() -> String:
		return "Draw Stroke"
