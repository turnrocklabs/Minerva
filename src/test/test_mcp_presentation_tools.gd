extends SceneTree
## Headless integration test for MCPPresentationTools.
##
## Drives the disk-mode tool surface end-to-end to compose the "Butter Tarts"
## index scenario: brown-butter background, ivory italic title, teal HR line,
## left-col bulleted facts, right-col image (placeholder solid block — the
## HITL pass replaces it with a graphics-editor-generated butter tart).
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script test/test_mcp_presentation_tools.gd
##
## Validates output against the plugin's authoritative validate_deck().

const OUT_PATH: String = "/tmp/butter_tarts_headless.mdeck"

const COLOR_BROWNED_BUTTER: String = "#A07A4A"
const COLOR_IVORY: String = "#FAF1DD"
const COLOR_TEAL: String = "#1F4E5A"
const COLOR_BUTTER_TART_PLACEHOLDER: String = "#C19A6B"

var MCPPresentationTools_: Script = null
var SlideModel: Script = null

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	# Defer everything to first process_frame — SceneTree._init runs BEFORE
	# autoloads register, and MCPPresentationTools / MCPToolUtils transitively
	# reference SingletonObject at parse time. By process_frame, autoloads
	# have been instantiated and the identifier resolves.
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	MCPPresentationTools_ = load("res://Scripts/Services/MCP/Modules/MCPPresentationTools.gd")
	SlideModel = load(OS.get_environment("HOME").path_join("github/plugins/presentation/ui/slide_model.gd"))

	print("=== MCPPresentationTools — Butter Tarts headless test ===\n")

	# Clean any previous artifact.
	if FileAccess.file_exists(OUT_PATH):
		DirAccess.remove_absolute(OUT_PATH)

	var tools: Object = MCPPresentationTools_.new(null)

	test_create_deck(tools)
	test_set_brown_butter_background(tools)
	test_add_powerpoint_title(tools)
	test_add_teal_hr_line(tools)
	test_add_bulleted_facts(tools)
	test_add_butter_tart_placeholder(tools)
	test_list_slides_reflects_state(tools)
	test_final_deck_validates_against_plugin()
	test_solid_color_rejects_invalid_hex(tools)
	test_coords_out_of_range_rejected(tools)
	test_target_requires_path_or_tab(tools)

	print("\n=== %d passed, %d failed ===" % [_pass, _fail])
	quit(_fail)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func test_create_deck(tools: Object) -> void:
	var r: Dictionary = tools._create_deck({
		"path": OUT_PATH,
		"aspect": "16:9",
	})
	_assert(r.get("success", false) == true, "create_deck succeeds", r)
	_assert(r.get("path", "") == OUT_PATH, "create_deck returns path", r)
	_assert(FileAccess.file_exists(OUT_PATH), "create_deck wrote file to disk", {})


func test_set_brown_butter_background(tools: Object) -> void:
	var r: Dictionary = tools._set_slide_background({
		"path": OUT_PATH,
		"slide_index": 0,
		"color": COLOR_BROWNED_BUTTER,
	})
	_assert(r.get("success", false) == true, "set_slide_background (color) succeeds", r)

	var deck: Dictionary = _read_deck()
	var slide: Dictionary = (deck["slides"] as Array)[0] as Dictionary
	var bg: Dictionary = slide["background"] as Dictionary
	_assert(bg.get("kind", "") == "color", "background.kind == color", bg)
	_assert(bg.get("value", "") == COLOR_BROWNED_BUTTER, "background.value matches hex", bg)


func test_add_powerpoint_title(tools: Object) -> void:
	# PowerPoint-style title: italic, ivory on brown. Font size is derived from
	# tile.h × slide_h ÷ line_count by the plugin renderer (drag-corner-resize-
	# the-text). h=0.11 on a 720-tall slide gives a single-line ~58px font.
	# Title is left-aligned (PowerPoint-valid style) — no [center] wrapper.
	var content: String = "[i][color=%s]Butter Tarts[/color][/i]" % COLOR_IVORY
	var r: Dictionary = tools._add_text_tile({
		"path": OUT_PATH,
		"slide_index": 0,
		"x": 0.05, "y": 0.06,
		"w": 0.90, "h": 0.11,
		"content": content,
		"text_mode": "plain",
	})
	_assert(r.get("success", false) == true, "add_text_tile (title) succeeds", r)
	_assert(r.has("tile_id"), "title returns tile_id", r)

	var slide: Dictionary = (_read_deck()["slides"] as Array)[0] as Dictionary
	var tiles: Array = slide["tiles"] as Array
	_assert(tiles.size() == 1, "slide has 1 tile after title add", {"count": tiles.size()})
	var t: Dictionary = tiles[0] as Dictionary
	_assert(t.get("kind", "") == "text", "title tile.kind == text", t)
	_assert(str(t.get("content", "")).contains("Butter Tarts"), "title content contains 'Butter Tarts'", t)
	_assert(str(t.get("content", "")).contains("[i]"), "title content has italic BBCode", t)
	_assert(abs(float(t.get("h", 0.0)) - 0.11) < 0.0001, "title h=0.11 (drives font sizing)", t)


func test_add_teal_hr_line(tools: Object) -> void:
	# 2/3-width centered thin line right under the title (tile ends at 0.06+0.11=0.17).
	# x=0.165 w=0.67 → centered (0.165 + 0.67/2 = 0.5)
	var r: Dictionary = tools._add_image_tile({
		"path": OUT_PATH,
		"slide_index": 0,
		"x": 0.165, "y": 0.19,
		"w": 0.67, "h": 0.012,
		"solid_color": COLOR_TEAL,
	})
	_assert(r.get("success", false) == true, "add_image_tile (HR solid_color) succeeds", r)

	var slide: Dictionary = (_read_deck()["slides"] as Array)[0] as Dictionary
	var tiles: Array = slide["tiles"] as Array
	_assert(tiles.size() == 2, "slide has 2 tiles after HR add", {"count": tiles.size()})
	var hr: Dictionary = tiles[1] as Dictionary
	_assert(hr.get("kind", "") == "image", "HR tile.kind == image", hr)
	_assert(not String(hr.get("src", "")).is_empty(), "HR tile has non-empty src (base64)", {"len": String(hr.get("src", "")).length()})
	_assert(abs(float(hr.get("h", 0.0)) - 0.012) < 0.0001, "HR is thin (h≈0.012)", hr)


func test_add_bulleted_facts(tools: Object) -> void:
	# 4 fact lines. Body sizing rule: h ≈ line_count × 0.05. 4 × 0.05 = 0.20.
	var facts: String = "Origin: Quintessentially Canadian, dating to early 1900s.\nKey ingredients: butter, sugar, eggs, vinegar — pastry shell.\nVariations: with or without raisins, walnuts, or pecans.\nThe debate: runny vs firm filling sparks regional rivalries."
	var r: Dictionary = tools._add_text_tile({
		"path": OUT_PATH,
		"slide_index": 0,
		"x": 0.05, "y": 0.28,
		"w": 0.42, "h": 0.20,
		"content": facts,
		"text_mode": "bullet",
	})
	_assert(r.get("success", false) == true, "add_text_tile (bullet facts) succeeds", r)

	var slide: Dictionary = (_read_deck()["slides"] as Array)[0] as Dictionary
	var tiles: Array = slide["tiles"] as Array
	_assert(tiles.size() == 3, "slide has 3 tiles after facts add", {"count": tiles.size()})
	var fact_tile: Dictionary = tiles[2] as Dictionary
	_assert(fact_tile.get("text_mode", "") == "bullet", "facts tile.text_mode == bullet", fact_tile)
	_assert(str(fact_tile.get("content", "")).contains("Quintessentially"), "facts content preserved", {})


func test_add_butter_tart_placeholder(tools: Object) -> void:
	# Right column — placeholder solid block. HITL replaces with a graphics-editor
	# generated image via source_graphics_editor.
	var r: Dictionary = tools._add_image_tile({
		"path": OUT_PATH,
		"slide_index": 0,
		"x": 0.53, "y": 0.28,
		"w": 0.42, "h": 0.62,
		"solid_color": COLOR_BUTTER_TART_PLACEHOLDER,
	})
	_assert(r.get("success", false) == true, "add_image_tile (right-col placeholder) succeeds", r)

	var slide: Dictionary = (_read_deck()["slides"] as Array)[0] as Dictionary
	_assert((slide["tiles"] as Array).size() == 4, "slide has 4 tiles total", {"count": (slide["tiles"] as Array).size()})


func test_list_slides_reflects_state(tools: Object) -> void:
	var r: Dictionary = tools._list_slides({"path": OUT_PATH})
	_assert(r.get("success", false) == true, "list_slides succeeds", r)
	var slides: Array = r.get("slides", []) as Array
	_assert(slides.size() == 1, "list_slides reports 1 slide", {"count": slides.size()})
	var first: Dictionary = slides[0] as Dictionary
	_assert(int(first.get("tile_count", 0)) == 4, "list_slides reports 4 tiles on slide 0", first)
	_assert(str(r.get("aspect", "")) == "16:9", "list_slides reports aspect 16:9", r)


func test_final_deck_validates_against_plugin() -> void:
	var deck: Dictionary = _read_deck()
	var errors: Array = SlideModel.validate_deck(deck)
	_assert(errors.is_empty(), "final deck passes plugin's validate_deck()", {"errors": errors})


func test_solid_color_rejects_invalid_hex(tools: Object) -> void:
	var r: Dictionary = tools._add_image_tile({
		"path": OUT_PATH,
		"slide_index": 0,
		"x": 0.0, "y": 0.0, "w": 0.1, "h": 0.1,
		"solid_color": "not-a-hex",
	})
	_assert(r.get("success", false) == false, "invalid solid_color is rejected", r)
	_assert(str(r.get("error", "")).to_lower().contains("hex"), "error mentions hex", r)


func test_coords_out_of_range_rejected(tools: Object) -> void:
	var r: Dictionary = tools._add_text_tile({
		"path": OUT_PATH,
		"slide_index": 0,
		"x": 1.5, "y": 0.0, "w": 0.1, "h": 0.1,
		"content": "out of range",
	})
	_assert(r.get("success", false) == false, "x>1.0 is rejected", r)
	_assert(str(r.get("error", "")).to_lower().contains("[0, 1]"), "error mentions [0, 1] range", r)


func test_target_requires_path_or_tab(tools: Object) -> void:
	var r: Dictionary = tools._add_text_tile({
		"slide_index": 0,
		"x": 0.1, "y": 0.1, "w": 0.1, "h": 0.1,
		"content": "no target",
	})
	_assert(r.get("success", false) == false, "missing target rejected", r)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _read_deck() -> Dictionary:
	var f: FileAccess = FileAccess.open(OUT_PATH, FileAccess.READ)
	if f == null:
		return {}
	var text: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _assert(cond: bool, msg: String, ctx: Variant = null) -> void:
	if cond:
		_pass += 1
		print("  PASS  %s" % msg)
	else:
		_fail += 1
		print("  FAIL  %s | ctx=%s" % [msg, str(ctx)])
