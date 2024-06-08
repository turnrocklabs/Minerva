extends Control


@onready var _default_zoom = theme.default_font_size

func zoom_ui(factor: int):
	if theme.has_default_font_size():
		theme.default_font_size += factor
	else:
		theme.default_font_size = ThemeDB.fallback_font_size + factor

func reset_zoom():
	theme.default_font_size = _default_zoom

func _gui_input(event):

	if event.is_action_released("zoom_in", true):
		zoom_ui(1)
		
		accept_event()

	if event.is_action_released("zoom_out", true):
		zoom_ui(-1)
		
		accept_event()
