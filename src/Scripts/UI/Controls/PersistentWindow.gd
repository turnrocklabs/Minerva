#@tool
class_name PersistentWindow
extends Window

## Design-time sizes (1x scale) — captured before any scaling is applied
var _base_size: Vector2i
var _base_min_size: Vector2i


func _ready():
	if $".".name != "Drawer":
		close_requested.connect(hide)
	#exclusive = true
	transient = true

	# Store design-time sizes before scaling
	_base_size = size
	_base_min_size = min_size

	# Sync UI scale from root viewport (sub-windows don't inherit content_scale_factor)
	_apply_content_scale()
	about_to_popup.connect(_sync_content_scale)

	var panel = Panel.new()
	add_child(panel, false, INTERNAL_MODE_FRONT)
	panel.anchors_preset = Control.PRESET_FULL_RECT


func _sync_content_scale():
	_apply_content_scale()


func _apply_content_scale():
	var scale: float = get_tree().root.content_scale_factor
	content_scale_factor = scale
	if scale != 1.0:
		min_size = Vector2i(Vector2(_base_min_size) * scale)
		size = Vector2i(Vector2(_base_size) * scale)
