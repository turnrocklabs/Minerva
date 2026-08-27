class_name AnnotationDockPane
extends VBoxContainer
## Per-editor annotation dock primitive.
##
## The pane owns the visibility affordance and mounts a substrate workbench.
## Editors/plugins can reparent this node into right or bottom split areas; the
## pane keeps its host and visibility state stable across that move.
##
## Height (BOTTOM mode): the pane opens at a third of the editor tab's height
## and never takes more than half of it — on open, on a grip drag, and on a
## window resize — so the document always keeps the other half. The policy
## numbers live in AnnotationDockSizing; _apply_height_budget explains why the
## budget has to be spent on a scroll region rather than merely capped.

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
const _WorkflowAnnotationListScript = preload("res://Scripts/UI/Controls/AnnotationDockPane/WorkflowAnnotationList.gd")
var _workbench: Control = null
var _workflow_list: Control = null
var _toolbar: AnnotationToolbar = null
const _AnnotationDockSizingScript = preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationDockSizing.gd")

## Grip along the pane's top edge in BOTTOM mode. Dragging it up/down is the
## only way the user resizes the dock, so it is the sole writer of
## _preferred_height.
var _resize_handle: HSeparator = null
## Height the user last dragged this pane to, in pixels; 0 = never dragged, use
## the opening third. Per-tab memory comes for free: one pane per editor tab,
## and Editor reuses the same pane across plugin-surface reloads.
var _preferred_height: float = 0.0
## The Control whose height the pane budgets against — the editor tab, set by
## the host at mount time. Never written by the pane; only read.
var _height_source: Control = null
## The pane's single scrolling region: toolbar + both lists live inside it, so
## the pane's height is a number we set, not a sum of whatever the lists grew
## to. Only the grip and the chevron sit outside it.
var _dock_scroll: ScrollContainer = null
var _dock_body: VBoxContainer = null
var _dragging_height: bool = false
var _drag_start_pointer_y: float = 0.0
var _drag_start_height: float = 0.0

const _RIGHT_EXPANDED_MIN := Vector2(260, 0)
const _RIGHT_COLLAPSED_MIN := Vector2(30, 0)
const _BOTTOM_EXPANDED_MIN := Vector2(0, 132)
const _BOTTOM_COLLAPSED_MIN := Vector2(0, 24)
const _CHEVRON_SIZE := Vector2(24, 20)
const _HANDLE_SIZE := Vector2(0, 8)


func _ready() -> void:
	_build_ui()


func set_host(host: RefCounted) -> void:
	_host = host
	_ensure_ui()
	if _workbench.has_method("set_host"):
		_workbench.set_host(host)
	if _workflow_list != null and _workflow_list.has_method("set_host"):
		_workflow_list.set_host(host)
	if _toolbar != null and host is AnnotationHost:
		var ann_host := host as AnnotationHost
		_toolbar.set_registry(ann_host.get_registry())
		_toolbar.set_host(ann_host)
	# Row count drives how much of the budget the workflow strip asks for, so
	# the split is recomputed after every list refresh. Deferred: the lists are
	# connected first (above) and re-clamp their own scrolls deferred too.
	var budget_callable := Callable(self, "_refresh_height_budget")
	if _host != null and _host.has_signal("annotations_changed") \
			and not _host.is_connected("annotations_changed", budget_callable):
		_host.connect("annotations_changed", budget_callable)
	_refresh_height_budget()


## The editor tab whose vertical space the dock is allowed a share of. Hosts
## call this at mount time; without it the pane falls back to the viewport,
## which is only right for a full-window editor.
func set_available_height_source(source: Control) -> void:
	if _height_source == source:
		return
	var resized_callable := Callable(self, "_refresh_height_budget")
	if _height_source != null and is_instance_valid(_height_source) \
			and _height_source.resized.is_connected(resized_callable):
		_height_source.resized.disconnect(resized_callable)
	_height_source = source
	if _height_source != null and not _height_source.resized.is_connected(resized_callable):
		_height_source.resized.connect(resized_callable)
	_apply_height_budget()


## User-set dock height (the drag's only entry point, and the one tests drive).
## Clamped to the 50 % cap before it is remembered, so a stored size can never
## reappear oversized after a window resize.
func set_preferred_height(height: float) -> void:
	_preferred_height = _AnnotationDockSizingScript.clamp_height(height, _available_height())
	_apply_height_budget()


func get_preferred_height() -> float:
	return _preferred_height


func get_workbench() -> Control:
	_ensure_ui()
	return _workbench


## The workflow-annotation listing surface (workflow-class kinds ONLY — the
## review workbench excludes them; pcb-ui-native-cluster §4).
func get_workflow_list() -> Control:
	_ensure_ui()
	return _workflow_list


func get_toolbar() -> AnnotationToolbar:
	_ensure_ui()
	return _toolbar


func clear_active_tool() -> void:
	_ensure_ui()
	if _toolbar != null:
		_toolbar.clear_active_tool()


## Expand/collapse from outside the pane — the chevron's own path, exposed so
## hosts and tests drive the real state change instead of poking the button.
func set_collapsed(value: bool) -> void:
	_ensure_ui()
	_set_collapsed(value)


func is_collapsed() -> bool:
	return _collapsed


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

	# Top-edge grip (BOTTOM mode only — a RIGHT-docked pane fills its column and
	# has no height of its own to give away).
	_resize_handle = HSeparator.new()
	_resize_handle.name = "ResizeHandle"
	_resize_handle.custom_minimum_size = _HANDLE_SIZE
	_resize_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	_resize_handle.mouse_default_cursor_shape = Control.CURSOR_VSPLIT
	_resize_handle.tooltip_text = "Drag to resize the annotations dock"
	_resize_handle.gui_input.connect(_on_resize_handle_input)
	add_child(_resize_handle)

	_chevron = Button.new()
	_chevron.name = "ToggleButton"
	_chevron.text = "v"
	# The pane's OWN open/close control: it lives inside the pane in every
	# layout, so a dock is always closable even when a host's sidebar (which
	# may carry its own toggle) is scrolled out of reach.
	_chevron.tooltip_text = "Toggle annotations"
	_chevron.focus_mode = Control.FOCUS_NONE
	_chevron.custom_minimum_size = _CHEVRON_SIZE
	_chevron.size_flags_horizontal = Control.SIZE_SHRINK_END
	_chevron.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_chevron.pressed.connect(_toggle_collapsed)
	add_child(_chevron)

	_dock_scroll = ScrollContainer.new()
	_dock_scroll.name = "DockScroll"
	_dock_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_dock_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_dock_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dock_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_dock_scroll)

	_dock_body = VBoxContainer.new()
	_dock_body.name = "DockBody"
	_dock_body.add_theme_constant_override("separation", 4)
	_dock_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dock_scroll.add_child(_dock_body)

	_toolbar = AnnotationToolbar.new()
	_toolbar.name = "AnnotationToolbar"
	_toolbar.presentation_mode = AnnotationToolbar.PresentationMode.COMPACT
	_toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.active_tool_changed.connect(func(tool: AnnotationAuthorTool) -> void: active_tool_changed.emit(tool))
	_dock_body.add_child(_toolbar)

	_workbench = _AnnotationWorkbenchScript.new()
	_workbench.name = "AnnotationWorkbench"
	_workbench.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_workbench.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_workbench.connect("repair_requested", func(id: String) -> void: repair_requested.emit(id))
	_workbench.connect("add_comment_requested", func(text: String) -> void: add_comment_requested.emit(text))
	_workbench.connect("annotation_selected", func(id: String) -> void: annotation_selected.emit(id))
	_dock_body.add_child(_workbench)

	# Workflow listing (pcb-ui-native-cluster §4): workflow-class annotations
	# excluded from the review workbench above list HERE, kind-grouped. The
	# control renders nothing when the host has no workflow annotations.
	_workflow_list = _WorkflowAnnotationListScript.new()
	_workflow_list.name = "WorkflowAnnotationList"
	_workflow_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_workflow_list.connect("annotation_selected", func(id: String) -> void: annotation_selected.emit(id))
	_dock_body.add_child(_workflow_list)

	_apply_layout_state()
	if _host != null and _workbench.has_method("set_host"):
		_workbench.set_host(_host)
	if _host != null and _workflow_list.has_method("set_host"):
		_workflow_list.set_host(_host)


func _toggle_collapsed() -> void:
	_set_collapsed(not _collapsed)


func _set_collapsed(value: bool) -> void:
	_collapsed = value
	# Collapsing the dock removes the only visible affordance for an active
	# tool (the toolbar buttons go invisible) — leaving a tool active in that
	# state strands the user: the AnnotationOverlay above the editor surface
	# stays at MOUSE_FILTER_STOP while a tool is set, so the underlying view
	# can't be interacted with, and there's no toolbar in sight to untoggle
	# the tool. Force-clear when collapsing so the overlay flips back to
	# IGNORE; expanding doesn't need a symmetric action (no tool was being
	# preserved across the collapse).
	if _collapsed and _toolbar != null:
		_toolbar.clear_active_tool()
	_apply_layout_state()


func _apply_layout_state() -> void:
	if _resize_handle != null:
		_resize_handle.visible = not _collapsed and dock_mode == DockMode.BOTTOM
	if _dock_scroll != null:
		_dock_scroll.visible = not _collapsed
	if _toolbar != null:
		_toolbar.visible = not _collapsed
	if _workbench != null:
		_workbench.visible = not _collapsed
	if _workflow_list != null:
		_workflow_list.visible = not _collapsed
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
	_apply_height_budget()


## Height of the editor tab this dock shares. Zero means "unknown" — the pane
## then leaves the lists' own defaults alone rather than budgeting off a guess.
func _available_height() -> float:
	if _height_source != null and is_instance_valid(_height_source) and _height_source.size.y > 0.0:
		return _height_source.size.y
	if is_inside_tree():
		return get_viewport_rect().size.y
	return 0.0


func _refresh_height_budget() -> void:
	call_deferred("_apply_height_budget")


## Sizes the pane, and the scrolling region inside it, from the editor's height.
##
## The pane is SHRINK_END in BOTTOM mode, so its on-screen height is its
## COMBINED MINIMUM — a custom_minimum_size alone cannot shrink it below what
## its contents demand, so a long annotation list pushes the dock past the
## document unless the height is SPENT rather than merely capped: everything
## except the grip and the chevron lives in one ScrollContainer, and that
## scroll's minimum height is the whole budget.
## Extra rows (and extra toolbar rows) scroll inside it instead of growing the
## pane.
func _apply_height_budget() -> void:
	if _dock_scroll == null or _collapsed:
		return
	var available := _available_height()
	if available <= 0.0:
		return
	if dock_mode != DockMode.BOTTOM:
		# A RIGHT-docked pane is a column member: its height is the column's, so
		# it must not force one of its own beyond a usable floor.
		_dock_scroll.custom_minimum_size.y = _AnnotationDockSizingScript.MIN_LIST_HEIGHT
		return
	var wanted := _preferred_height
	if wanted <= 0.0:
		wanted = available * _AnnotationDockSizingScript.OPEN_FRACTION
	var target := _AnnotationDockSizingScript.clamp_height(wanted, available)
	custom_minimum_size.y = target
	# SPEND THE BUDGET, and no more: the list gets whatever the target leaves
	# after the chrome. Holding it to MIN_LIST_HEIGHT when the budget is smaller
	# than that made the pane's COMBINED minimum overrun the cap — on a 120 px
	# tab the cap is 60 but chrome + the 44 px floor forced ~80, and the
	# document lost more than half. The cap is the promise (see
	# AnnotationDockSizing.clamp_height); the list floor is a preference, and it
	# is already satisfied by every target big enough to hold it.
	_dock_scroll.custom_minimum_size.y = maxf(0.0, target - _fixed_chrome_height())


## The pane's non-scrolling frame: the grip, the chevron, and the separations
## around them. Everything else is inside _dock_scroll and costs nothing.
func _fixed_chrome_height() -> float:
	var separation := float(get_theme_constant(&"separation"))
	var chrome := separation  # gap between the frame and the scrolling region
	if _resize_handle != null and _resize_handle.visible:
		chrome += _resize_handle.get_combined_minimum_size().y + separation
	if _chevron != null and _chevron.visible:
		chrome += _chevron.get_combined_minimum_size().y
	return chrome


## The dock hangs off the bottom edge, so dragging the grip UP grows it.
func _on_resize_handle_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		_dragging_height = button.pressed
		if _dragging_height:
			_drag_start_pointer_y = button.global_position.y
			_drag_start_height = size.y
	elif event is InputEventMouseMotion and _dragging_height:
		var motion := event as InputEventMouseMotion
		set_preferred_height(_drag_start_height + (_drag_start_pointer_y - motion.global_position.y))
