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
	test_list_tiles_returns_4_with_kinds(tools)
	test_list_annotations_empty(tools)
	test_get_tile_round_trips(tools)
	test_get_tile_excludes_image_src_by_default(tools)
	test_get_tile_includes_image_src_when_requested(tools)
	test_get_slide_returns_full_slide(tools)
	test_inspect_unknown_tile_id_errors(tools)
	test_inspect_slide_index_out_of_range(tools)
	test_final_deck_validates_against_plugin()
	test_solid_color_rejects_invalid_hex(tools)
	test_coords_out_of_range_rejected(tools)
	test_target_requires_path_or_tab(tools)
	# Modify tools — these MUTATE the test deck, so they run after all the
	# read-only / fresh-compose assertions above.
	test_modify_tile_coords(tools)
	test_modify_tile_text_content(tools)
	test_modify_tile_rejects_text_field_on_image_tile(tools)
	test_modify_tile_image_solid_color(tools)
	test_modify_tile_rejects_two_image_sources(tools)
	test_modify_tile_rotation_round_trip(tools)
	test_modify_tile_unknown_id(tools)
	test_set_slide_title(tools)
	test_set_aspect(tools)
	test_set_aspect_rejects_invalid(tools)
	test_move_slide(tools)
	test_move_slide_out_of_range(tools)
	# Remove tools — order matters: succeeds_with_multiple must run before
	# refuses_last (succeeds_with_multiple drops the deck back to 1 slide).
	test_remove_tile(tools)
	test_remove_tile_unknown_id(tools)
	test_remove_slide_succeeds_with_multiple(tools)
	test_remove_slide_refuses_last(tools)
	test_list_annotations_derives_resolved_from_lifecycle(tools)
	# Annotation tools — exercise add/remove/set_resolved + list_kinds + list_open.
	test_list_annotation_kinds(tools)
	test_add_annotation_basic(tools)
	test_add_annotation_rejects_unknown_kind(tools)
	test_add_annotation_text_payload_mirrored(tools)
	test_add_annotation_with_explicit_anchor_validates(tools)
	test_set_annotation_resolved_via_bool(tools)
	test_set_annotation_resolved_via_lifecycle(tools)
	test_set_annotation_resolved_with_note(tools)
	test_list_open_annotations_excludes_resolved(tools)
	test_remove_annotation(tools)
	test_remove_annotation_clears_empty_array(tools)
	# Spreadsheet tools — exercise add/modify/resize end-to-end on disk.
	test_add_spreadsheet_tile_default_grid(tools)
	test_add_spreadsheet_tile_with_cells(tools)
	test_add_spreadsheet_rejects_mismatched_grid(tools)
	test_modify_spreadsheet_cells_round_trip(tools)
	test_modify_spreadsheet_cells_skips_oob(tools)
	test_modify_spreadsheet_rejects_non_spreadsheet_tile(tools)
	test_resize_spreadsheet_grow_preserves(tools)
	test_resize_spreadsheet_shrink_truncates(tools)
	test_post_modify_deck_still_validates()

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


func test_list_tiles_returns_4_with_kinds(tools: Object) -> void:
	var r: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	_assert(r.get("success", false) == true, "list_tiles succeeds", r)
	_assert(int(r.get("slide_index", -1)) == 0, "list_tiles echoes slide_index", r)
	var tiles: Array = r.get("tiles", []) as Array
	_assert(tiles.size() == 4, "list_tiles returns 4 entries", {"count": tiles.size()})

	# Kind sequence per the compose order above.
	var kinds: Array = []
	for t in tiles:
		kinds.append(str((t as Dictionary).get("kind", "")))
	_assert(kinds == ["text", "image", "text", "image"], "list_tiles kinds in compose order", {"kinds": kinds})

	# Title (tile 0): text content present, not truncated, no image bytes leaking.
	var title: Dictionary = tiles[0] as Dictionary
	_assert(title.has("tile_id") and not str(title["tile_id"]).is_empty(), "title summary has tile_id", title)
	_assert(title.has("content") and str(title["content"]).contains("Butter Tarts"), "title summary preserves content", title)
	_assert(not title.has("_truncated"), "title content not truncated", title)
	_assert(str(title.get("text_mode", "")) == "plain", "title text_mode == plain", title)

	# HR (tile 1): image — must NOT inline base64; must report src_size_bytes > 0.
	var hr: Dictionary = tiles[1] as Dictionary
	_assert(not hr.has("src"), "HR summary omits src", hr)
	_assert(int(hr.get("src_size_bytes", 0)) > 0, "HR summary reports non-zero src_size_bytes", hr)

	# Bullet facts (tile 2): text_mode == bullet, content preserved.
	var facts: Dictionary = tiles[2] as Dictionary
	_assert(str(facts.get("text_mode", "")) == "bullet", "facts text_mode == bullet", facts)
	_assert(str(facts.get("content", "")).contains("Quintessentially"), "facts content preserved", facts)


func test_list_annotations_empty(tools: Object) -> void:
	# v1 compose path doesn't add annotations — expect empty list.
	var r: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	_assert(r.get("success", false) == true, "list_annotations succeeds", r)
	_assert((r.get("annotations", []) as Array).is_empty(), "annotations array is empty for fresh slide", r)


func test_get_tile_round_trips(tools: Object) -> void:
	# Pull tile 0's id from list_tiles, then fetch its full dict.
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var tile_id: String = str(((lr["tiles"] as Array)[0] as Dictionary)["tile_id"])

	var r: Dictionary = tools._get_tile({"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id})
	_assert(r.get("success", false) == true, "get_tile succeeds", r)
	var tile: Dictionary = r.get("tile", {}) as Dictionary
	_assert(str(tile.get("id", "")) == tile_id, "get_tile returns matching id", tile)
	_assert(str(tile.get("kind", "")) == "text", "get_tile preserves kind", tile)
	_assert(str(tile.get("content", "")).contains("Butter Tarts"), "get_tile preserves content", tile)
	_assert(abs(float(tile.get("h", 0.0)) - 0.11) < 0.0001, "get_tile preserves h", tile)


func test_get_tile_excludes_image_src_by_default(tools: Object) -> void:
	# Tile 1 (HR) is an image tile.
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var tile_id: String = str(((lr["tiles"] as Array)[1] as Dictionary)["tile_id"])

	var r: Dictionary = tools._get_tile({"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id})
	_assert(r.get("success", false) == true, "get_tile (image) succeeds", r)
	var tile: Dictionary = r.get("tile", {}) as Dictionary
	_assert(str(tile.get("kind", "")) == "image", "get_tile returns image kind", tile)
	_assert(not tile.has("src"), "default get_tile omits image src", tile)
	_assert(int(tile.get("src_size_bytes", 0)) > 0, "get_tile reports src_size_bytes for image", tile)


func test_get_tile_includes_image_src_when_requested(tools: Object) -> void:
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var tile_id: String = str(((lr["tiles"] as Array)[1] as Dictionary)["tile_id"])

	var r: Dictionary = tools._get_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id, "include_src": true
	})
	_assert(r.get("success", false) == true, "get_tile with include_src succeeds", r)
	var tile: Dictionary = r.get("tile", {}) as Dictionary
	_assert(str(tile.get("src", "")).length() > 0, "get_tile with include_src returns base64", {"len": str(tile.get("src", "")).length()})


func test_get_slide_returns_full_slide(tools: Object) -> void:
	var r: Dictionary = tools._get_slide({"path": OUT_PATH, "slide_index": 0})
	_assert(r.get("success", false) == true, "get_slide succeeds", r)
	var slide: Dictionary = r.get("slide", {}) as Dictionary
	_assert(slide.has("id") and not str(slide["id"]).is_empty(), "get_slide preserves id", slide)
	_assert(slide.has("background"), "get_slide preserves background", {})
	var bg: Dictionary = slide["background"] as Dictionary
	_assert(str(bg.get("value", "")) == COLOR_BROWNED_BUTTER, "get_slide background color preserved", bg)
	var slide_tiles: Array = slide.get("tiles", []) as Array
	_assert(slide_tiles.size() == 4, "get_slide returns all 4 tiles", {"count": slide_tiles.size()})

	# Image tiles must have src omitted by default but report src_size_bytes.
	for t_v in slide_tiles:
		var t: Dictionary = t_v as Dictionary
		if str(t.get("kind", "")) == "image":
			_assert(not t.has("src"), "get_slide default omits image src", t)
			_assert(int(t.get("src_size_bytes", 0)) > 0, "get_slide reports src_size_bytes", t)


func test_inspect_unknown_tile_id_errors(tools: Object) -> void:
	var r: Dictionary = tools._get_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": "tile_does_not_exist"
	})
	_assert(r.get("success", false) == false, "get_tile with unknown id errors", r)
	_assert(str(r.get("error", "")).to_lower().contains("not found"), "error mentions 'not found'", r)


func test_inspect_slide_index_out_of_range(tools: Object) -> void:
	var r: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 99})
	_assert(r.get("success", false) == false, "list_tiles slide_index OOR errors", r)
	_assert(str(r.get("error", "")).to_lower().contains("out of range"), "error mentions 'out of range'", r)


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
# Modify-tool tests (mutate the deck — run after all read-only assertions)
# ---------------------------------------------------------------------------

func test_modify_tile_coords(tools: Object) -> void:
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var t0: Dictionary = (lr["tiles"] as Array)[0] as Dictionary
	var tile_id: String = str(t0["tile_id"])
	var orig_x: float = float(t0["x"])
	var new_x: float = orig_x + 0.1

	var r: Dictionary = tools._modify_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id, "x": new_x
	})
	_assert(r.get("success", false) == true, "modify_tile (x) succeeds", r)

	var gr: Dictionary = tools._get_tile({"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id})
	var tile: Dictionary = gr["tile"] as Dictionary
	_assert(abs(float(tile["x"]) - new_x) < 0.0001, "modified x persists on disk", tile)


func test_modify_tile_text_content(tools: Object) -> void:
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var tile_id: String = str(((lr["tiles"] as Array)[0] as Dictionary)["tile_id"])
	var new_content: String = "Renamed Title"

	var r: Dictionary = tools._modify_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id, "content": new_content
	})
	_assert(r.get("success", false) == true, "modify_tile (content) succeeds", r)

	var gr: Dictionary = tools._get_tile({"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id})
	_assert(str((gr["tile"] as Dictionary)["content"]) == new_content, "modified content persists", gr)


func test_modify_tile_rejects_text_field_on_image_tile(tools: Object) -> void:
	# Tile 1 (HR) is an image tile.
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var hr_id: String = str(((lr["tiles"] as Array)[1] as Dictionary)["tile_id"])
	var r: Dictionary = tools._modify_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": hr_id, "content": "nope"
	})
	_assert(r.get("success", false) == false, "modify_tile rejects content on image tile", r)


func test_modify_tile_image_solid_color(tools: Object) -> void:
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var hr_id: String = str(((lr["tiles"] as Array)[1] as Dictionary)["tile_id"])
	var r: Dictionary = tools._modify_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": hr_id, "solid_color": "#ff0000"
	})
	_assert(r.get("success", false) == true, "modify_tile (solid_color) succeeds", r)

	var gr: Dictionary = tools._get_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": hr_id, "include_src": true
	})
	_assert(str((gr["tile"] as Dictionary).get("src", "")).length() > 0, "new src is non-empty", {})


func test_modify_tile_rejects_two_image_sources(tools: Object) -> void:
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var hr_id: String = str(((lr["tiles"] as Array)[1] as Dictionary)["tile_id"])
	var r: Dictionary = tools._modify_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": hr_id,
		"solid_color": "#ff0000", "image_base64": "AAAA"
	})
	_assert(r.get("success", false) == false, "modify_tile rejects 2 image sources", r)


func test_modify_tile_rotation_round_trip(tools: Object) -> void:
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var tile_id: String = str(((lr["tiles"] as Array)[0] as Dictionary)["tile_id"])

	# Set rotation.
	var r1: Dictionary = tools._modify_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id, "rotation": 0.25
	})
	_assert(r1.get("success", false) == true, "modify_tile set rotation succeeds", r1)
	var g1: Dictionary = tools._get_tile({"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id})
	_assert(abs(float((g1["tile"] as Dictionary).get("rotation", 0.0)) - 0.25) < 0.0001, "rotation set", g1)

	# Clear rotation (set to 0 erases the field per omit-when-default).
	var r2: Dictionary = tools._modify_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id, "rotation": 0.0
	})
	_assert(r2.get("success", false) == true, "modify_tile clear rotation succeeds", r2)
	var g2: Dictionary = tools._get_tile({"path": OUT_PATH, "slide_index": 0, "tile_id": tile_id})
	_assert(not (g2["tile"] as Dictionary).has("rotation"), "rotation 0 erases field", g2)


func test_modify_tile_unknown_id(tools: Object) -> void:
	var r: Dictionary = tools._modify_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": "tile_does_not_exist", "x": 0.5
	})
	_assert(r.get("success", false) == false, "modify_tile unknown id errors", r)
	_assert(str(r.get("error", "")).to_lower().contains("not found"), "error mentions 'not found'", r)


func test_set_slide_title(tools: Object) -> void:
	var r1: Dictionary = tools._set_slide_title({
		"path": OUT_PATH, "slide_index": 0, "title": "Butter Tarts (renamed)"
	})
	_assert(r1.get("success", false) == true, "set_slide_title set succeeds", r1)
	var ls1: Dictionary = tools._list_slides({"path": OUT_PATH})
	var s1: Dictionary = (ls1["slides"] as Array)[0] as Dictionary
	_assert(str(s1.get("title", "")) == "Butter Tarts (renamed)", "title persists", s1)

	# Empty string clears (omit-when-default).
	var r2: Dictionary = tools._set_slide_title({"path": OUT_PATH, "slide_index": 0, "title": ""})
	_assert(r2.get("success", false) == true, "set_slide_title clear succeeds", r2)
	var ls2: Dictionary = tools._list_slides({"path": OUT_PATH})
	var s2: Dictionary = (ls2["slides"] as Array)[0] as Dictionary
	_assert(not s2.has("title"), "empty title removes field", s2)


func test_set_aspect(tools: Object) -> void:
	var r: Dictionary = tools._set_aspect({"path": OUT_PATH, "aspect": "4:3"})
	_assert(r.get("success", false) == true, "set_aspect succeeds", r)
	var ls: Dictionary = tools._list_slides({"path": OUT_PATH})
	_assert(str(ls.get("aspect", "")) == "4:3", "aspect persists on disk", ls)
	# Restore for downstream tests.
	tools._set_aspect({"path": OUT_PATH, "aspect": "16:9"})


func test_set_aspect_rejects_invalid(tools: Object) -> void:
	var r: Dictionary = tools._set_aspect({"path": OUT_PATH, "aspect": "21:9"})
	_assert(r.get("success", false) == false, "set_aspect rejects invalid value", r)


func test_move_slide(tools: Object) -> void:
	# Add a second slide so we have something to reorder.
	tools._add_slide({"path": OUT_PATH, "title": "Second slide"})
	var deck_before: Dictionary = _read_deck()
	var id0: String = str(((deck_before["slides"] as Array)[0] as Dictionary)["id"])
	var id1: String = str(((deck_before["slides"] as Array)[1] as Dictionary)["id"])

	var r: Dictionary = tools._move_slide({"path": OUT_PATH, "from_index": 0, "to_index": 1})
	_assert(r.get("success", false) == true, "move_slide succeeds", r)

	var deck_after: Dictionary = _read_deck()
	_assert(str(((deck_after["slides"] as Array)[0] as Dictionary)["id"]) == id1, "slide1 now first", {})
	_assert(str(((deck_after["slides"] as Array)[1] as Dictionary)["id"]) == id0, "slide0 now second", {})

	# Restore order so post-modify validate sees the original index ordering.
	tools._move_slide({"path": OUT_PATH, "from_index": 1, "to_index": 0})


func test_move_slide_out_of_range(tools: Object) -> void:
	var r: Dictionary = tools._move_slide({"path": OUT_PATH, "from_index": 99, "to_index": 0})
	_assert(r.get("success", false) == false, "move_slide OOR from_index errors", r)


func test_remove_tile(tools: Object) -> void:
	# Use whichever tile is at index 3 (the right-col placeholder).
	var lr: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	var tiles_before: Array = lr["tiles"] as Array
	var before_count: int = tiles_before.size()
	_assert(before_count >= 4, "deck has >= 4 tiles before remove_tile", {"count": before_count})
	var victim_id: String = str((tiles_before[before_count - 1] as Dictionary)["tile_id"])

	var r: Dictionary = tools._remove_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": victim_id
	})
	_assert(r.get("success", false) == true, "remove_tile succeeds", r)
	_assert(int(r.get("removed_at", -1)) == before_count - 1, "removed_at returns old index", r)

	var lr2: Dictionary = tools._list_tiles({"path": OUT_PATH, "slide_index": 0})
	_assert((lr2["tiles"] as Array).size() == before_count - 1, "tile count drops by 1", lr2)
	# Removed id no longer present.
	for t_v in (lr2["tiles"] as Array):
		_assert(str((t_v as Dictionary)["tile_id"]) != victim_id, "removed id absent", t_v)


func test_remove_tile_unknown_id(tools: Object) -> void:
	var r: Dictionary = tools._remove_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": "tile_does_not_exist"
	})
	_assert(r.get("success", false) == false, "remove_tile unknown id errors", r)
	_assert(str(r.get("error", "")).to_lower().contains("not found"), "error mentions 'not found'", r)


func test_remove_slide_succeeds_with_multiple(tools: Object) -> void:
	# Pre-seed: ensure the deck has exactly 2 slides regardless of upstream
	# state — earlier tests (move_slide) may have left a second slide present.
	var deck_before: Dictionary = _read_deck()
	var slides_before: Array = deck_before["slides"] as Array
	while slides_before.size() < 2:
		tools._add_slide({"path": OUT_PATH, "title": "Pad"})
		deck_before = _read_deck()
		slides_before = deck_before["slides"] as Array
	# Remove every slide after index 1 directly so we always start at exactly 2.
	# We don't have a wholesale-truncate tool yet, so loop remove_slide on the tail.
	while slides_before.size() > 2:
		tools._remove_slide({"path": OUT_PATH, "slide_index": slides_before.size() - 1})
		deck_before = _read_deck()
		slides_before = deck_before["slides"] as Array

	var first_id: String = str((slides_before[0] as Dictionary)["id"])
	var r: Dictionary = tools._remove_slide({"path": OUT_PATH, "slide_index": 0})
	_assert(r.get("success", false) == true, "remove_slide (with >=2) succeeds", r)
	_assert(str(r.get("slide_id", "")) == first_id, "removed id matches first slide id", r)

	var ls: Dictionary = tools._list_slides({"path": OUT_PATH})
	_assert((ls["slides"] as Array).size() == 1, "post-remove: 1 slide", ls)
	_assert(str(((ls["slides"] as Array)[0] as Dictionary).get("id", "")) != first_id, "original first slide is gone", ls)


func test_remove_slide_refuses_last(tools: Object) -> void:
	# Precondition: succeeds_with_multiple ran first and dropped to 1 slide.
	var ls: Dictionary = tools._list_slides({"path": OUT_PATH})
	_assert((ls["slides"] as Array).size() == 1, "precondition: 1 slide", ls)
	var r: Dictionary = tools._remove_slide({"path": OUT_PATH, "slide_index": 0})
	_assert(r.get("success", false) == false, "remove_slide refuses last slide", r)
	_assert(str(r.get("error", "")).to_lower().contains("only slide"), "error mentions 'only slide'", r)


func test_list_annotations_derives_resolved_from_lifecycle(tools: Object) -> void:
	# Inject 3 synthetic envelopes directly into slide.annotations[] (the
	# add_annotation MCP tool ships in work_item #6). One open, one resolved,
	# one without lifecycle — list_annotations should derive resolved from
	# lifecycle=="resolved" and surface lifecycle verbatim when present.
	var deck: Dictionary = _read_deck()
	var slide: Dictionary = (deck["slides"] as Array)[0] as Dictionary
	slide["annotations"] = [
		{"id": "ann_open_1", "kind": "text_2d", "lifecycle": "open", "summary": "fix the title size"},
		{"id": "ann_resolved_1", "kind": "callout", "lifecycle": "resolved", "summary": "good now"},
		{"id": "ann_legacy_1", "kind": "text_2d", "summary": "no lifecycle field"},
	]
	# Write back to disk and re-list.
	var f: FileAccess = FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(deck, "  "))
	f.close()

	var r: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	_assert(r.get("success", false) == true, "list_annotations succeeds with envelopes", r)
	var anns: Array = r.get("annotations", []) as Array
	_assert(anns.size() == 3, "list_annotations returns all 3 envelopes", {"count": anns.size()})

	# Map by id for clarity.
	var by_id: Dictionary = {}
	for a in anns:
		by_id[str((a as Dictionary)["annotation_id"])] = a as Dictionary

	var open_a: Dictionary = by_id["ann_open_1"] as Dictionary
	_assert(str(open_a.get("lifecycle", "")) == "open", "open envelope reports lifecycle=open", open_a)
	_assert(bool(open_a.get("resolved", true)) == false, "open envelope: resolved=false", open_a)

	var resolved_a: Dictionary = by_id["ann_resolved_1"] as Dictionary
	_assert(str(resolved_a.get("lifecycle", "")) == "resolved", "resolved envelope reports lifecycle=resolved", resolved_a)
	_assert(bool(resolved_a.get("resolved", false)) == true, "resolved envelope: resolved=true", resolved_a)

	var legacy_a: Dictionary = by_id["ann_legacy_1"] as Dictionary
	_assert(not legacy_a.has("lifecycle"), "legacy envelope omits lifecycle in summary", legacy_a)
	_assert(bool(legacy_a.get("resolved", true)) == false, "legacy envelope (no lifecycle): resolved=false", legacy_a)

	# Payload summary derived from `summary` field.
	_assert(str(open_a.get("payload_summary", "")) == "fix the title size", "open envelope payload_summary preserved", open_a)


func test_list_annotation_kinds(tools: Object) -> void:
	var r: Dictionary = tools._list_annotation_kinds({})
	_assert(r.get("success", false) == true, "list_annotation_kinds succeeds", r)
	var kinds: Array = r.get("kinds", []) as Array
	# Presentation host accepts ["callout", "2d_arrow", "2d_text"].
	_assert(kinds.size() >= 3, "list_annotation_kinds returns >= 3 kinds", {"count": kinds.size()})
	var names: Array = []
	for k in kinds:
		names.append(str((k as Dictionary).get("kind", "")))
	_assert(names.has("callout"), "kinds include callout", {"names": names})
	_assert(names.has("2d_text"), "kinds include 2d_text", {"names": names})
	_assert(names.has("2d_arrow"), "kinds include 2d_arrow", {"names": names})
	# Lifecycle states surfaced.
	var states: Array = r.get("lifecycle_states", []) as Array
	_assert(states.has("open") and states.has("resolved"), "lifecycle_states include open + resolved", states)


func test_add_annotation_basic(tools: Object) -> void:
	# Reset slide.annotations[] first — the lifecycle test left synthetic envelopes.
	var deck: Dictionary = _read_deck()
	var slide: Dictionary = (deck["slides"] as Array)[0] as Dictionary
	slide.erase("annotations")
	var f: FileAccess = FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(deck, "  "))
	f.close()

	# 2d_text uses anchor compat "core/*"; default anchor synthesized with plugin="core".
	var r: Dictionary = tools._add_annotation({
		"path": OUT_PATH, "slide_index": 0,
		"kind": "2d_text",
		"summary": "make the title bigger",
	})
	_assert(r.get("success", false) == true, "add_annotation (2d_text) succeeds", r)
	_assert(not str(r.get("annotation_id", "")).is_empty(), "add_annotation returns annotation_id", r)

	# Read back via list_annotations and verify shape.
	var lr: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	var anns: Array = lr.get("annotations", []) as Array
	_assert(anns.size() == 1, "1 annotation present after add", {"count": anns.size()})
	var ann: Dictionary = anns[0] as Dictionary
	_assert(str(ann.get("kind", "")) == "2d_text", "annotation kind preserved", ann)
	_assert(str(ann.get("lifecycle", "")) == "open", "default lifecycle is open", ann)
	_assert(bool(ann.get("resolved", true)) == false, "default resolved=false", ann)
	_assert(str(ann.get("payload_summary", "")) == "make the title bigger", "summary surfaces as payload_summary", ann)

	# Substrate schema validation: round-trip through AnnotationV2Schema.
	# This is the test hook the cold reviewer recommended — without it, bad
	# envelope shape would only be caught at next read, not during authoring.
	var deck_after: Dictionary = _read_deck()
	var slide_after: Dictionary = (deck_after["slides"] as Array)[0] as Dictionary
	var raw_envelope: Dictionary = ((slide_after["annotations"] as Array)[0] as Dictionary)
	var SchemaScript: Script = load("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
	var schema = SchemaScript.new()
	var v_result = schema.validate(raw_envelope)
	_assert(not v_result.has_errors(), "envelope passes AnnotationV2Schema.validate()", {"errors": v_result.to_error_dicts()})


func test_add_annotation_rejects_unknown_kind(tools: Object) -> void:
	var r: Dictionary = tools._add_annotation({
		"path": OUT_PATH, "slide_index": 0,
		"kind": "bogus_kind",
		"summary": "won't land",
	})
	_assert(r.get("success", false) == false, "add_annotation rejects unknown kind", r)


func test_add_annotation_text_payload_mirrored(tools: Object) -> void:
	# When caller doesn't pass kind_payload, summary should be mirrored into
	# kind_payload.text for text-bearing kinds (callout, text_2d).
	var deck_before: Dictionary = _read_deck()
	var pre_count: int = ((deck_before["slides"] as Array)[0] as Dictionary).get("annotations", []).size()

	var r: Dictionary = tools._add_annotation({
		"path": OUT_PATH, "slide_index": 0,
		"kind": "callout",
		"summary": "fix this",
	})
	_assert(r.get("success", false) == true, "add_annotation (callout) succeeds", r)

	var deck_after: Dictionary = _read_deck()
	var anns: Array = ((deck_after["slides"] as Array)[0] as Dictionary).get("annotations", []) as Array
	_assert(anns.size() == pre_count + 1, "annotations count grew by 1", {"before": pre_count, "after": anns.size()})
	var newest: Dictionary = anns[anns.size() - 1] as Dictionary
	var payload: Dictionary = newest.get("kind_payload", {}) as Dictionary
	_assert(str(payload.get("text", "")) == "fix this", "summary mirrored into kind_payload.text", payload)


func test_add_annotation_with_explicit_anchor_validates(tools: Object) -> void:
	# Caller-supplied anchor wins. Pass a custom anchor for a callout (compat */*).
	var r: Dictionary = tools._add_annotation({
		"path": OUT_PATH, "slide_index": 0,
		"kind": "callout",
		"summary": "anchored to a specific point",
		"anchor": {
			"plugin": "presentation",
			"type": "tile",
			"id": "tile_made_up",
			"snapshot": {"position": [0.25, 0.75]},
		},
	})
	_assert(r.get("success", false) == true, "add_annotation with explicit anchor succeeds", r)

	# Round-trip envelope through schema validator.
	var deck: Dictionary = _read_deck()
	var anns: Array = ((deck["slides"] as Array)[0] as Dictionary).get("annotations", []) as Array
	var newest: Dictionary = anns[anns.size() - 1] as Dictionary
	var SchemaScript: Script = load("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
	var schema = SchemaScript.new()
	var v_result = schema.validate(newest)
	_assert(not v_result.has_errors(), "explicit-anchor envelope passes AnnotationV2Schema", {"errors": v_result.to_error_dicts()})


func test_set_annotation_resolved_via_bool(tools: Object) -> void:
	# Use the first annotation we added. Pull its id from list_annotations.
	var lr: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	var ann_id: String = str(((lr["annotations"] as Array)[0] as Dictionary)["annotation_id"])

	var r: Dictionary = tools._set_annotation_resolved({
		"path": OUT_PATH, "slide_index": 0,
		"annotation_id": ann_id, "resolved": true,
	})
	_assert(r.get("success", false) == true, "set_annotation_resolved (true) succeeds", r)
	_assert(str(r.get("lifecycle", "")) == "resolved", "lifecycle becomes 'resolved'", r)

	# Confirm via list_annotations.
	var lr2: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	for a in (lr2["annotations"] as Array):
		if str((a as Dictionary)["annotation_id"]) == ann_id:
			_assert(bool((a as Dictionary).get("resolved", false)) == true, "list_annotations sees resolved=true", a)


func test_set_annotation_resolved_via_lifecycle(tools: Object) -> void:
	var lr: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	var ann_id: String = str(((lr["annotations"] as Array)[0] as Dictionary)["annotation_id"])

	var r: Dictionary = tools._set_annotation_resolved({
		"path": OUT_PATH, "slide_index": 0,
		"annotation_id": ann_id, "lifecycle": "applied",
	})
	_assert(r.get("success", false) == true, "set_annotation_resolved (lifecycle=applied) succeeds", r)
	_assert(str(r.get("lifecycle", "")) == "applied", "lifecycle becomes 'applied'", r)

	# 'applied' should not register as resolved=true (only "resolved" does).
	var lr2: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	for a in (lr2["annotations"] as Array):
		if str((a as Dictionary)["annotation_id"]) == ann_id:
			_assert(bool((a as Dictionary).get("resolved", true)) == false, "applied is NOT resolved=true", a)
			_assert(str((a as Dictionary).get("lifecycle", "")) == "applied", "lifecycle field surfaces 'applied'", a)


func test_set_annotation_resolved_with_note(tools: Object) -> void:
	var lr: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	var ann_id: String = str(((lr["annotations"] as Array)[0] as Dictionary)["annotation_id"])

	var r: Dictionary = tools._set_annotation_resolved({
		"path": OUT_PATH, "slide_index": 0,
		"annotation_id": ann_id, "resolved": true, "note": "increased title h to 0.14",
	})
	_assert(r.get("success", false) == true, "set_annotation_resolved with note succeeds", r)

	# Verify resolution_notes appended on disk.
	var deck: Dictionary = _read_deck()
	var anns: Array = ((deck["slides"] as Array)[0] as Dictionary).get("annotations", []) as Array
	for a_v in anns:
		var env: Dictionary = a_v as Dictionary
		if str(env.get("id", "")) == ann_id:
			var notes: Array = env.get("resolution_notes", []) as Array
			_assert(notes.size() >= 1, "resolution_notes appended", env)
			var first_note: Dictionary = notes[notes.size() - 1] as Dictionary
			_assert(str(first_note.get("note", "")) == "increased title h to 0.14", "note text preserved", first_note)


func test_list_open_annotations_excludes_resolved(tools: Object) -> void:
	# At this point: at least one resolved + the unresolved callout.
	var r: Dictionary = tools._list_open_annotations({"path": OUT_PATH})
	_assert(r.get("success", false) == true, "list_open_annotations succeeds", r)
	var open_list: Array = r.get("open", []) as Array
	# The "fix this" callout (added in test_add_annotation_text_payload_mirrored)
	# is still lifecycle=open. The first one we resolved must NOT appear here.
	var summaries: Array = []
	for o in open_list:
		summaries.append(str((o as Dictionary).get("summary", "")))
	_assert(summaries.has("fix this"), "open list includes the unresolved callout", summaries)
	# The "make the title bigger" was set to lifecycle=applied (not resolved/open).
	# applied != open, so it should NOT be in the open list either.
	_assert(not summaries.has("make the title bigger"), "open list excludes non-open annotations", summaries)


func test_remove_annotation(tools: Object) -> void:
	# Remove the open callout. After this only the applied annotation remains.
	var lr: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	var anns: Array = lr["annotations"] as Array
	var victim_id: String = ""
	for a in anns:
		if str((a as Dictionary).get("payload_summary", "")) == "fix this":
			victim_id = str((a as Dictionary)["annotation_id"])
			break
	_assert(not victim_id.is_empty(), "found 'fix this' annotation to remove", lr)

	var r: Dictionary = tools._remove_annotation({
		"path": OUT_PATH, "slide_index": 0, "annotation_id": victim_id,
	})
	_assert(r.get("success", false) == true, "remove_annotation succeeds", r)

	var lr2: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	for a in (lr2["annotations"] as Array):
		_assert(str((a as Dictionary)["annotation_id"]) != victim_id, "removed id absent from list", a)


func test_remove_annotation_clears_empty_array(tools: Object) -> void:
	# Remove the remaining annotation and confirm slide.annotations key is removed.
	var lr: Dictionary = tools._list_annotations({"path": OUT_PATH, "slide_index": 0})
	var anns: Array = lr["annotations"] as Array
	for a in anns:
		var ann_id: String = str((a as Dictionary)["annotation_id"])
		tools._remove_annotation({
			"path": OUT_PATH, "slide_index": 0, "annotation_id": ann_id,
		})

	var deck: Dictionary = _read_deck()
	var slide: Dictionary = (deck["slides"] as Array)[0] as Dictionary
	_assert(not slide.has("annotations"), "annotations key removed when array empties", slide)


func test_add_spreadsheet_tile_default_grid(tools: Object) -> void:
	var r: Dictionary = tools._add_spreadsheet_tile({
		"path": OUT_PATH, "slide_index": 0,
		"x": 0.05, "y": 0.05, "w": 0.3, "h": 0.2,
		"rows": 3, "cols": 4,
	})
	_assert(r.get("success", false) == true, "add_spreadsheet_tile (default grid) succeeds", r)
	_assert(not str(r.get("tile_id", "")).is_empty(), "returns tile_id", r)
	# Verify shape on disk.
	var deck: Dictionary = _read_deck()
	var tiles: Array = ((deck["slides"] as Array)[0] as Dictionary).get("tiles", []) as Array
	var ss: Dictionary = tiles[tiles.size() - 1] as Dictionary
	_assert(str(ss.get("kind", "")) == "spreadsheet", "tile kind == spreadsheet", ss)
	_assert(int(ss.get("rows", 0)) == 3 and int(ss.get("cols", 0)) == 4, "rows/cols persist", ss)
	var grid: Array = ss.get("cells", []) as Array
	_assert(grid.size() == 3, "grid has 3 rows", {"size": grid.size()})
	_assert((grid[0] as Array).size() == 4, "row 0 has 4 cols", {})


func test_add_spreadsheet_tile_with_cells(tools: Object) -> void:
	var r: Dictionary = tools._add_spreadsheet_tile({
		"path": OUT_PATH, "slide_index": 0,
		"x": 0.5, "y": 0.5, "w": 0.4, "h": 0.2,
		"rows": 2, "cols": 2,
		"header_row": true,
		"cells": [
			[{"value": "Name"}, {"value": "Score"}],
			[{"value": "Alice"}, {"value": 42}],
		],
	})
	_assert(r.get("success", false) == true, "add_spreadsheet_tile (with cells) succeeds", r)
	var deck: Dictionary = _read_deck()
	var tiles: Array = ((deck["slides"] as Array)[0] as Dictionary).get("tiles", []) as Array
	var ss: Dictionary = tiles[tiles.size() - 1] as Dictionary
	_assert(bool(ss.get("header_row", false)) == true, "header_row flag preserved", ss)
	var grid: Array = ss["cells"] as Array
	# Auto-typing: "Name" → text(1), 42 → number(2)
	_assert(int((grid[0] as Array)[0]["type"]) == 1, "string auto-types to text(1)", grid[0])
	_assert(int((grid[1] as Array)[1]["type"]) == 2, "number auto-types to number(2)", grid[1])


func test_add_spreadsheet_rejects_mismatched_grid(tools: Object) -> void:
	var r: Dictionary = tools._add_spreadsheet_tile({
		"path": OUT_PATH, "slide_index": 0,
		"x": 0.0, "y": 0.0, "w": 0.1, "h": 0.1,
		"rows": 2, "cols": 2,
		"cells": [
			[{"value": "A"}, {"value": "B"}],
			# Missing second row.
		],
	})
	_assert(r.get("success", false) == false, "mismatched grid rejected", r)
	_assert(str(r.get("error", "")).to_lower().contains("row count"), "error mentions row count", r)


func test_modify_spreadsheet_cells_round_trip(tools: Object) -> void:
	# Use the spreadsheet from test_add_spreadsheet_tile_with_cells (has data).
	var deck: Dictionary = _read_deck()
	var tiles: Array = ((deck["slides"] as Array)[0] as Dictionary).get("tiles", []) as Array
	var ss_id: String = ""
	for t in tiles:
		var t_d: Dictionary = t as Dictionary
		if str(t_d.get("kind", "")) == "spreadsheet" and int(t_d.get("rows", 0)) == 2:
			ss_id = str(t_d["id"])
			break
	_assert(not ss_id.is_empty(), "located 2x2 spreadsheet tile", {})

	var r: Dictionary = tools._modify_spreadsheet_cells({
		"path": OUT_PATH, "slide_index": 0, "tile_id": ss_id,
		"cells": [
			{"row": 1, "col": 1, "value": 99, "bold": true},
			{"row": 0, "col": 0, "value": "Renamed"},
		],
	})
	_assert(r.get("success", false) == true, "modify_spreadsheet_cells succeeds", r)
	_assert(int(r.get("cells_updated", 0)) == 2, "2 cells updated", r)
	_assert((r.get("skipped", []) as Array).is_empty(), "no cells skipped", r)

	var gr: Dictionary = tools._get_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": ss_id, "include_src": true
	})
	var grid: Array = (gr["tile"] as Dictionary)["cells"] as Array
	_assert(int((grid[1] as Array)[1]["value"]) == 99, "cell (1,1) value updated to 99", grid)
	_assert(bool((grid[1] as Array)[1].get("bold", false)) == true, "cell (1,1) is now bold", grid)
	_assert(str((grid[0] as Array)[0]["value"]) == "Renamed", "cell (0,0) value updated", grid)
	# Untouched cells preserved.
	_assert(str((grid[0] as Array)[1]["value"]) == "Score", "cell (0,1) untouched", grid)


func test_modify_spreadsheet_cells_skips_oob(tools: Object) -> void:
	var deck: Dictionary = _read_deck()
	var tiles: Array = ((deck["slides"] as Array)[0] as Dictionary).get("tiles", []) as Array
	var ss_id: String = ""
	for t in tiles:
		var t_d: Dictionary = t as Dictionary
		if str(t_d.get("kind", "")) == "spreadsheet" and int(t_d.get("rows", 0)) == 2:
			ss_id = str(t_d["id"])
			break

	var r: Dictionary = tools._modify_spreadsheet_cells({
		"path": OUT_PATH, "slide_index": 0, "tile_id": ss_id,
		"cells": [
			{"row": 0, "col": 0, "value": "OK"},
			{"row": 99, "col": 99, "value": "out of bounds"},
		],
	})
	_assert(r.get("success", false) == true, "modify with mixed valid/OOB succeeds", r)
	_assert(int(r.get("cells_updated", 0)) == 1, "1 cell updated", r)
	_assert((r.get("skipped", []) as Array).size() == 1, "1 cell skipped", r)


func test_modify_spreadsheet_rejects_non_spreadsheet_tile(tools: Object) -> void:
	# Earlier tests pruned the original Butter Tarts slide, so slide 0 may not
	# have a text tile anymore. Add one explicitly, then try modify-cells on it.
	var ar: Dictionary = tools._add_text_tile({
		"path": OUT_PATH, "slide_index": 0,
		"x": 0.01, "y": 0.01, "w": 0.05, "h": 0.05,
		"content": "for-rejection-test",
	})
	_assert(ar.get("success", false) == true, "seeded a text tile for rejection test", ar)
	var text_id: String = str(ar["tile_id"])

	var r: Dictionary = tools._modify_spreadsheet_cells({
		"path": OUT_PATH, "slide_index": 0, "tile_id": text_id,
		"cells": [{"row": 0, "col": 0, "value": "X"}],
	})
	_assert(r.get("success", false) == false, "rejects non-spreadsheet tile", r)
	# Clean up.
	tools._remove_tile({"path": OUT_PATH, "slide_index": 0, "tile_id": text_id})


## Tile id of the 2x2 spreadsheet seeded in test_add_spreadsheet_tile_with_cells —
## carried forward through grow/shrink so the wrong-spreadsheet ambiguity can't bite.
var _ss_2x2_id: String = ""


func test_resize_spreadsheet_grow_preserves(tools: Object) -> void:
	# Locate by rows=2 cols=2 (unique at this point).
	var deck: Dictionary = _read_deck()
	var tiles: Array = ((deck["slides"] as Array)[0] as Dictionary).get("tiles", []) as Array
	for t in tiles:
		var t_d: Dictionary = t as Dictionary
		if str(t_d.get("kind", "")) == "spreadsheet" and int(t_d.get("rows", 0)) == 2 and int(t_d.get("cols", 0)) == 2:
			_ss_2x2_id = str(t_d["id"])
			break
	_assert(not _ss_2x2_id.is_empty(), "located 2x2 spreadsheet to grow", {})

	var r: Dictionary = tools._resize_spreadsheet({
		"path": OUT_PATH, "slide_index": 0, "tile_id": _ss_2x2_id,
		"rows": 3, "cols": 3,
	})
	_assert(r.get("success", false) == true, "resize_spreadsheet (grow) succeeds", r)

	var gr: Dictionary = tools._get_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": _ss_2x2_id, "include_src": true
	})
	var ss: Dictionary = gr["tile"] as Dictionary
	_assert(int(ss["rows"]) == 3 and int(ss["cols"]) == 3, "grid is now 3x3", ss)
	var grid: Array = ss["cells"] as Array
	# Earlier modify-skips-oob set (0,0) to "OK", overwriting the prior "Renamed".
	_assert(str((grid[0] as Array)[0]["value"]) == "OK", "(0,0) value preserved on grow", grid)
	_assert(int((grid[1] as Array)[1]["value"]) == 99, "(1,1) value preserved on grow", grid)
	# New cells: type=CELL_EMPTY=0
	_assert(int((grid[2] as Array)[2]["type"]) == 0, "new cell (2,2) is empty", grid)


func test_resize_spreadsheet_shrink_truncates(tools: Object) -> void:
	# Use the carried-forward id from grow so we don't pick the wrong sheet.
	_assert(not _ss_2x2_id.is_empty(), "carried-forward spreadsheet id is set", {})

	var r: Dictionary = tools._resize_spreadsheet({
		"path": OUT_PATH, "slide_index": 0, "tile_id": _ss_2x2_id,
		"rows": 1, "cols": 2,
	})
	_assert(r.get("success", false) == true, "resize_spreadsheet (shrink) succeeds", r)

	var gr: Dictionary = tools._get_tile({
		"path": OUT_PATH, "slide_index": 0, "tile_id": _ss_2x2_id, "include_src": true
	})
	var ss: Dictionary = gr["tile"] as Dictionary
	var grid: Array = ss["cells"] as Array
	_assert(int(ss["rows"]) == 1 and int(ss["cols"]) == 2, "grid is now 1x2", ss)
	_assert(grid.size() == 1, "grid has 1 row after shrink", grid)
	_assert((grid[0] as Array).size() == 2, "row has 2 cols after shrink", grid)
	# (0,0) should still be "OK" from the modify_cells_skips_oob test.
	_assert(str((grid[0] as Array)[0]["value"]) == "OK", "(0,0) preserved through shrink", grid)


func test_post_modify_deck_still_validates() -> void:
	var deck: Dictionary = _read_deck()
	var errors: Array = SlideModel.validate_deck(deck)
	_assert(errors.is_empty(), "post-modify deck still passes validate_deck()", {"errors": errors})


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
