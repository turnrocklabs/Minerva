#@tool
class_name PersistentWindow
extends Window


func _ready():
	close_requested.connect(hide)
	#exclusive = true
	transient = true

	var panel = Panel.new()
	add_child(panel, false, INTERNAL_MODE_FRONT)
	panel.anchors_preset = Control.PRESET_FULL_RECT
