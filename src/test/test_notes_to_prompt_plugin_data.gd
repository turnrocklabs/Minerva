extends SceneTree
## Headless tests for NotesContainer.wrap_notes - the seam every provider's
## wrap_memory passes through.
##
## Coverage:
##   - A plugin_data note is handed to the provider as its alt text (a TEXT note)
##     followed by its preview (an IMAGE note), in that order.
##   - IMAGE and TEXT notes pass through unchanged and keep their position.
##   - The text half is omitted when the alt text is empty; the image half is
##     omitted when there is no preview.
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script test/test_notes_to_prompt_plugin_data.gd

const ALT_TEXT: String = "Slide 1 of 2"
const TEXT_NOTE_CONTENT: String = "butter tarts are a Canadian pastry"

var _pass: int = 0
var _fail: int = 0


## Stands in for a real provider: converts the two note kinds every provider
## implements and records each result in call order. Built from source at run
## time, after the autoloads exist: naming BaseProvider or Note at this
## script's own compile time would pull them in before SingletonObject is
## registered, and the whole suite would fail to load.
const STUB_PROVIDER_SOURCE := """
extends "res://Scripts/Services/Providers/BaseProvider.gd"
const NoteScript := preload("res://Scripts/UI/Controls/Note.gd")
var handed: Array = []

func wrap_memory(item) -> Variant:
	var wrapped: Variant = null
	if item.type == NoteScript.Type.TEXT:
		wrapped = item.get_controls_container().content
	elif item.type == NoteScript.Type.IMAGE:
		wrapped = item.get_controls_container().image
	handed.append(wrapped)
	return wrapped
"""

var NoteScript: Script = null
var NotesContainerScript: Script = null
var StubProvider: GDScript = null


func _init() -> void:
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	print("=== plugin_data notes reach the provider (NotesContainer.wrap_notes) ===\n")
	NoteScript = load("res://Scripts/UI/Controls/Note.gd")
	NotesContainerScript = load("res://Scenes/note/NotesContainer.gd")
	StubProvider = GDScript.new()
	StubProvider.source_code = STUB_PROVIDER_SOURCE
	StubProvider.reload()

	test_plugin_data_becomes_text_then_image()
	test_halves_the_note_lacks_are_omitted()

	if _pass == 0:
		_fail += 1
		printerr("  FAIL: no assertion ran — the suite did not reach its checks")
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


# -- Helpers ----------------------------------------------------------------

func _make_image(color: Color) -> Image:
	var img: Image = Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return img


func _same_pixels(a: Variant, b: Image) -> bool:
	if not (a is Image):
		return false
	var img: Image = a
	return img.get_size() == b.get_size() and img.get_data() == b.get_data()


## A typed Array[Note] built without naming Note at compile time.
func _notes(raw: Array) -> Array:
	return Array(raw, TYPE_OBJECT, &"Node", NoteScript)


func _make_plugin_data_note(preview: Image, alt_text: String) -> Node:
	return NoteScript.create_plugin_data_note(
		"Deck",
		"presentation",
		"SlideEditorPanel",
		{"version": 1, "deck": {"slides": [{"id": "s1"}]}},
		preview,
		alt_text,
		"",
		false,
	)


func _release(notes: Array, provider: Object) -> void:
	for note in notes:
		var controls: Control = note.get_controls_container()
		if controls != null and controls.get_parent() == null:
			controls.free()
		note.free()
	provider.free()


# -- Tests ------------------------------------------------------------------

func test_plugin_data_becomes_text_then_image() -> void:
	print("TEST: plugin_data expands to alt text then preview, others unchanged")

	var preview: Image = _make_image(Color(0.1, 0.4, 0.7, 1.0))
	var photo: Image = _make_image(Color(0.9, 0.2, 0.2, 1.0))

	var notes: Array = _notes([
		_make_plugin_data_note(preview, ALT_TEXT),
		NoteScript.create_image_note("Photo", photo, "a photo", "", false),
		NoteScript.create_text_note("Prose", TEXT_NOTE_CONTENT, "", false),
	])

	var provider: Object = StubProvider.new()
	var output: Array = NotesContainerScript.wrap_notes(provider, notes)

	_check("provider is handed 4 items for 3 notes", provider.handed.size() == 4)
	if provider.handed.size() == 4:
		_check("1st is the plugin_data alt text",
			provider.handed[0] is String and provider.handed[0] == ALT_TEXT)
		_check("2nd is the plugin_data preview image",
			_same_pixels(provider.handed[1], preview))
		_check("3rd is the image note's image",
			_same_pixels(provider.handed[2], photo))
		_check("4th is the text note's content",
			provider.handed[3] is String and provider.handed[3] == TEXT_NOTE_CONTENT)

	_check("wrap_notes returns exactly what the provider produced",
		output.size() == provider.handed.size())
	if output.size() == provider.handed.size():
		var same: bool = true
		for i in output.size():
			if output[i] != provider.handed[i]:
				same = false
		_check("returned values match the provider's results in order", same)

	_release(notes, provider)


func test_halves_the_note_lacks_are_omitted() -> void:
	print("TEST: empty alt text and missing preview each drop their half")

	var preview: Image = _make_image(Color(0.2, 0.8, 0.3, 1.0))

	var notes: Array = _notes([
		_make_plugin_data_note(Image.new(), ALT_TEXT),
		_make_plugin_data_note(preview, ""),
	])

	var provider: Object = StubProvider.new()
	NotesContainerScript.wrap_notes(provider, notes)

	_check("two half-empty notes yield 2 items, not 4", provider.handed.size() == 2)
	if provider.handed.size() == 2:
		_check("the previewless note yields its alt text only",
			provider.handed[0] is String and provider.handed[0] == ALT_TEXT)
		_check("the alt-less note yields its preview only",
			_same_pixels(provider.handed[1], preview))

	_release(notes, provider)
