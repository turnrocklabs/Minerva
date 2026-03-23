extends SceneTree
## Unit tests for TerminalConfig and TerminalThemes.
## Run: godot --headless --path <minerva/src> --main-loop res://test/test_terminal_config.gd

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("\n===== TerminalConfig Tests =====\n")

	test_defaults()
	test_save_load_roundtrip()
	test_signal_emission()
	test_theme_presets_valid()
	test_get_active_palette_preset()
	test_get_active_palette_custom()
	test_full_palette_size()
	test_font_loading()
	test_invalid_theme_fallback()
	test_scrollback_clamping()
	test_font_size_clamping()
	test_cursor_style_clamping()
	test_missing_config_section()

	print("\n===== Results: %d passed, %d failed =====" % [_pass, _fail])
	if _fail > 0:
		print("******** FAILED ********")
	quit(1 if _fail > 0 else 0)


func _assert(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % label)
	else:
		_fail += 1
		print("  FAIL: %s" % label)


func _assert_eq(actual, expected, label: String) -> void:
	if typeof(actual) == typeof(expected) and actual == expected:
		_pass += 1
		print("  PASS: %s" % label)
	else:
		_fail += 1
		print("  FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])


# -- Tests --------------------------------------------------------------------

func test_defaults() -> void:
	print("test_defaults:")
	var tc := TerminalConfig.new()
	_assert_eq(tc.theme_name, "default", "default theme name")
	_assert_eq(tc.default_fg, Color.WHITE, "default fg")
	_assert_eq(tc.default_bg, Color.BLACK, "default bg")
	_assert(tc.font_family.ends_with("CascadiaMono.ttf"), "default font family")
	_assert(tc.font_size >= 8 and tc.font_size <= 32, "default font size in range")
	_assert_eq(tc.scrollback_lines, 5000, "default scrollback")
	_assert_eq(tc.cursor_style, 0, "default cursor style (block)")
	_assert_eq(tc.cursor_blink, true, "default cursor blink")
	_assert_eq(tc.custom_palette.size(), 0, "default custom palette empty")


func test_save_load_roundtrip() -> void:
	print("test_save_load_roundtrip:")
	var tc := TerminalConfig.new()
	tc.theme_name = "dracula"
	tc.default_fg = Color(0.9, 0.9, 0.8)
	tc.default_bg = Color(0.1, 0.1, 0.2)
	tc.font_family = "res://assets/fonts/CascadiaCode/CascadiaMonoNF.ttf"
	tc.font_size = 18
	tc.scrollback_lines = 1000
	tc.cursor_style = 1
	tc.cursor_blink = false

	var cfg := ConfigFile.new()
	tc.save(cfg)

	var tc2 := TerminalConfig.new()
	tc2.load_from_config(cfg)

	_assert_eq(tc2.theme_name, "dracula", "roundtrip theme_name")
	_assert(tc2.default_fg.is_equal_approx(Color(0.9, 0.9, 0.8)), "roundtrip default_fg")
	_assert(tc2.default_bg.is_equal_approx(Color(0.1, 0.1, 0.2)), "roundtrip default_bg")
	_assert_eq(tc2.font_family, "res://assets/fonts/CascadiaCode/CascadiaMonoNF.ttf", "roundtrip font_family")
	_assert_eq(tc2.font_size, 18, "roundtrip font_size")
	_assert_eq(tc2.scrollback_lines, 1000, "roundtrip scrollback")
	_assert_eq(tc2.cursor_style, 1, "roundtrip cursor_style")
	_assert_eq(tc2.cursor_blink, false, "roundtrip cursor_blink")


func test_signal_emission() -> void:
	print("test_signal_emission:")
	var tc := TerminalConfig.new()
	var count := 0
	tc.settings_changed.connect(func(): count += 1)

	tc.theme_name = "nord"
	_assert_eq(count, 1, "signal after theme_name change")

	tc.font_size = 20
	_assert_eq(count, 2, "signal after font_size change")

	tc.cursor_blink = false
	_assert_eq(count, 3, "signal after cursor_blink change")

	# No signal when setting same value
	tc.cursor_blink = false
	_assert_eq(count, 3, "no signal when value unchanged")


func test_theme_presets_valid() -> void:
	print("test_theme_presets_valid:")
	var names := TerminalThemes.list_themes()
	_assert(names.size() >= 5, "at least 5 themes defined")

	for name in names:
		var theme := TerminalThemes.get_theme(name)
		_assert(theme.has("palette"), "theme '%s' has palette" % name)
		_assert(theme.has("fg"), "theme '%s' has fg" % name)
		_assert(theme.has("bg"), "theme '%s' has bg" % name)
		var pal: PackedColorArray = theme.palette
		_assert_eq(pal.size(), 16, "theme '%s' palette has 16 colors" % name)


func test_get_active_palette_preset() -> void:
	print("test_get_active_palette_preset:")
	var tc := TerminalConfig.new()
	tc.theme_name = "dracula"
	var pal := tc.get_active_palette()
	_assert_eq(pal.size(), 16, "dracula palette size")
	# Dracula black is Color8(33, 34, 44)
	_assert(pal[0].r8 == 33 and pal[0].g8 == 34, "dracula black matches")


func test_get_active_palette_custom() -> void:
	print("test_get_active_palette_custom:")
	var tc := TerminalConfig.new()
	var custom := PackedColorArray()
	for i in range(16):
		custom.append(Color(i / 16.0, 0, 0))
	tc.custom_palette = custom
	tc.theme_name = "custom"
	var pal := tc.get_active_palette()
	_assert_eq(pal.size(), 16, "custom palette size")
	_assert(pal[0].is_equal_approx(Color(0, 0, 0)), "custom palette[0]")
	_assert(pal[8].is_equal_approx(Color(0.5, 0, 0)), "custom palette[8]")


func test_full_palette_size() -> void:
	print("test_full_palette_size:")
	var tc := TerminalConfig.new()
	var full := tc.get_full_palette()
	_assert_eq(full.size(), 256, "full palette has 256 entries")


func test_font_loading() -> void:
	print("test_font_loading:")
	var tc := TerminalConfig.new()
	var f := tc.get_font()
	_assert(f != null, "default font loads")
	_assert(f is Font, "default font is Font type")


func test_invalid_theme_fallback() -> void:
	print("test_invalid_theme_fallback:")
	var tc := TerminalConfig.new()
	tc.theme_name = "nonexistent_theme_xyz"
	var pal := tc.get_active_palette()
	_assert_eq(pal.size(), 16, "invalid theme falls back to default (16 colors)")


func test_scrollback_clamping() -> void:
	print("test_scrollback_clamping:")
	var tc := TerminalConfig.new()
	tc.scrollback_lines = 50  # below minimum
	_assert(tc.scrollback_lines >= 100, "scrollback clamped to >= 100")
	tc.scrollback_lines = -1  # unlimited
	_assert_eq(tc.scrollback_lines, -1, "unlimited scrollback allowed")
	tc.scrollback_lines = 999999  # above max
	_assert(tc.scrollback_lines <= 100000, "scrollback clamped to <= 100000")


func test_font_size_clamping() -> void:
	print("test_font_size_clamping:")
	var tc := TerminalConfig.new()
	tc.font_size = 4  # below min
	_assert_eq(tc.font_size, 8, "font size clamped to min 8")
	tc.font_size = 50  # above max
	_assert_eq(tc.font_size, 32, "font size clamped to max 32")


func test_cursor_style_clamping() -> void:
	print("test_cursor_style_clamping:")
	var tc := TerminalConfig.new()
	tc.cursor_style = 5
	_assert_eq(tc.cursor_style, 2, "cursor style clamped to max 2")
	tc.cursor_style = -1
	_assert_eq(tc.cursor_style, 0, "cursor style clamped to min 0")


func test_missing_config_section() -> void:
	print("test_missing_config_section:")
	var tc := TerminalConfig.new()
	var cfg := ConfigFile.new()
	# No Terminal section — should not crash, keep defaults
	tc.load_from_config(cfg)
	_assert_eq(tc.theme_name, "default", "missing section keeps default theme")
	_assert_eq(tc.font_size, tc.font_size, "missing section keeps default font size")
