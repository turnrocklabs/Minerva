class_name AnnotationOverlay
extends Control
## Shared base for editor annotation overlays.
##
## The important contract is input discipline: overlays are transparent while
## idle and only claim pointer/key events while an authoring or manipulation tool
## is active. Control.MOUSE_FILTER_PASS is deliberately avoided because it does
## not forward events to siblings behind the overlay.

signal active_tool_changed(tool: Object)

var _active_tool: Object = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_active_tool(tool: Object) -> void:
	if _active_tool == tool:
		return
	if _active_tool != null and _active_tool.has_method("on_deactivate"):
		_active_tool.on_deactivate()
	_active_tool = tool
	mouse_filter = Control.MOUSE_FILTER_STOP if _active_tool != null else Control.MOUSE_FILTER_IGNORE
	active_tool_changed.emit(_active_tool)


func clear_active_tool() -> void:
	set_active_tool(null)


func has_active_tool() -> bool:
	return _active_tool != null


func _gui_input(event: InputEvent) -> void:
	if _active_tool == null:
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.pressed and key.keycode == KEY_ESCAPE:
			clear_active_tool()
			accept_event()
			return
	if _active_tool.has_method("handle_input"):
		var handled: Variant = _active_tool.call("handle_input", event)
		if bool(handled):
			accept_event()
