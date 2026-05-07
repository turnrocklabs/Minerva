extends SceneTree
## Test: MCPDocTools — minerva_doc_read/write/edit/save/save_all.
## Run: godot --headless --path src --script test/test_mcp_doc_tools.gd

var MCPDocToolsScript: Script = null

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/mcp_doc_tools_test"


func _init() -> void:
	# Defer to first process_frame — SceneTree._init runs BEFORE autoloads
	# register, and MCPDocTools transitively references SingletonObject via
	# MCPToolUtils. Loading after first frame lets autoloads resolve.
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	MCPDocToolsScript = load("res://Scripts/Services/MCP/Modules/MCPDocTools.gd")

	print("=== MCPDocTools Tests ===\n")

	_setup()

	var tools = MCPDocToolsScript.new(null)

	test_doc_read_missing_path_arg(tools)
	test_doc_read_not_found(tools)
	test_doc_read_loads_disk_into_buffer(tools)
	test_doc_read_returns_buffer_text_after_write(tools)

	test_doc_write_missing_args(tools)
	test_doc_write_does_not_touch_disk(tools)
	test_doc_write_marks_dirty_and_bumps_version(tools)

	test_doc_edit_missing_args(tools)
	test_doc_edit_not_found(tools)
	test_doc_edit_unique_match_replaces(tools)
	test_doc_edit_no_match_errors(tools)
	test_doc_edit_non_unique_errors(tools)

	test_doc_save_no_buffer_errors(tools)
	test_doc_save_writes_to_disk_and_clears_dirty(tools)

	test_doc_save_all_flushes_dirty_only(tools)

	test_dual_key_both_specified_errors(tools)
	test_dual_key_neither_specified_errors(tools)
	test_editor_name_not_found_errors(tools)

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


func _reset_registry() -> void:
	DocumentRegistry.reset_instance()


# ---------------------------------------------------------------------------
# minerva_doc_read
# ---------------------------------------------------------------------------

func test_doc_read_missing_path_arg(tools) -> void:
	print("test_doc_read_missing_path_arg")
	_reset_registry()
	var r: Dictionary = tools.handle("minerva_doc_read", {})
	check("error on missing path", r.success == false)
	check("error mentions path", "path" in str(r.get("error", "")))


func test_doc_read_not_found(tools) -> void:
	print("test_doc_read_not_found")
	_reset_registry()
	var r: Dictionary = tools.handle("minerva_doc_read", {"path": _temp_path("nope.txt")})
	check("success=false", r.success == false)
	check("error contains not_found", "not_found" in str(r.get("error", "")))


func test_doc_read_loads_disk_into_buffer(tools) -> void:
	print("test_doc_read_loads_disk_into_buffer")
	_reset_registry()
	var path := _temp_path("from_disk.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("hello disk")
	f.close()

	var r: Dictionary = tools.handle("minerva_doc_read", {"path": path})
	check("success=true", r.success == true)
	check("text matches disk", r.get("text", "") == "hello disk")
	check("version=0", r.get("version", -1) == 0)
	check("not dirty", r.get("dirty", true) == false)
	check("buffer registered after read", DocumentRegistry.get_instance().has_buffer(path))


func test_doc_read_returns_buffer_text_after_write(tools) -> void:
	print("test_doc_read_returns_buffer_text_after_write")
	_reset_registry()
	var path := _temp_path("buffer_text.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("on disk")
	f.close()

	tools.handle("minerva_doc_write", {"path": path, "text": "in buffer"})
	var r: Dictionary = tools.handle("minerva_doc_read", {"path": path})
	check("read returns buffer (not disk) text", r.get("text", "") == "in buffer")
	check("dirty=true", r.get("dirty", false) == true)


# ---------------------------------------------------------------------------
# minerva_doc_write
# ---------------------------------------------------------------------------

func test_doc_write_missing_args(tools) -> void:
	print("test_doc_write_missing_args")
	_reset_registry()
	var r1: Dictionary = tools.handle("minerva_doc_write", {})
	check("error on missing path", r1.success == false)
	var r2: Dictionary = tools.handle("minerva_doc_write", {"path": _temp_path("p.txt")})
	check("error on missing text", r2.success == false)


func test_doc_write_does_not_touch_disk(tools) -> void:
	print("test_doc_write_does_not_touch_disk")
	_reset_registry()
	var path := _temp_path("write_no_disk.txt")
	check("file does not exist before write", not FileAccess.file_exists(path))
	var r: Dictionary = tools.handle("minerva_doc_write", {"path": path, "text": "buffer only"})
	check("write success", r.success == true)
	check("file STILL does not exist on disk", not FileAccess.file_exists(path))


func test_doc_write_marks_dirty_and_bumps_version(tools) -> void:
	print("test_doc_write_marks_dirty_and_bumps_version")
	_reset_registry()
	var path := _temp_path("dirty.txt")
	var r1: Dictionary = tools.handle("minerva_doc_write", {"path": path, "text": "v1"})
	check("dirty=true", r1.get("dirty", false) == true)
	check("version=1", r1.get("version", -1) == 1)
	var r2: Dictionary = tools.handle("minerva_doc_write", {"path": path, "text": "v2"})
	check("version=2", r2.get("version", -1) == 2)


# ---------------------------------------------------------------------------
# minerva_doc_edit
# ---------------------------------------------------------------------------

func test_doc_edit_missing_args(tools) -> void:
	print("test_doc_edit_missing_args")
	_reset_registry()
	var r: Dictionary = tools.handle("minerva_doc_edit", {"path": _temp_path("p.txt")})
	check("error on missing args", r.success == false)


func test_doc_edit_not_found(tools) -> void:
	print("test_doc_edit_not_found")
	_reset_registry()
	var r: Dictionary = tools.handle("minerva_doc_edit", {
		"path": _temp_path("missing.txt"),
		"old_string": "x",
		"new_string": "y",
	})
	check("success=false", r.success == false)
	check("error contains not_found", "not_found" in str(r.get("error", "")))


func test_doc_edit_unique_match_replaces(tools) -> void:
	print("test_doc_edit_unique_match_replaces")
	_reset_registry()
	var path := _temp_path("edit.txt")
	tools.handle("minerva_doc_write", {"path": path, "text": "alpha BETA gamma"})
	var r: Dictionary = tools.handle("minerva_doc_edit", {
		"path": path,
		"old_string": "BETA",
		"new_string": "DELTA",
	})
	check("edit success", r.success == true)
	var read_r: Dictionary = tools.handle("minerva_doc_read", {"path": path})
	check("text replaced", read_r.get("text", "") == "alpha DELTA gamma")


func test_doc_edit_no_match_errors(tools) -> void:
	print("test_doc_edit_no_match_errors")
	_reset_registry()
	var path := _temp_path("edit_nomatch.txt")
	tools.handle("minerva_doc_write", {"path": path, "text": "hello"})
	var r: Dictionary = tools.handle("minerva_doc_edit", {
		"path": path,
		"old_string": "ZZZ",
		"new_string": "yyy",
	})
	check("success=false", r.success == false)
	check("error mentions not found", "not found" in str(r.get("error", "")))


func test_doc_edit_non_unique_errors(tools) -> void:
	print("test_doc_edit_non_unique_errors")
	_reset_registry()
	var path := _temp_path("edit_dup.txt")
	tools.handle("minerva_doc_write", {"path": path, "text": "foo bar foo"})
	var r: Dictionary = tools.handle("minerva_doc_edit", {
		"path": path,
		"old_string": "foo",
		"new_string": "FOO",
	})
	check("success=false on non-unique", r.success == false)
	check("error mentions unique", "unique" in str(r.get("error", "")))


# ---------------------------------------------------------------------------
# minerva_doc_save
# ---------------------------------------------------------------------------

func test_doc_save_no_buffer_errors(tools) -> void:
	print("test_doc_save_no_buffer_errors")
	_reset_registry()
	var r: Dictionary = tools.handle("minerva_doc_save", {"path": _temp_path("nope.txt")})
	check("success=false", r.success == false)
	check("error mentions no buffer", "no buffer" in str(r.get("error", "")))


func test_doc_save_writes_to_disk_and_clears_dirty(tools) -> void:
	print("test_doc_save_writes_to_disk_and_clears_dirty")
	_reset_registry()
	var path := _temp_path("save_me.txt")
	tools.handle("minerva_doc_write", {"path": path, "text": "to be saved"})
	check("file does not exist yet", not FileAccess.file_exists(path))

	var r: Dictionary = tools.handle("minerva_doc_save", {"path": path})
	check("save success", r.success == true)
	check("file exists on disk", FileAccess.file_exists(path))

	var read_r: Dictionary = tools.handle("minerva_doc_read", {"path": path})
	check("dirty cleared after save", read_r.get("dirty", true) == false)

	var f := FileAccess.open(path, FileAccess.READ)
	check("disk text matches buffer", f.get_as_text() == "to be saved")
	f.close()


# ---------------------------------------------------------------------------
# minerva_doc_save_all
# ---------------------------------------------------------------------------

func test_doc_save_all_flushes_dirty_only(tools) -> void:
	print("test_doc_save_all_flushes_dirty_only")
	_reset_registry()
	var dirty1 := _temp_path("save_all_a.txt")
	var dirty2 := _temp_path("save_all_b.txt")
	var clean := _temp_path("save_all_clean.txt")

	# Set up: two dirty buffers, one clean buffer (load existing file).
	var f := FileAccess.open(clean, FileAccess.WRITE)
	f.store_string("clean content")
	f.close()
	tools.handle("minerva_doc_read", {"path": clean})  # creates clean buffer
	tools.handle("minerva_doc_write", {"path": dirty1, "text": "a"})
	tools.handle("minerva_doc_write", {"path": dirty2, "text": "b"})

	var r: Dictionary = tools.handle("minerva_doc_save_all", {})
	check("save_all success", r.success == true)
	var saved: Array = r.get("saved_paths", [])
	check("two paths saved", saved.size() == 2)
	check("dirty1 in saved", dirty1 in saved)
	check("dirty2 in saved", dirty2 in saved)
	check("clean NOT in saved", not (clean in saved))
	check("dirty1 file exists", FileAccess.file_exists(dirty1))
	check("dirty2 file exists", FileAccess.file_exists(dirty2))


# ---------------------------------------------------------------------------
# Dual-key validation (path XOR editor_name)
# ---------------------------------------------------------------------------

func test_dual_key_both_specified_errors(tools) -> void:
	print("test_dual_key_both_specified_errors")
	_reset_registry()
	var r: Dictionary = tools.handle("minerva_doc_read", {
		"path": _temp_path("x.txt"),
		"editor_name": "scratch.txt",
	})
	check("success=false when both keys", r.success == false)
	check("error mentions either / not both",
		"either" in str(r.get("error", "")) or "not both" in str(r.get("error", "")))


func test_dual_key_neither_specified_errors(tools) -> void:
	print("test_dual_key_neither_specified_errors")
	_reset_registry()
	# doc_write: text is checked first, supply it so we exercise the resolver.
	var r: Dictionary = tools.handle("minerva_doc_write", {"text": "..."})
	check("success=false when neither key", r.success == false)
	check("error mentions required",
		"required" in str(r.get("error", "")))


func test_editor_name_not_found_errors(tools) -> void:
	print("test_editor_name_not_found_errors")
	_reset_registry()
	# In headless tests SingletonObject.editor_pane is null, so find_editor_by_name
	# always returns null. That should surface as editor_not_found.
	var r: Dictionary = tools.handle("minerva_doc_read", {"editor_name": "no_such_tab"})
	check("success=false on unknown editor", r.success == false)
	check("error contains editor_not_found",
		"editor_not_found" in str(r.get("error", "")))
