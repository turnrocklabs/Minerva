extends SceneTree
## Headless tests for DCR 019df4dc365f task #24:
## Persist plugin_data through .minproj save/load + chat history.
##
## Coverage:
##   - Note.serialize() emits a JSON-safe Dictionary (round-trippable via
##     JSON.stringify ↔ JSON.parse_string), since .minproj is JSON.
##   - Note.deserialize() of that JSON-round-tripped dict reproduces the
##     plugin_data note (payload + preview bytes + caption + UUID).
##   - ChatHistoryItem.Serialize/Deserialize preserves a plugin_data note
##     dictionary placed in InjectedNotes (opaque variant_to_base64 path).
##   - Backward compat: an older saved note dict without ContentType
##     "plugin_data" deserializes without leaking linked_plugin_payload.
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script test/test_plugin_data_persistence.gd

var NoteScript: Script = null
var ChatHistoryItemScript: Script = null

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	NoteScript = load("res://Scripts/UI/Controls/Note.gd")
	ChatHistoryItemScript = load("res://Scripts/Models/ChatHistoryItem.gd")

	print("=== plugin_data persistence (.minproj + chat history) ===\n")

	await test_serialize_dict_is_json_safe()
	await test_json_round_trip_preserves_payload_and_image()
	await test_json_round_trip_preserves_caption_and_uuid()
	await test_chat_history_round_trips_plugin_data_in_injected_notes()
	test_chat_history_handles_empty_injected_notes()
	await test_old_text_note_dict_does_not_carry_plugin_payload()

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

func _make_image() -> Image:
	var img: = Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.1, 0.4, 0.7, 1.0))
	return img


func _make_plugin_data_note() -> Node:
	var img: = _make_image()
	var payload: = {
		"version": 1,
		"deck": {
			"version": 1,
			"aspect": "16:9",
			"slides": [{"id": "s1", "title": "Hello", "tiles": []}],
		},
		"selected_slide": 0,
	}
	var note: Node = NoteScript.create_plugin_data_note(
		"Round-trip test deck",
		"presentation",
		"SlideEditorPanel",
		payload,
		img,
		"Slide preview",
		"test-uuid-9999",
		false, # don't register — keeps tests isolated
	)
	root.add_child(note)
	await process_frame
	return note


# ── .minproj path ──────────────────────────────────────────────────────

func test_serialize_dict_is_json_safe() -> void:
	print("test_serialize_dict_is_json_safe:")
	var note: Node = await _make_plugin_data_note()
	var data: Dictionary = note.serialize()

	# .minproj writes JSON. The serialized dict must survive a JSON round-trip
	# without losing plugin_data fields.
	var as_json: String = JSON.stringify(data)
	_check("JSON.stringify produced non-empty text", not as_json.is_empty())

	var parsed: Variant = JSON.parse_string(as_json)
	_check("JSON.parse_string returned a Dictionary", parsed is Dictionary)

	var pd: Dictionary = parsed as Dictionary
	_check("ContentType preserved as plugin_data", String(pd.get("ContentType", "")) == "plugin_data")
	_check("LinkedPluginPayload preserved as String", pd.get("LinkedPluginPayload", null) is String)
	_check("MemoryImage preserved as String", pd.get("MemoryImage", null) is String)
	_check("ImageCaption preserved", String(pd.get("ImageCaption", "")) == "Slide preview")
	_check("UUID preserved", String(pd.get("UUID", "")) == "test-uuid-9999")

	note.queue_free()


func test_json_round_trip_preserves_payload_and_image() -> void:
	print("test_json_round_trip_preserves_payload_and_image:")
	var note: Node = await _make_plugin_data_note()
	var original_bytes: PackedByteArray = note.get_controls_container().image.save_png_to_buffer()
	var data: Dictionary = note.serialize()

	# Round-trip through JSON to mimic .minproj read/write.
	var hydrated: Variant = JSON.parse_string(JSON.stringify(data))
	_check("hydrated data is Dictionary", hydrated is Dictionary)

	var restored: Node = NoteScript.deserialize(hydrated as Dictionary, false)
	_check("deserialize returned a Node", restored != null)
	root.add_child(restored)
	await process_frame

	# Payload survives intact.
	var wrapper: Variant = JSON.parse_string(restored.linked_plugin_payload)
	_check("restored linked_plugin_payload parses", wrapper is Dictionary)
	if wrapper is Dictionary:
		var w: Dictionary = wrapper as Dictionary
		_check("plugin_id round-tripped", String(w.get("plugin_id", "")) == "presentation")
		_check("panel_name round-tripped", String(w.get("panel_name", "")) == "SlideEditorPanel")
		var inner: Dictionary = w.get("payload", {}) as Dictionary
		var deck: Dictionary = inner.get("deck", {}) as Dictionary
		_check("deck.aspect round-tripped", String(deck.get("aspect", "")) == "16:9")
		var slides: Array = deck.get("slides", []) as Array
		_check("slide count round-tripped", slides.size() == 1)
		if slides.size() == 1:
			_check("slide title round-tripped",
				String((slides[0] as Dictionary).get("title", "")) == "Hello")

	# Image bytes survive (compare PNG-encoded bytes — Image.create is deterministic on a fill).
	var restored_image: Image = restored.get_controls_container().image
	_check("restored image is non-null", restored_image != null and not restored_image.is_empty())
	if restored_image != null and not restored_image.is_empty():
		var restored_bytes: PackedByteArray = restored_image.save_png_to_buffer()
		_check("PNG bytes match original", restored_bytes == original_bytes)

	note.queue_free()
	restored.queue_free()


func test_json_round_trip_preserves_caption_and_uuid() -> void:
	print("test_json_round_trip_preserves_caption_and_uuid:")
	var note: Node = await _make_plugin_data_note()
	var hydrated: Dictionary = JSON.parse_string(JSON.stringify(note.serialize())) as Dictionary

	var restored: Node = NoteScript.deserialize(hydrated, false)
	root.add_child(restored)
	await process_frame

	_check("UUID preserved across JSON round-trip", restored.uuid == "test-uuid-9999")
	_check("Title preserved", restored.title == "Round-trip test deck")
	_check("ImageCaption preserved",
		restored.get_controls_container().caption == "Slide preview")

	note.queue_free()
	restored.queue_free()


# ── Chat history path ──────────────────────────────────────────────────

func test_chat_history_round_trips_plugin_data_in_injected_notes() -> void:
	print("test_chat_history_round_trips_plugin_data_in_injected_notes:")
	var note: Node = await _make_plugin_data_note()
	var note_dict: Dictionary = note.serialize()

	var item: RefCounted = ChatHistoryItemScript.new()
	item.Message = "Look at this deck"
	item.InjectedNotes = [note_dict, "ad-hoc string note"]

	var saved: Dictionary = item.Serialize()
	# InjectedNotes are stored as base64 of variant_to_base64 — opaque blob.
	_check("InjectedNotes serialized to String (base64)", saved.get("InjectedNotes", null) is String)

	# JSON-round-trip saved (mimics .minproj's chat-history write).
	var hydrated: Dictionary = JSON.parse_string(JSON.stringify(saved)) as Dictionary
	_check("hydrated chat-history dict is Dictionary", hydrated != null)

	var restored: RefCounted = ChatHistoryItemScript.Deserialize(hydrated)
	_check("Deserialize returned a ChatHistoryItem", restored != null)
	if restored != null:
		_check("Message survived", restored.Message == "Look at this deck")
		_check("InjectedNotes restored to Array of size 2",
			restored.InjectedNotes is Array and (restored.InjectedNotes as Array).size() == 2)
		if restored.InjectedNotes is Array and (restored.InjectedNotes as Array).size() == 2:
			var first: Variant = restored.InjectedNotes[0]
			_check("first injected note is Dictionary", first is Dictionary)
			if first is Dictionary:
				var d: Dictionary = first as Dictionary
				_check("plugin_data ContentType survived", String(d.get("ContentType", "")) == "plugin_data")
				_check("LinkedPluginPayload string survived",
					String(d.get("LinkedPluginPayload", "")).contains("presentation"))
			_check("second injected note is the literal string",
				String(restored.InjectedNotes[1]) == "ad-hoc string note")

	note.queue_free()


func test_chat_history_handles_empty_injected_notes() -> void:
	print("test_chat_history_handles_empty_injected_notes:")
	var item: RefCounted = ChatHistoryItemScript.new()
	item.Message = "no notes"
	item.InjectedNotes = []

	var saved: Dictionary = item.Serialize()
	var hydrated: Dictionary = JSON.parse_string(JSON.stringify(saved)) as Dictionary
	var restored: RefCounted = ChatHistoryItemScript.Deserialize(hydrated)

	_check("empty InjectedNotes round-trips", restored != null
		and restored.InjectedNotes is Array
		and (restored.InjectedNotes as Array).size() == 0)


# ── Backward compatibility ─────────────────────────────────────────────

func test_old_text_note_dict_does_not_carry_plugin_payload() -> void:
	# An older .minproj saved a text note before plugin_data existed.
	# Loading it must not leak linked_plugin_payload onto the restored note.
	print("test_old_text_note_dict_does_not_carry_plugin_payload:")
	var legacy_dict: Dictionary = {
		"Title": "Legacy text note",
		"UUID": "legacy-uuid",
		"ContentType": "text",
		"Content": "Hello world",
		"Enabled": true,
		"Expanded": true,
	}
	var restored: Node = NoteScript.deserialize(legacy_dict, false)
	_check("legacy text note deserialized", restored != null)
	if restored != null:
		root.add_child(restored)
		await process_frame
		_check("linked_plugin_payload is empty string", restored.linked_plugin_payload == "")
		_check("type is not PLUGIN_DATA",
			int(restored.type) != int(NoteScript.Type.PLUGIN_DATA))
		restored.queue_free()
