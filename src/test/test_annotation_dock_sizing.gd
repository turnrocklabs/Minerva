extends SceneTree
## Annotation dock height budget + row reach.
##
## Run: godot --headless --path src --script test/test_annotation_dock_sizing.gd
##
## Boots a REAL AnnotationDockPane in the shape an editor tab mounts it in — a
## column with the document above and the dock pinned to the bottom — against a
## real AnnotationHost holding long-summary review annotations and workflow
## annotations. Two properties are checked at a narrow width (554 px, the PCB
## tab's bottom strip) and at a wide one:
##
##   HEIGHT  opens at about a third of the tab, never past half — on open,
##           after a grip drag, after the tab shrinks — and the dragged size is
##           remembered while it fits.
##   REACH   no row's trailing controls sit off-screen with no way to scroll to
##           them, and a horizontal scrollbar shows exactly when the content is
##           wider than the dock; at 1200 px the content is not wider at all.

const DockPaneScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationDockPane.gd")
const SizingScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationDockSizing.gd")

const NARROW_WIDTH := 554.0
const WIDE_WIDTH := 1200.0
const TALL_HEIGHT := 900.0
## Short enough that HALF of it is BELOW the size the grip drag leaves behind
## (200 px), so the re-clamp on resize has to actually move the pane. At 400 the
## cap would be exactly 200 and the assertion would pass without it.
const SHORT_HEIGHT := 300.0
## Slack for container separations and theme metrics — the assertions are about
## thirds and halves of the tab, not exact pixels.
const SLACK := 12.0

var _pass := 0
var _fail := 0

var _tab: VBoxContainer = null
var _document: Control = null
var _pane: Node = null
var _host: _DockHost = null


## Workflow-class kind so the dock's second list surface is populated too.
class _FlowKind extends AnnotationKind:
	func _init() -> void:
		name = &"test_flow"
		display_name = "Test flow"
		owning_plugin = &"test"
		workflow_class = true

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2()


## Host with resolvable (non-stale) anchors and every lifecycle action enabled,
## so each row carries the full trailing control set the reach check is about.
class _DockHost extends AnnotationHost:
	var _registry: AnnotationRegistry = null
	var _annotations: Array = []

	func _init() -> void:
		super()
		_registry = AnnotationRegistry.new()
		_registry.register_annotation_kind(_FlowKind.new())
		for i in 6:
			_annotations.append(_make("review_%d" % i, "callout", i + 1))
		for i in 3:
			_annotations.append(_make("flow_%d" % i, "test_flow", i + 7))

	static func _make(id: String, kind: String, index: int) -> Dictionary:
		return {
			"id": id,
			"kind": kind,
			"lifecycle": "open",
			"display_index": index,
			"summary": "%s — a deliberately long annotation summary that is far wider than any dock, so the row has to elide or scroll" % id,
			"anchor": {"plugin": "core", "type": "canvas.point", "id": {"x": 4.0, "y": 8.0}},
		}

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_annotations() -> Array:
		return _annotations

	func get_capabilities() -> Dictionary:
		return {
			"lifecycle": {"resolve": true, "reopen": true, "delete": true, "apply": true},
		}


func check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func _init() -> void:
	print("=== Annotation dock sizing ===\n")
	await process_frame

	_build_tab()
	await _settle()

	_test_opens_at_a_third()
	await _test_grip_drag_is_capped()
	await _test_resize_keeps_the_document_half()
	_test_rows_stay_reachable_when_narrow()
	await _test_nothing_scrolls_when_wide()
	await _test_pane_carries_its_own_close_control()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


## Two frames: the budget re-applies deferred on a tab resize, and container
## layout lands the frame after the minimum sizes change.
func _settle() -> void:
	await process_frame
	await process_frame


## The platform BOTTOM mount: document fills, dock shrinks to the bottom edge,
## and the tab itself is the height the dock budgets against.
func _build_tab() -> void:
	_host = _DockHost.new()

	_tab = VBoxContainer.new()
	_tab.name = "EditorTab"
	get_root().add_child(_tab)
	_tab.size = Vector2(NARROW_WIDTH, TALL_HEIGHT)

	_document = Control.new()
	_document.name = "DocumentFiller"
	_document.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_document.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab.add_child(_document)

	_pane = DockPaneScript.new()
	_pane.name = "AnnotationDockPane"
	_pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pane.size_flags_vertical = Control.SIZE_SHRINK_END
	_tab.add_child(_pane)
	_pane.set_dock_mode(DockPaneScript.DockMode.BOTTOM)
	_pane.set_available_height_source(_tab)
	_pane.set_host(_host)
	_pane.set_collapsed(false)


func _workbench() -> Control:
	return _pane.get_workbench()


func _workflow_list() -> Control:
	return _pane.get_workflow_list()


func _entry_rows() -> Array:
	var list := _workbench().get_node_or_null("AnnotationScroll/ScrollBody/EntriesList")
	if list == null:
		return []
	return list.get_children()


# ── Height ────────────────────────────────────────────────────────────────────

func _test_opens_at_a_third() -> void:
	print("-- opens at a third of the tab, never past half --")
	var third := TALL_HEIGHT * SizingScript.OPEN_FRACTION
	check("rows are actually listed (the checks below are not vacuous)",
		_entry_rows().size() >= 3)
	check("workflow surface listed its annotations too",
		int(_workflow_list().entry_count()) == 3)
	check("dock height is about a third of the tab (got %.0f, want ~%.0f)" % [_pane.size.y, third],
		absf(_pane.size.y - third) <= SLACK)
	check("dock is inside the 50% cap", _pane.size.y <= TALL_HEIGHT * 0.5 + 1.0)
	check("document keeps the rest of the tab",
		_document.size.y >= TALL_HEIGHT - _pane.size.y - SLACK)


func _test_grip_drag_is_capped() -> void:
	print("\n-- grip drag is capped, and a smaller drag is remembered --")
	var handle := _pane.get_node_or_null("ResizeHandle") as Control
	check("pane has a drag grip in BOTTOM mode", handle != null and handle.visible)
	if handle == null:
		return

	_drag(handle, 1000.0)
	await _settle()
	check("dragging the grip far up stops at half the tab (got %.0f)" % _pane.size.y,
		_pane.size.y <= TALL_HEIGHT * 0.5 + 1.0)
	check("the remembered size is the clamped one, not the requested one",
		float(_pane.get_preferred_height()) <= TALL_HEIGHT * 0.5 + 1.0)
	check("document still keeps half the tab",
		_document.size.y >= TALL_HEIGHT * 0.5 - SLACK)

	_drag(handle, -(_pane.size.y - 200.0))
	await _settle()
	check("a drag back down is honoured (got %.0f, want ~200)" % _pane.size.y,
		absf(_pane.size.y - 200.0) <= SLACK)


func _test_resize_keeps_the_document_half() -> void:
	print("\n-- window resize re-clamps, memory survives it --")
	# The pane arrives here at the 200 px the previous drag left it at, and half
	# of SHORT_HEIGHT is less than that — so this only passes if the resize
	# genuinely re-clamps rather than leaving the pane where it was.
	check("the pane starts this case ABOVE the cap it will have to fall to",
		_pane.size.y > SHORT_HEIGHT * 0.5 + 1.0)
	_tab.size = Vector2(NARROW_WIDTH, SHORT_HEIGHT)
	await _settle()
	check("dock re-clamps to half the shorter tab (got %.0f)" % _pane.size.y,
		_pane.size.y <= SHORT_HEIGHT * 0.5 + 1.0)
	check("document keeps its half of the shorter tab",
		_document.size.y >= SHORT_HEIGHT * 0.5 - SLACK)

	_tab.size = Vector2(NARROW_WIDTH, TALL_HEIGHT)
	await _settle()
	check("the dragged size comes back when the tab grows again (got %.0f, want ~200)" % _pane.size.y,
		absf(_pane.size.y - 200.0) <= SLACK)


# ── Reach ─────────────────────────────────────────────────────────────────────

func _test_rows_stay_reachable_when_narrow() -> void:
	print("\n-- rows stay reachable at %d px --" % int(NARROW_WIDTH))
	var scroll := _workbench().get_node_or_null("AnnotationScroll") as ScrollContainer
	check("workbench rows live in a ScrollContainer", scroll != null)
	if scroll == null:
		return
	var content := scroll.get_node_or_null("ScrollBody") as Control
	check("the scroll has a content body to measure", content != null)
	if content == null:
		return
	var h_bar := scroll.get_h_scroll_bar()
	var viewport_right := scroll.get_global_rect().end.x
	var content_right := content.get_global_rect().end.x
	# WIDER THAN THE DOCK is measured from the two rects, not read back off the
	# scrollbar — otherwise "is the bar right?" would be asking the bar.
	var content_wider := content.size.x > scroll.size.x + 1.0
	# Can the user actually travel to the far edge? Only if horizontal scrolling
	# is enabled AND the bar has room left to move.
	var can_scroll := scroll.horizontal_scroll_mode != ScrollContainer.SCROLL_MODE_DISABLED \
		and (h_bar.max_value - h_bar.page) > 1.0

	# A row FAILS when its trailing control is off-screen and no amount of
	# scrolling brings it back: either it sits outside the scrollable content
	# altogether (clipped, not scrolled) or the content cannot be travelled.
	var stranded := 0
	var all_shrunk := true
	for row in _entry_rows():
		var control := row as Control
		if control == null or control.get_child_count() == 0:
			continue
		var trailing := control.get_child(control.get_child_count() - 1) as Control
		if trailing != null:
			var trailing_right := trailing.get_global_rect().end.x
			var on_screen := trailing_right <= viewport_right + 1.0
			var inside_content := trailing_right <= content_right + 1.0
			if not on_screen and not (inside_content and can_scroll):
				stranded += 1
		if control.size.x > scroll.size.x + 1.0:
			all_shrunk = false
	check("no row's trailing control is off-screen with no way to scroll to it (%d stranded)"
		% stranded, stranded == 0)
	check("rows shrink to the dock width unless the content really is wider",
		all_shrunk or content_wider)
	check("content wider than the dock can be scrolled to",
		can_scroll or not content_wider)
	check("a horizontal scrollbar is visible exactly when the content is wider than the dock",
		h_bar.visible == content_wider)


func _test_nothing_scrolls_when_wide() -> void:
	print("\n-- nothing scrolls at %d px --" % int(WIDE_WIDTH))
	_tab.size = Vector2(WIDE_WIDTH, TALL_HEIGHT)
	await _settle()
	check("workbench does not scroll horizontally when the dock is wide",
		not bool(_workbench().is_scrolling_horizontally()))
	check("workflow list does not scroll horizontally when the dock is wide",
		not bool(_workflow_list().is_scrolling_horizontally()))


# ── Close affordance ──────────────────────────────────────────────────────────

func _test_pane_carries_its_own_close_control() -> void:
	print("\n-- the pane can be closed from inside the pane --")
	var toggle := _pane.get_node_or_null("ToggleButton") as Button
	check("toggle button is a direct child of the pane", toggle != null)
	if toggle == null:
		return
	check("toggle is visible while the dock is open", toggle.visible)
	toggle.pressed.emit()
	await _settle()
	check("pressing it collapses the dock", bool(_pane.is_collapsed()))
	check("a collapsed dock takes almost no height (got %.0f)" % _pane.size.y,
		_pane.size.y <= 40.0)


# ── Input helpers ─────────────────────────────────────────────────────────────

## Presses the grip and moves the pointer `delta_up` pixels upward (the dock
## hangs off the bottom edge, so up = bigger), then releases.
func _drag(handle: Control, delta_up: float) -> void:
	var origin := handle.get_global_rect().get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.global_position = origin
	handle.gui_input.emit(press)

	var motion := InputEventMouseMotion.new()
	motion.global_position = origin - Vector2(0.0, delta_up)
	handle.gui_input.emit(motion)

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.global_position = motion.global_position
	handle.gui_input.emit(release)
