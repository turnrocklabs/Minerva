extends SceneTree
## Headless tests for the three editable-plugin-note hooks added to
## ~/github/plugins/presentation/ui/SlideEditorPanel.gd:
##   - _on_panel_create_note_request(ctx)
##   - _on_panel_restore_from_note(payload)
##   - _on_panel_render_for_llm(ctx)
##
## We instantiate the panel without building the UI (no add_child to root),
## set _deck directly, and call the hooks. _refresh_all() short-circuits on
## a null _canvas so this is safe.
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script test/test_presentation_panel_note_hooks.gd

var SlideEditorPanel: Script = null
var SlideModel: Script = null

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	var home: String = OS.get_environment("HOME")
	SlideEditorPanel = load(home.path_join("github/plugins/presentation/ui/SlideEditorPanel.gd"))
	SlideModel       = load(home.path_join("github/plugins/presentation/ui/slide_model.gd"))

	print("=== Presentation plugin — editable-note hooks ===\n")

	test_create_note_request_emits_plugin_data_shape()
	test_create_note_request_deep_copies_deck()
	test_restore_from_note_accepts_valid_payload()
	test_restore_from_note_rejects_wrong_version()
	test_restore_from_note_rejects_invalid_deck()
	test_restore_clamps_selected_slide_index()
	test_render_for_llm_emits_text_per_slide()
	test_render_for_llm_emits_image_for_image_tile()
	test_render_for_llm_emits_text_for_spreadsheet_tile()
	test_render_for_llm_handles_empty_deck()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(description: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		printerr("  FAIL: %s" % description)


# ── Helpers ────────────────────────────────────────────────────────────

func _make_panel_with_deck(deck: Dictionary, selected: int = 0):
	var panel = SlideEditorPanel.new()
	panel._deck = deck
	panel._selected_slide_index = selected
	return panel


func _make_minimal_deck() -> Dictionary:
	# Use the model's factory so version/aspect are correct.
	var deck: Dictionary = SlideModel.make_deck()
	# make_deck returns a deck with one empty slide. Add a title and a text tile.
	var slides: Array = deck.get("slides", []) as Array
	(slides[0] as Dictionary)["title"] = "Hello"
	var text_tile: Dictionary = SlideModel.make_text_tile(0.1, 0.1, 0.5, 0.2, "Body line one\nBody line two")
	((slides[0] as Dictionary).get("tiles", []) as Array).append(text_tile)
	return deck


func _make_tiny_png_base64() -> String:
	# Build a 2×2 RGBA Image, save to PNG, base64-encode. Round-trips through
	# load_png_from_buffer in _image_tile_to_image.
	var img: = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.6, 0.9, 1.0))
	var bytes: PackedByteArray = img.save_png_to_buffer()
	return Marshalls.raw_to_base64(bytes)


# ── _on_panel_create_note_request ──────────────────────────────────────

func test_create_note_request_emits_plugin_data_shape() -> void:
	print("test_create_note_request_emits_plugin_data_shape:")
	var panel = _make_panel_with_deck(_make_minimal_deck(), 0)
	var ctx: = {"panel_name": "SlideEditorPanel", "plugin_id": "presentation"}
	var result: Dictionary = panel._on_panel_create_note_request(ctx)

	_check("kind is plugin_data", result.get("kind", "") == "plugin_data")
	_check("plugin_id is presentation", result.get("plugin_id", "") == "presentation")
	_check("panel_name passed through", result.get("panel_name", "") == "SlideEditorPanel")
	_check("payload is Dictionary", result.get("payload", null) is Dictionary)
	_check("preview_alt_text non-empty", String(result.get("preview_alt_text", "")) != "")

	var p: Dictionary = result.get("payload", {}) as Dictionary
	_check("payload.version == 1", int(p.get("version", 0)) == 1)
	_check("payload.deck present", p.get("deck", null) is Dictionary)
	_check("payload.selected_slide preserved", int(p.get("selected_slide", -1)) == 0)
	panel.free()


func test_create_note_request_deep_copies_deck() -> void:
	print("test_create_note_request_deep_copies_deck:")
	var panel = _make_panel_with_deck(_make_minimal_deck(), 0)
	var result: Dictionary = panel._on_panel_create_note_request({"panel_name": "SlideEditorPanel"})
	var snap_deck: Dictionary = (result.get("payload", {}) as Dictionary).get("deck", {})

	# Mutate the original deck — snapshot must be unaffected (deep copy).
	(panel._deck.get("slides", [])[0] as Dictionary)["title"] = "Mutated"
	var snap_title: String = String(((snap_deck.get("slides", [])[0]) as Dictionary).get("title", ""))
	_check("deep-copy isolates snapshot from later edits", snap_title == "Hello")
	panel.free()


# ── _on_panel_restore_from_note ────────────────────────────────────────

func test_restore_from_note_accepts_valid_payload() -> void:
	print("test_restore_from_note_accepts_valid_payload:")
	var panel = _make_panel_with_deck(SlideModel.make_deck(), 0)
	var saved_deck: Dictionary = _make_minimal_deck()
	(saved_deck.get("slides", [])[0] as Dictionary)["title"] = "Restored"
	var ok: bool = panel._on_panel_restore_from_note({
		"version": 1, "deck": saved_deck, "selected_slide": 0
	})
	_check("returns true on valid payload", ok)
	_check("deck.title installed", String(((panel._deck.get("slides", [])[0]) as Dictionary).get("title", "")) == "Restored")
	panel.free()


func test_restore_from_note_rejects_wrong_version() -> void:
	print("test_restore_from_note_rejects_wrong_version:")
	var panel = _make_panel_with_deck(SlideModel.make_deck(), 0)
	var ok: bool = panel._on_panel_restore_from_note({
		"version": 99, "deck": _make_minimal_deck(), "selected_slide": 0
	})
	_check("returns false on unknown version", ok == false)
	panel.free()


func test_restore_from_note_rejects_invalid_deck() -> void:
	print("test_restore_from_note_rejects_invalid_deck:")
	var panel = _make_panel_with_deck(SlideModel.make_deck(), 0)
	var ok: bool = panel._on_panel_restore_from_note({
		"version": 1, "deck": {"this": "is not a valid deck"}
	})
	_check("returns false on invalid deck shape", ok == false)
	panel.free()


func test_restore_clamps_selected_slide_index() -> void:
	print("test_restore_clamps_selected_slide_index:")
	var panel = _make_panel_with_deck(SlideModel.make_deck(), 0)
	var ok: bool = panel._on_panel_restore_from_note({
		"version": 1, "deck": _make_minimal_deck(), "selected_slide": 999
	})
	_check("returns true even with overshoot index", ok)
	_check("selected_slide_index clamped to last slide", panel._selected_slide_index == 0)
	panel.free()


# ── _on_panel_render_for_llm ───────────────────────────────────────────

func test_render_for_llm_emits_text_per_slide() -> void:
	print("test_render_for_llm_emits_text_per_slide:")
	var panel = _make_panel_with_deck(_make_minimal_deck(), 0)
	var parts: Array = panel._on_panel_render_for_llm({})
	_check("at least one part returned", parts.size() >= 1)
	if parts.size() >= 1:
		var first: Dictionary = parts[0] as Dictionary
		_check("first part is text", String(first.get("type", "")) == "text")
		var text: String = String(first.get("text", ""))
		_check("text contains slide marker 'Slide 1'", text.contains("Slide 1"))
		_check("text contains title 'Hello'", text.contains("Hello"))
		_check("text contains tile body", text.contains("Body line one"))
	panel.free()


func test_render_for_llm_emits_image_for_image_tile() -> void:
	print("test_render_for_llm_emits_image_for_image_tile:")
	var deck: Dictionary = _make_minimal_deck()
	var img_tile: Dictionary = SlideModel.make_image_tile(_make_tiny_png_base64(), 0.5, 0.1, 0.4, 0.4)
	((deck.get("slides", [])[0]) as Dictionary).get("tiles", []).append(img_tile)
	var panel = _make_panel_with_deck(deck, 0)

	var parts: Array = panel._on_panel_render_for_llm({})
	# Find the image part.
	var has_image: bool = false
	for p in parts:
		if p is Dictionary and String((p as Dictionary).get("type", "")) == "image":
			has_image = true
			var img_v: Variant = (p as Dictionary).get("image", null)
			_check("image part carries an Image instance", img_v is Image)
			_check("alt text non-empty", String((p as Dictionary).get("alt", "")) != "")
			break
	_check("MultimodalPayload includes an image part", has_image)
	panel.free()


func test_render_for_llm_emits_text_for_spreadsheet_tile() -> void:
	print("test_render_for_llm_emits_text_for_spreadsheet_tile:")
	var deck: Dictionary = SlideModel.make_deck()
	var grid: Array = [
		[SlideModel.make_cell("Name"),    SlideModel.make_cell("Score")],
		[SlideModel.make_cell("Imran"),   SlideModel.make_cell(95)],
		[SlideModel.make_cell("Anyone"),  SlideModel.make_cell(80)],
	]
	var sheet: Dictionary = SlideModel.make_spreadsheet_tile(3, 2, grid, 0.1, 0.1, 0.6, 0.4, true, false)
	((deck.get("slides", [])[0]) as Dictionary).get("tiles", []).append(sheet)
	var panel = _make_panel_with_deck(deck, 0)

	var parts: Array = panel._on_panel_render_for_llm({})
	var found_csv: bool = false
	for p in parts:
		if p is Dictionary and String((p as Dictionary).get("type", "")) == "text":
			var t: String = String((p as Dictionary).get("text", ""))
			if t.contains("Imran") and t.contains("95"):
				found_csv = true
				break
	_check("MultimodalPayload includes spreadsheet text part", found_csv)
	panel.free()


func test_render_for_llm_handles_empty_deck() -> void:
	print("test_render_for_llm_handles_empty_deck:")
	var deck: Dictionary = {"version": SlideModel.SCHEMA_VERSION, "aspect": "16:9", "slides": []}
	var panel = _make_panel_with_deck(deck, 0)
	var parts: Array = panel._on_panel_render_for_llm({})
	_check("empty deck yields empty payload", parts.size() == 0)
	panel.free()
