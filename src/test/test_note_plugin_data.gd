extends SceneTree
## Headless round-trip test for the new NoteScript.Type.PLUGIN_DATA kind.
##
## Validates: factory shape, linked_plugin_payload JSON wrapping,
## serialize/deserialize round-trip, image bytes preservation, and
## defensive handling of malformed/missing payloads.
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script test/test_note_plugin_data.gd

var NoteScript: Script = null
var NoteImageControlsScript: Script = null

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	# Defer load until autoloads register (mirrors test_mcp_presentation_tools).
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	NoteScript = load("res://Scripts/UI/Controls/Note.gd")
	NoteImageControlsScript = load("res://Scenes/note/note_controls/image_controls.gd")

	print("=== Note plugin_data round-trip tests ===\n")

	test_type_enum_and_name_mapping()
	await test_factory_produces_well_formed_note()
	await test_serialize_emits_expected_keys()
	await test_round_trip_preserves_payload()
	await test_round_trip_preserves_image_bytes()
	await test_deserialize_handles_missing_payload()
	await test_deserialize_handles_malformed_json()
	await test_empty_preview_image_handled()

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

func _make_test_image(w: int = 8, h: int = 8, fill: Color = Color(0.2, 0.6, 0.9, 1.0)) -> Image:
	var img: = Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(fill)
	return img


func _make_note_async(
	title: String,
	plugin_id: String,
	panel_name: String,
	payload: Dictionary,
	preview: Image,
	alt: String = ""
):
	var note = NoteScript.create_plugin_data_note(
		title, plugin_id, panel_name, payload, preview, alt, "", false
	)
	root.add_child(note)
	# `note.initialized` fires synchronously during add_child — awaiting it
	# here would deadlock. A single frame yield ensures any deferred setup
	# settles before we start poking at the controls container.
	await process_frame
	return note


# ── Tests ──────────────────────────────────────────────────────────────

func test_type_enum_and_name_mapping() -> void:
	print("test_type_enum_and_name_mapping:")
	_check("Type.PLUGIN_DATA exists", NoteScript.Type.PLUGIN_DATA != null)
	_check("PLUGIN_DATA is the 6th enum value (index 5)", int(NoteScript.Type.PLUGIN_DATA) == 5)
	_check("type_names maps PLUGIN_DATA to 'plugin_data'", NoteScript._type_names.get(NoteScript.Type.PLUGIN_DATA, "") == "plugin_data")


func test_factory_produces_well_formed_note() -> void:
	print("test_factory_produces_well_formed_note:")
	var img: = _make_test_image()
	var payload: = {"slides": [{"id": "s1", "title": "Hello"}], "selected": 0}
	var note =await _make_note_async("Deck", "presentation", "SlideEditorPanel", payload, img, "Slide 1 of 1")

	_check("note.type is PLUGIN_DATA", note.type == NoteScript.Type.PLUGIN_DATA)
	_check("content_type derived as 'plugin_data'", note.content_type == "plugin_data")
	_check("title set", note.title == "Deck")
	_check("linked_plugin_payload non-empty", not note.linked_plugin_payload.is_empty())

	var wrapper: Variant = JSON.parse_string(note.linked_plugin_payload)
	_check("linked_plugin_payload is valid JSON Dictionary", wrapper is Dictionary)
	if wrapper is Dictionary:
		_check("wrapper has version=1", int(wrapper.get("version", 0)) == 1)
		_check("wrapper.plugin_id preserved", wrapper.get("plugin_id", "") == "presentation")
		_check("wrapper.panel_name preserved", wrapper.get("panel_name", "") == "SlideEditorPanel")
		var inner: Variant = wrapper.get("payload", null)
		_check("wrapper.payload is Dictionary", inner is Dictionary)
		if inner is Dictionary:
			_check("payload.selected preserved", int(inner.get("selected", -1)) == 0)
			_check("payload.slides has 1 entry", (inner.get("slides", []) as Array).size() == 1)

	note.queue_free()


func test_serialize_emits_expected_keys() -> void:
	print("test_serialize_emits_expected_keys:")
	var img: = _make_test_image()
	var note =await _make_note_async("S", "p", "P", {"k": "v"}, img, "alt")
	var data: Dictionary = note.serialize()

	_check("ContentType is 'plugin_data'", data.get("ContentType", "") == "plugin_data")
	_check("LinkedPluginPayload present", data.has("LinkedPluginPayload"))
	_check("MemoryImage present (preview rasterized)", data.has("MemoryImage"))
	_check("MemoryImage non-empty", String(data.get("MemoryImage", "")).length() > 0)
	_check("ImageCaption carries alt text", data.get("ImageCaption", "") == "alt")
	_check("Title present", data.get("Title", "") == "S")
	_check("UUID present", String(data.get("UUID", "")).length() > 0)

	note.queue_free()


func test_round_trip_preserves_payload() -> void:
	print("test_round_trip_preserves_payload:")
	var img: = _make_test_image()
	var payload: = {
		"version": 1,
		"deck": {"slides": [{"title": "A"}, {"title": "B"}]},
		"meta": {"author": "imran"},
	}
	var n1 =await _make_note_async("Round", "presentation", "SlideEditorPanel", payload, img, "Cap")
	var dict: Dictionary = n1.serialize()
	n1.queue_free()

	var n2 =NoteScript.deserialize(dict, false)
	_check("deserialize returned non-null Note", n2 != null)
	if n2 == null:
		return
	root.add_child(n2)
	await process_frame

	_check("type preserved", n2.type == NoteScript.Type.PLUGIN_DATA)
	_check("title preserved", n2.title == "Round")

	var wrapper: Variant = JSON.parse_string(n2.linked_plugin_payload)
	_check("wrapper restored", wrapper is Dictionary)
	if wrapper is Dictionary:
		_check("plugin_id preserved", wrapper.get("plugin_id", "") == "presentation")
		_check("panel_name preserved", wrapper.get("panel_name", "") == "SlideEditorPanel")
		var inner: Variant = wrapper.get("payload", null)
		_check("payload nested dict survived", inner is Dictionary)
		if inner is Dictionary:
			var deck: Variant = inner.get("deck", null)
			_check("payload.deck.slides preserved (size 2)", deck is Dictionary and (deck.get("slides", []) as Array).size() == 2)

	n2.queue_free()


func test_round_trip_preserves_image_bytes() -> void:
	print("test_round_trip_preserves_image_bytes:")
	var original: = _make_test_image(16, 16, Color(0.9, 0.1, 0.4, 1.0))
	var original_bytes: PackedByteArray = original.save_png_to_buffer()

	var n1 =await _make_note_async("ImgTest", "p", "P", {}, original, "")
	var dict: Dictionary = n1.serialize()
	n1.queue_free()

	var n2 =NoteScript.deserialize(dict, false)
	if n2 == null:
		_check("deserialize returned non-null", false)
		return
	root.add_child(n2)
	await process_frame

	# Pull the round-tripped image from the controls container.
	var controls: Variant = n2.get_controls_container()
	_check("controls container is NoteImageControls", controls != null and controls.get_script() == NoteImageControlsScript)
	if controls != null and controls.get_script() == NoteImageControlsScript:
		var roundtrip_bytes: PackedByteArray = (controls.image as Image).save_png_to_buffer()
		_check("image PNG bytes match (size %d == %d)" % [roundtrip_bytes.size(), original_bytes.size()],
			roundtrip_bytes == original_bytes)

	n2.queue_free()


func test_deserialize_handles_missing_payload() -> void:
	print("test_deserialize_handles_missing_payload:")
	# Synthesize a minimal on-disk shape with no LinkedPluginPayload.
	var img: = _make_test_image()
	var dict: = {
		"Title": "Bare",
		"UUID": "test-uuid-bare",
		"ContentType": "plugin_data",
		"MemoryImage": Marshalls.raw_to_base64(img.save_png_to_buffer()),
		"ImageCaption": "",
	}
	var n =NoteScript.deserialize(dict, false)
	_check("deserialize without LinkedPluginPayload still returns Note", n != null)
	if n != null:
		root.add_child(n)
		await process_frame
		_check("type still PLUGIN_DATA", n.type == NoteScript.Type.PLUGIN_DATA)
		# Wrapper should be empty-ish with empty plugin_id/panel_name and {} payload.
		var wrapper: Variant = JSON.parse_string(n.linked_plugin_payload)
		_check("wrapper still parseable JSON", wrapper is Dictionary)
		if wrapper is Dictionary:
			_check("plugin_id defaults to empty string", String(wrapper.get("plugin_id", "X")) == "")
			_check("payload defaults to empty Dictionary", wrapper.get("payload", null) is Dictionary)
		n.queue_free()


func test_deserialize_handles_malformed_json() -> void:
	print("test_deserialize_handles_malformed_json:")
	var img: = _make_test_image()
	var dict: = {
		"Title": "Bad",
		"UUID": "test-uuid-bad",
		"ContentType": "plugin_data",
		"LinkedPluginPayload": "this is not json {",
		"MemoryImage": Marshalls.raw_to_base64(img.save_png_to_buffer()),
		"ImageCaption": "",
	}
	var n =NoteScript.deserialize(dict, false)
	_check("malformed JSON does not crash deserialize", n != null)
	if n != null:
		root.add_child(n)
		await process_frame
		_check("type still PLUGIN_DATA", n.type == NoteScript.Type.PLUGIN_DATA)
		# Factory was called with default empty wrapper values, so JSON should be valid.
		var wrapper: Variant = JSON.parse_string(n.linked_plugin_payload)
		_check("post-factory wrapper is well-formed JSON", wrapper is Dictionary)
		n.queue_free()


func test_empty_preview_image_handled() -> void:
	print("test_empty_preview_image_handled:")
	var dict: = {
		"Title": "NoImg",
		"UUID": "test-uuid-noimg",
		"ContentType": "plugin_data",
		"LinkedPluginPayload": JSON.stringify({"version": 1, "plugin_id": "p", "panel_name": "P", "payload": {}}),
		"MemoryImage": "",
		"ImageCaption": "",
	}
	var n =NoteScript.deserialize(dict, false)
	_check("missing image bytes does not crash deserialize", n != null)
	if n != null:
		root.add_child(n)
		await process_frame
		_check("type PLUGIN_DATA even without preview", n.type == NoteScript.Type.PLUGIN_DATA)
		n.queue_free()
