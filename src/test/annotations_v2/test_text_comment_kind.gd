extends SceneTree
## Tests for Phase 2: AnnotationTextComment kind registration, stamping, migration,
## and body_view_factory.
## Run: godot --headless --path src --script test/annotations_v2/test_text_comment_kind.gd

const _TEAHScript = preload("res://Scripts/Services/Annotations/TextEditorAnnotationHost.gd")
const _TextCommentScript = preload("res://Scripts/Services/Annotations/kinds/AnnotationTextComment.gd")

var _pass_count := 0
var _fail_count := 0


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func _initialize() -> void:
	print("[tags: unit,annotations,text_comment]")
	print("=== test_text_comment_kind ===\n")

	test_kind_registers_at_host_init()
	test_add_comment_at_stamps_text_comment()
	test_kind_has_visual_render_false()
	test_load_migrates_legacy_text_with_target_scope_range()
	test_load_migrates_legacy_text_with_target_scope_line()
	test_load_does_not_migrate_text_without_target_scope()
	test_load_does_not_migrate_text_with_other_target_scope()
	test_body_view_factory_returns_control_with_text()
	test_summary_includes_comment_text()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Test 1: kind registered at host init ──────────────────────────────────────

func test_kind_registers_at_host_init() -> void:
	print("test_kind_registers_at_host_init:")
	var host := _TEAHScript.new()
	var registry := host.get_registry()
	check("registry has text_comment kind", registry.has_kind(&"text_comment"))
	var kind := registry.get_annotation_kind(&"text_comment")
	check("get_annotation_kind returns non-null", kind != null)
	if kind != null:
		check("display_name == Comment", kind.display_name == "Comment")


# ── Test 2: add_comment_at stamps text_comment ────────────────────────────────

func test_add_comment_at_stamps_text_comment() -> void:
	print("test_add_comment_at_stamps_text_comment:")
	var host := _TEAHScript.new()
	host.set_text("hello world this is test text for the annotation")
	var ann_id := host.add_comment_at(0, 5, "hello", "range")
	check("add_comment_at returns non-empty id", not ann_id.is_empty())
	if ann_id.is_empty():
		return
	var ann := host.get_by_id(ann_id)
	check("annotation kind == text_comment", ann.get("kind", "") == "text_comment")


# ── Test 3: has_visual_render returns false ───────────────────────────────────

func test_kind_has_visual_render_false() -> void:
	print("test_kind_has_visual_render_false:")
	var kind := _TextCommentScript.new()
	check("has_visual_render() == false", kind.has_visual_render() == false)


# ── Test 4: load migrates legacy text with target_scope=range ─────────────────

func test_load_migrates_legacy_text_with_target_scope_range() -> void:
	print("test_load_migrates_legacy_text_with_target_scope_range:")
	var host := _TEAHScript.new()
	var legacy := _make_legacy_envelope("ann_legacy_1", "range")
	host.load_annotations([legacy])
	var annotations := host.get_annotations()
	check("annotation loaded", annotations.size() == 1)
	if annotations.size() > 0:
		check("kind migrated to text_comment", annotations[0].get("kind", "") == "text_comment")


# ── Test 5: load migrates legacy text with target_scope=line ──────────────────

func test_load_migrates_legacy_text_with_target_scope_line() -> void:
	print("test_load_migrates_legacy_text_with_target_scope_line:")
	var host := _TEAHScript.new()
	var legacy := _make_legacy_envelope("ann_legacy_2", "line")
	host.load_annotations([legacy])
	var annotations := host.get_annotations()
	check("annotation loaded", annotations.size() == 1)
	if annotations.size() > 0:
		check("kind migrated to text_comment", annotations[0].get("kind", "") == "text_comment")


# ── Test 6: load does NOT migrate text without target_scope ───────────────────

func test_load_does_not_migrate_text_without_target_scope() -> void:
	print("test_load_does_not_migrate_text_without_target_scope:")
	var host := _TEAHScript.new()
	var envelope := _make_legacy_envelope("ann_no_scope", "")
	# Remove target_scope from kind_payload entirely
	var payload: Dictionary = envelope.get("kind_payload", {})
	payload.erase("target_scope")
	envelope["kind_payload"] = payload
	host.load_annotations([envelope])
	var annotations := host.get_annotations()
	check("annotation loaded", annotations.size() == 1)
	if annotations.size() > 0:
		check("kind stays text (no target_scope)", annotations[0].get("kind", "") == "text")


# ── Test 7: load does NOT migrate text with unrecognised target_scope ──────────

func test_load_does_not_migrate_text_with_other_target_scope() -> void:
	print("test_load_does_not_migrate_text_with_other_target_scope:")
	var host := _TEAHScript.new()
	var envelope := _make_legacy_envelope("ann_other_scope", "char")
	host.load_annotations([envelope])
	var annotations := host.get_annotations()
	check("annotation loaded", annotations.size() == 1)
	if annotations.size() > 0:
		check("kind stays text (target_scope=char)", annotations[0].get("kind", "") == "text")


# ── Test 8: body_view_factory returns Control containing comment text ──────────

func test_body_view_factory_returns_control_with_text() -> void:
	print("test_body_view_factory_returns_control_with_text:")
	var kind := _TextCommentScript.new()
	var envelope := {
		"id": "ann_bvf",
		"kind": "text_comment",
		"schema_version": 2,
		"kind_payload": {"text": "hello world", "target_scope": "range"},
		"lifecycle": "open",
		"author": {"kind": "human"},
	}
	var control: Variant = kind.body_view_factory(envelope, func(_p: Dictionary) -> void: pass)
	check("body_view_factory returns a Control", control is Control)
	if control is Control:
		var found := _find_label_containing(control as Control, "hello world")
		check("returned Control has Label with comment text", found != null)
		(control as Control).queue_free()


# ── Test 9: summary includes comment text ─────────────────────────────────────

func test_summary_includes_comment_text() -> void:
	print("test_summary_includes_comment_text:")
	var kind := _TextCommentScript.new()
	var envelope := {
		"kind_payload": {"text": "this is a test comment"},
	}
	var result := kind.summary(envelope)
	check("summary starts with display_name", result.begins_with("Comment"))
	check("summary contains comment text", "this is a test comment" in result)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_legacy_envelope(ann_id: String, target_scope: String) -> Dictionary:
	return {
		"id": ann_id,
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": 0, "end": 3},
			"snapshot": {
				"position": [0.0, 0.0],
				"text": "old",
				"document_revision": 1,
				"target_scope": target_scope,
			},
		},
		"kind_payload": {"text": "old comment", "target_scope": target_scope},
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "text",
		"visible_in_views": ["all"],
		"summary": "old comment",
		"created_at": 1700000000,
		"updated_at": 1700000000,
	}


func _find_label_containing(node: Node, text: String) -> Label:
	if node is Label and text in (node as Label).text:
		return node as Label
	for child in node.get_children():
		var found := _find_label_containing(child, text)
		if found != null:
			return found
	return null
