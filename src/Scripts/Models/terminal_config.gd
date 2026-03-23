extends RefCounted
class_name TerminalConfig
## Terminal appearance and behavior settings.
## Persisted to config_file.cfg under [Terminal] section.

signal settings_changed

const SECTION := "Terminal"

## Color theme preset name, or "custom" for user-defined palette.
var theme_name: String = "default":
	set(v):
		if theme_name != v:
			theme_name = v
			settings_changed.emit()

## 16 ANSI colors used when theme_name == "custom".
var custom_palette: PackedColorArray = PackedColorArray():
	set(v):
		custom_palette = v
		settings_changed.emit()

## Default foreground color (used when cell has no fg style).
var default_fg: Color = Color.WHITE:
	set(v):
		if default_fg != v:
			default_fg = v
			settings_changed.emit()

## Default background color (terminal backdrop + unstyled cell bg).
var default_bg: Color = Color.BLACK:
	set(v):
		if default_bg != v:
			default_bg = v
			settings_changed.emit()

## Font resource path.
var font_family: String = "res://assets/fonts/CascadiaCode/CascadiaMono.ttf":
	set(v):
		if font_family != v:
			font_family = v
			settings_changed.emit()

## Font size in points.
var font_size: int = 0:
	set(v):
		v = clampi(v, 8, 32)
		if font_size != v:
			font_size = v
			settings_changed.emit()

## Scrollback buffer line count. -1 = unlimited.
var scrollback_lines: int = 5000:
	set(v):
		if v != -1:
			v = clampi(v, 100, 100000)
		if scrollback_lines != v:
			scrollback_lines = v
			settings_changed.emit()

## Cursor style: 0=block, 1=bar, 2=underline.
var cursor_style: int = 0:
	set(v):
		v = clampi(v, 0, 2)
		if cursor_style != v:
			cursor_style = v
			settings_changed.emit()

## Whether the cursor blinks.
var cursor_blink: bool = true:
	set(v):
		if cursor_blink != v:
			cursor_blink = v
			settings_changed.emit()


func _init() -> void:
	if font_size == 0:
		font_size = ThemeDB.fallback_font_size


func get_active_palette() -> PackedColorArray:
	## Returns the 16-color ANSI palette for the current theme.
	if theme_name == "custom" and custom_palette.size() == 16:
		return custom_palette
	var themes_class = load("res://Scripts/Models/terminal_themes.gd")
	if themes_class:
		var theme_data: Dictionary = themes_class.get_theme(theme_name)
		if not theme_data.is_empty():
			return theme_data.palette
	# Fallback: default theme
	var fallback = load("res://Scripts/Models/terminal_themes.gd")
	if fallback:
		return fallback.get_theme("default").palette
	return PackedColorArray()


func get_full_palette() -> PackedColorArray:
	## Returns the full 256-color palette: 16 ANSI + 216 cube + 24 grayscale.
	var palette := PackedColorArray()
	palette.append_array(get_active_palette())
	# 216 color cube (6x6x6)
	for r in range(6):
		for g in range(6):
			for b in range(6):
				palette.append(Color(r * 51 / 255.0, g * 51 / 255.0, b * 51 / 255.0))
	# 24 grayscale shades
	for i in range(24):
		var v: float = (i * 10 + 8) / 255.0
		palette.append(Color(v, v, v))
	return palette


func get_theme_fg_bg() -> Dictionary:
	## Returns {"fg": Color, "bg": Color} from current theme, or custom overrides.
	if theme_name == "custom":
		return {"fg": default_fg, "bg": default_bg}
	var themes_class = load("res://Scripts/Models/terminal_themes.gd")
	if themes_class:
		var theme_data: Dictionary = themes_class.get_theme(theme_name)
		if not theme_data.is_empty():
			return {"fg": theme_data.get("fg", default_fg), "bg": theme_data.get("bg", default_bg)}
	return {"fg": default_fg, "bg": default_bg}


func get_font() -> Font:
	## Load and return the configured font resource.
	var f = load(font_family)
	if f is Font:
		return f
	return ThemeDB.fallback_font


func save(config: ConfigFile) -> void:
	config.set_value(SECTION, "theme_name", theme_name)
	config.set_value(SECTION, "default_fg", default_fg)
	config.set_value(SECTION, "default_bg", default_bg)
	config.set_value(SECTION, "font_family", font_family)
	config.set_value(SECTION, "font_size", font_size)
	config.set_value(SECTION, "scrollback_lines", scrollback_lines)
	config.set_value(SECTION, "cursor_style", cursor_style)
	config.set_value(SECTION, "cursor_blink", cursor_blink)
	if theme_name == "custom" and custom_palette.size() == 16:
		config.set_value(SECTION, "custom_palette", custom_palette)


func load_from_config(config: ConfigFile) -> void:
	if not config.has_section(SECTION):
		return
	theme_name = config.get_value(SECTION, "theme_name", "default")
	default_fg = config.get_value(SECTION, "default_fg", Color.WHITE)
	default_bg = config.get_value(SECTION, "default_bg", Color.BLACK)
	font_family = config.get_value(SECTION, "font_family", "res://assets/fonts/CascadiaCode/CascadiaMono.ttf")
	font_size = config.get_value(SECTION, "font_size", ThemeDB.fallback_font_size)
	scrollback_lines = config.get_value(SECTION, "scrollback_lines", 5000)
	cursor_style = config.get_value(SECTION, "cursor_style", 0)
	cursor_blink = config.get_value(SECTION, "cursor_blink", true)
	var saved_palette = config.get_value(SECTION, "custom_palette", PackedColorArray())
	if saved_palette is PackedColorArray and saved_palette.size() == 16:
		custom_palette = saved_palette
