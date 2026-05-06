extends SceneTree
## Test: legacy minerva_file_* MCP tools are buffer-canonical (Task 3 of DCR 019dfa66).
##
## After Task 3, the legacy tools must:
##   - delegate writes through DocumentRegistry, NOT FileAccess directly
##   - leave disk untouched until the buffer is explicitly saved
##   - return content that reflects the buffer, even when disk has stale text
##
## Pattern follows test_mcp_cad_tools.gd: instantiate the module via .new(null),
## skip register_tools(), exercise handle() directly. handle() is a coroutine in
## MCPCodeTools (because _codetools_bash uses await), so all calls are awaited.
##
## Run: godot --headless --path src --script test/test_legacy_buffer_canonical.gd

const MCPCodeToolsScript := preload("res://Scripts/Services/MCP/Modules/MCPCodeTools.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/legacy_buffer_canonical_test"


func _init() -> void:
	print("=== Legacy Buffer-Canonical Tests ===\n")

	_setup()

	var code_tools = MCPCodeToolsScript.new(null)
	if code_tools == null:
		printerr("FATAL: MCPCodeTools.new(null) returned null — body-level compile failure?")
		quit(2)
		return

	await test_file_write_does_not_touch_disk(code_tools)
	await test_file_write_creates_buffer_with_content(code_tools)
	await test_file_write_preserves_existing_disk_until_save(code_tools)
	await test_file_edit_does_not_touch_disk(code_tools)
	await test_file_edit_modifies_buffer(code_tools)
	await test_doc_save_flushes_legacy_writes_to_disk(code_tools)

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


func _read_disk(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _write_disk(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


# ---------------------------------------------------------------------------
# minerva_file_write — buffer-canonical, no disk touch
# ---------------------------------------------------------------------------

func test_file_write_does_not_touch_disk(tools) -> void:
	print("test_file_write_does_not_touch_disk")
	_reset_registry()
	var path := _temp_path("write_no_disk.txt")
	check("file does not exist before", not FileAccess.file_exists(path))

	var r: Dictionary = await tools.handle("minerva_file_write", {"path": path, "content": "buffer-only"})
	check("write success", r.get("success", false) == true)
	check("disk file STILL does not exist", not FileAccess.file_exists(path))


func test_file_write_creates_buffer_with_content(tools) -> void:
	print("test_file_write_creates_buffer_with_content")
	_reset_registry()
	var path := _temp_path("buffer_has_content.txt")
	await tools.handle("minerva_file_write", {"path": path, "content": "hello"})

	var registry := DocumentRegistry.get_instance()
	check("buffer registered for path", registry.has_buffer(path))
	var br := registry.get_or_create_buffer(path)
	check("buffer ok", br.ok)
	check("buffer text matches what was written", (br.buffer as DocumentBuffer).text == "hello")
	check("buffer marked dirty", (br.buffer as DocumentBuffer).dirty == true)


func test_file_write_preserves_existing_disk_until_save(tools) -> void:
	print("test_file_write_preserves_existing_disk_until_save")
	_reset_registry()
	var path := _temp_path("preserve_disk.txt")
	_write_disk(path, "ORIGINAL")

	await tools.handle("minerva_file_write", {"path": path, "content": "MUTATED"})
	check("disk preserves ORIGINAL after legacy write", _read_disk(path) == "ORIGINAL")


# ---------------------------------------------------------------------------
# minerva_file_edit — buffer-canonical, no disk touch
# ---------------------------------------------------------------------------

func test_file_edit_does_not_touch_disk(tools) -> void:
	print("test_file_edit_does_not_touch_disk")
	_reset_registry()
	var path := _temp_path("edit_no_disk.txt")
	_write_disk(path, "alpha bravo charlie")

	await tools.handle("minerva_file_edit", {
		"path": path, "old_string": "bravo", "new_string": "BRAVO",
	})
	check("disk unchanged after legacy edit", _read_disk(path) == "alpha bravo charlie")


func test_file_edit_modifies_buffer(tools) -> void:
	print("test_file_edit_modifies_buffer")
	_reset_registry()
	var path := _temp_path("edit_buffer.txt")
	_write_disk(path, "alpha bravo charlie")

	var r: Dictionary = await tools.handle("minerva_file_edit", {
		"path": path, "old_string": "bravo", "new_string": "BRAVO",
	})
	check("edit success", r.get("success", false) == true)

	var registry := DocumentRegistry.get_instance()
	var br := registry.get_or_create_buffer(path)
	check("buffer reflects edit", (br.buffer as DocumentBuffer).text == "alpha BRAVO charlie")


# ---------------------------------------------------------------------------
# Save round-trip — only minerva_doc_save flips disk
# ---------------------------------------------------------------------------

func test_doc_save_flushes_legacy_writes_to_disk(tools) -> void:
	print("test_doc_save_flushes_legacy_writes_to_disk")
	_reset_registry()
	var path := _temp_path("flush_after_legacy.txt")
	_write_disk(path, "OLD")

	await tools.handle("minerva_file_write", {"path": path, "content": "NEW"})
	check("disk still OLD after legacy write", _read_disk(path) == "OLD")

	# Save via DocumentRegistry directly (the buffer-canonical path).
	# Equivalent to calling minerva_doc_save through MCPDocTools.
	var br := DocumentRegistry.get_instance().get_or_create_buffer(path)
	check("buffer ok before save", br.ok)
	var save_r: Dictionary = (br.buffer as DocumentBuffer).save_to_disk()
	check("save succeeded", save_r.get("ok", false) == true)
	check("disk now NEW after save", _read_disk(path) == "NEW")
	check("buffer no longer dirty", (br.buffer as DocumentBuffer).dirty == false)
