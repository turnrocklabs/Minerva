extends SceneTree
## Unit tests for AnnotationRefResolver — the chat bridge that resolves cited
## refs ("C7") to current re-anchored code + intent (DCR 019e9f602391 P4).
##
## Run: godot --headless --path src --script test/test_annotation_ref_resolver.gd

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationRefResolver Tests (DCR 019e9f602391 P4) ===\n")

	print("-- parse_refs --")
	test_parse_refs()

	print("\n-- resolve_for_chat: live host, current code + intent --")
	test_resolve_returns_current_code_and_intent()

	print("\n-- resolve_for_chat: scoped to project_id --")
	test_resolve_scoped_to_project()

	print("\n-- resolve_for_chat: stale anchor flagged --")
	test_resolve_flags_stale()

	print("\n-- resolve_for_chat: unknown ref skipped --")
	test_resolve_unknown_skipped()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _ann(ref: String, project: String, summary: String, start: int, end: int) -> Dictionary:
	return {
		"id": "ann_" + ref,
		"ref": ref,
		"ref_project": project,
		"lifecycle": "open",
		"summary": summary,
		"anchor": {"plugin": "core", "type": "text.range", "id": {"start": start, "end": end}},
	}


## Register a mock host and return its editor name. Caller deregisters.
func _register_host(name: String, anns: Array, text: String, stale: bool) -> void:
	AnnotationHostRegistry.register(name, _MockHost.new(anns, text, stale))


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_parse_refs() -> void:
	print("test_parse_refs:")
	var refs := AnnotationRefResolver.parse_refs("rethink C7 and C12, but not ABC7 or C7x")
	check_eq("parses C7 + C12 only (word-bounded)", Array(refs), ["C7", "C12"])
	var dup := AnnotationRefResolver.parse_refs("C3 then C3 again")
	check_eq("dedupes repeated refs", Array(dup), ["C3"])
	check_eq("no refs -> empty", Array(AnnotationRefResolver.parse_refs("no refs here")), [])


func test_resolve_returns_current_code_and_intent() -> void:
	print("test_resolve_returns_current_code_and_intent:")
	AnnotationHostRegistry._reset_for_test()
	_register_host("main.gd", [_ann("C7", "P", "x.gd belongs in y.gd", 0, 5)], "hello world", false)
	var notes := AnnotationRefResolver.resolve_for_chat("let us revisit C7", "P")
	check_eq("one note returned", notes.size(), 1)
	var note := str(notes[0]) if notes.size() > 0 else ""
	check("note names the ref C7", note.contains("C7"))
	check("note carries the intent", note.contains("x.gd belongs in y.gd"))
	check("note carries CURRENT code at the anchor ('hello')", note.contains("hello"))
	check("note is not flagged stale", not note.contains("STALE"))
	AnnotationHostRegistry._reset_for_test()


func test_resolve_scoped_to_project() -> void:
	print("test_resolve_scoped_to_project:")
	AnnotationHostRegistry._reset_for_test()
	_register_host("main.gd", [_ann("C7", "PROJ_A", "owned by A", 0, 5)], "hello world", false)
	check_eq("same project resolves", AnnotationRefResolver.resolve_for_chat("C7", "PROJ_A").size(), 1)
	check_eq("foreign project does not resolve", AnnotationRefResolver.resolve_for_chat("C7", "PROJ_B").size(), 0)
	AnnotationHostRegistry._reset_for_test()


func test_resolve_flags_stale() -> void:
	print("test_resolve_flags_stale:")
	AnnotationHostRegistry._reset_for_test()
	_register_host("main.gd", [_ann("C9", "P", "intent", 0, 5)], "hello world", true)
	var notes := AnnotationRefResolver.resolve_for_chat("C9", "P")
	check("stale anchor is flagged in the note", notes.size() == 1 and str(notes[0]).contains("STALE"))
	AnnotationHostRegistry._reset_for_test()


func test_resolve_unknown_skipped() -> void:
	print("test_resolve_unknown_skipped:")
	AnnotationHostRegistry._reset_for_test()
	_register_host("main.gd", [_ann("C1", "P", "intent", 0, 5)], "hello world", false)
	check_eq("unknown ref yields no notes", AnnotationRefResolver.resolve_for_chat("what about C99?", "P").size(), 0)
	AnnotationHostRegistry._reset_for_test()


# ── Mock host ─────────────────────────────────────────────────────────────────

class _MockHost extends AnnotationHost:
	var _anns: Array
	var _text: String
	var _stale: bool

	func _init(anns: Array, text: String, stale: bool) -> void:
		_anns = anns
		_text = text
		_stale = stale

	func get_all_annotations() -> Array:
		return _anns

	func get_text_content() -> String:
		return _text

	func resolve_anchor(_anchor: Dictionary) -> Dictionary:
		return {"stale": _stale, "position": Vector2.ZERO, "bounds": Rect2(), "view_metadata": {}}
