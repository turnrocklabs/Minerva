extends SceneTree
## Test: MCPDiskTools — minerva_disk_read/write/exists.
## Run: godot --headless --path src --script test/test_mcp_disk_tools.gd

const MCPDiskToolsScript := preload("res://Scripts/Services/MCP/Modules/MCPDiskTools.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/mcp_disk_tools_test"


func _init() -> void:
	print("=== MCPDiskTools Tests ===\n")

	_setup()

	var tools = MCPDiskToolsScript.new(null)

	test_disk_read_missing_path(tools)
	test_disk_read_not_found(tools)
	test_disk_read_existing_file(tools)

	test_disk_write_missing_args(tools)
	test_disk_write_creates_file(tools)
	test_disk_write_overwrites(tools)
	test_disk_write_fires_external_change_when_buffer_exists(tools)
	test_disk_write_no_signal_when_no_buffer(tools)

	test_disk_exists_true(tools)
	test_disk_exists_false(tools)

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
# minerva_disk_read
# ---------------------------------------------------------------------------

func test_disk_read_missing_path(tools) -> void:
	print("test_disk_read_missing_path")
	var r: Dictionary = tools.handle("minerva_disk_read", {})
	check("error on missing path", r.success == false)


func test_disk_read_not_found(tools) -> void:
	print("test_disk_read_not_found")
	var r: Dictionary = tools.handle("minerva_disk_read", {"path": _temp_path("ghost.txt")})
	check("success=false", r.success == false)
	check("error contains not_found", "not_found" in str(r.get("error", "")))


func test_disk_read_existing_file(tools) -> void:
	print("test_disk_read_existing_file")
	var path := _temp_path("disk_read.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("disk contents")
	f.close()
	var r: Dictionary = tools.handle("minerva_disk_read", {"path": path})
	check("success=true", r.success == true)
	check("text matches", r.get("text", "") == "disk contents")


# ---------------------------------------------------------------------------
# minerva_disk_write
# ---------------------------------------------------------------------------

func test_disk_write_missing_args(tools) -> void:
	print("test_disk_write_missing_args")
	var r1: Dictionary = tools.handle("minerva_disk_write", {})
	check("error on missing path", r1.success == false)
	var r2: Dictionary = tools.handle("minerva_disk_write", {"path": _temp_path("p.txt")})
	check("error on missing text", r2.success == false)


func test_disk_write_creates_file(tools) -> void:
	print("test_disk_write_creates_file")
	_reset_registry()
	var path := _temp_path("disk_write_new.txt")
	check("file does not exist before", not FileAccess.file_exists(path))
	var r: Dictionary = tools.handle("minerva_disk_write", {"path": path, "text": "fresh"})
	check("write success", r.success == true)
	check("file exists after", FileAccess.file_exists(path))
	var f := FileAccess.open(path, FileAccess.READ)
	check("file contents match", f.get_as_text() == "fresh")
	f.close()


func test_disk_write_overwrites(tools) -> void:
	print("test_disk_write_overwrites")
	_reset_registry()
	var path := _temp_path("disk_write_overwrite.txt")
	var f1 := FileAccess.open(path, FileAccess.WRITE)
	f1.store_string("original")
	f1.close()
	tools.handle("minerva_disk_write", {"path": path, "text": "replaced"})
	var f2 := FileAccess.open(path, FileAccess.READ)
	check("file contents replaced", f2.get_as_text() == "replaced")
	f2.close()


func test_disk_write_fires_external_change_when_buffer_exists(tools) -> void:
	# Post-T7: minerva_disk_write routes through registry.poke_path → file_changed
	# emission, which the registry dispatches as silent-reload for clean buffers
	# and external_change_detected for dirty buffers. Verify both branches.
	print("test_disk_write_fires_external_change_when_buffer_exists")
	_reset_registry()

	# (a) Clean buffer → silent reload. external_change_detected does NOT fire;
	# the buffer's text reflects the disk write.
	var clean_path := _temp_path("disk_write_clean_buffer.txt")
	var clean_r := DocumentRegistry.get_instance().get_or_create_buffer(clean_path)
	check("clean buffer created", clean_r.ok)
	var clean_buf: DocumentBuffer = clean_r.buffer
	var clean_fired := {"count": 0}
	clean_buf.external_change_detected.connect(func(): clean_fired.count += 1)
	tools.handle("minerva_disk_write", {"path": clean_path, "text": "external on clean"})
	check("clean buffer text now matches disk write", clean_buf.text == "external on clean")
	check("external_change_detected did NOT fire for clean buffer", clean_fired.count == 0)

	# (b) Dirty buffer → external_change_detected fires; buffer untouched.
	var dirty_path := _temp_path("disk_write_dirty_buffer.txt")
	var dirty_r := DocumentRegistry.get_instance().get_or_create_buffer(dirty_path)
	check("dirty buffer created", dirty_r.ok)
	var dirty_buf: DocumentBuffer = dirty_r.buffer
	dirty_buf.apply_edit("user-edit-not-saved")
	var dirty_fired := {"count": 0}
	dirty_buf.external_change_detected.connect(func(): dirty_fired.count += 1)
	tools.handle("minerva_disk_write", {"path": dirty_path, "text": "external on dirty"})
	check("external_change_detected fired for dirty buffer", dirty_fired.count == 1)
	check("dirty buffer text unchanged (waiting for user choice)", dirty_buf.text == "user-edit-not-saved")


func test_disk_write_no_signal_when_no_buffer(tools) -> void:
	print("test_disk_write_no_signal_when_no_buffer")
	_reset_registry()
	var path := _temp_path("disk_write_no_buffer.txt")
	# No buffer for this path. Just write directly. Should succeed; no signal to check
	# because no buffer exists. Just ensure the call succeeds.
	var r: Dictionary = tools.handle("minerva_disk_write", {"path": path, "text": "fine"})
	check("write succeeds without buffer", r.success == true)
	check("no buffer was created by disk_write", not DocumentRegistry.get_instance().has_buffer(path))


# ---------------------------------------------------------------------------
# minerva_disk_exists
# ---------------------------------------------------------------------------

func test_disk_exists_true(tools) -> void:
	print("test_disk_exists_true")
	var path := _temp_path("exists_yes.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("x")
	f.close()
	var r: Dictionary = tools.handle("minerva_disk_exists", {"path": path})
	check("success", r.success == true)
	check("exists=true", r.get("exists", false) == true)


func test_disk_exists_false(tools) -> void:
	print("test_disk_exists_false")
	var r: Dictionary = tools.handle("minerva_disk_exists", {"path": _temp_path("nope.txt")})
	check("success", r.success == true)
	check("exists=false", r.get("exists", true) == false)
