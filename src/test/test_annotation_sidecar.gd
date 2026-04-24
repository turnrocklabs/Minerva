extends SceneTree
## Unit tests for AnnotationSidecar.
## Run: godot --headless --script test/test_annotation_sidecar.gd
##
## Coverage:
##   sidecar_path_for
##     - Appends .annotations.json to full filename (double extension)
##     - Works for paths with no directory component
##     - Works for paths with multiple extensions (foo.tar.gz)
##
##   resolve_relative_path
##     - Relative path resolves against sidecar directory
##     - Absolute path returned unchanged
##
##   make_relative
##     - Path inside sidecar dir → relative form
##     - Path outside sidecar dir → returned unchanged
##     - Inverse round-trip: make_relative ∘ resolve_relative_path = identity
##
##   has_sidecar / delete_sidecar
##     - has_sidecar false for non-existent file
##     - has_sidecar true after writing a sidecar
##     - delete_sidecar removes the file; has_sidecar returns false after delete
##     - delete_sidecar on non-existent returns OK (idempotent)
##
##   write_sidecar
##     - Empty annotations[] deletes rather than writes
##     - Missing annotations key treated as empty → delete
##     - Non-empty annotations[] produces a file on disk
##     - Written file is valid JSON and round-trips substrate_version
##     - substrate_version is always stamped to SUBSTRATE_VERSION regardless of input
##     - Write to non-existent directory returns an error (not a crash)
##
##   read_sidecar
##     - Non-existent sidecar → empty Dictionary
##     - Corrupt JSON → empty Dictionary + backup file created
##     - Corrupt structure (missing annotations array) → empty Dictionary + backup
##     - Valid sidecar round-trips annotations array, document, unknown_kinds
##     - Unknown top-level fields are preserved on round-trip
##
##   write→read round-trip
##     - Annotations survive a full write→read cycle unchanged

var _pass_count: int = 0
var _fail_count: int = 0

## Temporary directory used by all tests.  Created in _init, cleaned up in quit().
var _tmp_dir: String = ""


func _init() -> void:
	_tmp_dir = _make_tmp_dir()

	print("=== AnnotationSidecar Tests ===\n")

	print("-- sidecar_path_for --")
	test_sidecar_path_full_extension()
	test_sidecar_path_no_directory()
	test_sidecar_path_multi_extension()

	print("\n-- resolve_relative_path --")
	test_resolve_relative_joins_sidecar_dir()
	test_resolve_absolute_unchanged()

	print("\n-- make_relative --")
	test_make_relative_inside_dir()
	test_make_relative_outside_dir_unchanged()
	test_make_relative_round_trip()

	print("\n-- has_sidecar / delete_sidecar --")
	test_has_sidecar_false_when_absent()
	test_has_sidecar_true_after_write()
	test_delete_sidecar_removes_file()
	test_delete_sidecar_idempotent()

	print("\n-- write_sidecar --")
	test_write_empty_annotations_deletes()
	test_write_missing_annotations_key_deletes()
	test_write_nonempty_creates_file()
	test_write_stamps_substrate_version()
	test_write_overrides_wrong_substrate_version()
	test_write_bad_dir_returns_error()

	print("\n-- read_sidecar --")
	test_read_absent_returns_empty()
	test_read_corrupt_json_returns_empty_and_backups()
	test_read_corrupt_structure_returns_empty_and_backups()
	test_read_valid_sidecar_returns_data()
	test_read_preserves_unknown_top_level_fields()

	print("\n-- write → read round-trip --")
	test_round_trip_annotations_unchanged()

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

## Returns a minimal valid sidecar data dict with the given annotations array.
func _sidecar_data(annotations: Array = []) -> Dictionary:
	return {
		"substrate_version": AnnotationSidecar.SUBSTRATE_VERSION,
		"document": {"path": "board.minpcb", "kind": "minpcb"},
		"annotations": annotations,
		"unknown_kinds": [],
	}


## Returns a minimal valid annotation dict.
func _valid_annotation() -> Dictionary:
	return {
		"id": "ann_aabbcc",
		"author": "human",
		"kind": "2d_arrow",
		"view_context": "pcb",
		"primitives": [{"kind": "arrow", "from": [0.0, 0.0], "to": [10.0, 10.0]}],
		"created_at": "2026-04-23T14:22:01Z",
	}


## Returns a document path inside the shared tmp dir.
func _doc_path(name: String) -> String:
	return _tmp_dir.path_join(name)


## Creates a temp directory under user://tmp/ and returns its absolute path.
func _make_tmp_dir() -> String:
	var base := "user://tmp/test_annotation_sidecar_%d" % int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(base)
	# Convert user:// path to the absolute OS path so FileAccess.file_exists works
	# consistently with DirAccess.rename_absolute (which also accepts user:// URIs).
	# We keep user:// throughout — Godot resolves it uniformly.
	return base


## Deletes the temp directory tree created by _make_tmp_dir().
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


## Writes raw text directly to a path (bypasses AnnotationSidecar — for injecting corrupt files).
func _write_raw(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("test helper _write_raw: cannot open %s" % path)
		return
	f.store_string(text)
	f.close()


# ── sidecar_path_for ──────────────────────────────────────────────────────────

func test_sidecar_path_full_extension() -> void:
	print("test_sidecar_path_full_extension:")
	var sp := AnnotationSidecar.sidecar_path_for("/some/dir/board.minpcb")
	check_eq(
		"double-extension sidecar path",
		sp,
		"/some/dir/board.minpcb.annotations.json"
	)


func test_sidecar_path_no_directory() -> void:
	print("test_sidecar_path_no_directory:")
	var sp := AnnotationSidecar.sidecar_path_for("board.minpcb")
	check_eq("no-dir sidecar path", sp, "board.minpcb.annotations.json")


func test_sidecar_path_multi_extension() -> void:
	print("test_sidecar_path_multi_extension:")
	var sp := AnnotationSidecar.sidecar_path_for("/data/archive.tar.gz")
	check_eq(
		"multi-extension file appends .annotations.json",
		sp,
		"/data/archive.tar.gz.annotations.json"
	)


# ── resolve_relative_path ─────────────────────────────────────────────────────

func test_resolve_relative_joins_sidecar_dir() -> void:
	print("test_resolve_relative_joins_sidecar_dir:")
	var resolved := AnnotationSidecar.resolve_relative_path(
		"/home/user/boards/board.minpcb",
		"textures/label.png"
	)
	check_eq(
		"relative path resolves against sidecar dir",
		resolved,
		"/home/user/boards/textures/label.png"
	)


func test_resolve_absolute_unchanged() -> void:
	print("test_resolve_absolute_unchanged:")
	var abs_path := "/absolute/other/file.png"
	var resolved := AnnotationSidecar.resolve_relative_path(
		"/home/user/boards/board.minpcb",
		abs_path
	)
	check_eq("absolute path is returned unchanged", resolved, abs_path)


# ── make_relative ─────────────────────────────────────────────────────────────

func test_make_relative_inside_dir() -> void:
	print("test_make_relative_inside_dir:")
	var rel := AnnotationSidecar.make_relative(
		"/home/user/boards/board.minpcb",
		"/home/user/boards/textures/label.png"
	)
	check_eq("path inside sidecar dir → relative", rel, "textures/label.png")


func test_make_relative_outside_dir_unchanged() -> void:
	print("test_make_relative_outside_dir_unchanged:")
	var outside := "/other/volume/file.png"
	var rel := AnnotationSidecar.make_relative(
		"/home/user/boards/board.minpcb",
		outside
	)
	check_eq("path outside sidecar dir → returned unchanged", rel, outside)


func test_make_relative_round_trip() -> void:
	print("test_make_relative_round_trip:")
	var doc := "/home/user/boards/board.minpcb"
	var original_relative := "textures/label.png"
	# resolve then make_relative should recover the original relative string
	var abs_form := AnnotationSidecar.resolve_relative_path(doc, original_relative)
	var recovered := AnnotationSidecar.make_relative(doc, abs_form)
	check_eq("round-trip: make_relative(resolve(x)) == x", recovered, original_relative)


# ── has_sidecar / delete_sidecar ──────────────────────────────────────────────

func test_has_sidecar_false_when_absent() -> void:
	print("test_has_sidecar_false_when_absent:")
	var doc := _doc_path("absent_doc.minpcb")
	check("has_sidecar returns false for non-existent file", not AnnotationSidecar.has_sidecar(doc))


func test_has_sidecar_true_after_write() -> void:
	print("test_has_sidecar_true_after_write:")
	var doc := _doc_path("present_doc.minpcb")
	var data := _sidecar_data([_valid_annotation()])
	var err := AnnotationSidecar.write_sidecar(doc, data)
	check("write_sidecar returns OK", err == OK)
	check("has_sidecar true after write", AnnotationSidecar.has_sidecar(doc))
	# Cleanup
	AnnotationSidecar.delete_sidecar(doc)


func test_delete_sidecar_removes_file() -> void:
	print("test_delete_sidecar_removes_file:")
	var doc := _doc_path("to_delete.minpcb")
	AnnotationSidecar.write_sidecar(doc, _sidecar_data([_valid_annotation()]))
	check("has_sidecar true before delete", AnnotationSidecar.has_sidecar(doc))
	var err := AnnotationSidecar.delete_sidecar(doc)
	check("delete_sidecar returns OK", err == OK)
	check("has_sidecar false after delete", not AnnotationSidecar.has_sidecar(doc))


func test_delete_sidecar_idempotent() -> void:
	print("test_delete_sidecar_idempotent:")
	var doc := _doc_path("idempotent_delete.minpcb")
	# No sidecar written — delete should still return OK.
	var err := AnnotationSidecar.delete_sidecar(doc)
	check("delete_sidecar on non-existent returns OK", err == OK)


# ── write_sidecar ─────────────────────────────────────────────────────────────

func test_write_empty_annotations_deletes() -> void:
	print("test_write_empty_annotations_deletes:")
	var doc := _doc_path("empty_anns.minpcb")
	# First write a non-empty sidecar so we have something to delete.
	AnnotationSidecar.write_sidecar(doc, _sidecar_data([_valid_annotation()]))
	check("sidecar exists before empty write", AnnotationSidecar.has_sidecar(doc))
	# Now write with empty annotations.
	var err := AnnotationSidecar.write_sidecar(doc, _sidecar_data([]))
	check("write_sidecar with empty annotations returns OK", err == OK)
	check("sidecar deleted after empty-annotations write", not AnnotationSidecar.has_sidecar(doc))


func test_write_missing_annotations_key_deletes() -> void:
	print("test_write_missing_annotations_key_deletes:")
	var doc := _doc_path("no_annotations_key.minpcb")
	AnnotationSidecar.write_sidecar(doc, _sidecar_data([_valid_annotation()]))
	# Data dict with no 'annotations' key at all.
	var data := {"substrate_version": 1, "document": {"path": "x.minpcb", "kind": "minpcb"}}
	var err := AnnotationSidecar.write_sidecar(doc, data)
	check("write without annotations key returns OK", err == OK)
	check("sidecar deleted when annotations key absent", not AnnotationSidecar.has_sidecar(doc))


func test_write_nonempty_creates_file() -> void:
	print("test_write_nonempty_creates_file:")
	var doc := _doc_path("nonempty_write.minpcb")
	var err := AnnotationSidecar.write_sidecar(doc, _sidecar_data([_valid_annotation()]))
	check("write returns OK", err == OK)
	check("sidecar file exists after write", AnnotationSidecar.has_sidecar(doc))
	# Cleanup
	AnnotationSidecar.delete_sidecar(doc)


func test_write_stamps_substrate_version() -> void:
	print("test_write_stamps_substrate_version:")
	var doc := _doc_path("stamp_version.minpcb")
	var data := _sidecar_data([_valid_annotation()])
	AnnotationSidecar.write_sidecar(doc, data)
	var read_back := AnnotationSidecar.read_sidecar(doc)
	check_eq(
		"substrate_version stamped to SUBSTRATE_VERSION",
		read_back.get("substrate_version"),
		AnnotationSidecar.SUBSTRATE_VERSION
	)
	AnnotationSidecar.delete_sidecar(doc)


func test_write_overrides_wrong_substrate_version() -> void:
	print("test_write_overrides_wrong_substrate_version:")
	var doc := _doc_path("override_version.minpcb")
	var data := _sidecar_data([_valid_annotation()])
	data["substrate_version"] = 999  # deliberately wrong
	AnnotationSidecar.write_sidecar(doc, data)
	var read_back := AnnotationSidecar.read_sidecar(doc)
	check_eq(
		"caller-supplied substrate_version overridden by SUBSTRATE_VERSION",
		read_back.get("substrate_version"),
		AnnotationSidecar.SUBSTRATE_VERSION
	)
	AnnotationSidecar.delete_sidecar(doc)


func test_write_bad_dir_returns_error() -> void:
	print("test_write_bad_dir_returns_error:")
	# A path under a directory that definitely does not exist.
	var doc := "/nonexistent_root_dir_minerva_test/subdir/board.minpcb"
	var err := AnnotationSidecar.write_sidecar(doc, _sidecar_data([_valid_annotation()]))
	check("write to non-existent directory returns non-OK error", err != OK)


# ── read_sidecar ──────────────────────────────────────────────────────────────

func test_read_absent_returns_empty() -> void:
	print("test_read_absent_returns_empty:")
	var doc := _doc_path("absent_read.minpcb")
	var result := AnnotationSidecar.read_sidecar(doc)
	check("read absent sidecar → empty dict", result.is_empty())


func test_read_corrupt_json_returns_empty_and_backups() -> void:
	print("test_read_corrupt_json_returns_empty_and_backups:")
	var doc := _doc_path("corrupt_json.minpcb")
	var sp := AnnotationSidecar.sidecar_path_for(doc)
	_write_raw(sp, "{ this is not valid JSON }")
	var result := AnnotationSidecar.read_sidecar(doc)
	check("corrupt JSON → empty dict returned", result.is_empty())
	# The original sidecar path should no longer exist (backed up).
	check("corrupt JSON → original sidecar renamed away", not FileAccess.file_exists(sp))


func test_read_corrupt_structure_returns_empty_and_backups() -> void:
	print("test_read_corrupt_structure_returns_empty_and_backups:")
	var doc := _doc_path("corrupt_struct.minpcb")
	var sp := AnnotationSidecar.sidecar_path_for(doc)
	# Valid JSON but missing the required 'annotations' array.
	_write_raw(sp, JSON.stringify({"substrate_version": 1, "document": {"path": "x"}}))
	var result := AnnotationSidecar.read_sidecar(doc)
	check("missing annotations → empty dict returned", result.is_empty())
	check("missing annotations → original sidecar renamed away", not FileAccess.file_exists(sp))


func test_read_valid_sidecar_returns_data() -> void:
	print("test_read_valid_sidecar_returns_data:")
	var doc := _doc_path("valid_read.minpcb")
	var ann := _valid_annotation()
	var data := _sidecar_data([ann])
	AnnotationSidecar.write_sidecar(doc, data)

	var result := AnnotationSidecar.read_sidecar(doc)
	check("read returns non-empty dict", not result.is_empty())
	check("annotations array present", result.has("annotations"))
	var anns: Array = result.get("annotations", [])
	check("annotations array has 1 entry", anns.size() == 1)
	check_eq("annotation id preserved", anns[0].get("id"), ann["id"])
	check_eq("annotation kind preserved", anns[0].get("kind"), ann["kind"])
	check("document key present", result.has("document"))
	check("unknown_kinds key present", result.has("unknown_kinds"))
	AnnotationSidecar.delete_sidecar(doc)


func test_read_preserves_unknown_top_level_fields() -> void:
	print("test_read_preserves_unknown_top_level_fields:")
	var doc := _doc_path("unknown_fields.minpcb")
	var data := _sidecar_data([_valid_annotation()])
	data["future_field"] = "some_value"  # unknown top-level field
	AnnotationSidecar.write_sidecar(doc, data)
	var result := AnnotationSidecar.read_sidecar(doc)
	check(
		"unknown top-level field preserved on round-trip",
		result.get("future_field", "") == "some_value"
	)
	AnnotationSidecar.delete_sidecar(doc)


# ── write → read round-trip ───────────────────────────────────────────────────

func test_round_trip_annotations_unchanged() -> void:
	print("test_round_trip_annotations_unchanged:")
	var doc := _doc_path("round_trip.minpcb")
	var ann1 := _valid_annotation()
	var ann2 := _valid_annotation()
	ann2["id"] = "ann_ddeeff"
	ann2["kind"] = "2d_text"
	ann2["primitives"] = [{"kind": "text", "at": [5.0, 5.0], "content": "hello"}]

	var data := _sidecar_data([ann1, ann2])
	AnnotationSidecar.write_sidecar(doc, data)
	var result := AnnotationSidecar.read_sidecar(doc)

	var anns: Array = result.get("annotations", [])
	check_eq("round-trip: two annotations preserved", anns.size(), 2)
	check_eq("round-trip: first annotation id", anns[0].get("id"), ann1["id"])
	check_eq("round-trip: second annotation id", anns[1].get("id"), ann2["id"])
	check_eq("round-trip: second annotation kind", anns[1].get("kind"), ann2["kind"])
	AnnotationSidecar.delete_sidecar(doc)
