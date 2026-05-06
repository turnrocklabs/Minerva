extends SceneTree
## Test: FileWatcherService — pub/sub watch list, tick polling, refcounted owners.
## Run: godot --headless --script src/test/test_file_watcher_service.gd

const FWS = preload("res://Scripts/Services/Watcher/FileWatcherService.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _temp_dir: String = "/tmp/file_watcher_service_test"


func _init() -> void:
	print("=== FileWatcherService Tests ===\n")

	_setup()

	test_initial_state()
	test_watch_returns_error_on_empty_owner()
	test_watch_then_is_watched_and_count()
	test_watch_two_owners_same_path_dedups()
	test_unwatch_last_owner_drops_watch()
	test_unwatch_unknown_is_noop()
	test_tick_emits_file_changed_on_modification()
	test_tick_no_emit_when_unchanged()
	test_tick_silent_baseline_on_first_appearance_emits_once()
	test_poke_emits_immediately()
	test_poke_unknown_path_is_noop()
	test_disappearance_does_not_emit()
	test_unwatch_all_removes_only_that_owners_watches()
	test_emit_carries_correct_payload()

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


func _fresh_service() -> FWS:
	FWS.reset_instance()
	return FWS.get_instance()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func test_initial_state() -> void:
	print("test_initial_state")
	var fw := _fresh_service()
	check("watch_count = 0 initially", fw.watch_count() == 0)
	check("is_watched false on unwatched path", not fw.is_watched("/tmp/anything"))


func test_watch_returns_error_on_empty_owner() -> void:
	print("test_watch_returns_error_on_empty_owner")
	var fw := _fresh_service()
	var path := _temp_path("a.txt")
	_write(path, "a")
	var r := fw.watch(path, "")
	check("watch returns ok=false on empty owner_id", not r.ok)
	check("error reports owner_id_empty", str(r.error) == "owner_id_empty")
	check("no watch added", fw.watch_count() == 0)


func test_watch_then_is_watched_and_count() -> void:
	print("test_watch_then_is_watched_and_count")
	var fw := _fresh_service()
	var path := _temp_path("watched.txt")
	_write(path, "x")
	var r := fw.watch(path, "owner_a")
	check("watch ok", r.ok)
	check("watch_count = 1", fw.watch_count() == 1)
	check("is_watched true", fw.is_watched(path))
	check("owner_count = 1", fw.owner_count(path) == 1)


func test_watch_two_owners_same_path_dedups() -> void:
	print("test_watch_two_owners_same_path_dedups")
	var fw := _fresh_service()
	var path := _temp_path("shared.txt")
	_write(path, "x")
	fw.watch(path, "owner_a")
	fw.watch(path, "owner_b")
	check("watch_count still 1 (one path)", fw.watch_count() == 1)
	check("owner_count = 2", fw.owner_count(path) == 2)


func test_unwatch_last_owner_drops_watch() -> void:
	print("test_unwatch_last_owner_drops_watch")
	var fw := _fresh_service()
	var path := _temp_path("drop.txt")
	_write(path, "x")
	fw.watch(path, "owner_a")
	fw.watch(path, "owner_b")
	fw.unwatch(path, "owner_a")
	check("watch survives with one remaining owner", fw.is_watched(path))
	check("owner_count = 1", fw.owner_count(path) == 1)
	fw.unwatch(path, "owner_b")
	check("watch dropped when last owner leaves", not fw.is_watched(path))
	check("watch_count = 0", fw.watch_count() == 0)


func test_unwatch_unknown_is_noop() -> void:
	print("test_unwatch_unknown_is_noop")
	var fw := _fresh_service()
	var path := _temp_path("nothing.txt")
	# Should not crash.
	fw.unwatch(path, "no_such_owner")
	check("unwatch on unwatched path is silent no-op", fw.watch_count() == 0)


func test_tick_emits_file_changed_on_modification() -> void:
	print("test_tick_emits_file_changed_on_modification")
	var fw := _fresh_service()
	var path := _temp_path("modify.txt")
	_write(path, "v1")
	fw.watch(path, "owner_a")

	var fired := {"count": 0, "last_path": "", "last_mtime": -1, "last_size": -1}
	fw.file_changed.connect(func(p: String, m: int, s: int) -> void:
		fired.count += 1
		fired.last_path = p
		fired.last_mtime = m
		fired.last_size = s
	)

	# Wait a tick of wall clock so mtime can advance.
	OS.delay_msec(1100)
	_write(path, "v2_longer")

	var changed_count := fw.tick()
	check("tick reports 1 change", changed_count == 1)
	check("file_changed fired once", fired.count == 1)
	check("payload path matches", fired.last_path == path)
	check("payload size matches v2", fired.last_size == "v2_longer".length())


func test_tick_no_emit_when_unchanged() -> void:
	print("test_tick_no_emit_when_unchanged")
	var fw := _fresh_service()
	var path := _temp_path("static.txt")
	_write(path, "static")
	fw.watch(path, "owner_a")

	var fired := {"count": 0}
	fw.file_changed.connect(func(_p, _m, _s): fired.count += 1)

	# First tick — baseline already established at watch time, so no emit.
	fw.tick()
	check("no emit on tick when file is unchanged", fired.count == 0)


func test_tick_silent_baseline_on_first_appearance_emits_once() -> void:
	print("test_tick_silent_baseline_on_first_appearance_emits_once")
	var fw := _fresh_service()
	var path := _temp_path("appears.txt")
	# Watch a path that does NOT exist yet — baseline {0, 0}.
	fw.watch(path, "owner_a")

	var fired := {"count": 0}
	fw.file_changed.connect(func(_p, _m, _s): fired.count += 1)

	# Create the file. First tick should emit (snapshot was 0,0).
	_write(path, "now exists")
	fw.tick()
	check("fires once when watched path first appears", fired.count == 1)

	# Second tick with no change should not emit.
	fw.tick()
	check("does not re-fire when unchanged", fired.count == 1)


func test_poke_emits_immediately() -> void:
	print("test_poke_emits_immediately")
	var fw := _fresh_service()
	var path := _temp_path("poke.txt")
	_write(path, "v1")
	fw.watch(path, "owner_a")

	var fired := {"count": 0}
	fw.file_changed.connect(func(_p, _m, _s): fired.count += 1)

	OS.delay_msec(1100)
	_write(path, "v2")

	fw.poke(path)
	check("poke fires file_changed immediately", fired.count == 1)


func test_poke_unknown_path_is_noop() -> void:
	print("test_poke_unknown_path_is_noop")
	var fw := _fresh_service()
	var fired := {"count": 0}
	fw.file_changed.connect(func(_p, _m, _s): fired.count += 1)
	fw.poke("/tmp/never_watched")
	check("poke on unwatched path is silent", fired.count == 0)


func test_disappearance_does_not_emit() -> void:
	print("test_disappearance_does_not_emit")
	var fw := _fresh_service()
	var path := _temp_path("vanish.txt")
	_write(path, "exists")
	fw.watch(path, "owner_a")

	var fired := {"count": 0}
	fw.file_changed.connect(func(_p, _m, _s): fired.count += 1)

	DirAccess.remove_absolute(path)
	fw.tick()
	check("disappearance does not emit (out of DoD scope)", fired.count == 0)
	check("watch survives disappearance", fw.is_watched(path))

	# Re-baseline absorbs the deletion. Re-create with new content.
	_write(path, "back")
	fw.tick()
	check("reappearance emits as new change", fired.count == 1)


func test_unwatch_all_removes_only_that_owners_watches() -> void:
	print("test_unwatch_all_removes_only_that_owners_watches")
	var fw := _fresh_service()
	var path_x := _temp_path("x.txt")
	var path_y := _temp_path("y.txt")
	_write(path_x, "x")
	_write(path_y, "y")
	fw.watch(path_x, "plugin_a")
	fw.watch(path_y, "plugin_a")
	fw.watch(path_y, "plugin_b")

	var removed := fw.unwatch_all("plugin_a")
	check("unwatch_all returns count of removed owner-rows", removed == 2)
	check("plugin_b's path_y still watched", fw.is_watched(path_y))
	check("path_x dropped (plugin_a was sole owner)", not fw.is_watched(path_x))
	check("path_y owner_count = 1", fw.owner_count(path_y) == 1)


func test_emit_carries_correct_payload() -> void:
	print("test_emit_carries_correct_payload")
	var fw := _fresh_service()
	var path := _temp_path("payload.txt")
	_write(path, "short")
	fw.watch(path, "owner_a")

	var captured := {"path": "", "mtime": -1, "size": -1}
	fw.file_changed.connect(func(p: String, m: int, s: int) -> void:
		captured.path = p
		captured.mtime = m
		captured.size = s
	)

	OS.delay_msec(1100)
	_write(path, "much_longer_content_here")
	fw.tick()

	check("path payload matches", captured.path == path)
	check("size payload matches new content", captured.size == "much_longer_content_here".length())
	check("mtime payload > 0", captured.mtime > 0)
