extends SceneTree

const AnnotationSidebarModelScript = preload("res://Scripts/Services/Annotations/AnnotationSidebarModel.gd")
const AnnotationAnchorRegistryScript = preload("res://Scripts/Services/Annotations/AnnotationAnchorRegistry.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_broken_anchor_sidebar ===\n")
	test_sidebar_broken_section_visible_when_stale_annotations_exist()
	test_sidebar_broken_section_hidden_when_no_stale_annotations()
	test_sidebar_broken_section_count_matches_stale_annotations()
	test_sidebar_broken_entry_shows_summary()
	test_sidebar_broken_entry_shows_last_known_view()
	test_sidebar_broken_entry_has_repair_button()
	test_sidebar_repair_button_calls_registry_repair()
	test_sidebar_repair_null_return_opens_retarget_picker()
	test_sidebar_repair_non_null_return_updates_annotation()
	test_sidebar_filter_pill_show_broken_only_toggle_exists()
	test_sidebar_filter_pill_filters_to_stale_only()
	test_sidebar_filter_pill_toggle_off_shows_all()
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


func _make_annotation(id: String, lifecycle: String) -> Dictionary:
	return {
		"id": id,
		"kind": "text",
		"schema_version": 2,
		"anchor": {"plugin": "core", "type": "text.range", "id": {"start": 0, "end": 10}, "snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"text": "comment"},
		"lifecycle": lifecycle,
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Text comment id=%s" % id,
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
	}


func test_sidebar_broken_section_visible_when_stale_annotations_exist() -> void:
	var model := AnnotationSidebarModelScript.new()
	model.set_annotations([_make_annotation("ann_001", "open"), _make_annotation("ann_002", "stale")])
	check("broken section visible when stale annotations present", model.is_broken_section_visible())


func test_sidebar_broken_section_hidden_when_no_stale_annotations() -> void:
	var model := AnnotationSidebarModelScript.new()
	model.set_annotations([_make_annotation("ann_001", "open"), _make_annotation("ann_002", "applied")])
	check("broken section hidden when no stale annotations", not model.is_broken_section_visible())


func test_sidebar_broken_section_count_matches_stale_annotations() -> void:
	var model := AnnotationSidebarModelScript.new()
	model.set_annotations([_make_annotation("ann_001", "stale"), _make_annotation("ann_002", "stale"), _make_annotation("ann_003", "open")])
	check("broken count = 2", model.get_broken_count() == 2)


func test_sidebar_broken_entry_shows_summary() -> void:
	var model := AnnotationSidebarModelScript.new()
	var ann := _make_annotation("ann_stale", "stale")
	ann["summary"] = "Important broken comment"
	model.set_annotations([ann])
	var entries := model.get_broken_entries()
	check("broken entry has at least one entry", entries.size() > 0)
	if entries.size() > 0:
		check("broken entry shows summary", entries[0].get("summary", "") == "Important broken comment")


func test_sidebar_broken_entry_shows_last_known_view() -> void:
	var model := AnnotationSidebarModelScript.new()
	var ann := _make_annotation("ann_stale", "stale")
	ann["view_context"] = "editor:side"
	model.set_annotations([ann])
	var entries := model.get_broken_entries()
	check("broken entries present", entries.size() > 0)
	if entries.size() > 0:
		check("broken entry shows view_context as last known view", entries[0].get("last_view", "") == "editor:side")


func test_sidebar_broken_entry_has_repair_button() -> void:
	var model := AnnotationSidebarModelScript.new()
	model.set_annotations([_make_annotation("ann_stale", "stale")])
	var entries := model.get_broken_entries()
	check("broken entries present", entries.size() > 0)
	if entries.size() > 0:
		check("broken entry has repair_available flag", entries[0].get("repair_available", false))


func test_sidebar_repair_button_calls_registry_repair() -> void:
	var repair_called := [false]
	var registry := AnnotationAnchorRegistryScript.new()
	registry.register("core", "text.range", _RecordingRepairResolver.new(repair_called))
	var model := AnnotationSidebarModelScript.new()
	model.set_anchor_registry(registry)
	model.set_annotations([_make_annotation("ann_stale", "stale")])
	model.trigger_repair("ann_stale")
	check("repair button triggers registry repair()", repair_called[0])


func test_sidebar_repair_null_return_opens_retarget_picker() -> void:
	var picker_opened := [false]
	var registry := AnnotationAnchorRegistryScript.new()
	registry.register("core", "text.range", _NullRepairResolver.new())
	var model := AnnotationSidebarModelScript.new()
	model.retarget_picker_requested.connect(func(_id): picker_opened[0] = true)
	model.set_anchor_registry(registry)
	model.set_annotations([_make_annotation("ann_stale", "stale")])
	model.trigger_repair("ann_stale")
	check("null repair return opens retarget picker", picker_opened[0])


func test_sidebar_repair_non_null_return_updates_annotation() -> void:
	var updated_id := [""]
	var new_anchor := {"plugin": "core", "type": "text.range", "id": {"start": 100, "end": 120}, "snapshot": {"position": [10.0, 20.0]}}
	var registry := AnnotationAnchorRegistryScript.new()
	registry.register("core", "text.range", _FixedRepairResolver.new(new_anchor))
	var model := AnnotationSidebarModelScript.new()
	model.annotation_repaired.connect(func(id, _new_anchor): updated_id[0] = id)
	model.set_anchor_registry(registry)
	model.set_annotations([_make_annotation("ann_stale", "stale")])
	model.trigger_repair("ann_stale")
	check("non-null repair emits annotation_repaired signal", updated_id[0] == "ann_stale")
	check("repaired annotation leaves broken filter", model.get_broken_count() == 0)


func test_sidebar_filter_pill_show_broken_only_toggle_exists() -> void:
	check("AnnotationSidebarModel has set_show_broken_only method", AnnotationSidebarModelScript.new().has_method("set_show_broken_only"))


func test_sidebar_filter_pill_filters_to_stale_only() -> void:
	var model := AnnotationSidebarModelScript.new()
	model.set_annotations([_make_annotation("ann_open", "open"), _make_annotation("ann_stale", "stale"), _make_annotation("ann_applied", "applied")])
	model.set_show_broken_only(true)
	var visible := model.get_visible_annotations()
	check("show_broken_only=true only stale annotations visible", visible.size() == 1)
	if visible.size() == 1:
		check("visible annotation is the stale one", visible[0].get("id", "") == "ann_stale")


func test_sidebar_filter_pill_toggle_off_shows_all() -> void:
	var model := AnnotationSidebarModelScript.new()
	model.set_annotations([_make_annotation("ann_open", "open"), _make_annotation("ann_stale", "stale"), _make_annotation("ann_applied", "applied")])
	model.set_show_broken_only(true)
	model.set_show_broken_only(false)
	check("show_broken_only=false all annotations visible", model.get_visible_annotations().size() == 3)


class _RecordingRepairResolver extends RefCounted:
	var _called_arr: Array
	func _init(arr: Array) -> void: _called_arr = arr
	func validate(_anchor: Dictionary) -> Array: return []
	func summary(_anchor: Dictionary, _host: Object) -> String: return "test"
	func repair(_anchor: Dictionary, _host: Object) -> Variant:
		_called_arr[0] = true
		return null


class _NullRepairResolver extends RefCounted:
	func validate(_anchor: Dictionary) -> Array: return []
	func summary(_anchor: Dictionary, _host: Object) -> String: return "test"
	func repair(_anchor: Dictionary, _host: Object) -> Variant: return null


class _FixedRepairResolver extends RefCounted:
	var _new_anchor: Dictionary
	func _init(new_anchor: Dictionary) -> void: _new_anchor = new_anchor
	func validate(_anchor: Dictionary) -> Array: return []
	func summary(_anchor: Dictionary, _host: Object) -> String: return "test"
	func repair(_anchor: Dictionary, _host: Object) -> Variant: return _new_anchor
