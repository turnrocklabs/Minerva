extends SceneTree
## Contract tests for broken/stale anchor sidebar UX (task #4).
## Run: godot --headless --path src --script test/annotations_v2/test_broken_anchor_sidebar.gd
##
## RED in Round 1 — AnnotationSidebarModel v2 does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_broken_anchor_sidebar ===\n")

	print("-- sidebar: class existence --")
	test_sidebar_model_class_exists()

	print("\n-- sidebar: broken section visibility --")
	test_sidebar_broken_section_visible_when_stale_annotations_exist()
	test_sidebar_broken_section_hidden_when_no_stale_annotations()
	test_sidebar_broken_section_count_matches_stale_annotations()

	print("\n-- sidebar: broken entry content --")
	test_sidebar_broken_entry_shows_summary()
	test_sidebar_broken_entry_shows_last_known_view()
	test_sidebar_broken_entry_has_repair_button()

	print("\n-- sidebar: repair button dispatch --")
	test_sidebar_repair_button_calls_registry_repair()
	test_sidebar_repair_null_return_opens_retarget_picker()
	test_sidebar_repair_non_null_return_updates_annotation()

	print("\n-- sidebar: filter pill --")
	test_sidebar_filter_pill_show_broken_only_toggle_exists()
	test_sidebar_filter_pill_filters_to_stale_only()
	test_sidebar_filter_pill_toggle_off_shows_all()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _make_annotation(id: String, lifecycle: String) -> Dictionary:
	return {
		"id": id,
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": 0, "end": 10},
			"snapshot": {"position": [0.0, 0.0], "text": "sample", "document_revision": 1}
		},
		"kind_payload": {"text": "comment"},
		"lifecycle": lifecycle,
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Text comment id=%s" % id,
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z"
	}


func _make_model() -> Variant:
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		return null
	return ClassDB.instantiate("AnnotationSidebarModel")


func _make_registry() -> Variant:
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		return null
	return ClassDB.instantiate("AnnotationAnchorRegistry")


# ── Class existence ───────────────────────────────────────────────────────────

func test_sidebar_model_class_exists() -> void:
	print("test_sidebar_model_class_exists:")
	check("AnnotationSidebarModel class exists",
		ClassDB.class_exists("AnnotationSidebarModel"))


# ── Broken section visibility tests ──────────────────────────────────────────

func test_sidebar_broken_section_visible_when_stale_annotations_exist() -> void:
	print("test_sidebar_broken_section_visible_when_stale_annotations_exist:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	var model = _make_model()
	if model == null or not model.has_method("set_annotations") or not model.has_method("is_broken_section_visible"):
		check("AnnotationSidebarModel instantiable with required methods", false)
		return
	model.set_annotations([
		_make_annotation("ann_001", "open"),
		_make_annotation("ann_002", "stale")
	])
	check("broken section visible when stale annotations present",
		model.is_broken_section_visible())


func test_sidebar_broken_section_hidden_when_no_stale_annotations() -> void:
	print("test_sidebar_broken_section_hidden_when_no_stale_annotations:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	var model = _make_model()
	if model == null or not model.has_method("set_annotations") or not model.has_method("is_broken_section_visible"):
		check("AnnotationSidebarModel instantiable with required methods", false)
		return
	model.set_annotations([
		_make_annotation("ann_001", "open"),
		_make_annotation("ann_002", "applied")
	])
	check("broken section hidden when no stale annotations",
		not model.is_broken_section_visible())


func test_sidebar_broken_section_count_matches_stale_annotations() -> void:
	print("test_sidebar_broken_section_count_matches_stale_annotations:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	var model = _make_model()
	if model == null or not model.has_method("set_annotations") or not model.has_method("get_broken_count"):
		check("AnnotationSidebarModel instantiable with required methods", false)
		return
	model.set_annotations([
		_make_annotation("ann_001", "stale"),
		_make_annotation("ann_002", "stale"),
		_make_annotation("ann_003", "open")
	])
	check("broken count = 2", model.get_broken_count() == 2)


# ── Broken entry content tests ────────────────────────────────────────────────

func test_sidebar_broken_entry_shows_summary() -> void:
	print("test_sidebar_broken_entry_shows_summary:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	var model = _make_model()
	if model == null or not model.has_method("set_annotations") or not model.has_method("get_broken_entries"):
		check("AnnotationSidebarModel instantiable with required methods", false)
		return
	var ann = _make_annotation("ann_stale", "stale")
	ann["summary"] = "Important broken comment"
	model.set_annotations([ann])
	var entries = model.get_broken_entries()
	check("broken entry has at least one entry", entries.size() > 0)
	if entries.size() > 0:
		check("broken entry shows summary",
			entries[0].get("summary", "") == "Important broken comment")


func test_sidebar_broken_entry_shows_last_known_view() -> void:
	print("test_sidebar_broken_entry_shows_last_known_view:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	var model = _make_model()
	if model == null or not model.has_method("set_annotations") or not model.has_method("get_broken_entries"):
		check("AnnotationSidebarModel instantiable with required methods", false)
		return
	var ann = _make_annotation("ann_stale", "stale")
	ann["view_context"] = "editor:side"
	model.set_annotations([ann])
	var entries = model.get_broken_entries()
	if entries.size() > 0:
		check("broken entry shows view_context as last known view",
			entries[0].get("last_view", "") == "editor:side")
	else:
		check("broken entries present", false)


func test_sidebar_broken_entry_has_repair_button() -> void:
	print("test_sidebar_broken_entry_has_repair_button:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	var model = _make_model()
	if model == null or not model.has_method("set_annotations") or not model.has_method("get_broken_entries"):
		check("AnnotationSidebarModel instantiable with required methods", false)
		return
	model.set_annotations([_make_annotation("ann_stale", "stale")])
	var entries = model.get_broken_entries()
	if entries.size() > 0:
		check("broken entry has repair_available flag",
			entries[0].get("repair_available", false) == true)
	else:
		check("broken entries present", false)


# ── Repair dispatch tests ─────────────────────────────────────────────────────

func test_sidebar_repair_button_calls_registry_repair() -> void:
	print("test_sidebar_repair_button_calls_registry_repair:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var repair_called := [false]
	var mock_registry = _make_registry()
	if mock_registry == null or not mock_registry.has_method("register"):
		check("AnnotationAnchorRegistry instantiable", false)
		return
	var resolver = _RecordingRepairResolver.new(repair_called)
	mock_registry.register("core", "text.range", resolver)
	var model = _make_model()
	if model == null or not model.has_method("set_anchor_registry") or not model.has_method("set_annotations") or not model.has_method("trigger_repair"):
		check("AnnotationSidebarModel instantiable with required methods", false)
		return
	model.set_anchor_registry(mock_registry)
	model.set_annotations([_make_annotation("ann_stale", "stale")])
	model.trigger_repair("ann_stale")
	check("repair button triggers registry repair()", repair_called[0])


func test_sidebar_repair_null_return_opens_retarget_picker() -> void:
	print("test_sidebar_repair_null_return_opens_retarget_picker:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var picker_opened := [false]
	var model = _make_model()
	if model == null:
		check("AnnotationSidebarModel instantiable", false)
		return
	if not model.has_method("set_anchor_registry") or not model.has_method("set_annotations") or not model.has_method("trigger_repair"):
		check("AnnotationSidebarModel has required methods", false)
		return
	model.retarget_picker_requested.connect(func(_id): picker_opened[0] = true)
	var mock_registry = _make_registry()
	if mock_registry == null:
		check("AnnotationAnchorRegistry instantiable", false)
		return
	mock_registry.register("core", "text.range", _NullRepairResolver.new())
	model.set_anchor_registry(mock_registry)
	model.set_annotations([_make_annotation("ann_stale", "stale")])
	model.trigger_repair("ann_stale")
	check("null repair return opens retarget picker", picker_opened[0])


func test_sidebar_repair_non_null_return_updates_annotation() -> void:
	print("test_sidebar_repair_non_null_return_updates_annotation:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	if not ClassDB.class_exists("AnnotationAnchorRegistry"):
		check("AnnotationAnchorRegistry exists", false)
		return
	var updated_id := [""]
	var model = _make_model()
	if model == null:
		check("AnnotationSidebarModel instantiable", false)
		return
	if not model.has_method("set_anchor_registry") or not model.has_method("set_annotations") or not model.has_method("trigger_repair"):
		check("AnnotationSidebarModel has required methods", false)
		return
	model.annotation_repaired.connect(func(id, _new_anchor): updated_id[0] = id)
	var new_anchor := {
		"plugin": "core", "type": "text.range",
		"id": {"start": 100, "end": 120},
		"snapshot": {"position": [10.0, 20.0], "text": "new text", "document_revision": 5}
	}
	var mock_registry = _make_registry()
	if mock_registry == null:
		check("AnnotationAnchorRegistry instantiable", false)
		return
	mock_registry.register("core", "text.range", _FixedRepairResolver.new(new_anchor))
	model.set_anchor_registry(mock_registry)
	model.set_annotations([_make_annotation("ann_stale", "stale")])
	model.trigger_repair("ann_stale")
	check("non-null repair emits annotation_repaired signal", updated_id[0] == "ann_stale")


# ── Filter pill tests ─────────────────────────────────────────────────────────

func test_sidebar_filter_pill_show_broken_only_toggle_exists() -> void:
	print("test_sidebar_filter_pill_show_broken_only_toggle_exists:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	var model = _make_model()
	if model == null:
		check("AnnotationSidebarModel instantiable", false)
		return
	check("AnnotationSidebarModel has set_show_broken_only method",
		model.has_method("set_show_broken_only"))


func test_sidebar_filter_pill_filters_to_stale_only() -> void:
	print("test_sidebar_filter_pill_filters_to_stale_only:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	var model = _make_model()
	if model == null or not model.has_method("set_annotations") or not model.has_method("set_show_broken_only") or not model.has_method("get_visible_annotations"):
		check("AnnotationSidebarModel instantiable with required methods", false)
		return
	model.set_annotations([
		_make_annotation("ann_open", "open"),
		_make_annotation("ann_stale", "stale"),
		_make_annotation("ann_applied", "applied")
	])
	model.set_show_broken_only(true)
	var visible = model.get_visible_annotations()
	check("show_broken_only=true → only stale annotations visible", visible.size() == 1)
	if visible.size() == 1:
		check("visible annotation is the stale one", visible[0].get("id", "") == "ann_stale")


func test_sidebar_filter_pill_toggle_off_shows_all() -> void:
	print("test_sidebar_filter_pill_toggle_off_shows_all:")
	if not ClassDB.class_exists("AnnotationSidebarModel"):
		check("AnnotationSidebarModel exists", false)
		return
	var model = _make_model()
	if model == null or not model.has_method("set_annotations") or not model.has_method("set_show_broken_only") or not model.has_method("get_visible_annotations"):
		check("AnnotationSidebarModel instantiable with required methods", false)
		return
	model.set_annotations([
		_make_annotation("ann_open", "open"),
		_make_annotation("ann_stale", "stale"),
		_make_annotation("ann_applied", "applied")
	])
	model.set_show_broken_only(true)
	model.set_show_broken_only(false)
	var visible = model.get_visible_annotations()
	check("show_broken_only=false → all 3 annotations visible", visible.size() == 3)


# ── Mock helpers ──────────────────────────────────────────────────────────────

class _RecordingRepairResolver extends RefCounted:
	var _called_arr: Array

	func _init(arr: Array) -> void:
		_called_arr = arr

	func validate(_anchor: Dictionary) -> Array: return []
	func summary(_anchor: Dictionary, _host) -> String: return "test"
	func repair(_anchor: Dictionary, _host) -> Variant:
		_called_arr[0] = true
		return null


class _NullRepairResolver extends RefCounted:
	func validate(_anchor: Dictionary) -> Array: return []
	func summary(_anchor: Dictionary, _host) -> String: return "test"
	func repair(_anchor: Dictionary, _host) -> Variant: return null


class _FixedRepairResolver extends RefCounted:
	var _new_anchor: Dictionary

	func _init(new_anchor: Dictionary) -> void:
		_new_anchor = new_anchor

	func validate(_anchor: Dictionary) -> Array: return []
	func summary(_anchor: Dictionary, _host) -> String: return "test"
	func repair(_anchor: Dictionary, _host) -> Variant: return _new_anchor
