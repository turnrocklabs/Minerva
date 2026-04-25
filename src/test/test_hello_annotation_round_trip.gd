extends SceneTree
## Unit tests for HelloPanel annotation save/load round-trip (Unit 3).
## Run: godot --headless --script test/test_hello_annotation_round_trip.gd
##
## Coverage:
##   1. Panel-state path round-trip: annotations survive save Dict → set_annotations.
##   2. Sidecar write/read round-trip: 2 annotations written then read back unchanged.
##   3. Sidecar-wins precedence: sidecar (1 ann) beats Dict (2 different anns).
##   4. Empty annotations don't write a sidecar (zero-annotation rule, §7.5).
##   5. No sidecar + no Dict annotations → host returns [].

var _pass_count: int = 0
var _fail_count: int = 0

## Temporary directory used by all tests. Created in _init, cleaned up on quit.
var _tmp_dir: String = ""


func _init() -> void:
	_tmp_dir = _make_tmp_dir()

	print("=== Hello Annotation Round-Trip Tests ===\n")

	print("-- 1. Panel-state Dict round-trip --")
	test_panel_state_dict_round_trip()

	print("\n-- 2. Sidecar write/read round-trip --")
	test_sidecar_write_read_round_trip()

	print("\n-- 3. Sidecar-wins precedence --")
	test_sidecar_wins_over_dict()

	print("\n-- 4. Empty annotations delete sidecar --")
	test_empty_annotations_delete_sidecar()

	print("\n-- 5. No sidecar, no Dict → empty host --")
	test_no_sidecar_no_dict_empty_host()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)

	_cleanup_tmp_dir()
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

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


# ── Fixture helpers ───────────────────────────────────────────────────────────

func _make_annotation(id: String, kind: String) -> Dictionary:
	return {
		"id": id,
		"author": "human",
		"kind": kind,
		"view_context": "hello",
		"primitives": [{"kind": "arrow", "from": [0.0, 0.0], "to": [10.0, 10.0]}],
		"created_at": "2026-04-24T00:00:00Z",
	}


func _make_tmp_dir() -> String:
	var base := "user://tmp/test_hello_round_trip_%d" % int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(base)
	return base


func _doc_path(name: String) -> String:
	return _tmp_dir.path_join(name)


func _cleanup_tmp_dir() -> void:
	if _tmp_dir.is_empty():
		return
	var dir := DirAccess.open(_tmp_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(_tmp_dir.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(_tmp_dir)


# ── Tests ─────────────────────────────────────────────────────────────────────

## Test 1: annotations survive save-Dict → set_annotations round-trip.
## Simulates the project-state path (_on_panel_save_request returns a Dict
## with an "annotations" key; _on_panel_load_request feeds it to set_annotations).
func test_panel_state_dict_round_trip() -> void:
	print("test_panel_state_dict_round_trip:")
	var host := Helloscene_AnnotationHost.new()
	host._registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(host._registry)

	# Author two annotations directly.
	var ann1 := _make_annotation("ann_aabb01", "2d_arrow")
	var ann2 := _make_annotation("ann_aabb02", "2d_arrow")
	host.add_annotation(ann1)
	host.add_annotation(ann2)
	check_eq("host has 2 annotations after adds", host.get_annotations().size(), 2)

	# Simulate what _on_panel_save_request returns.
	var saved_annotations: Array = host.get_annotations()
	var panel_state := {
		"version": 1,
		"text": "hello",
		"label_text": "Hello Scene",
		"annotations": saved_annotations,
	}

	# Simulate what _on_panel_load_request does with the Dict on a fresh host.
	var fresh_host := Helloscene_AnnotationHost.new()
	fresh_host._registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(fresh_host._registry)

	var doc_anns = panel_state.get("annotations", [])
	if doc_anns is Array:
		fresh_host.set_annotations(doc_anns)

	var restored := fresh_host.get_annotations()
	check_eq("restored host has 2 annotations", restored.size(), 2)
	check_eq("first annotation id matches",
		str((restored[0] as Dictionary).get("id", "")), "ann_aabb01")
	check_eq("second annotation id matches",
		str((restored[1] as Dictionary).get("id", "")), "ann_aabb02")
	check_eq("first annotation kind preserved",
		str((restored[0] as Dictionary).get("kind", "")), "2d_arrow")


## Test 2: sidecar write/read round-trip with 2 annotations.
func test_sidecar_write_read_round_trip() -> void:
	print("test_sidecar_write_read_round_trip:")
	var doc := _doc_path("round_trip_hello.hello")
	var ann1 := _make_annotation("ann_cc0001", "2d_arrow")
	var ann2 := _make_annotation("ann_cc0002", "2d_arrow")

	var sidecar_data := {
		"substrate_version": 1,
		"document": {"path": doc, "kind": "hello"},
		"annotations": [ann1, ann2],
		"unknown_kinds": [],
	}
	var write_err := AnnotationSidecar.write_sidecar(doc, sidecar_data)
	check("write_sidecar returns OK", write_err == OK)
	check("sidecar file exists after write", AnnotationSidecar.has_sidecar(doc))

	var read_back := AnnotationSidecar.read_sidecar(doc)
	check("read_sidecar returns non-empty dict", not read_back.is_empty())
	check("read_back has annotations key", read_back.has("annotations"))

	var anns: Array = read_back.get("annotations", [])
	check_eq("round-trip: 2 annotations preserved", anns.size(), 2)
	check_eq("round-trip: first annotation id",
		str((anns[0] as Dictionary).get("id", "")), "ann_cc0001")
	check_eq("round-trip: second annotation id",
		str((anns[1] as Dictionary).get("id", "")), "ann_cc0002")
	check_eq("round-trip: substrate_version stamped",
		read_back.get("substrate_version"), AnnotationSidecar.SUBSTRATE_VERSION)

	# Cleanup
	AnnotationSidecar.delete_sidecar(doc)


## Test 3: sidecar-wins precedence rule.
## If a sidecar exists, its annotations win over whatever is in the project-state Dict.
## This test mirrors the logic in _on_panel_load_request without needing a full SceneTree.
func test_sidecar_wins_over_dict() -> void:
	print("test_sidecar_wins_over_dict:")
	var doc := _doc_path("precedence_test.hello")

	# Sidecar has 1 annotation.
	var sidecar_ann := _make_annotation("ann_sidecar_only", "2d_arrow")
	var sidecar_data := {
		"substrate_version": 1,
		"document": {"path": doc, "kind": "hello"},
		"annotations": [sidecar_ann],
		"unknown_kinds": [],
	}
	AnnotationSidecar.write_sidecar(doc, sidecar_data)

	# Project-state Dict has 2 different annotations.
	var dict_ann1 := _make_annotation("ann_dict_only_1", "2d_arrow")
	var dict_ann2 := _make_annotation("ann_dict_only_2", "2d_arrow")
	var project_state := {
		"version": 1,
		"text": "x",
		"label_text": "y",
		"annotations": [dict_ann1, dict_ann2],
	}

	# Apply the same precedence logic as _on_panel_load_request.
	var annotations_to_restore: Array = []

	var sidecar: Dictionary = AnnotationSidecar.read_sidecar(doc)
	if not sidecar.is_empty() and sidecar.has("annotations"):
		var sidecar_anns = sidecar.get("annotations", [])
		if sidecar_anns is Array:
			annotations_to_restore = sidecar_anns

	# Fall back to project-state Dict if no sidecar.
	if annotations_to_restore.is_empty():
		var doc_anns = project_state.get("annotations", [])
		if doc_anns is Array:
			annotations_to_restore = doc_anns

	# Verify sidecar won.
	check_eq("sidecar-wins: 1 annotation from sidecar", annotations_to_restore.size(), 1)
	check_eq("sidecar-wins: id is the sidecar annotation",
		str((annotations_to_restore[0] as Dictionary).get("id", "")), "ann_sidecar_only")

	# Apply to a fresh host to confirm set_annotations works too.
	var host := Helloscene_AnnotationHost.new()
	host.set_annotations(annotations_to_restore)
	check_eq("host shows 1 annotation after sidecar-wins restore",
		host.get_annotations().size(), 1)
	check_eq("host annotation id is sidecar annotation",
		str((host.get_annotations()[0] as Dictionary).get("id", "")), "ann_sidecar_only")

	# Cleanup
	AnnotationSidecar.delete_sidecar(doc)


## Test 4: write_sidecar with empty annotations deletes the sidecar (§7.5 zero-annotation rule).
## This also validates the guard in _on_panel_save_request — if annotations is empty,
## we skip the write (equivalent to the zero-annotation rule doing the deletion).
func test_empty_annotations_delete_sidecar() -> void:
	print("test_empty_annotations_delete_sidecar:")
	var doc := _doc_path("empty_anns_test.hello")

	# First write a non-empty sidecar.
	var ann := _make_annotation("ann_temp", "2d_arrow")
	var sidecar_data := {
		"substrate_version": 1,
		"document": {"path": doc, "kind": "hello"},
		"annotations": [ann],
		"unknown_kinds": [],
	}
	AnnotationSidecar.write_sidecar(doc, sidecar_data)
	check("sidecar exists before empty write", AnnotationSidecar.has_sidecar(doc))

	# Now write with empty annotations — should delete the sidecar.
	var empty_data := {
		"substrate_version": 1,
		"document": {"path": doc, "kind": "hello"},
		"annotations": [],
		"unknown_kinds": [],
	}
	var err := AnnotationSidecar.write_sidecar(doc, empty_data)
	check("write_sidecar with [] returns OK", err == OK)
	check("sidecar deleted after empty-annotations write",
		not AnnotationSidecar.has_sidecar(doc))


## Test 5: no sidecar present, no Dict annotations → host.get_annotations() returns [].
func test_no_sidecar_no_dict_empty_host() -> void:
	print("test_no_sidecar_no_dict_empty_host:")
	var doc := _doc_path("absent_all.hello")
	# Confirm no sidecar exists.
	check("no sidecar for test path", not AnnotationSidecar.has_sidecar(doc))

	# Simulate _on_panel_load_request: sidecar absent, Dict has no annotations key.
	var project_state: Dictionary = {"version": 1, "text": "", "label_text": ""}

	var annotations_to_restore: Array = []

	var sidecar: Dictionary = AnnotationSidecar.read_sidecar(doc)
	if not sidecar.is_empty() and sidecar.has("annotations"):
		var sidecar_anns = sidecar.get("annotations", [])
		if sidecar_anns is Array:
			annotations_to_restore = sidecar_anns

	if annotations_to_restore.is_empty():
		var doc_anns = project_state.get("annotations", [])
		if doc_anns is Array:
			annotations_to_restore = doc_anns

	var host := Helloscene_AnnotationHost.new()
	host.set_annotations(annotations_to_restore)

	check_eq("empty host after no-sidecar + no-dict restore",
		host.get_annotations().size(), 0)
