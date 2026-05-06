extends SceneTree
## Test: DocumentBuffer — text mutation, version monotonicity, signal emission.
## Run: godot --headless --script src/test/test_document_buffer.gd

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/document_buffer_test"


func _init() -> void:
	print("=== DocumentBuffer Tests ===\n")

	_setup()

	test_initial_state()
	test_apply_edit_changes_text_and_bumps_version()
	test_apply_edit_emits_text_changed()
	test_apply_edit_with_same_text_is_no_op()
	test_save_to_disk_writes_file_and_clears_dirty()
	test_save_to_disk_emits_saved()
	test_reload_replaces_text_and_bumps_version_on_change()
	test_reload_no_op_when_disk_matches()
	test_reload_clears_dirty_regardless()
	test_notify_external_change_emits_signal()

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


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func test_initial_state() -> void:
	print("test_initial_state")
	var b := DocumentBuffer.new("/tmp/x.txt", "hello")
	check("file_path set", b.file_path == "/tmp/x.txt")
	check("text set", b.text == "hello")
	check("version=0 initially", b.version == 0)
	check("dirty=false initially", not b.dirty)


func test_apply_edit_changes_text_and_bumps_version() -> void:
	print("test_apply_edit_changes_text_and_bumps_version")
	var b := DocumentBuffer.new("/tmp/x.txt", "a")
	b.apply_edit("b")
	check("text updated", b.text == "b")
	check("version=1", b.version == 1)
	check("dirty=true", b.dirty)
	b.apply_edit("c")
	check("version=2 after second edit", b.version == 2)


func test_apply_edit_emits_text_changed() -> void:
	print("test_apply_edit_emits_text_changed")
	var b := DocumentBuffer.new("/tmp/x.txt", "a")
	var fired := {"count": 0, "last_text": "", "last_version": -1}
	b.text_changed.connect(func(t: String, v: int) -> void:
		fired.count += 1
		fired.last_text = t
		fired.last_version = v
	)
	b.apply_edit("b")
	check("text_changed fired once", fired.count == 1)
	check("text_changed payload text", fired.last_text == "b")
	check("text_changed payload version", fired.last_version == 1)


func test_apply_edit_with_same_text_is_no_op() -> void:
	print("test_apply_edit_with_same_text_is_no_op")
	var b := DocumentBuffer.new("/tmp/x.txt", "same")
	var fired := {"count": 0}
	b.text_changed.connect(func(_t, _v): fired.count += 1)
	b.apply_edit("same")
	check("no signal on identical text", fired.count == 0)
	check("version unchanged", b.version == 0)
	check("dirty unchanged", not b.dirty)


func test_save_to_disk_writes_file_and_clears_dirty() -> void:
	print("test_save_to_disk_writes_file_and_clears_dirty")
	var path := _temp_path("save.txt")
	var b := DocumentBuffer.new(path, "")
	b.apply_edit("save me")
	check("dirty before save", b.dirty)
	var r := b.save_to_disk()
	check("save ok", r.ok)
	check("dirty cleared", not b.dirty)
	check("file exists on disk", FileAccess.file_exists(path))
	var read_r := DiskAccess.read(path)
	check("disk contents match buffer", read_r.ok and read_r.text == "save me")


func test_save_to_disk_emits_saved() -> void:
	print("test_save_to_disk_emits_saved")
	var path := _temp_path("save_signal.txt")
	var b := DocumentBuffer.new(path, "x")
	var fired := {"count": 0}
	b.saved.connect(func(): fired.count += 1)
	b.save_to_disk()
	check("saved emitted", fired.count == 1)


func test_reload_replaces_text_and_bumps_version_on_change() -> void:
	print("test_reload_replaces_text_and_bumps_version_on_change")
	var path := _temp_path("reload_change.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("disk_version")
	f.close()

	var b := DocumentBuffer.new(path, "buffer_version")
	var fired := {"count": 0, "last_text": ""}
	b.text_changed.connect(func(t: String, _v: int) -> void:
		fired.count += 1
		fired.last_text = t
	)
	var r := b.reload_from_disk()
	check("reload ok", r.ok)
	check("text replaced from disk", b.text == "disk_version")
	check("version bumped", b.version == 1)
	check("text_changed fired", fired.count == 1)
	check("text_changed payload matches disk", fired.last_text == "disk_version")


func test_reload_no_op_when_disk_matches() -> void:
	print("test_reload_no_op_when_disk_matches")
	var path := _temp_path("reload_same.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("identical")
	f.close()

	var b := DocumentBuffer.new(path, "identical")
	var fired := {"count": 0}
	b.text_changed.connect(func(_t, _v): fired.count += 1)
	b.reload_from_disk()
	check("no text_changed when disk matches buffer", fired.count == 0)
	check("version unchanged", b.version == 0)


func test_reload_clears_dirty_regardless() -> void:
	print("test_reload_clears_dirty_regardless")
	var path := _temp_path("reload_dirty.txt")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("disk")
	f.close()

	var b := DocumentBuffer.new(path, "disk")  # dirty starts false; matches disk
	b.apply_edit("buffer_edit")
	check("dirty before reload", b.dirty)
	b.reload_from_disk()
	check("dirty cleared by reload", not b.dirty)


func test_notify_external_change_emits_signal() -> void:
	print("test_notify_external_change_emits_signal")
	var b := DocumentBuffer.new("/tmp/x.txt", "")
	var fired := {"count": 0}
	b.external_change_detected.connect(func(): fired.count += 1)
	b.notify_external_change()
	check("external_change_detected emitted", fired.count == 1)
