class_name AnnotationDockPane
extends VBoxContainer
## Per-editor annotation dock primitive.
##
## The pane owns the visibility affordance and mounts a substrate workbench.
## Editors/plugins can reparent this node into right or bottom split areas; the
## pane keeps its host and visibility state stable across that move.

signal repair_requested(annotation_id: String)
signal add_comment_requested(text: String)
signal annotation_selected(annotation_id: String)
signal active_tool_changed(tool: AnnotationAuthorTool)

enum DockMode { RIGHT, BOTTOM }

var dock_mode: DockMode = DockMode.BOTTOM
var _collapsed := true
var _host: RefCounted = null
var _chevron: Button
const _AnnotationWorkbenchScript = preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationWorkbench.gd")
var _workbench: Control = null
var _toolbar: AnnotationToolbar = null

const _RIGHT_EXPANDED_MIN := Vector2(260, 0)
const _RIGHT_COLLAPSED_MIN := Vector2(30, 0)
const _BOTTOM_EXPANDED_MIN := Vector2(0, 132)
const _BOTTOM_COLLAPSED_MIN := Vector2(0, 24)
const _CHEVRON_SIZE := Vector2(24, 20)


func _ready() -> void:
	_build_ui()


func set_host(host: RefCounted) -> void:
	_host = host
	_ensure_ui()
	if _workbench.has_method("set_host"):
		_workbench.set_host(host)
	if _toolbar != null and host is AnnotationHost:
		var ann_host := host as AnnotationHost
		_toolbar.set_registry(ann_host.get_registry())
		_toolbar.set_host(ann_host)


func get_workbench() -> Control:
	_ensure_ui()
	return _workbench


func get_toolbar() -> AnnotationToolbar:
	_ensure_ui()
	return _toolbar


func set_dock_mode(mode: DockMode) -> void:
	dock_mode = mode
	_apply_layout_state()


func set_can_add_comment(value: bool) -> void:
	_ensure_ui()
	if _workbench.has_method("set_can_add_comment"):
		_workbench.set_can_add_comment(value)


func begin_add_comment_flow() -> void:
	_ensure_ui()
	_set_collapsed(false)
	if _workbench.has_method("begin_add_comment_flow"):
		_workbench.begin_add_comment_flow()


func show_status(message: String) -> void:
	_ensure_ui()
	if _workbench.has_method("show_status"):
		_workbench.show_status(message)


func enter_retarget_mode(annotation_id: String) -> void:
	_ensure_ui()
	if _workbench.has_method("enter_retarget_mode"):
		_workbench.enter_retarget_mode(annotation_id)


func exit_retarget_mode() -> void:
	_ensure_ui()
	if _workbench.has_method("exit_retarget_mode"):
		_workbench.exit_retarget_mode()


func refresh() -> void:
	_ensure_ui()
	if _workbench.has_method("refresh"):
		_workbench.refresh()


func _ensure_ui() -> void:
	if _workbench == null:
		_build_ui()


func _build_ui() -> void:
	if _workbench != null:
		return
	add_theme_constant_override("separation", 4)

	_chevron = Button.new()
	_chevron.text = "v"
	_chevron.tooltip_text = "Toggle annotations"
	_chevron.focus_mode = Control.FOCUS_NONE
	_chevron.custom_minimum_size = _CHEVRON_SIZE
	_chevron.size_flags_horizontal = Control.SIZE_SHRINK_END
	_chevron.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_chevron.pressed.connect(_toggle_collapsed)
	add_child(_chevron)

	_toolbar = AnnotationToolbar.new()
	_toolbar.name = "AnnotationToolbar"
	_toolbar.presentation_mode = AnnotationToolbar.PresentationMode.COMPACT
	_toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.active_tool_changed.connect(func(tool: AnnotationAuthorTool) -> void: active_tool_changed.emit(tool))
	add_child(_toolbar)

	_workbench = _AnnotationWorkbenchScript.new()
	_workbench.name = "AnnotationWorkbench"
	_workbench.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_workbench.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_workbench.connect("repair_requested", func(id: String) -> void: repair_requested.emit(id))
	_workbench.connect("add_comment_requested", func(text: String) -> void: add_comment_requested.emit(text))
	_workbench.connect("annotation_selected", func(id: String) -> void: annotation_selected.emit(id))
	add_child(_workbench)
	_apply_layout_state()
	if _host != null and _workbench.has_method("set_host"):
		_workbench.set_host(_host)


func _toggle_collapsed() -> void:
	_set_collapsed(not _collapsed)


func _set_collapsed(value: bool) -> void:
	_collapsed = value
	_apply_layout_state()


func _apply_layout_state() -> void:
	if _toolbar != null:
		_toolbar.visible = not _collapsed
	if _workbench != null:
		_workbench.visible = not _collapsed
	if _chevron != null:
		if dock_mode == DockMode.RIGHT:
			_chevron.text = "<" if _collapsed else ">"
		else:
			_chevron.text = "^" if _collapsed else "v"
	if dock_mode == DockMode.RIGHT:
		custom_minimum_size = _RIGHT_COLLAPSED_MIN if _collapsed else _RIGHT_EXPANDED_MIN
		size_flags_horizontal = Control.SIZE_SHRINK_END
		size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		custom_minimum_size = _BOTTOM_COLLAPSED_MIN if _collapsed else _BOTTOM_EXPANDED_MIN
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		size_flags_vertical = Control.SIZE_SHRINK_END
