extends Control
## Smoke test for AnnotationToolbar.PresentationMode + ResponsiveContainer dogfood.
##
## Top toolbar's mode is driven by ResponsiveContainer.width_class:
##   xs / sm  → COMPACT  (narrow panel: icon strip)
##   md / lg / xl → LABELED  (wide panel: full headers)
##
## Bottom toolbar mode is user-toggleable via the "Toggle bottom" button —
## independent of width class so it always demonstrates a runtime rebuild.
##
## Both toolbars share one AnnotationRegistry so button populations match.

# --- node references (resolved in _ready) ---
var _responsive: ResponsiveContainer = null
var _width_label: Label = null
var _toolbar_top: AnnotationToolbar = null
var _toolbar_bottom: AnnotationToolbar = null
var _toggle_btn: Button = null
var _status_label: Label = null

# Shared annotation substrate.
var _registry: AnnotationRegistry = null

# Bottom toolbar mode (user-toggleable).
var _bottom_mode: AnnotationToolbar.PresentationMode = AnnotationToolbar.PresentationMode.COMPACT


func _ready() -> void:
	_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_registry)

	_responsive = $ResponsiveContainer
	_width_label = $ResponsiveContainer/VBox/WidthLabel
	_toolbar_top = $ResponsiveContainer/VBox/LabeledSection/LabeledToolbar
	_toolbar_bottom = $ResponsiveContainer/VBox/CompactSection/CompactToolbar
	_toggle_btn = $ResponsiveContainer/VBox/Controls/ToggleButton
	_status_label = $ResponsiveContainer/VBox/Controls/StatusLabel

	_toolbar_top.set_registry(_registry)
	_toolbar_bottom.set_registry(_registry)

	# Top toolbar mode is driven by width class. Apply initial state before any
	# resize event fires (matches the documented ResponsiveContainer pattern).
	_apply_width_class(_responsive.width_class)
	_responsive.width_class_changed.connect(_apply_width_class)

	# Bottom toolbar starts COMPACT (independent of width class).
	_toolbar_bottom.set_presentation_mode(_bottom_mode)

	_toggle_btn.pressed.connect(_on_toggle_pressed)
	_update_status()


func _apply_width_class(cls: StringName) -> void:
	# Top toolbar follows the width class. Narrow → COMPACT, wide → LABELED.
	# This is the dogfood case: a real plugin panel would use the same pattern
	# to switch its toolbar mode based on available width.
	var top_mode: AnnotationToolbar.PresentationMode = (
		AnnotationToolbar.PresentationMode.LABELED
		if cls == ResponsiveContainer.CLASS_MD
			or cls == ResponsiveContainer.CLASS_LG
			or cls == ResponsiveContainer.CLASS_XL
		else AnnotationToolbar.PresentationMode.COMPACT
	)
	_toolbar_top.set_presentation_mode(top_mode)
	if _width_label != null:
		_width_label.text = "width class: %s  (%dpx)" % [cls, int(_responsive.size.x)]
	_update_status()


func _on_toggle_pressed() -> void:
	if _bottom_mode == AnnotationToolbar.PresentationMode.LABELED:
		_bottom_mode = AnnotationToolbar.PresentationMode.COMPACT
	else:
		_bottom_mode = AnnotationToolbar.PresentationMode.LABELED
	_toolbar_bottom.set_presentation_mode(_bottom_mode)
	_update_status()


func _update_status() -> void:
	if _status_label == null:
		return
	var top_name: String = (
		"COMPACT" if _toolbar_top.presentation_mode == AnnotationToolbar.PresentationMode.COMPACT
		else "LABELED"
	)
	var bot_name: String = "COMPACT" if _bottom_mode == AnnotationToolbar.PresentationMode.COMPACT else "LABELED"
	_status_label.text = "top: %s  |  bottom: %s" % [top_name, bot_name]
