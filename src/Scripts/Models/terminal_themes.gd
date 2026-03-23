extends RefCounted
class_name TerminalThemes
## Built-in terminal color theme presets.
## Each theme has a 16-color ANSI palette + default fg/bg.

# Theme data: {"palette": PackedColorArray[16], "fg": Color, "bg": Color}
# Palette order: black, red, green, yellow, blue, magenta, cyan, white,
#                bright_black, bright_red, bright_green, bright_yellow,
#                bright_blue, bright_magenta, bright_cyan, bright_white

static var THEMES: Dictionary = {
	"default": {
		"palette": PackedColorArray([
			Color8(0, 0, 0),        Color8(204, 0, 0),      Color8(0, 204, 0),      Color8(204, 204, 0),
			Color8(70, 130, 230),   Color8(204, 0, 204),    Color8(0, 204, 204),    Color8(204, 204, 204),
			Color8(128, 128, 128),  Color8(255, 0, 0),      Color8(0, 255, 0),      Color8(255, 255, 0),
			Color8(100, 160, 255),  Color8(255, 0, 255),    Color8(0, 255, 255),    Color8(255, 255, 255),
		]),
		"fg": Color.WHITE,
		"bg": Color.BLACK,
	},
	"solarized_dark": {
		"palette": PackedColorArray([
			Color8(7, 54, 66),      Color8(220, 50, 47),    Color8(133, 153, 0),    Color8(181, 137, 0),
			Color8(38, 139, 210),   Color8(211, 54, 130),   Color8(42, 161, 152),   Color8(238, 232, 213),
			Color8(0, 43, 54),      Color8(203, 75, 22),    Color8(88, 110, 117),   Color8(101, 123, 131),
			Color8(131, 148, 150),  Color8(108, 113, 196),  Color8(147, 161, 161),  Color8(253, 246, 227),
		]),
		"fg": Color8(131, 148, 150),
		"bg": Color8(0, 43, 54),
	},
	"dracula": {
		"palette": PackedColorArray([
			Color8(33, 34, 44),     Color8(255, 85, 85),    Color8(80, 250, 123),   Color8(241, 250, 140),
			Color8(98, 114, 164),   Color8(255, 121, 198),  Color8(139, 233, 253),  Color8(248, 248, 242),
			Color8(98, 114, 164),   Color8(255, 110, 110),  Color8(105, 255, 148),  Color8(255, 255, 165),
			Color8(123, 139, 189),  Color8(255, 146, 223),  Color8(164, 255, 255),  Color8(255, 255, 255),
		]),
		"fg": Color8(248, 248, 242),
		"bg": Color8(40, 42, 54),
	},
	"nord": {
		"palette": PackedColorArray([
			Color8(59, 66, 82),     Color8(191, 97, 106),   Color8(163, 190, 140),  Color8(235, 203, 139),
			Color8(129, 161, 193),  Color8(180, 142, 173),  Color8(136, 192, 208),  Color8(229, 233, 240),
			Color8(76, 86, 106),    Color8(191, 97, 106),   Color8(163, 190, 140),  Color8(235, 203, 139),
			Color8(129, 161, 193),  Color8(180, 142, 173),  Color8(143, 188, 187),  Color8(236, 239, 244),
		]),
		"fg": Color8(216, 222, 233),
		"bg": Color8(46, 52, 64),
	},
	"monokai": {
		"palette": PackedColorArray([
			Color8(39, 40, 34),     Color8(249, 38, 114),   Color8(166, 226, 46),   Color8(244, 191, 117),
			Color8(102, 217, 239),  Color8(174, 129, 255),  Color8(161, 239, 228),  Color8(248, 248, 242),
			Color8(117, 113, 94),   Color8(249, 38, 114),   Color8(166, 226, 46),   Color8(244, 191, 117),
			Color8(102, 217, 239),  Color8(174, 129, 255),  Color8(161, 239, 228),  Color8(248, 248, 242),
		]),
		"fg": Color8(248, 248, 242),
		"bg": Color8(39, 40, 34),
	},
	"light": {
		"palette": PackedColorArray([
			Color8(0, 0, 0),        Color8(194, 54, 33),    Color8(37, 188, 36),    Color8(173, 173, 39),
			Color8(73, 46, 225),    Color8(211, 56, 211),   Color8(51, 187, 200),   Color8(203, 204, 205),
			Color8(129, 131, 131),  Color8(252, 57, 31),    Color8(49, 231, 34),    Color8(234, 236, 35),
			Color8(88, 51, 255),    Color8(249, 53, 248),   Color8(20, 240, 240),   Color8(233, 235, 235),
		]),
		"fg": Color8(0, 0, 0),
		"bg": Color8(253, 253, 253),
	},
}


static func get_theme(name: String) -> Dictionary:
	if THEMES.has(name):
		return THEMES[name]
	return THEMES.get("default", {})


static func list_themes() -> PackedStringArray:
	var names := PackedStringArray()
	for key in THEMES:
		names.append(key)
	return names


static func theme_display_name(name: String) -> String:
	match name:
		"default": return "Default"
		"solarized_dark": return "Solarized Dark"
		"dracula": return "Dracula"
		"nord": return "Nord"
		"monokai": return "Monokai"
		"light": return "Light"
		_: return name.capitalize()
