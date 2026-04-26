class_name AnnotationToolbar
extends VBoxContainer
## Annotation authoring toolbar widget.
##
## Design §11.1. Populated at runtime from an AnnotationRegistry. Each kind
## that returns a non-null author_ui() gets one toggle button. Pressing a
## button activates that kind's AnnotationAuthorTool and deactivates the
## previously-active one.
##
## Layout (matches PCBEditor's annotation sidebar pattern):
##   - Tools Header Label (centered) "Tools"
##   - FlowContainer (`_tools_flow`) holding Select/Translate/Rotate/Scale buttons
##   - Header Label (centered) showing `header_text` (default "Annotate")
##   - FlowContainer (`_button_flow`) holding the icon-only toggle buttons
##   - Status Label (`_status_label`) in pink showing the active kind's
##     display_name, or empty when no tool is active
##
## Ownership:
##   - Call set_registry() to wire up the kind list and live register/deregister signals.
##   - Call set_host() to give the toolbar an AnnotationHost to pass through to tools.
##   - get_active_tool() returns the currently-active AnnotationAuthorTool, or null.
##
## Ordering (design §11.1):
##   - Core kinds (name starting with "2d_") appear first, in the order they were
##     registered.
##   - Plugin kinds appear after core kinds, in registration order.
##
## Keyboard shortcuts: deferred to a future task per task scope constraint.

## Emitted whenever the active tool changes. tool is the newly-active
## AnnotationAuthorTool, or null when the previously-active tool was
## deactivated without a successor (toggle-off, kind deregister, etc.).
## Hosting canvases listen so they can route pointer events to (and draw
## previews from) the current tool.
signal active_tool_changed(tool: AnnotationAuthorTool)

## Emitted whenever the active Tools-section button changes.
## name is the button name ("select", "translate", "rotate", "scale") or ""
## when the previously-active Tools button was toggled off.
signal active_tool_button_changed(name: String)

# ── Tools-section icons ────────────────────────────────────────────────────────
## PCB icon UIDs for the Tools-section buttons (Select/Translate/Rotate).
## Verified by grepping .import files — all three assets exist.
## "scale" has no matching PCB icon; falls back to text label.
const _TOOL_ICON_UIDS: Dictionary = {
	"select":    "uid://eckoinneympm",  # graphics_editor/select_tool_icon_24.png
	"translate": "uid://1q2kkovqy5qk",  # pcb_editor/expand-arrows_white_24.png
	"rotate":    "uid://c6bt6vccnmejo", # pcb_editor/rotate_24.png
	"scale":     "",                    # no PCB icon; text fallback
}

## Header label text. Configurable; default "Annotate".
@export var header_text: String = "Annotate"

## The active tool, or null when no tool is selected.
var _active_tool: AnnotationAuthorTool = null

## The kind name whose button is currently toggled on.
var _active_kind_name: StringName = &""

## Registry this toolbar is bound to.
var _registry: AnnotationRegistry = null

## Host passed to tools on activation.
var _host: AnnotationHost = null

## kind_name (StringName) → Button — the live button table.
var _buttons: Dictionary = {}

## name (String) → Button — the Tools-section button table.
## Keys: "select", "translate", "rotate", "scale".
var _tool_buttons: Dictionary = {}

## The name of the currently-active Tools button, or "" if none.
var _active_tool_button_name: String = ""

## Layout children — built lazily by _ensure_layout(). May be null until then.
var _tools_header_label: Label = null
var _tools_flow: FlowContainer = null
var _header_label: Label = null
var _button_flow: FlowContainer = null
var _status_label: Label = null


func _ready() -> void:
	_ensure_layout()


# ── Public API ─────────────────────────────────────────────────────────────────

## Bind this toolbar to a registry.
## Populates buttons immediately from kinds that have a non-null author_ui(),
## then connects to registration/deregistration signals for live updates.
## Calling again replaces the previous registry.
func set_registry(registry: AnnotationRegistry) -> void:
	_ensure_layout()

	# Disconnect from the old registry if any.
	if _registry != null:
		if _registry.annotation_kind_registered.is_connected(_on_kind_registered):
			_registry.annotation_kind_registered.disconnect(_on_kind_registered)
		if _registry.annotation_kind_deregistered.is_connected(_on_kind_deregistered):
			_registry.annotation_kind_deregistered.disconnect(_on_kind_deregistered)

	# Clear existing buttons and deactivate any active tool.
	_deactivate_current_tool()
	_clear_buttons()

	_registry = registry

	if _registry == null:
		return

	# Populate from existing kinds, respecting the core-first ordering.
	var kinds := registry.list_annotation_kinds()
	# Core kinds first (name starts with "2d_"), then plugin kinds.
	var core_kinds: Array[AnnotationKind] = []
	var plugin_kinds: Array[AnnotationKind] = []
	for kind in kinds:
		if str(kind.name).begins_with("2d_"):
			core_kinds.append(kind)
		else:
			plugin_kinds.append(kind)

	for kind in core_kinds:
		_try_add_button(kind)
	for kind in plugin_kinds:
		_try_add_button(kind)

	# Connect live signals.
	_registry.annotation_kind_registered.connect(_on_kind_registered)
	_registry.annotation_kind_deregistered.connect(_on_kind_deregistered)


## Set the AnnotationHost that will be passed to tools on activation.
## Can be called before or after set_registry().
func set_host(host: AnnotationHost) -> void:
	_host = host


## Returns the currently-active AnnotationAuthorTool, or null if none is active.
func get_active_tool() -> AnnotationAuthorTool:
	return _active_tool

# ── Internal: layout ──────────────────────────────────────────────────────────

## Build the header / FlowContainer / status-label structure if not already
## built. Idempotent. Called from _ready() and defensively from set_registry()
## so the toolbar works even when used outside the SceneTree (headless tests).
func _ensure_layout() -> void:
	if _button_flow != null:
		return

	# ── Tools section ──────────────────────────────────────────────────────────
	_tools_header_label = Label.new()
	_tools_header_label.name = "_tools_header_label"
	_tools_header_label.text = "Tools"
	_tools_header_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_tools_header_label)

	_tools_flow = FlowContainer.new()
	_tools_flow.name = "_tools_flow"
	add_child(_tools_flow)

	for tool_name in ["Select"]:
		var btn := Button.new()
		btn.tooltip_text = tool_name
		btn.toggle_mode = true
		btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		# Apply icon if one is declared for this key; otherwise fall back to text.
		var tool_key: String = tool_name.to_lower()
		var icon_uid: String = _TOOL_ICON_UIDS.get(tool_key, "")
		if icon_uid != "":
			btn.icon = load(icon_uid) as Texture2D
			# No text when an icon is present (matches PCBEditor convention).
		else:
			# Text fallback for tools without a dedicated icon (currently: Scale).
			btn.text = tool_name
		# Capture the tool name in an Array wrapper to survive lambda capture.
		var name_capture: Array = [tool_key]
		btn.toggled.connect(func(pressed: bool) -> void:
			_on_tool_button_toggled(name_capture[0], pressed)
		)
		_tools_flow.add_child(btn)
		_tool_buttons[tool_key] = btn

	# ── Annotate section ───────────────────────────────────────────────────────
	_header_label = Label.new()
	_header_label.text = header_text
	_header_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_header_label)

	_button_flow = FlowContainer.new()
	_button_flow.name = "_button_flow"
	add_child(_button_flow)

	_status_label = Label.new()
	_status_label.name = "_status_label"
	_status_label.text = ""
	_status_label.add_theme_color_override("font_color", Color(0.95, 0.5, 0.9))
	add_child(_status_label)

# ── Internal: Tools-section tool construction ─────────────────────────────────

## Construct and return a fresh tool instance for the given Tools-section button
## name. Returns null for unknown names.
func _construct_tool_for_name(tool_name: String) -> AnnotationAuthorTool:
	match tool_name:
		"select": return AnnotationTransformTool.new()
		_:        return null


# ── Internal: button population ───────────────────────────────────────────────

## Try to add a button for this kind. Does nothing if author_ui() returns null.
func _try_add_button(kind: AnnotationKind) -> void:
	if kind.author_ui() == null:
		return
	_ensure_layout()
	var btn := Button.new()
	btn.toggle_mode = true
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn.tooltip_text = kind.display_name
	if kind.toolbar_icon != null:
		# Icon-only button: no text, just the icon.
		btn.icon = kind.toolbar_icon
	else:
		# Fallback: text label (legacy behavior for kinds with no icon).
		btn.text = kind.display_name
	# Capture the kind name in an Array wrapper to survive lambda capture semantics.
	var kind_name_capture: Array = [kind.name]
	btn.toggled.connect(func(pressed: bool) -> void:
		_on_button_toggled(kind_name_capture[0], pressed)
	)
	_button_flow.add_child(btn)
	_buttons[kind.name] = btn


## Remove all buttons and clear the button table.
func _clear_buttons() -> void:
	for kind_name in _buttons.keys():
		var btn: Button = _buttons[kind_name]
		if is_instance_valid(btn):
			btn.queue_free()
	_buttons.clear()

# ── Internal: tool activation/deactivation ─────────────────────────────────────

## Deactivate the current tool if one is active.
## Does NOT remove the button toggle state — callers update that separately.
func _deactivate_current_tool() -> void:
	if _active_tool == null:
		return
	# Disconnect signals before deactivating to avoid re-entrant callbacks.
	if _active_tool.annotation_ready.is_connected(_on_annotation_ready):
		_active_tool.annotation_ready.disconnect(_on_annotation_ready)
	if _active_tool.cancelled.is_connected(_on_tool_cancelled):
		_active_tool.cancelled.disconnect(_on_tool_cancelled)
	_active_tool.on_deactivate()
	_active_tool = null
	_active_kind_name = &""
	if _status_label != null:
		_status_label.text = ""
	active_tool_changed.emit(null)


## Activate a tool for the given kind. Deactivates the previous tool first.
func _activate_tool_for_kind(kind_name: StringName) -> void:
	# Deactivate previous tool (and untoggle its button).
	var prev_kind_name := _active_kind_name
	_deactivate_current_tool()

	# Untoggle the previous Annotate button without re-entering the toggle handler.
	if prev_kind_name != &"" and _buttons.has(prev_kind_name):
		var prev_btn: Button = _buttons[prev_kind_name]
		if is_instance_valid(prev_btn) and prev_btn.button_pressed:
			prev_btn.set_pressed_no_signal(false)

	# Untoggle any active Tools-section button (mutual exclusion across sections).
	_untoggle_active_tool_button()

	if _registry == null:
		return
	var kind := _registry.get_annotation_kind(kind_name)
	if kind == null:
		return
	var tool: Object = kind.author_ui()
	if tool == null:
		return

	_active_tool = tool as AnnotationAuthorTool
	if _active_tool == null:
		push_warning("[AnnotationToolbar] author_ui() for kind '%s' returned a non-null "
			% str(kind_name) + "Object that is not an AnnotationAuthorTool. Ignoring.")
		return

	_active_kind_name = kind_name

	# Wire tool signals.
	_active_tool.annotation_ready.connect(_on_annotation_ready)
	_active_tool.cancelled.connect(_on_tool_cancelled)

	_active_tool.on_activate(_host)
	if _status_label != null:
		_status_label.text = kind.display_name
	active_tool_changed.emit(_active_tool)

# ── Internal: Tools-section helpers ──────────────────────────────────────────

## Visually untoggle the currently-active Tools button (if any) and clear the
## tracked name + emit active_tool_button_changed(""). Does NOT re-enter
## _on_tool_button_toggled because it uses set_pressed_no_signal.
func _untoggle_active_tool_button() -> void:
	if _active_tool_button_name == "":
		return
	var prev_name := _active_tool_button_name
	_active_tool_button_name = ""
	if _tool_buttons.has(prev_name):
		var prev_btn: Button = _tool_buttons[prev_name]
		if is_instance_valid(prev_btn) and prev_btn.button_pressed:
			prev_btn.set_pressed_no_signal(false)
	active_tool_button_changed.emit("")


## Called when a Tools-section button is toggled on or off.
func _on_tool_button_toggled(name: String, pressed: bool) -> void:
	if pressed:
		# Untoggle every other Tools button first.
		for other_name in _tool_buttons.keys():
			if other_name != name:
				var other_btn: Button = _tool_buttons[other_name]
				if is_instance_valid(other_btn) and other_btn.button_pressed:
					other_btn.set_pressed_no_signal(false)

		# Tear down any previously-active manipulation tool (one might have been
		# active from a prior Tools-button press). Disconnect annotation_modified
		# before we drop the reference to avoid stale signal connections.
		_teardown_active_manipulation_tool()

		# Untoggle and deactivate any active Annotate-section tool.
		# _deactivate_current_tool emits active_tool_changed(null) internally;
		# we will emit active_tool_changed(new_tool) afterwards, so the final
		# emission seen by the canvas is the new tool.
		var prev_kind := _active_kind_name
		_deactivate_current_tool()
		# _deactivate_current_tool clears _active_kind_name but not the button visual.
		if prev_kind != &"" and _buttons.has(prev_kind):
			var prev_btn: Button = _buttons[prev_kind]
			if is_instance_valid(prev_btn) and prev_btn.button_pressed:
				prev_btn.set_pressed_no_signal(false)

		_active_tool_button_name = name
		if _status_label != null:
			_status_label.text = name.capitalize()
		active_tool_button_changed.emit(name)

		# Construct and activate the tool, then forward to the canvas via
		# active_tool_changed. This is the single canonical emission point for
		# Tools-section tools; _deactivate_current_tool's null-emission above is
		# transient and the canvas will be overwritten by this non-null one.
		var new_tool: AnnotationAuthorTool = _construct_tool_for_name(name)
		if new_tool != null:
			new_tool.on_activate(_host)
			# Wire annotation_modified so the canvas can forward it to the host.
			if new_tool.annotation_modified.is_connected(_on_manipulation_tool_modified):
				pass  # already connected (shouldn't happen, but be safe)
			else:
				new_tool.annotation_modified.connect(_on_manipulation_tool_modified)
			_active_tool = new_tool
			_active_kind_name = &""
		active_tool_changed.emit(new_tool)
	else:
		# Toggled off: only clear if this button was the active one.
		if _active_tool_button_name == name:
			_teardown_active_manipulation_tool()
			_active_tool_button_name = ""
			if _status_label != null:
				_status_label.text = ""
			active_tool_button_changed.emit("")
			active_tool_changed.emit(null)


# ── Internal: manipulation tool helpers ───────────────────────────────────────

## Deactivate and disconnect the currently-active Tools-section manipulation
## tool (Select/Translate/Rotate/Scale), if any. Does NOT touch _active_kind_name
## or the Annotate-section state. Does NOT emit active_tool_changed — callers
## are responsible for the appropriate follow-up emission.
func _teardown_active_manipulation_tool() -> void:
	if _active_tool == null:
		return
	# Only tear down if this is a manipulation tool (i.e. active from a Tools
	# button, not from an Annotate-section kind). We detect this by checking
	# whether _active_kind_name is empty — kind-activated tools always set it.
	if _active_kind_name != &"":
		return
	# Disconnect annotation_modified to avoid stale callbacks.
	if _active_tool.annotation_modified.is_connected(_on_manipulation_tool_modified):
		_active_tool.annotation_modified.disconnect(_on_manipulation_tool_modified)
	_active_tool.on_deactivate()
	_active_tool = null


## Forwarded from a manipulation tool's annotation_modified signal.
## Relays the change to the host via update_annotation.
## The host's annotations_changed signal then triggers canvas redraw.
func _on_manipulation_tool_modified(annotation_id: String, new_annotation: Dictionary) -> void:
	if _host != null:
		_host.update_annotation(annotation_id, new_annotation)


# ── Internal: signal handlers ─────────────────────────────────────────────────

## Called when the user presses or releases a kind button.
func _on_button_toggled(kind_name: StringName, pressed: bool) -> void:
	if pressed:
		# Activate the tool for this kind.
		# If a different tool is already active, _activate_tool_for_kind deactivates it.
		_activate_tool_for_kind(kind_name)
		# Ensure the button stays visually toggled on.
		if _buttons.has(kind_name):
			var btn: Button = _buttons[kind_name]
			if is_instance_valid(btn) and not btn.button_pressed:
				btn.set_pressed_no_signal(true)
	else:
		# User toggled off the currently-active button → deactivate without switching.
		if kind_name == _active_kind_name:
			_deactivate_current_tool()


## Called when the active tool emits annotation_ready.
## Forwards to host.add_annotation() as the single call site (design §11.2 comment).
func _on_annotation_ready(annotation: Dictionary) -> void:
	if _host != null:
		_host.add_annotation(annotation)


## Called when the active tool emits cancelled (e.g., user pressed Escape).
func _on_tool_cancelled() -> void:
	# Untoggle the active button and clean up.
	var kind_name := _active_kind_name
	_deactivate_current_tool()
	if kind_name != &"" and _buttons.has(kind_name):
		var btn: Button = _buttons[kind_name]
		if is_instance_valid(btn):
			btn.set_pressed_no_signal(false)


## Called when the registry emits annotation_kind_registered.
## Appends a button for plugin kinds (after core kinds). Core kinds registered
## after construction also get appended — toolbar preserves registration order
## within each tier, which means late-arriving core kinds appear after earlier
## plugin kinds in the visual order. This is an acceptable edge case: core kinds
## are expected to be registered at startup before any toolbar is constructed.
func _on_kind_registered(kind_name: StringName) -> void:
	if _registry == null:
		return
	var kind := _registry.get_annotation_kind(kind_name)
	if kind == null:
		return
	# If already present (shouldn't happen, but be safe), skip.
	if _buttons.has(kind_name):
		return
	_try_add_button(kind)


## Called when the registry emits annotation_kind_deregistered.
## If the deregistering kind's tool is currently active, deactivates it and
## emits cancelled on it before removing the button (design §11.3).
func _on_kind_deregistered(kind_name: StringName) -> void:
	if _active_kind_name == kind_name:
		# Emit cancelled on the tool before deactivating (design §11.3).
		if _active_tool != null:
			# Disconnect annotation_ready first so we don't forward a stale add.
			if _active_tool.annotation_ready.is_connected(_on_annotation_ready):
				_active_tool.annotation_ready.disconnect(_on_annotation_ready)
			# Disconnect cancelled handler so deactivating doesn't re-trigger it.
			if _active_tool.cancelled.is_connected(_on_tool_cancelled):
				_active_tool.cancelled.disconnect(_on_tool_cancelled)
			_active_tool.on_deactivate()
			# Emit cancelled after deactivate so the tool is already torn down.
			_active_tool.cancelled.emit()
			_active_tool = null
			_active_kind_name = &""
			if _status_label != null:
				_status_label.text = ""
			active_tool_changed.emit(null)

	# Remove the button.
	if _buttons.has(kind_name):
		var btn: Button = _buttons[kind_name]
		if is_instance_valid(btn):
			btn.queue_free()
		_buttons.erase(kind_name)
