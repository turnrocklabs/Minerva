extends SceneTree
## Test: DiskAccess — read/write/exists routed through PathResolver.
## Run: godot --headless --script src/test/test_disk_access.gd

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/disk_access_test"


func _init() -> void:
	print("=== DiskAccess Tests ===\n")

	_setup()

	test_read_existing_file()
	test_read_missing_file_returns_not_found()
	test_read_empty_path_errors()
	test_write_creates_file()
	test_write_creates_parent_dirs()
	test_write_overwrites_existing_file()
	test_exists_true_for_existing()
	test_exists_false_for_missing()

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


# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func test_read_existing_file() -> void:
	print("test_read_existing_file")
	var path := _temp_path("read_existing.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("hello world")
	f.close()

	var r := DiskAccess.read(path)
	check("ok=true on existing file", r.ok)
	check("text matches", r.text == "hello world")


func test_read_missing_file_returns_not_found() -> void:
	print("test_read_missing_file_returns_not_found")
	var r := DiskAccess.read(_temp_path("does_not_exist.txt"))
	check("ok=false on missing file", not r.ok)
	check("error contains not_found", "not_found" in str(r.get("error", "")))


func test_read_empty_path_errors() -> void:
	print("test_read_empty_path_errors")
	var r := DiskAccess.read("")
	check("ok=false on empty path", not r.ok)


func test_write_creates_file() -> void:
	print("test_write_creates_file")
	var path := _temp_path("write_creates.txt")
	var r := DiskAccess.write(path, "fresh content")
	check("write ok=true", r.ok)
	check("file exists after write", FileAccess.file_exists(path))

	var read_r := DiskAccess.read(path)
	check("readback matches", read_r.ok and read_r.text == "fresh content")


func test_write_creates_parent_dirs() -> void:
	print("test_write_creates_parent_dirs")
	var nested := _temp_path("newdir/sub/created.txt")
	var r := DiskAccess.write(nested, "deep")
	check("write into nonexistent dirs ok=true (mkdir -p)", r.ok)
	check("file exists in created dirs", FileAccess.file_exists(nested))
	DirAccess.remove_absolute(nested)
	DirAccess.remove_absolute(_temp_path("newdir/sub"))
	DirAccess.remove_absolute(_temp_path("newdir"))


func test_write_overwrites_existing_file() -> void:
	print("test_write_overwrites_existing_file")
	var path := _temp_path("overwrite.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("original")
	f.close()

	var r := DiskAccess.write(path, "replaced")
	check("write ok=true", r.ok)

	var read_r := DiskAccess.read(path)
	check("text replaced", read_r.ok and read_r.text == "replaced")


func test_exists_true_for_existing() -> void:
	print("test_exists_true_for_existing")
	var path := _temp_path("exists_yes.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("x")
	f.close()
	check("exists returns true", DiskAccess.exists(path))


func test_exists_false_for_missing() -> void:
	print("test_exists_false_for_missing")
	check("exists returns false", not DiskAccess.exists(_temp_path("nope.txt")))
