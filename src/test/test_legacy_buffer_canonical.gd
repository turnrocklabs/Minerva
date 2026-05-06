extends SceneTree
## Test: legacy MCP file tools are now buffer-canonical (Task 3 invariant).
##
## After Task 3, calling minerva_file_write or minerva_file_edit must NOT
## modify the file on disk. Disk only changes when minerva_doc_save runs.
##
## Run: godot --headless --path src --script test/test_legacy_buffer_canonical.gd

const MCPCodeToolsScript := preload("res://Scripts/Services/MCP/Modules/MCPCodeTools.gd")
const MCPDocToolsScript := preload("res://Scripts/Services/MCP/Modules/MCPDocTools.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/legacy_buffer_canonical_test"


func _init() -> void:
	print("=== Legacy Buffer-Canonical Tests ===\n")

	_setup()

	var code_tools = MCPCodeToolsScript.new(null)
	var doc_tools = MCPDocToolsScript.new(null)

	test_file_write_does_not_touch_disk(code_tools)
	test_file_write_then_doc_save_writes_to_disk(code_tools, doc_tools)
	test_file_edit_does_not_touch_disk(code_tools)
	test_file_read_returns_buffer_text_not_disk_text(code_tools)
	test_file_read_response_shape_preserved(code_tools)
	test_file_edit_response_shape_preserved(code_tools)

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

func test_file_write_does_not_touch_disk(tools) -> void:
	print("test_file_write_does_not_touch_disk")
	_reset_registry()
	var path := _temp_path("file_write.txt")
	check("file does not exist before", not FileAccess.file_exists(path))

	var r: Dictionary = tools.handle("minerva_file_write", {"path": path, "content": "buffer-only"})
	check("write success=true", r.get("success", false) == true)
	check("response has path", r.get("path", "") == path)
	check("response has bytes_written", r.get("bytes_written", -1) == "buffer-only".length())
	# Buffer-canonical invariant: disk untouched
	check("file STILL does not exist on disk", not FileAccess.file_exists(path))
	# Buffer is dirty in registry
	check("buffer registered after write", DocumentRegistry.get_instance().has_buffer(path))


func test_file_write_then_doc_save_writes_to_disk(code_tools, doc_tools) -> void:
	print("test_file_write_then_doc_save_writes_to_disk")
	_reset_registry()
	var path := _temp_path("write_then_save.txt")

	code_tools.handle("minerva_file_write", {"path": path, "content": "save me"})
	check("file does not exist after write", not FileAccess.file_exists(path))

	var save_r: Dictionary = doc_tools.handle("minerva_doc_save", {"path": path})
	check("doc_save success", save_r.get("success", false) == true)
	check("file exists after doc_save", FileAccess.file_exists(path))

	var f := FileAccess.open(path, FileAccess.READ)
	check("disk text matches", f.get_as_text() == "save me")
	f.close()


func test_file_edit_does_not_touch_disk(tools) -> void:
	print("test_file_edit_does_not_touch_disk")
	_reset_registry()
	var path := _temp_path("file_edit.txt")
	# Seed disk so we can detect a write.
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("hello WORLD foo")
	f.close()

	var r: Dictionary = tools.handle("minerva_file_edit", {
		"path": path,
		"old_string": "WORLD",
		"new_string": "GALAXY",
	})
	check("edit success=true", r.get("success", false) == true)
	check("response has replacements=1", r.get("replacements", 0) == 1)
	check("response has path", r.get("path", "") == path)

	# Buffer-canonical: disk still has the old content
	var f2 := FileAccess.open(path, FileAccess.READ)
	check("disk text UNCHANGED after edit", f2.get_as_text() == "hello WORLD foo")
	f2.close()


func test_file_read_returns_buffer_text_not_disk_text(tools) -> void:
	print("test_file_read_returns_buffer_text_not_disk_text")
	_reset_registry()
	var path := _temp_path("buffer_vs_disk.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("disk version")
	f.close()

	# Edit creates a divergent buffer.
	tools.handle("minerva_file_edit", {
		"path": path,
		"old_string": "disk",
		"new_string": "buffer",
	})

	var r: Dictionary = tools.handle("minerva_file_read", {"path": path})
	check("read success", r.get("success", false) == true)
	# content is line-numbered; check the substring
	check("read returns BUFFER text not disk", "buffer version" in str(r.get("content", "")))


func test_file_read_response_shape_preserved(tools) -> void:
	print("test_file_read_response_shape_preserved")
	_reset_registry()
	var path := _temp_path("shape.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("line one\nline two\nline three")
	f.close()

	var r: Dictionary = tools.handle("minerva_file_read", {"path": path})
	check("has success", r.has("success"))
	check("has content", r.has("content"))
	check("has lines_read", r.has("lines_read"))
	check("has total_lines", r.has("total_lines"))
	check("has truncated", r.has("truncated"))
	check("has binary", r.has("binary"))
	check("total_lines correct", r.get("total_lines", 0) == 3)


func test_file_edit_response_shape_preserved(tools) -> void:
	print("test_file_edit_response_shape_preserved")
	_reset_registry()
	var path := _temp_path("edit_shape.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("alpha BETA gamma")
	f.close()

	var r: Dictionary = tools.handle("minerva_file_edit", {
		"path": path,
		"old_string": "BETA",
		"new_string": "DELTA",
	})
	check("has success", r.has("success"))
	check("has replacements", r.has("replacements"))
	check("has path", r.has("path"))
	check("replacements=1", r.get("replacements", 0) == 1)
