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

	test_create_unbacked_returns_buffer_with_synthetic_path()
	test_create_unbacked_distinct_per_call()
	test_unbacked_lookup_via_get_or_create()
	test_get_or_create_unbacked_missing_errors()
	test_rebind_buffer_unbacked_to_real_path()
	test_rebind_buffer_preserves_instance_identity()
	test_rebind_buffer_collision_errors()
	test_dispose_unbacked_buffer()
	test_is_unbacked_path_helper()

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


# ---------------------------------------------------------------------------
# Unbacked buffers + rebind (anonymous editor support)
# ---------------------------------------------------------------------------

func test_create_unbacked_returns_buffer_with_synthetic_path() -> void:
	print("test_create_unbacked_returns_buffer_with_synthetic_path")
	var reg := _fresh_registry()
	var r := reg.create_unbacked_buffer()
	check("ok=true", r.ok == true)
	var buf: DocumentBuffer = r.buffer
	check("buffer is non-null", buf != null)
	check("file_path begins with unbacked://", buf.file_path.begins_with("unbacked://"))
	check("text starts empty", buf.text == "")
	check("dirty starts false", buf.dirty == false)


func test_create_unbacked_distinct_per_call() -> void:
	print("test_create_unbacked_distinct_per_call")
	var reg := _fresh_registry()
	var a: DocumentBuffer = reg.create_unbacked_buffer().buffer
	var b: DocumentBuffer = reg.create_unbacked_buffer().buffer
	check("paths differ", a.file_path != b.file_path)
	check("instances differ", a != b)


func test_unbacked_lookup_via_get_or_create() -> void:
	print("test_unbacked_lookup_via_get_or_create")
	var reg := _fresh_registry()
	var minted: DocumentBuffer = reg.create_unbacked_buffer().buffer
	var lookup_r := reg.get_or_create_buffer(minted.file_path)
	check("lookup succeeds", lookup_r.ok == true)
	check("returns same instance", lookup_r.buffer == minted)


func test_get_or_create_unbacked_missing_errors() -> void:
	print("test_get_or_create_unbacked_missing_errors")
	var reg := _fresh_registry()
	# Synthetic path that was never minted via create_unbacked_buffer.
	var r := reg.get_or_create_buffer("unbacked://does-not-exist")
	check("ok=false", r.ok == false)
	check("error mentions create_unbacked_buffer",
		"create_unbacked_buffer" in str(r.get("error", "")))


func test_rebind_buffer_unbacked_to_real_path() -> void:
	print("test_rebind_buffer_unbacked_to_real_path")
	var reg := _fresh_registry()
	var buf: DocumentBuffer = reg.create_unbacked_buffer().buffer
	var old_id: String = buf.file_path
	var real_path := _temp_path("rebound.txt")
	buf.apply_edit("seed text")  # Pre-rebind content survives.

	var r := reg.rebind_buffer(old_id, real_path)
	check("rebind ok", r.ok == true)
	check("buffer.file_path is new path", buf.file_path == real_path)
	check("old key removed", not reg.has_buffer(old_id))
	check("new key registered", reg.has_buffer(real_path))
	check("text preserved", buf.text == "seed text")


func test_rebind_buffer_preserves_instance_identity() -> void:
	print("test_rebind_buffer_preserves_instance_identity")
	var reg := _fresh_registry()
	var buf: DocumentBuffer = reg.create_unbacked_buffer().buffer
	var old_id: String = buf.file_path
	var real_path := _temp_path("identity.txt")
	reg.rebind_buffer(old_id, real_path)
	# Looking up via the new path returns the SAME instance.
	var fetched: DocumentBuffer = reg.get_or_create_buffer(real_path).buffer
	check("same instance after rebind", fetched == buf)


func test_rebind_buffer_collision_errors() -> void:
	print("test_rebind_buffer_collision_errors")
	var reg := _fresh_registry()
	var occupied := _temp_path("occupied.txt")
	var f := FileAccess.open(occupied, FileAccess.WRITE)
	f.store_string("existing")
	f.close()
	reg.get_or_create_buffer(occupied)  # Another buffer at this path.

	var unbacked: DocumentBuffer = reg.create_unbacked_buffer().buffer
	var r := reg.rebind_buffer(unbacked.file_path, occupied)
	check("rebind into occupied path errors", r.ok == false)
	check("error mentions buffer already exists",
		"already exists" in str(r.get("error", "")))


func test_dispose_unbacked_buffer() -> void:
	print("test_dispose_unbacked_buffer")
	var reg := _fresh_registry()
	var buf: DocumentBuffer = reg.create_unbacked_buffer().buffer
	var path: String = buf.file_path
	check("buffer registered before dispose", reg.has_buffer(path))
	reg.dispose_buffer(path)
	check("buffer gone after dispose", not reg.has_buffer(path))


func test_is_unbacked_path_helper() -> void:
	print("test_is_unbacked_path_helper")
	check("real path not unbacked", DocumentRegistry.is_unbacked_path("/abs/foo.txt") == false)
	check("synthetic path is unbacked", DocumentRegistry.is_unbacked_path("unbacked://abc-def") == true)
	check("empty not unbacked", DocumentRegistry.is_unbacked_path("") == false)
