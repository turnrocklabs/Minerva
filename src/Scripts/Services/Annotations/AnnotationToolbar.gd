class_name AnnotationToolbar
extends HBoxContainer
## Annotation authoring toolbar widget.
##
## Design §11.1. Populated at runtime from an AnnotationRegistry. Each kind
## that returns a non-null author_ui() gets one toggle button. Pressing a
## button activates that kind's AnnotationAuthorTool and deactivates the
## previously-active one.
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

# ── Public API ─────────────────────────────────────────────────────────────────

## Bind this toolbar to a registry.
## Populates buttons immediately from kinds that have a non-null author_ui(),
## then connects to registration/deregistration signals for live updates.
## Calling again replaces the previous registry.
func set_registry(registry: AnnotationRegistry) -> void:
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

# ── Internal: button population ───────────────────────────────────────────────

## Try to add a button for this kind. Does nothing if author_ui() returns null.
func _try_add_button(kind: AnnotationKind) -> void:
	if kind.author_ui() == null:
		return
	var btn := Button.new()
	btn.text = kind.display_name
	btn.toggle_mode = true
	if kind.toolbar_icon != null:
		btn.icon = kind.toolbar_icon
	# Capture the kind name in an Array wrapper to survive lambda capture semantics.
	var kind_name_capture: Array = [kind.name]
	btn.toggled.connect(func(pressed: bool) -> void:
		_on_button_toggled(kind_name_capture[0], pressed)
	)
	add_child(btn)
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


## Activate a tool for the given kind. Deactivates the previous tool first.
func _activate_tool_for_kind(kind_name: StringName) -> void:
	# Deactivate previous tool (and untoggle its button).
	var prev_kind_name := _active_kind_name
	_deactivate_current_tool()

	# Untoggle the previous button without re-entering the toggle handler.
	if prev_kind_name != &"" and _buttons.has(prev_kind_name):
		var prev_btn: Button = _buttons[prev_kind_name]
		if is_instance_valid(prev_btn) and prev_btn.button_pressed:
			prev_btn.set_pressed_no_signal(false)

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

	# Remove the button.
	if _buttons.has(kind_name):
		var btn: Button = _buttons[kind_name]
		if is_instance_valid(btn):
			btn.queue_free()
		_buttons.erase(kind_name)
