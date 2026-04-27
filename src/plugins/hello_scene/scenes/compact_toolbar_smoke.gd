extends Control
## Smoke test scene for AnnotationToolbar compact presentation mode.
##
## Layout: two toolbars stacked vertically, each with full panel width.
##   1. Top toolbar:    LABELED — wide VBox layout with Tools/Annotate headers
##                      and a status label.  Stays LABELED throughout the test.
##   2. Bottom toolbar: COMPACT (initial) — narrow HBox icon strip.  Toggleable
##                      via the button at the bottom; switches between LABELED
##                      and COMPACT to verify _rebuild_layout() handles runtime
##                      mode changes cleanly (no orphan nodes, registry kept).
##
## Both toolbars share one AnnotationRegistry so button populations match.

# --- node references (resolved in _ready) ---
var _toolbar_labeled: AnnotationToolbar = null
var _toolbar_compact: AnnotationToolbar = null
var _toggle_btn: Button = null
var _status_label: Label = null

# Shared annotation substrate.
var _registry: AnnotationRegistry = null

# Tracks the current mode of the BOTTOM (toggleable) toolbar. Initialized to
# match the explicit set_presentation_mode(COMPACT) call in _ready below.
var _current_mode: AnnotationToolbar.PresentationMode = AnnotationToolbar.PresentationMode.COMPACT


func _ready() -> void:
	_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_registry)

	_toolbar_labeled = $VBox/LabeledSection/LabeledToolbar
	_toolbar_compact = $VBox/CompactSection/CompactToolbar

	_toolbar_labeled.set_registry(_registry)
	_toolbar_compact.set_registry(_registry)

	# Top toolbar stays LABELED (default — no explicit set needed).
	# Bottom toolbar starts in COMPACT to demonstrate the alternate layout.
	_toolbar_compact.set_presentation_mode(AnnotationToolbar.PresentationMode.COMPACT)

	_toggle_btn = $VBox/Controls/ToggleButton
	_status_label = $VBox/Controls/StatusLabel

	_toggle_btn.pressed.connect(_on_toggle_pressed)
	_update_status()


func _on_toggle_pressed() -> void:
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
	_status_label.text = "Bottom toolbar: %s  (button toggles)" % mode_name
