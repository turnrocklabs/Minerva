class_name AnnotationToolbar
extends VBoxContainer
## Annotation authoring toolbar widget.
##
## Design §11.1. Populated at runtime from an AnnotationRegistry. Each kind
## that returns a non-null author_ui() gets one toggle button. Pressing a
## button activates that kind's AnnotationAuthorTool and deactivates the
## previously-active one.
##
## Presentation modes (set `presentation_mode` @export or call set_presentation_mode()):
##
##   LABELED (default) — VBoxContainer layout with Tools/Annotate header labels,
##     FlowContainers for buttons, and a status label.  Unchanged from v1 behavior.
##     - Tools Header Label (centered) "Tools"
##     - FlowContainer (`_tools_flow`) holding the single Select button (the
##       universal manipulation tool — see _construct_tool_for_name)
##     - Header Label (centered) showing `header_text` (default "Annotate")
##     - FlowContainer (`_button_flow`) holding the icon-only toggle buttons
##     - Status Label (`_status_label`) in pink showing the active kind's
##       display_name, or empty when no tool is active
##
##   COMPACT — HBoxContainer strip ~40–50 px tall. No header labels, no status label.
##     Suitable for narrow plugin panels (e.g. CAD side-panel).
##     - Buttons flow left-to-right inside an HBoxContainer.
##     - Buttons WITH toolbar_icon: rendered icon-only, no text.
##     - Buttons WITHOUT toolbar_icon: rendered with a 1–2 char abbreviation.
##       Abbreviation rule: first character of the display_name, uppercased.
##       If that would collide with an existing button, two chars are used
##       (first + second of the name).  Plugin authors should set toolbar_icon
##       to avoid abbreviation collisions in dense toolbars.
##     - Tooltips show the full display_name so users can discover each icon.
##
## Switching modes at runtime (set_presentation_mode) drops all layout children
## and rebuilds cleanly — no orphan nodes, no signal leaks in the layout layer.
## Button state (toggle, active tool) is preserved across rebuilds.
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
## name is the button name (currently only "select") or "" when the
## previously-active Tools button was toggled off.
signal active_tool_button_changed(name: String)

# ── Presentation mode ──────────────────────────────────────────────────────────

enum PresentationMode {
	## Default labeled VBox layout with section headers and a status label.
	LABELED,
	## Compact HBox icon strip (~40–50 px tall). No headers or status label.
	COMPACT,
}

## Current presentation mode. Changing this at runtime triggers a full layout
## rebuild. Existing consumers (LABELED is the default) see no behavioral change.
@export var presentation_mode: PresentationMode = PresentationMode.LABELED : set = set_presentation_mode


## Switch the toolbar to a new presentation mode. Safe to call at runtime:
## drops all layout children and rebuilds them cleanly, then re-populates
## buttons from the current registry without disturbing tool activation state.
##
## Called automatically when the @export property is changed in the Inspector
## or by code. If the layout has not been built yet (before _ready()), the
## setter records the mode and returns — _ready() will call _ensure_layout()
## with the correct mode already set.
func set_presentation_mode(mode: PresentationMode) -> void:
	presentation_mode = mode
	# Only rebuild if the layout has already been constructed.
	# If _button_flow is null, _ready() hasn't run yet; _ensure_layout() will
	# pick up the correct mode when it fires for the first time.
	if _button_flow != null:
		_rebuild_layout()

# ── Tools-section icons ────────────────────────────────────────────────────────
## Icon UIDs for the Tools-section buttons, keyed by button name.
##
## There is exactly ONE Tools-section button — Select — because the single
## universal manipulation tool (AnnotationTransformTool) does select, move,
## rotate and scale from one armed state with no mode switching. The former
## Translate/Rotate/Scale entries were removed with their buttons; re-adding a
## key here does nothing unless _construct_tool_for_name also learns the name,
## and a second manipulation button is a design regression — don't.
const _TOOL_ICON_UIDS: Dictionary = {
	"select": "uid://eckoinneympm",  # graphics_editor/select_tool_icon_24.png
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
var _capabilities: Dictionary = {}

## kind_name (StringName) → Button — the live button table.
var _buttons: Dictionary = {}

## name (String) → Button — the Tools-section button table.
## Keys: "select" (the only manipulation button).
var _tool_buttons: Dictionary = {}

## The name of the currently-active Tools button, or "" if none.
var _active_tool_button_name: String = ""

## Layout children — built lazily by _ensure_layout(). May be null until then.
## In LABELED mode _tools_flow and _button_flow are FlowContainers; in COMPACT
## mode they both point to the same HBoxContainer. Typed as Container (common
## base) so both modes can share assignment without static-type errors.
var _tools_header_label: Label = null
var _tools_flow: Container = null
var _header_label: Label = null
var _button_flow: Container = null
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
	if host != null and host.has_method("get_annotation_capabilities"):
		_capabilities = host.get_annotation_capabilities()
	elif host != null and host.has_method("get_capabilities"):
		_capabilities = host.get_capabilities()
	else:
		_capabilities = {}
	_rebuild_layout()


## Returns the currently-active AnnotationAuthorTool, or null if none is active.
func get_active_tool() -> AnnotationAuthorTool:
	return _active_tool


func clear_active_tool() -> void:
	var prev_kind := _active_kind_name
	var had_active_tool := _active_tool != null
	_deactivate_current_tool()
	if prev_kind != &"" and _buttons.has(prev_kind):
		var prev_btn: Button = _buttons[prev_kind]
		if is_instance_valid(prev_btn) and prev_btn.button_pressed:
			prev_btn.set_pressed_no_signal(false)
	_teardown_active_manipulation_tool()
	_untoggle_active_tool_button()
	if _status_label != null:
		_status_label.text = ""
	if not had_active_tool:
		active_tool_changed.emit(null)

# ── Internal: layout ──────────────────────────────────────────────────────────

## Drop all layout children and rebuild for the current presentation_mode, then
## re-populate kind buttons from the current registry. Safe to call at runtime:
## button table (_buttons, _tool_buttons) is cleared before rebuild so the new
## buttons replace the old ones cleanly. Active tool state is preserved.
func _rebuild_layout() -> void:
	# Tear down existing layout nodes (layout container refs are nulled after free).
	_tear_down_layout()
	# Rebuild for the current mode.
	_ensure_layout()
	# Re-populate kind buttons from the registry (layout just created empty slots).
	if _registry != null:
		var kinds := _registry.list_annotation_kinds()
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
	# Restore visual toggle state for the active kind (if any).
	if _active_kind_name != &"" and _buttons.has(_active_kind_name):
		var btn: Button = _buttons[_active_kind_name]
		if is_instance_valid(btn) and not btn.button_pressed:
			btn.set_pressed_no_signal(true)
	# Restore visual toggle state for the active tool button (if any).
	if _active_tool_button_name != "" and _tool_buttons.has(_active_tool_button_name):
		var tbtn: Button = _tool_buttons[_active_tool_button_name]
		if is_instance_valid(tbtn) and not tbtn.button_pressed:
			tbtn.set_pressed_no_signal(true)
	# Restore status label text.
	if _status_label != null:
		if _active_kind_name != &"" and _registry != null:
			var kind := _registry.get_annotation_kind(_active_kind_name)
			_status_label.text = kind.display_name if kind != null else ""
		elif _active_tool_button_name != "":
			_status_label.text = _active_tool_button_name.capitalize()
		else:
			_status_label.text = ""


## Remove all layout nodes created by _ensure_layout() and clear the button
## tables. Does NOT free the outer VBoxContainer (self). Signal connections on
## the registry are left intact — only layout children are destroyed.
##
## In COMPACT mode _tools_flow and _button_flow both point to the same
## HBoxContainer, so we de-duplicate before freeing to avoid a double-free.
func _tear_down_layout() -> void:
	# Collect unique valid node references — guards against COMPACT mode where
	# _tools_flow and _button_flow are the same object.
	var seen: Array = []
	for node in [_status_label, _button_flow, _header_label, _tools_flow, _tools_header_label]:
		if node != null and is_instance_valid(node) and not (node in seen):
			seen.append(node)
			node.queue_free()
	_status_label = null
	_button_flow = null
	_header_label = null
	_tools_flow = null
	_tools_header_label = null
	# Clear button tables (buttons were children of the now-freed containers).
	_buttons.clear()
	_tool_buttons.clear()


## Build the header / FlowContainer / status-label structure if not already
## built. Idempotent. Called from _ready() and defensively from set_registry()
## so the toolbar works even when used outside the SceneTree (headless tests).
## Respects the current `presentation_mode`.
func _ensure_layout() -> void:
	if _button_flow != null:
		return

	if presentation_mode == PresentationMode.COMPACT:
		_ensure_layout_compact()
	else:
		_ensure_layout_labeled()


## Build the LABELED layout (default). VBoxContainer with section headers,
## FlowContainers, and a status label.
func _ensure_layout_labeled() -> void:
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
		if not _tool_allowed(tool_name.to_lower()):
			continue
		var btn := Button.new()
		btn.tooltip_text = tool_name
		btn.toggle_mode = true
		btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		# Apply icon if one is declared for this key; otherwise fall back to text.
		var tool_key: String = tool_name.to_lower()
		var icon_uid: String = _TOOL_ICON_UIDS.get(tool_key, "")
		if icon_uid != "":
			btn.icon = load(icon_uid) as Texture2D
			# No text when an icon is present.
		else:
			# Text fallback for a Tools button with no declared icon.
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


## Build the COMPACT layout. A single HBoxContainer strip ~40–50 px tall.
## No header labels, no status label. Tools-section and Annotate-section
## buttons are placed side-by-side in one row. Tooltip shows full names.
func _ensure_layout_compact() -> void:
	# Reuse _tools_flow and _button_flow as a single HBoxContainer. We store
	# both references pointing to the same node so _try_add_button and the
	# Tools-section construction code work without changes.
	var hbox := HBoxContainer.new()
	hbox.name = "_compact_hbox"
	# Limit height so the strip stays ~40–50 px.
	hbox.custom_minimum_size = Vector2(0, 40)
	add_child(hbox)

	# Point both flow refs at the same HBox so shared helpers (_try_add_button,
	# _tool_buttons population) add into the right container.
	_tools_flow = hbox
	_button_flow = hbox

	# _tools_header_label and _status_label remain null (compact mode omits them).
	# _header_label remains null (compact mode omits section labels).

	# Build Tools-section (Select) button into the compact HBox.
	for tool_name in ["Select"]:
		if not _tool_allowed(tool_name.to_lower()):
			continue
		var btn := Button.new()
		btn.toggle_mode = true
		btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		var tool_key: String = tool_name.to_lower()
		var icon_uid: String = _TOOL_ICON_UIDS.get(tool_key, "")
		if icon_uid != "":
			btn.icon = load(icon_uid) as Texture2D
			btn.tooltip_text = tool_name
		else:
			# Compact abbreviation: first char of name (uppercase).
			# See class-level doc for the abbreviation rule.
			btn.text = tool_name.left(1).to_upper()
			btn.tooltip_text = tool_name
		var name_capture: Array = [tool_key]
		btn.toggled.connect(func(pressed: bool) -> void:
			_on_tool_button_toggled(name_capture[0], pressed)
		)
		hbox.add_child(btn)
		_tool_buttons[tool_key] = btn

# ── Internal: Tools-section tool construction ─────────────────────────────────

## Construct and return a fresh tool instance for the given Tools-section button
## name. Returns null for unknown names.
##
## THE retirement mechanism: this match is the only way a manipulation tool
## reaches the UI. "select" builds AnnotationTransformTool — the one universal
## tool that selects, moves, rotates and scales without mode switching. The
## four single-gesture tools it subsumed were deleted (chore 019fb59b34ee).
func _construct_tool_for_name(tool_name: String) -> AnnotationAuthorTool:
	match tool_name:
		"select": return AnnotationTransformTool.new()
		_:        return null


# ── Internal: button population ───────────────────────────────────────────────

## Try to add a button for this kind. Does nothing if author_ui() returns null.
## In COMPACT mode, buttons without toolbar_icon render as a 1–2 char abbreviation:
##   - Primary: first character of display_name (uppercased).
##   - If that 1-char label already exists in _buttons' texts, use first 2 chars.
## Tooltip always shows the full display_name so users can discover the icon's meaning.
func _try_add_button(kind: AnnotationKind) -> void:
	if kind.author_ui() == null:
		return
	if not _kind_allowed(str(kind.name)):
		return
	_ensure_layout()
	var btn := Button.new()
	btn.toggle_mode = true
	btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# Tooltip always shows the full name (works in both modes, essential in COMPACT).
	btn.tooltip_text = kind.display_name
	if kind.toolbar_icon != null:
		# Icon-only button in both modes: no text, just the icon.
		btn.icon = kind.toolbar_icon
	elif presentation_mode == PresentationMode.COMPACT:
		# Compact abbreviation rule: first char of display_name, uppercased.
		# If that would duplicate an existing button's text, use first 2 chars.
		var abbr_1: String = kind.display_name.left(1).to_upper()
		var abbr_2: String = kind.display_name.left(2).to_upper()
		var used_texts: Array = []
		for existing_btn: Button in _buttons.values():
			if is_instance_valid(existing_btn):
				used_texts.append(existing_btn.text)
		btn.text = abbr_2 if (abbr_1 in used_texts) else abbr_1
	else:
		# LABELED fallback: full display_name as text (legacy behavior).
		btn.text = kind.display_name
	# Capture the kind name in an Array wrapper to survive lambda capture semantics.
	var kind_name_capture: Array = [kind.name]
	btn.toggled.connect(func(pressed: bool) -> void:
		_on_button_toggled(kind_name_capture[0], pressed)
	)
	_button_flow.add_child(btn)
	_buttons[kind.name] = btn


func _kind_allowed(kind_name: String) -> bool:
	var kinds: Variant = _capabilities.get("kinds", [])
	if kinds is Array and not (kinds as Array).is_empty():
		if kind_name in kinds:
			return true
		var aliases := BuiltinKinds.BUILTIN_KIND_ALIASES
		if aliases.has(kind_name) and aliases[kind_name] in kinds:
			return true
		for alias in aliases.keys():
			if str(aliases[alias]) == kind_name and str(alias) in kinds:
				return true
		return false
	return true


## Is the dock allowed to offer the built-in tool button `tool_name` (lowercase)?
##
## `tools` is an ALLOW-list, and an EMPTY one means "allow everything" — that is
## what every host omitting the key relies on. So the allow-list ALONE cannot
## express "this surface offers no Select": `"tools": []` SHOWS the button, the
## exact opposite of the intent (measured, B1u3).
##
## `tools_excluded` is the opt-in NEGATIVE channel, and it wins outright. It is
## absent from every host's capabilities but the pcb panel's, whose canvas owns
## ONE universal Select of its own and must not offer a second one in the dock;
## a host that never sets the key sees byte-identical behavior, and a host
## running against an older core that does not read the key simply keeps its
## Select button (the degrade path this pairs with).
func _tool_allowed(tool_name: String) -> bool:
	var excluded: Variant = _capabilities.get("tools_excluded", [])
	if excluded is Array and tool_name in (excluded as Array):
		return false
	var tools: Variant = _capabilities.get("tools", [])
	if tools is Array and not (tools as Array).is_empty():
		return tool_name in tools
	return true


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
## Param renamed `tool_name` from `name` to avoid shadowing Node.name.
func _on_tool_button_toggled(tool_name: String, pressed: bool) -> void:
	if pressed:
		# Untoggle every other Tools button first.
		for other_name in _tool_buttons.keys():
			if other_name != tool_name:
				var other_btn: Button = _tool_buttons[other_name]
				if is_instance_valid(other_btn) and other_btn.button_pressed:
					other_btn.set_pressed_no_signal(false)

		# Tear down any previously-active manipulation tool (one might have been
		# active from a prior Tools-button press).
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

		_active_tool_button_name = tool_name
		if _status_label != null:
			_status_label.text = tool_name.capitalize()
		active_tool_button_changed.emit(tool_name)

		# Construct and activate the tool, then forward to the canvas via
		# active_tool_changed. This is the single canonical emission point for
		# Tools-section tools; _deactivate_current_tool's null-emission above is
		# transient and the canvas will be overwritten by this non-null one.
		var new_tool: AnnotationAuthorTool = _construct_tool_for_name(tool_name)
		if new_tool != null:
			new_tool.on_activate(_host)
			_active_tool = new_tool
			_active_kind_name = &""
		active_tool_changed.emit(new_tool)
	else:
		# Toggled off: only clear if this button was the active one.
		if _active_tool_button_name == tool_name:
			_teardown_active_manipulation_tool()
			_active_tool_button_name = ""
			if _status_label != null:
				_status_label.text = ""
			active_tool_button_changed.emit("")
			active_tool_changed.emit(null)


# ── Internal: manipulation tool helpers ───────────────────────────────────────

## Deactivate and disconnect the currently-active Tools-section manipulation
## tool (the universal Select tool), if any. Does NOT touch _active_kind_name
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
	_active_tool.on_deactivate()
	_active_tool = null



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


## Called when the active tool emits cancelled (e.g., user pressed Escape, or
## the Universal Select tool clicked empty space).
func _on_tool_cancelled() -> void:
	# Untoggle the active button and clean up.
	var kind_name := _active_kind_name
	_deactivate_current_tool()
	if kind_name != &"" and _buttons.has(kind_name):
		var btn: Button = _buttons[kind_name]
		if is_instance_valid(btn):
			btn.set_pressed_no_signal(false)
	# Manipulation tools (Select/Transform) live in the Tools section and
	# leave _active_tool_button_name set after _deactivate_current_tool —
	# the kind-button branch above doesn't touch them. Untoggle here so the
	# toolbar visual matches the now-deactivated tool. No-op for kind tools
	# (idempotent: short-circuits when _active_tool_button_name is empty).
	_untoggle_active_tool_button()


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
