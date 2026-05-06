extends SceneTree
## Test: DocumentRegistry × FileWatcherService — the four DoD scenarios from
## DCR 019dfa66 Task 7 (external-change watcher + Reload/Keep prompt).
## Run: godot --headless --script src/test/test_external_change_watcher.gd

const FWS = preload("res://Scripts/Services/Watcher/FileWatcherService.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/external_change_watcher_test"


func _init() -> void:
	print("=== External Change Watcher Tests ===\n")

	_setup()

	test_clean_buffer_external_write_silent_reload()
	test_dirty_buffer_external_write_fires_signal()
	test_dirty_buffer_reload_replaces_text_with_disk()
	test_dirty_buffer_keep_leaves_buffer_unchanged()
	test_self_save_does_not_re_trigger()
	test_coalesce_one_prompt_per_buffer()
	test_dispose_unwatches_path()
	test_poke_path_triggers_immediate_check()
	test_external_write_with_same_size_still_handled()
	test_dispose_emits_buffer_disposed_signal()
	test_registry_and_plugin_can_coexist_on_same_path()

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


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _fresh() -> Dictionary:
	# Reset both singletons so tests don't leak state.
	DocumentRegistry.reset_instance()
	FWS.reset_instance()
	return {
		"reg": DocumentRegistry.get_instance(),
		"fw": FWS.get_instance(),
	}


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func test_clean_buffer_external_write_silent_reload() -> void:
	# DoD: clean buffer + external write → silent reload (text matches disk).
	print("test_clean_buffer_external_write_silent_reload")
	var s := _fresh()
	var path := _temp_path("clean_reload.txt")
	_write(path, "v1")

	var buf: DocumentBuffer = s.reg.get_or_create_buffer(path).buffer
	check("buffer not dirty initially", not buf.dirty)
	check("buffer text = v1", buf.text == "v1")

	var external_change_fired := {"count": 0}
	buf.external_change_detected.connect(func(): external_change_fired.count += 1)

	OS.delay_msec(1100)
	_write(path, "v2_external")
	s.fw.tick()

	check("text replaced with disk content", buf.text == "v2_external")
	check("buffer still not dirty after silent reload", not buf.dirty)
	check("external_change_detected NOT emitted (clean → silent)", external_change_fired.count == 0)


func test_dirty_buffer_external_write_fires_signal() -> void:
	# DoD: dirty buffer + external write → external_change_detected fires.
	print("test_dirty_buffer_external_write_fires_signal")
	var s := _fresh()
	var path := _temp_path("dirty_prompt.txt")
	_write(path, "v1")

	var buf: DocumentBuffer = s.reg.get_or_create_buffer(path).buffer
	buf.apply_edit("buffer_edit_unsaved")
	check("buffer is dirty", buf.dirty)

	var external_change_fired := {"count": 0}
	buf.external_change_detected.connect(func(): external_change_fired.count += 1)

	OS.delay_msec(1100)
	_write(path, "v2_external")
	s.fw.tick()

	check("external_change_detected emitted", external_change_fired.count == 1)
	check("buffer text NOT changed (waiting for user choice)", buf.text == "buffer_edit_unsaved")
	check("buffer still dirty (waiting for user choice)", buf.dirty)
	check("registry tracks prompt open", s.reg.is_prompt_open(path))


func test_dirty_buffer_reload_replaces_text_with_disk() -> void:
	# DoD: Reload action → buffer text matches disk.
	print("test_dirty_buffer_reload_replaces_text_with_disk")
	var s := _fresh()
	var path := _temp_path("reload_action.txt")
	_write(path, "v1")

	var buf: DocumentBuffer = s.reg.get_or_create_buffer(path).buffer
	buf.apply_edit("my_edits")

	OS.delay_msec(1100)
	_write(path, "their_edits")
	s.fw.tick()

	# Simulate the dialog's "Reload" button: reload + clear_prompt_open.
	buf.reload_from_disk()
	s.reg.clear_prompt_open(path)

	check("buffer text now matches disk", buf.text == "their_edits")
	check("buffer no longer dirty", not buf.dirty)
	check("prompt closed", not s.reg.is_prompt_open(path))


func test_dirty_buffer_keep_leaves_buffer_unchanged() -> void:
	# DoD: Keep action → buffer text unchanged.
	print("test_dirty_buffer_keep_leaves_buffer_unchanged")
	var s := _fresh()
	var path := _temp_path("keep_action.txt")
	_write(path, "v1")

	var buf: DocumentBuffer = s.reg.get_or_create_buffer(path).buffer
	buf.apply_edit("my_edits")

	OS.delay_msec(1100)
	_write(path, "their_edits")
	s.fw.tick()

	# Simulate "Keep Buffer": just clear_prompt_open. Buffer untouched.
	s.reg.clear_prompt_open(path)

	check("buffer text unchanged after Keep", buf.text == "my_edits")
	check("buffer still dirty after Keep", buf.dirty)
	check("prompt closed", not s.reg.is_prompt_open(path))


func test_self_save_does_not_re_trigger() -> void:
	# Saving via the buffer itself (Minerva's own write) should not fire
	# external_change_detected on the next tick — the snapshot matches the
	# fresh stat.
	print("test_self_save_does_not_re_trigger")
	var s := _fresh()
	var path := _temp_path("self_save.txt")
	_write(path, "v1")

	var buf: DocumentBuffer = s.reg.get_or_create_buffer(path).buffer
	buf.apply_edit("edited")
	buf.save_to_disk()

	var external_change_fired := {"count": 0}
	buf.external_change_detected.connect(func(): external_change_fired.count += 1)

	# Even if the watcher fires (mtime advanced from save), it should be a no-op
	# because matches_disk_snapshot returns true.
	s.fw.tick()
	check("no external_change_detected on self-save", external_change_fired.count == 0)


func test_coalesce_one_prompt_per_buffer() -> void:
	# DoD bullet 5: multiple external changes while a prompt is open coalesce
	# into one prompt.
	print("test_coalesce_one_prompt_per_buffer")
	var s := _fresh()
	var path := _temp_path("coalesce.txt")
	_write(path, "v1")

	var buf: DocumentBuffer = s.reg.get_or_create_buffer(path).buffer
	buf.apply_edit("my_edits")

	var external_change_fired := {"count": 0}
	buf.external_change_detected.connect(func(): external_change_fired.count += 1)

	OS.delay_msec(1100)
	_write(path, "first_external")
	s.fw.tick()

	# Second external write while prompt is still open.
	OS.delay_msec(1100)
	_write(path, "second_external")
	s.fw.tick()

	check("only one prompt fired (coalesced)", external_change_fired.count == 1)

	# After user picks (clears prompt), a third external change fires fresh.
	s.reg.clear_prompt_open(path)
	OS.delay_msec(1100)
	_write(path, "third_external")
	s.fw.tick()
	check("after prompt closes, next external change fires again", external_change_fired.count == 2)


func test_dispose_unwatches_path() -> void:
	print("test_dispose_unwatches_path")
	var s := _fresh()
	var path := _temp_path("dispose.txt")
	_write(path, "x")

	s.reg.get_or_create_buffer(path)
	check("path is watched after create", s.fw.is_watched(path))

	s.reg.dispose_buffer(path)
	check("path is NOT watched after dispose", not s.fw.is_watched(path))


func test_poke_path_triggers_immediate_check() -> void:
	print("test_poke_path_triggers_immediate_check")
	var s := _fresh()
	var path := _temp_path("poke_check.txt")
	_write(path, "v1")

	var buf: DocumentBuffer = s.reg.get_or_create_buffer(path).buffer
	buf.apply_edit("my_edits")  # dirty

	var external_change_fired := {"count": 0}
	buf.external_change_detected.connect(func(): external_change_fired.count += 1)

	OS.delay_msec(1100)
	_write(path, "external")

	# poke_path bypasses the polling tick.
	s.reg.poke_path(path)
	check("poke triggers external_change_detected immediately", external_change_fired.count == 1)


func test_external_write_with_same_size_still_handled() -> void:
	# Cold-review concern #1: same-second + same-byte-length external write
	# must not be silently swallowed as a self-save no-op. With the
	# matches_disk_snapshot suppression dropped, the dirty/clean dispatcher
	# correctly handles this case via reload_from_disk's content compare.
	print("test_external_write_with_same_size_still_handled")
	var s := _fresh()
	var path := _temp_path("same_size.txt")
	_write(path, "AAAAA")  # 5 bytes

	var buf: DocumentBuffer = s.reg.get_or_create_buffer(path).buffer
	buf.apply_edit("buffer-edit-not-saved")
	buf.save_to_disk()  # buf clean again, disk now has "buffer-edit-not-saved"

	var external_change_fired := {"count": 0}
	buf.external_change_detected.connect(func(): external_change_fired.count += 1)

	# External write with EXACT same byte length as buffer text but different
	# content. If we relied on (mtime, size) only, we might suppress this.
	var same_len := "x".repeat(buf.text.length())
	OS.delay_msec(1100)
	_write(path, same_len)

	s.fw.tick()
	# Buffer was clean, so silent reload — external_change_detected NOT fired
	# (same_len went straight into the buffer text). Verify the reload
	# actually happened (text now matches the external write, not what we saved).
	check("buffer text now reflects external write", buf.text == same_len)
	check("buffer not dirty after silent reload", not buf.dirty)
	check("no external_change_detected for clean+silent", external_change_fired.count == 0)


func test_dispose_emits_buffer_disposed_signal() -> void:
	# Cold-review nice-to-have #7: dispose_buffer must surface a signal so
	# UI consumers (WatcherRuntime) can dismiss any open dialog tied to the
	# path before the buffer is freed.
	print("test_dispose_emits_buffer_disposed_signal")
	var s := _fresh()
	var path := _temp_path("dispose_signal.txt")
	_write(path, "x")
	s.reg.get_or_create_buffer(path)

	var disposed := {"count": 0, "last_path": ""}
	s.reg.buffer_disposed.connect(func(p: String) -> void:
		disposed.count += 1
		disposed.last_path = p
	)
	s.reg.dispose_buffer(path)
	check("buffer_disposed emitted", disposed.count == 1)
	check("disposed path matches", disposed.last_path == path)


func test_registry_and_plugin_can_coexist_on_same_path() -> void:
	# Cold-review nice-to-have #8: the registry and a plugin both watching
	# the same path must use distinct owner_ids so neither's unwatch removes
	# the other's subscription. Exercises the test_paired_dsl HITL flow
	# where Panel.gd calls host.fs.watch on the buffer's own path.
	print("test_registry_and_plugin_can_coexist_on_same_path")
	var s := _fresh()
	var path := _temp_path("shared_owners.txt")
	_write(path, "x")
	s.reg.get_or_create_buffer(path)
	check("registry watches with one owner", s.fw.owner_count(path) == 1)

	# Simulate a plugin subscribing to the same path with a different owner_id.
	s.fw.watch(path, "plugin_panel:test_plugin:test_panel")
	check("two distinct owners on same path", s.fw.owner_count(path) == 2)

	# Plugin unwatching does not affect the registry's subscription.
	s.fw.unwatch(path, "plugin_panel:test_plugin:test_panel")
	check("plugin unwatch leaves registry watch intact", s.fw.is_watched(path))
	check("owner_count back to 1", s.fw.owner_count(path) == 1)
