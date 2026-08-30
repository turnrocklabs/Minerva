extends SceneTree
## ChatGPT provider carries Image notes into the request as image content parts.
##
## Run:
##   godot --headless --path src --script test/test_chatgpt_image_notes.gd
##
## Oracle: a USER turn holding one String note and one Image note is pushed
## through the send path — Format() followed by the request-time content
## conversion generate_content() applies — and must yield exactly two content
## parts: one input_text carrying both the note text and the message, and one
## input_image whose base64 payload decodes back to the PNG the source Image
## encodes to, and whose pixels match the source pixel-for-pixel.
##
## NOTE: class_name globals are invisible to --script runs; load() + duck-type.

const PROVIDER_PATH := "res://Scripts/Services/Providers/ChatGPT/ChatGPTProvider.gd"
const CHI_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const DATA_URL_PREFIX := "data:image/png;base64,"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	print("=== ChatGPT provider image notes ===\n")

	test_user_turn_carries_text_and_image()
	test_text_only_turn_keeps_single_part()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		printerr("  FAIL: %s%s" % [description, (" — " + detail) if detail != "" else ""])


## A small, deterministic source image with more than one colour, so a pixel
## comparison can actually fail if the payload is not the image we sent.
func _make_source_image() -> Image:
	var img := Image.create(6, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.1, 0.4, 0.7, 1.0))
	img.set_pixel(0, 0, Color(1.0, 0.0, 0.0, 1.0))
	img.set_pixel(5, 3, Color(0.0, 1.0, 0.0, 1.0))
	return img


## Format() then the request-time conversion, exactly as generate_content() does.
func _send_path(provider, item) -> Array:
	var converted = provider._convert_content_types(provider.Format(item))
	if converted is Dictionary:
		var content: Variant = (converted as Dictionary).get("content", [])
		if content is Array:
			return content as Array
	return []


func test_user_turn_carries_text_and_image() -> void:
	print("test_user_turn_carries_text_and_image:")

	var CHI = load(CHI_PATH)
	var provider = load(PROVIDER_PATH).new()

	var source: Image = _make_source_image()
	var source_png: PackedByteArray = source.save_png_to_buffer()

	var item = CHI.new(CHI.PartType.TEXT, CHI.ChatRole.USER, "What is in this picture?", true)
	item.InjectedNotes = ["The board is a 2-layer FR4 panel.", source]

	var content: Array = _send_path(provider, item)

	_check("content has exactly two parts (text + image)", content.size() == 2,
		"got %d: %s" % [content.size(), str(content)])
	if content.size() != 2:
		provider.free()
		return

	var text_part: Dictionary = content[0]
	_check("first part is input_text", text_part.get("type", "") == "input_text",
		str(text_part.get("type", "")))
	var text: String = str(text_part.get("text", ""))
	_check("text part carries the note", text.contains("2-layer FR4 panel"))
	_check("text part carries the message", text.contains("What is in this picture?"))

	var image_part: Dictionary = content[1]
	_check("second part is input_image", image_part.get("type", "") == "input_image",
		str(image_part.get("type", "")))

	var url: Variant = image_part.get("image_url", null)
	var url_ok: bool = url is String and (url as String).begins_with(DATA_URL_PREFIX)
	_check("image_url is a bare data-URL string", url_ok, str(url).left(64))
	if not url_ok:
		provider.free()
		return

	var decoded: PackedByteArray = Marshalls.base64_to_raw(
		(url as String).substr(DATA_URL_PREFIX.length()))
	_check("payload decodes to the same PNG bytes the source encodes to", decoded == source_png,
		"%d bytes vs %d" % [decoded.size(), source_png.size()])

	# Encoder-independent check: the decoded image IS the source image.
	var round_tripped := Image.new()
	var load_err: int = round_tripped.load_png_from_buffer(decoded)
	_check("payload loads as a PNG", load_err == OK, "error %d" % load_err)
	if load_err == OK:
		_check("round-tripped image has the source dimensions",
			round_tripped.get_size() == source.get_size(),
			"%s vs %s" % [round_tripped.get_size(), source.get_size()])
		_check("round-tripped pixels equal the source pixels",
			round_tripped.get_data() == source.get_data())

	provider.free()


func test_text_only_turn_keeps_single_part() -> void:
	print("test_text_only_turn_keeps_single_part:")

	var CHI = load(CHI_PATH)
	var provider = load(PROVIDER_PATH).new()

	var item = CHI.new(CHI.PartType.TEXT, CHI.ChatRole.USER, "Hello", true)
	item.InjectedNotes = ["A string note."]

	var content: Array = _send_path(provider, item)

	_check("string-note turn still has one content part", content.size() == 1,
		"got %d: %s" % [content.size(), str(content)])
	if content.size() == 1:
		_check("the single part is input_text",
			(content[0] as Dictionary).get("type", "") == "input_text")

	provider.free()
