class_name Helloscene_AnnotationCanvas
extends Control
## Drawing surface for hello_scene annotations.
##
## Owns no annotation state itself — reads from a Helloscene_AnnotationHost
## via host.get_annotations() each _draw, and forwards pointer/key events
## to the active AnnotationAuthorTool (provided by the toolbar through
## set_active_tool()).
##
## Coordinate model:
##   The hello canvas uses identity transforms (zoom 1, no pan), so local
##   widget coordinates ARE document coordinates. AnnotationRenderContext
##   is built with Transform2D.IDENTITY and zoom=1.0.
##
##   ⚠️ NOT for cargo-cult by CAD/PCB: those editors have a camera with pan
##   and zoom; their canvas must build the AnnotationRenderContext using the
##   real viewport transform and live zoom factor, not IDENTITY. Their
##   _gui_input may also need to consume MOUSE_MOTION mid-drag so parent
##   pan/zoom doesn't fight an in-progress author tool — hello does not.
##
## Preview-redraw contract (matches AnnotationArrowAuthorTool top-of-file
## comment): we redraw on pointer-move and on annotations_changed. We do
## NOT do per-frame _process redraw — pointer-move covers the only state
## the in-progress preview can change.
##
## class_name prefix "Helloscene" = canonical_prefix("hello_scene")
## per design §6.1.

# ── State ──────────────────────────────────────────────────────────────────────

var _host: Helloscene_AnnotationHost = null
var _active_tool: AnnotationAuthorTool = null

# ── Public API ─────────────────────────────────────────────────────────────────

## Bind this canvas to the panel's annotation host.
## Connects to host.annotations_changed so the canvas redraws when an
## annotation is added (or the list is bulk-replaced via set_annotations).
## Also connects to host.selection_changed so the selection halo refreshes
## whenever the user selects/deselects an annotation.
func set_host(host: Helloscene_AnnotationHost) -> void:
	if _host != null:
		if _host.annotations_changed.is_connected(_on_annotations_changed):
			_host.annotations_changed.disconnect(_on_annotations_changed)
		if _host.selection_changed.is_connected(queue_redraw):
			_host.selection_changed.disconnect(queue_redraw)
	_host = host
	if _host != null:
		_host.annotations_changed.connect(_on_annotations_changed)
		_host.selection_changed.connect(queue_redraw)
	queue_redraw()


## Set or clear the active authoring tool. The toolbar pushes this on tool
## activation/deactivation via its active_tool_changed signal.
## Disconnects annotation_modified from the previous tool (if any) and
## connects it to the new one (if it has that signal) so manipulation-tool
## changes are forwarded to the host via _on_tool_annotation_modified.
func set_active_tool(tool: AnnotationAuthorTool) -> void:
	# Disconnect from the outgoing tool's annotation_modified.
	if _active_tool != null:
		if _active_tool.annotation_modified.is_connected(_on_tool_annotation_modified):
			_active_tool.annotation_modified.disconnect(_on_tool_annotation_modified)
	_active_tool = tool
	# Connect to the incoming tool's annotation_modified (manipulation tools emit
	# this; authoring tools never do). The toolbar also connects annotation_modified
	# on its side for host.update_annotation; having both connected is safe because
	# the host's update_annotation is idempotent for equal-content calls.
	if _active_tool != null:
		if not _active_tool.annotation_modified.is_connected(_on_tool_annotation_modified):
			_active_tool.annotation_modified.connect(_on_tool_annotation_modified)
	queue_redraw()


# ── Drawing ────────────────────────────────────────────────────────────────────

func _draw() -> void:
	if _host == null:
		return
	var registry: AnnotationRegistry = _host.get_registry()
	var ctx := AnnotationRenderContext.create(
		get_canvas_item(),
		Transform2D.IDENTITY,
		Rect2(Vector2.ZERO, size),
		theme,
		1.0,
		_host.get_view_context()
	)

	# Render each annotation. dispatch_render handles unknown-kind placeholders
	# (grey dashed rect with kind name) per design §10.
	for ann in _host.get_annotations():
		if registry != null:
			registry.dispatch_render(ctx, ann)

	# In-progress preview from the active tool, if any.
	if _active_tool != null:
		_active_tool.draw_preview(ctx)


# ── Input ──────────────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if _active_tool == null:
		return

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		var mods := _mods_from_event(mb)
		if mb.pressed:
			var consumed := _active_tool.on_pointer_down(mb.position, mb.button_index, mods)
			if consumed:
				accept_event()
		else:
			var consumed_up := _active_tool.on_pointer_up(mb.position, mb.button_index, mods)
			if consumed_up:
				accept_event()
		queue_redraw()
		return

	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		_active_tool.on_pointer_move(mm.position)
		queue_redraw()
		return

	if event is InputEventKey:
		var ek: InputEventKey = event
		if ek.pressed and not ek.is_echo():
			if ek.keycode == KEY_ESCAPE:
				# Surface Escape to the tool via the mods channel (per
				# AnnotationArrowAuthorTool.on_pointer_down's Escape contract: when
				# mods == KEY_ESCAPE the tool treats it as a cancel). pos/button
				# are unused on the cancel path.
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)
				if consumed:
					accept_event()
				queue_redraw()
			elif ek.keycode == KEY_DELETE:
				# Surface Delete to the tool via the mods channel.
				# AnnotationSelectTool interprets mods == KEY_DELETE as a remove
				# command on the currently-selected annotation.
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)
				if consumed:
					accept_event()
				queue_redraw()


# ── Helpers ────────────────────────────────────────────────────────────────────

## Pack Godot modifier-key state into a bitmask. The exact bit values are
## not part of the AnnotationAuthorTool contract — tools that care about
## Shift/Ctrl/Alt should agree on the encoding with their host. We use the
## Godot KEY_MASK_* values for portability.
func _mods_from_event(event: InputEventWithModifiers) -> int:
	var mods := 0
	if event.shift_pressed:
		mods |= KEY_MASK_SHIFT
	if event.ctrl_pressed:
		mods |= KEY_MASK_CTRL
	if event.alt_pressed:
		mods |= KEY_MASK_ALT
	if event.meta_pressed:
		mods |= KEY_MASK_META
	return mods


# ── Signal handlers ────────────────────────────────────────────────────────────

func _on_annotations_changed() -> void:
	queue_redraw()


## Called when the active manipulation tool emits annotation_modified.
## Forwards the change to the host so the host's annotations_changed signal
## fires and the canvas redraws with the updated annotation.
func _on_tool_annotation_modified(annotation_id: String, new_annotation: Dictionary) -> void:
	if _host == null:
		return
	_host.update_annotation(annotation_id, new_annotation)
	queue_redraw()
