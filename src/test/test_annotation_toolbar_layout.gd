extends SceneTree
## Layout / VBox-refactor unit tests for AnnotationToolbar.
## Run: godot --headless --script test/test_annotation_toolbar_layout.gd
##
## Coverage:
##   - Toolbar extends VBoxContainer
##   - Header label exists, centered, default text "Annotate"
##   - FlowContainer exists as a child (named "_button_flow")
##   - Status label exists, starts empty, named "_status_label"
##   - On tool activation, status label shows the kind's display_name
##   - On tool deactivation, status label is empty again
##   - Button with toolbar_icon: text empty, icon set, tooltip = display_name
##   - Button without toolbar_icon: text = display_name (fallback), tooltip = display_name
##   - Buttons are children of _button_flow, not of self
##   - Button has size_flags_horizontal = SIZE_SHRINK_BEGIN and toggle_mode = true

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationToolbar Layout Tests ===\n")

	print("-- Layout structure --")
	test_toolbar_extends_vboxcontainer()
	test_header_label_default_text()
	test_button_flow_exists()
	test_status_label_starts_empty()
	test_header_text_export_var()

	print("\n-- Button construction --")
	test_button_with_icon_no_text()
	test_button_without_icon_uses_text_fallback()
	test_button_tooltip_always_set()
	test_button_toggle_and_size_flags()
	test_buttons_added_to_flow_not_self()

	print("\n-- Status label updates --")
	test_status_label_shows_display_name_on_activate()
	test_status_label_clears_on_deactivate()
	test_status_label_clears_on_deregister_active_kind()
	test_status_label_clears_on_toggle_off()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Mocks (mirror those in test_annotation_authoring.gd) ──────────────────────

class MockHost extends AnnotationHost:
	var added_annotations: Array = []

	func add_annotation(annotation: Dictionary) -> String:
		added_annotations.append(annotation)
		return "ann_mock01"

	func get_view_context() -> String:
		return "test_view"


class MockTool extends AnnotationAuthorTool:
	var activate_calls: int = 0
	var deactivate_calls: int = 0

	func on_activate(host: AnnotationHost) -> void:
		activate_calls += 1

	func on_deactivate() -> void:
		deactivate_calls += 1


class MockKindWithUI extends AnnotationKind:
	var last_tool: MockTool = null

	func _init(p_name: StringName, p_display: String, p_icon: Texture2D = null) -> void:
		name          = p_name
		display_name  = p_display
		owning_plugin = &"test"
		toolbar_icon  = p_icon

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2()

	func author_ui() -> Object:
		last_tool = MockTool.new()
		return last_tool


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_toolbar() -> AnnotationToolbar:
	# Add to root so _ready() fires, matching real-world use.
	# In headless SceneTree-script context, _ready() may not be invoked, so we
	# call _ensure_layout() defensively to guarantee the layout is built.
	var tb := AnnotationToolbar.new()
	root.add_child(tb)
	tb.set_host(MockHost.new())
	tb._ensure_layout()
	return tb


func _free_toolbar(tb: AnnotationToolbar) -> void:
	if tb.get_parent() != null:
		tb.get_parent().remove_child(tb)
	tb.queue_free()


func _make_registry() -> AnnotationRegistry:
	return AnnotationRegistry.new()


func _make_dummy_icon() -> Texture2D:
	# 1x1 white pixel image → ImageTexture. Headless-safe.
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)


# ── Tests: layout structure ───────────────────────────────────────────────────

func test_toolbar_extends_vboxcontainer() -> void:
	print("test_toolbar_extends_vboxcontainer:")
	var tb := _make_toolbar()
	check("AnnotationToolbar extends VBoxContainer", tb is VBoxContainer)
	# Verify base class is VBoxContainer (not HBoxContainer) via class hierarchy.
	# Using get_class() avoids the parse-time class-narrowing rejection.
	check_eq("toolbar's get_class() is VBoxContainer (was HBoxContainer)",
		tb.get_class(), "VBoxContainer")
	_free_toolbar(tb)


func test_header_label_default_text() -> void:
	print("test_header_label_default_text:")
	var tb := _make_toolbar()
	check("header label exists", tb._header_label != null)
	if tb._header_label != null:
		check_eq("header default text is 'Annotate'", tb._header_label.text, "Annotate")
		check_eq("header is horizontally centered",
			tb._header_label.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER)
	_free_toolbar(tb)


func test_button_flow_exists() -> void:
	print("test_button_flow_exists:")
	var tb := _make_toolbar()
	check("_button_flow is non-null", tb._button_flow != null)
	check("_button_flow is a FlowContainer", tb._button_flow is FlowContainer)
	check("_button_flow is a child of the toolbar",
		tb._button_flow != null and tb._button_flow.get_parent() == tb)
	_free_toolbar(tb)


func test_status_label_starts_empty() -> void:
	print("test_status_label_starts_empty:")
	var tb := _make_toolbar()
	check("_status_label is non-null", tb._status_label != null)
	if tb._status_label != null:
		check_eq("_status_label starts empty", tb._status_label.text, "")
	_free_toolbar(tb)


func test_header_text_export_var() -> void:
	print("test_header_text_export_var:")
	# Set header_text BEFORE adding to tree so _ready() picks it up.
	var tb := AnnotationToolbar.new()
	tb.header_text = "My Annotations"
	root.add_child(tb)
	tb.set_host(MockHost.new())
	tb._ensure_layout()
	check("header label uses configured header_text",
		tb._header_label != null and tb._header_label.text == "My Annotations")
	_free_toolbar(tb)


# ── Tests: button construction ────────────────────────────────────────────────

func test_button_with_icon_no_text() -> void:
	print("test_button_with_icon_no_text:")
	var icon := _make_dummy_icon()
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_icon", "Iconic Kind", icon)
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	var btn: Button = tb._buttons.get(&"plug_icon", null)
	check("button exists for kind with icon", btn != null)
	if btn != null:
		check_eq("icon-mode button has empty text", btn.text, "")
		check("icon-mode button has icon set", btn.icon == icon)
		check_eq("tooltip equals display_name", btn.tooltip_text, "Iconic Kind")

	_free_toolbar(tb)


func test_button_without_icon_uses_text_fallback() -> void:
	print("test_button_without_icon_uses_text_fallback:")
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_text", "Texty Kind", null)
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	var btn: Button = tb._buttons.get(&"plug_text", null)
	check("button exists for kind without icon", btn != null)
	if btn != null:
		check_eq("text-fallback button text == display_name", btn.text, "Texty Kind")
		check("text-fallback button has no icon", btn.icon == null)
		check_eq("tooltip still equals display_name", btn.tooltip_text, "Texty Kind")

	_free_toolbar(tb)


func test_button_tooltip_always_set() -> void:
	print("test_button_tooltip_always_set:")
	var icon := _make_dummy_icon()
	var reg := _make_registry()
	var k1 := MockKindWithUI.new(&"plug_a", "Alpha", icon)
	var k2 := MockKindWithUI.new(&"plug_b", "Beta",  null)
	reg.register_annotation_kind(k1)
	reg.register_annotation_kind(k2)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	var b1: Button = tb._buttons[&"plug_a"]
	var b2: Button = tb._buttons[&"plug_b"]
	check_eq("icon button tooltip", b1.tooltip_text, "Alpha")
	check_eq("text button tooltip", b2.tooltip_text, "Beta")

	_free_toolbar(tb)


func test_button_toggle_and_size_flags() -> void:
	print("test_button_toggle_and_size_flags:")
	var reg := _make_registry()
	var kind := MockKindWithUI.new(&"plug_flags", "Flags Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	var btn: Button = tb._buttons[&"plug_flags"]
	check("button has toggle_mode = true", btn.toggle_mode)
	check_eq("button size_flags_horizontal = SIZE_SHRINK_BEGIN",
		btn.size_flags_horizontal, Control.SIZE_SHRINK_BEGIN)

	_free_toolbar(tb)


func test_buttons_added_to_flow_not_self() -> void:
	print("test_buttons_added_to_flow_not_self:")
	var reg := _make_registry()
	var k1 := MockKindWithUI.new(&"plug_p", "P")
	var k2 := MockKindWithUI.new(&"plug_q", "Q")
	reg.register_annotation_kind(k1)
	reg.register_annotation_kind(k2)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	check_eq("_button_flow has 2 children", tb._button_flow.get_child_count(), 2)
	var b1: Button = tb._buttons[&"plug_p"]
	var b2: Button = tb._buttons[&"plug_q"]
	check("button p parent == _button_flow", b1.get_parent() == tb._button_flow)
	check("button q parent == _button_flow", b2.get_parent() == tb._button_flow)

	_free_toolbar(tb)


# ── Tests: status label updates ───────────────────────────────────────────────

func test_status_label_shows_display_name_on_activate() -> void:
	print("test_status_label_shows_display_name_on_activate:")
	var reg := _make_registry()
	var kind := MockKindWithUI.new(&"plug_act", "My Active Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	tb._on_button_toggled(&"plug_act", true)
	check_eq("status label shows display_name on activate",
		tb._status_label.text, "My Active Kind")

	_free_toolbar(tb)


func test_status_label_clears_on_deactivate() -> void:
	print("test_status_label_clears_on_deactivate:")
	var reg := _make_registry()
	var k1 := MockKindWithUI.new(&"plug_first",  "First Kind")
	var k2 := MockKindWithUI.new(&"plug_second", "Second Kind")
	reg.register_annotation_kind(k1)
	reg.register_annotation_kind(k2)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	tb._on_button_toggled(&"plug_first", true)
	check_eq("status shows first kind", tb._status_label.text, "First Kind")
	tb._on_button_toggled(&"plug_second", true)
	check_eq("status shows second kind after switch",
		tb._status_label.text, "Second Kind")

	_free_toolbar(tb)


func test_status_label_clears_on_deregister_active_kind() -> void:
	print("test_status_label_clears_on_deregister_active_kind:")
	var reg := _make_registry()
	var kind := MockKindWithUI.new(&"plug_dr", "Doomed Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	tb._on_button_toggled(&"plug_dr", true)
	check_eq("status shows kind", tb._status_label.text, "Doomed Kind")

	reg.deregister_annotation_kind(&"plug_dr")
	check_eq("status cleared after deregister of active kind",
		tb._status_label.text, "")

	_free_toolbar(tb)


func test_status_label_clears_on_toggle_off() -> void:
	print("test_status_label_clears_on_toggle_off:")
	var reg := _make_registry()
	var kind := MockKindWithUI.new(&"plug_off", "Toggle Off Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	tb._on_button_toggled(&"plug_off", true)
	check_eq("status set on toggle-on", tb._status_label.text, "Toggle Off Kind")
	tb._on_button_toggled(&"plug_off", false)
	check_eq("status cleared on toggle-off", tb._status_label.text, "")

	_free_toolbar(tb)
