extends SceneTree
## Test: DocumentRegistry — singleton path↔buffer mapping with disk-backed lazy load.
## Run: godot --headless --script src/test/test_document_registry.gd

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/document_registry_test"


func _init() -> void:
	print("=== DocumentRegistry Tests ===\n")

	_setup()

	test_get_or_create_loads_disk_text()
	test_get_or_create_returns_same_instance()
	test_get_or_create_creates_empty_for_missing_file()
	test_has_buffer()
	test_dispose_buffer_removes()
	test_list_buffer_paths()
	test_list_dirty_buffer_paths()

	_teardown()

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


func _setup() -> void:
	DirAccess.make_dir_recursive_absolute(_temp_dir)


func _teardown() -> void:
	var d := DirAccess.open(_temp_dir)
	if d == null:
		return
	for name in d.get_files():
		DirAccess.remove_absolute("%s/%s" % [_temp_dir, name])
	DirAccess.remove_absolute(_temp_dir)


func _temp_path(name: String) -> String:
	return "%s/%s" % [_temp_dir, name]


func _fresh_registry() -> DocumentRegistry:
	DocumentRegistry.reset_instance()
	return DocumentRegistry.get_instance()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func test_get_or_create_loads_disk_text() -> void:
	print("test_get_or_create_loads_disk_text")
	var path := _temp_path("load.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("from disk")
	f.close()

	var reg := _fresh_registry()
	var r := reg.get_or_create_buffer(path)
	check("ok=true", r.ok)
	var buf: DocumentBuffer = r.buffer
	check("text loaded from disk", buf.text == "from disk")
	check("version=0 on fresh load", buf.version == 0)
	check("dirty=false on fresh load", not buf.dirty)


func test_get_or_create_returns_same_instance() -> void:
	print("test_get_or_create_returns_same_instance")
	var path := _temp_path("same.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("hi")
	f.close()

	var reg := _fresh_registry()
	var r1 := reg.get_or_create_buffer(path)
	var r2 := reg.get_or_create_buffer(path)
	check("both ok", r1.ok and r2.ok)
	check("same instance", r1.buffer == r2.buffer)


func test_get_or_create_creates_empty_for_missing_file() -> void:
	print("test_get_or_create_creates_empty_for_missing_file")
	var reg := _fresh_registry()
	var path := _temp_path("does_not_exist_yet.txt")
	var r := reg.get_or_create_buffer(path)
	check("ok=true even for missing file", r.ok)
	var buf: DocumentBuffer = r.buffer
	check("buffer text empty", buf.text == "")
	check("buffer not dirty", not buf.dirty)
	check("file did not get created on disk", not FileAccess.file_exists(path))


func test_has_buffer() -> void:
	print("test_has_buffer")
	var reg := _fresh_registry()
	var path := _temp_path("has.txt")
	check("has_buffer=false before create", not reg.has_buffer(path))
	reg.get_or_create_buffer(path)
	check("has_buffer=true after create", reg.has_buffer(path))


func test_dispose_buffer_removes() -> void:
	print("test_dispose_buffer_removes")
	var reg := _fresh_registry()
	var path := _temp_path("dispose.txt")
	reg.get_or_create_buffer(path)
	check("present before dispose", reg.has_buffer(path))
	reg.dispose_buffer(path)
	check("absent after dispose", not reg.has_buffer(path))


func test_list_buffer_paths() -> void:
	print("test_list_buffer_paths")
	var reg := _fresh_registry()
	var p1 := _temp_path("list_a.txt")
	var p2 := _temp_path("list_b.txt")
	reg.get_or_create_buffer(p1)
	reg.get_or_create_buffer(p2)
	var paths := reg.list_buffer_paths()
	check("two paths tracked", paths.size() == 2)
	check("contains p1", p1 in paths)
	check("contains p2", p2 in paths)


func test_list_dirty_buffer_paths() -> void:
	print("test_list_dirty_buffer_paths")
	var reg := _fresh_registry()
	var clean_path := _temp_path("clean.txt")
	var dirty_path := _temp_path("dirty.txt")
	reg.get_or_create_buffer(clean_path)
	var r := reg.get_or_create_buffer(dirty_path)
	(r.buffer as DocumentBuffer).apply_edit("dirty edit")

	var dirty_paths := reg.list_dirty_buffer_paths()
	check("one dirty buffer", dirty_paths.size() == 1)
	check("dirty path listed", dirty_path in dirty_paths)
	check("clean path not listed", not (clean_path in dirty_paths))
