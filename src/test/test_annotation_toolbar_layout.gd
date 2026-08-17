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

	print("\n-- Tools section: structure --")
	test_tools_header_label_exists()
	test_tools_flow_exists_with_one_button()
	test_tool_buttons_properties()

	print("\n-- Tools section: mutual exclusion --")
	test_tool_button_toggle_lifecycle()
	test_tool_button_untoggle_kind_button()
	test_kind_button_untoggle_tool_button()

	print("\n-- Tools section: signal --")
	test_active_tool_button_changed_signal_on_toggle()
	test_active_tool_button_changed_signal_on_toggle_off()

	print("\n-- tools_excluded is opt-in and absent means unchanged (BT-61, B1u3) --")
	test_absent_tools_excluded_matches_the_pre_feature_toolbar()
	test_empty_tools_excluded_is_not_exclude_all()
	test_tools_excluded_removes_only_the_named_button()
	test_empty_tools_allow_list_still_shows_select()
	test_tools_excluded_beats_an_explicit_allow_list()

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

	func on_activate(_host: AnnotationHost) -> void:
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


# ── Tests: Tools section structure ───────────────────────────────────────────

func test_tools_header_label_exists() -> void:
	print("test_tools_header_label_exists:")
	var tb := _make_toolbar()
	check("_tools_header_label is non-null", tb._tools_header_label != null)
	if tb._tools_header_label != null:
		check_eq("_tools_header_label text is 'Tools'", tb._tools_header_label.text, "Tools")
		check_eq("_tools_header_label is horizontally centered",
			tb._tools_header_label.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER)
		check("_tools_header_label is a child of toolbar",
			tb._tools_header_label.get_parent() == tb)
	_free_toolbar(tb)


func test_tools_flow_exists_with_one_button() -> void:
	# R2.6: toolbar collapsed from 4 buttons to 1 "Select" button that maps to
	# AnnotationTransformTool (the unified gizmo tool).
	print("test_tools_flow_exists_with_one_button:")
	var tb := _make_toolbar()
	check("_tools_flow is non-null", tb._tools_flow != null)
	check("_tools_flow is a FlowContainer", tb._tools_flow is FlowContainer)
	check("_tools_flow is a child of toolbar",
		tb._tools_flow != null and tb._tools_flow.get_parent() == tb)
	check_eq("_tools_flow has exactly 1 child",
		tb._tools_flow.get_child_count() if tb._tools_flow != null else -1, 1)
	check_eq("_tool_buttons dict has 1 entry", tb._tool_buttons.size(), 1)
	check("_tool_buttons has key 'select'", tb._tool_buttons.has("select"))
	_free_toolbar(tb)


func test_tool_buttons_properties() -> void:
	# R2.6: only "select" button remains; it has an icon (uid://eckoinneympm),
	# empty text, tooltip "Select", toggle_mode=true, SIZE_SHRINK_BEGIN, in _tools_flow.
	print("test_tool_buttons_properties:")
	var tb := _make_toolbar()
	if not tb._tool_buttons.has("select"):
		check("button 'select' exists in _tool_buttons", false)
		_free_toolbar(tb)
		return
	var btn: Button = tb._tool_buttons["select"]
	check("button 'select' has icon",          btn.icon != null)
	check_eq("button 'select' text empty (icon mode)", btn.text, "")
	check_eq("button 'select' tooltip",        btn.tooltip_text, "Select")
	check("button 'select' toggle_mode",       btn.toggle_mode)
	check_eq("button 'select' size_flags_horizontal",
		btn.size_flags_horizontal, Control.SIZE_SHRINK_BEGIN)
	check("button 'select' parent is _tools_flow",
		btn.get_parent() == tb._tools_flow)
	_free_toolbar(tb)


# ── Tests: Tools-section single-button toggle lifecycle ──────────────────────

func test_tool_button_toggle_lifecycle() -> void:
	# R2.6: only one Tools button ("select") exists; toggle-on then toggle-off.
	# Invariant: _active_tool_button_name clears and active_tool_button_changed("")
	# fires on toggle-off.  The button's visual state is managed by the Button
	# widget in real UI; we verify the handler-level state machine only.
	# (Pre-R2.6 this slot tested mutual exclusion among 4 Tools buttons; now
	# there is only one button and "exclusion" reduces to toggle-off behavior.)
	print("test_tool_button_toggle_lifecycle:")
	var tb := _make_toolbar()

	# Simulate toggling "select" ON.
	tb._on_tool_button_toggled("select", true)
	check_eq("select is the active tool button", tb._active_tool_button_name, "select")
	check("active tool is AnnotationTransformTool after select toggle-on",
		tb.get_active_tool() is AnnotationTransformTool)

	# Collect signals emitted during toggle-off.
	var off_signals: Array = []
	tb.active_tool_button_changed.connect(func(name: String) -> void:
		off_signals.append(name)
	)

	tb._on_tool_button_toggled("select", false)
	check_eq("active_tool_button_name cleared after toggle-off", tb._active_tool_button_name, "")
	check_eq("active tool cleared after toggle-off", tb.get_active_tool(), null)
	check_eq("active_tool_button_changed('') fired on toggle-off",
		off_signals.size() >= 1 and off_signals[off_signals.size() - 1] == "", true)

	_free_toolbar(tb)


func test_tool_button_untoggle_kind_button() -> void:
	# R2.6: "select" button creates the universal AnnotationTransformTool.
	# Invariant: activating the Tools button clears any active Annotate-section kind.
	print("test_tool_button_untoggle_kind_button:")
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_cross", "Cross Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	# Activate an Annotate kind button.
	tb._on_button_toggled(&"plug_cross", true)
	check("annotate tool is active before tool-button press", tb.get_active_tool() != null)

	# Force the kind button to visually pressed (normally done by the Button widget).
	var kind_btn: Button = tb._buttons[&"plug_cross"]
	kind_btn.set_pressed_no_signal(true)

	# Now activate the Tools-section "select" button — kind tool must deactivate.
	tb._on_tool_button_toggled("select", true)
	# The active tool is now an AnnotationTransformTool; the kind binding is cleared.
	check("annotate kind binding cleared after tool-button press", tb._active_kind_name == &"")
	check("active tool is an AnnotationTransformTool", tb.get_active_tool() is AnnotationTransformTool)
	check("kind button visually untoggled", not kind_btn.button_pressed)
	check_eq("active_tool_button_name is 'select'", tb._active_tool_button_name, "select")

	_free_toolbar(tb)


func test_kind_button_untoggle_tool_button() -> void:
	# R2.6: uses "select" (the only Tools button) instead of "rotate".
	# Invariant: activating an Annotate-section kind visually untoggle the Tools button.
	print("test_kind_button_untoggle_tool_button:")
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_undo", "Undo Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	# Activate the Tools-section "select" button.
	tb._on_tool_button_toggled("select", true)
	check_eq("select is active tool button", tb._active_tool_button_name, "select")

	# Force the select button visually pressed.
	var select_btn: Button = tb._tool_buttons["select"]
	select_btn.set_pressed_no_signal(true)

	# Activate an Annotate kind button — Tools button must visually untoggle.
	tb._on_button_toggled(&"plug_undo", true)
	check("annotate tool is now active", tb.get_active_tool() != null)
	check("select button visually untoggled", not select_btn.button_pressed)
	check_eq("active_tool_button_name cleared", tb._active_tool_button_name, "")

	_free_toolbar(tb)


# ── Tests: active_tool_button_changed signal ──────────────────────────────────

func test_active_tool_button_changed_signal_on_toggle() -> void:
	# R2.6: "select" is the only Tools button; signal must carry "select".
	print("test_active_tool_button_changed_signal_on_toggle:")
	var tb := _make_toolbar()

	var received: Array = []
	tb.active_tool_button_changed.connect(func(name: String) -> void:
		received.append(name)
	)

	tb._on_tool_button_toggled("select", true)
	check_eq("signal fired once on toggle-on", received.size(), 1)
	check_eq("signal carries 'select'", received[0], "select")

	_free_toolbar(tb)


func test_active_tool_button_changed_signal_on_toggle_off() -> void:
	# R2.6: toggle "select" on then off — signal must fire twice.
	print("test_active_tool_button_changed_signal_on_toggle_off:")
	var tb := _make_toolbar()

	var received: Array = []
	tb.active_tool_button_changed.connect(func(name: String) -> void:
		received.append(name)
	)

	tb._on_tool_button_toggled("select", true)
	tb._on_tool_button_toggled("select", false)
	check_eq("signal fired twice total (on + off)", received.size(), 2)
	check_eq("first signal is 'select'", received[0], "select")
	check_eq("second signal is '' (cleared)", received[1], "")


# ══════════════════════════════════════════════════════════════════════════════
# BT-61 — `tools_excluded` absent leaves the toolbar byte-equal to pre-feature
# ══════════════════════════════════════════════════════════════════════════════
#
# Campaign 2, round B1 unit 3 (universal Select, docket item 019fbb9adc33), core
# half. The pcb panel owns ONE universal Select on its own canvas and must not be
# offered a second one in the dock, so it declares `tools_excluded: ["select"]`.
# Every OTHER host — and every older host running against this core — declares
# nothing, and for them the dock must be unchanged down to the button list.
#
# WHY A NEGATIVE CHANNEL EXISTS AT ALL (measured, B1u3): the `tools` allow-list
# cannot express "offer no Select", because an EMPTY allow-list means "allow
# everything" — which is what every host omitting the key relies on. So
# `"tools": []` SHOWS the button, the exact opposite of the intent. That fact is
# pinned below too; without it the negative channel looks redundant and someone
# will delete it.
#
# INDEPENDENT REPRESENTATION: the expected list is HAND-WRITTEN from the sources,
# not read back out of a reference toolbar —
#   * Tools section: `_ensure_layout_labeled` iterates the literal ["Select"],
#     lower-cased into _tool_buttons — one entry, "select".
#   * Annotate section: `_try_add_button` skips any kind whose author_ui()
#     returns null. Of the nine kinds BuiltinKinds registers, exactly TWO declare
#     author_ui — AnnotationArrow (2d_arrow) and AnnotationText (2d_text);
#     grep 'func author_ui' over kinds/ returns those two files and no others.
# Names are compared SORTED, so this pins the SET rather than the registry's
# iteration order (which the ordering tests above already own). The absent-vs-
# empty comparison is done unsorted as well, so ordering cannot drift between
# the two configurations either.
#
# CROSS-REPO: AUTH-PLUG-CANVAS's BT-58 fixture (nudge c2-epochB
# "boundary.bt58-fixture") confirms the other half of this feature keeps its two
# selections in two separate stores — an annotation id-set on the AnnotationHost
# and a board id list on the canvas, never mirrored. Nothing in the dock's button
# list participates in that, which is exactly why excluding the dock's Select is
# safe: it removes an affordance, not a selection store.

const _PRE_FEATURE_TOOL_BUTTONS: Array = ["select"]
const _PRE_FEATURE_KIND_BUTTONS: Array = ["2d_arrow", "2d_text"]


## A host that publishes whatever capabilities dict it is handed.
class CapabilityMockHost extends MockHost:
	var capabilities: Dictionary = {}

	func get_annotation_capabilities() -> Dictionary:
		return capabilities


## Build a toolbar bound to `capabilities` and the nine built-in kinds.
## set_host FIRST: it is what latches _capabilities, and the Tools section is
## constructed during the rebuild it triggers.
func _toolbar_with_capabilities(capabilities: Dictionary) -> AnnotationToolbar:
	var tb := AnnotationToolbar.new()
	root.add_child(tb)
	var host := CapabilityMockHost.new()
	host.capabilities = capabilities
	tb.set_host(host)
	var registry := AnnotationRegistry.new()
	BuiltinKinds.register_all(registry)
	tb.set_registry(registry)
	return tb


func _tool_button_names(tb: AnnotationToolbar, sorted_names: bool = true) -> Array:
	var out: Array = []
	for key in tb._tool_buttons.keys():
		out.append(str(key))
	if sorted_names:
		out.sort()
	return out


func _kind_button_names(tb: AnnotationToolbar, sorted_names: bool = true) -> Array:
	var out: Array = []
	for key in tb._buttons.keys():
		out.append(str(key))
	if sorted_names:
		out.sort()
	return out


func test_absent_tools_excluded_matches_the_pre_feature_toolbar() -> void:
	print("test_absent_tools_excluded_matches_the_pre_feature_toolbar:")
	var tb := _toolbar_with_capabilities({})
	check_eq("Tools section is the hand-written pre-feature list",
		_tool_button_names(tb), _PRE_FEATURE_TOOL_BUTTONS)
	check_eq("Annotate section is the hand-written pre-feature list",
		_kind_button_names(tb), _PRE_FEATURE_KIND_BUTTONS)
	_free_toolbar(tb)

	# The degrade path in the same shape: a host with no capabilities method at
	# all (every host that predates the whole capabilities channel).
	var plain := AnnotationToolbar.new()
	root.add_child(plain)
	plain.set_host(MockHost.new())
	var registry := AnnotationRegistry.new()
	BuiltinKinds.register_all(registry)
	plain.set_registry(registry)
	check_eq("a host with no capabilities method keeps its Select",
		_tool_button_names(plain), _PRE_FEATURE_TOOL_BUTTONS)
	check_eq("...and its kind buttons", _kind_button_names(plain), _PRE_FEATURE_KIND_BUTTONS)
	_free_toolbar(plain)


func test_empty_tools_excluded_is_not_exclude_all() -> void:
	print("test_empty_tools_excluded_is_not_exclude_all:")
	# An empty NEGATIVE list must mean "exclude nothing" — the mirror image of the
	# allow-list's "empty means allow everything". A host that writes the key and
	# then computes an empty array (no tools to hide on this surface) must get the
	# full toolbar, not an empty one.
	var absent := _toolbar_with_capabilities({})
	var empty := _toolbar_with_capabilities({"tools_excluded": []})

	check_eq("empty tools_excluded keeps the Select button",
		_tool_button_names(empty), _PRE_FEATURE_TOOL_BUTTONS)
	check_eq("empty tools_excluded keeps every kind button",
		_kind_button_names(empty), _PRE_FEATURE_KIND_BUTTONS)
	# Unsorted, so button ORDER cannot drift between the two configurations either.
	check_eq("empty and absent produce byte-equal Tools sections",
		_tool_button_names(empty, false), _tool_button_names(absent, false))
	check_eq("empty and absent produce byte-equal Annotate sections",
		_kind_button_names(empty, false), _kind_button_names(absent, false))

	_free_toolbar(absent)
	_free_toolbar(empty)


func test_tools_excluded_removes_only_the_named_button() -> void:
	print("test_tools_excluded_removes_only_the_named_button:")
	# The pcb panel's own configuration. Without this leg, everything above is
	# satisfied by a channel that does nothing whatsoever.
	var tb := _toolbar_with_capabilities({"tools_excluded": ["select"]})
	check_eq("the excluded Select button is gone", _tool_button_names(tb), [])
	check_eq("and nothing else was removed with it",
		_kind_button_names(tb), _PRE_FEATURE_KIND_BUTTONS)
	_free_toolbar(tb)

	# A name nobody offers is inert, not an error.
	var unknown := _toolbar_with_capabilities({"tools_excluded": ["lasso"]})
	check_eq("excluding an unknown tool changes nothing",
		_tool_button_names(unknown), _PRE_FEATURE_TOOL_BUTTONS)
	_free_toolbar(unknown)


func test_empty_tools_allow_list_still_shows_select() -> void:
	print("test_empty_tools_allow_list_still_shows_select:")
	# The measured fact the negative channel exists BECAUSE of. If this ever
	# starts failing, `tools_excluded` has become redundant and the reason it was
	# added has changed — which is a design decision, not a passing test.
	var tb := _toolbar_with_capabilities({"tools": []})
	check_eq("an empty allow-list still shows Select (allow-list can't say 'none')",
		_tool_button_names(tb), _PRE_FEATURE_TOOL_BUTTONS)
	_free_toolbar(tb)


func test_tools_excluded_beats_an_explicit_allow_list() -> void:
	print("test_tools_excluded_beats_an_explicit_allow_list:")
	# "It wins outright" — a host that both allows and excludes the same name gets
	# no button. Anything else leaves the pcb panel's two Selects reachable through
	# a capabilities dict that names Select positively for some other reason.
	var tb := _toolbar_with_capabilities({"tools": ["select"], "tools_excluded": ["select"]})
	check_eq("exclusion wins over an explicit allow-list entry",
		_tool_button_names(tb), [])
	_free_toolbar(tb)
