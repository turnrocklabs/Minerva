extends Control
## Smoke test scene for AnnotationToolbar compact presentation mode.
##
## Exercises:
##   1. LABELED mode (default) — wide VBox toolbar on the right.
##   2. COMPACT mode — narrow HBox icon strip along the top.
##   3. Runtime toggle via a Button — switches both toolbars between modes
##      to verify that _rebuild_layout() correctly tears down and recreates
##      children without leaving orphan nodes or stale signal connections.
##
## Both toolbars share the same AnnotationRegistry so button populations are
## identical, making it easy to visually compare the two modes side-by-side.
##
## NOTE: This scene is intentionally off-tree (not registered in manifest.json).
## TODO: orchestrator to register compact_toolbar_smoke panel in manifest.json.
##   Suggested entry — add to hello_scene's "ui.panels" array:
##   {
##     "name": "compact_toolbar_smoke",
##     "kind": "godot_scene",
##     "entry_scene": "scenes/compact_toolbar_smoke.tscn",
##     "scripts": ["scenes/compact_toolbar_smoke.gd"],
##     "file_extensions": [],
##     "ipc_channels": []
##   }

# --- node references (populated in _ready) ---
var _toolbar_labeled: AnnotationToolbar = null
var _toolbar_compact: AnnotationToolbar = null
var _toggle_btn: Button = null
var _status_label: Label = null

# Shared annotation substrate.
var _registry: AnnotationRegistry = null

# Tracks which mode the "live" toggle toolbar is in.
var _current_mode: AnnotationToolbar.PresentationMode = AnnotationToolbar.PresentationMode.LABELED


func _ready() -> void:
	# Build the shared registry and populate built-in kinds.
	_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_registry)

	# Wire both toolbars.
	_toolbar_labeled = $VBox/SideBySide/LabeledPanel/AnnotationToolbar
	_toolbar_compact = $VBox/SideBySide/CompactPanel/AnnotationToolbar

	_toolbar_labeled.set_registry(_registry)
	_toolbar_compact.set_registry(_registry)

	# Ensure initial modes are set correctly.
	_toolbar_labeled.set_presentation_mode(AnnotationToolbar.PresentationMode.LABELED)
	_toolbar_compact.set_presentation_mode(AnnotationToolbar.PresentationMode.COMPACT)

	_toggle_btn = $VBox/Controls/ToggleButton
	_status_label = $VBox/Controls/StatusLabel

	_toggle_btn.pressed.connect(_on_toggle_pressed)
	_update_status()


func _on_toggle_pressed() -> void:
	# Toggle the COMPACT toolbar's mode between LABELED and COMPACT at runtime.
	# This is the key acceptance test: the toolbar must survive a rebuild without
	# leaking children or losing its registry connection.
	if _current_mode == AnnotationToolbar.PresentationMode.LABELED:
		_current_mode = AnnotationToolbar.PresentationMode.COMPACT
	else:
		_current_mode = AnnotationToolbar.PresentationMode.LABELED
	_toolbar_compact.set_presentation_mode(_current_mode)
	_update_status()


func _update_status() -> void:
	if _status_label == null:
		return
	var mode_name: String = "COMPACT" if _current_mode == AnnotationToolbar.PresentationMode.COMPACT else "LABELED"
	_status_label.text = "Right toolbar is now: %s  (toggle button switches it at runtime)" % mode_name
