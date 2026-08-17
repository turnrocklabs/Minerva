extends SceneTree
## Unit tests for the render_content_to_image cache mechanism in
## Helloscene_AnnotationHost.
##
## Run: godot --headless --path src --script test/test_hello_annotation_render_cache.gd
##
## Coverage:
##   - _cached_panel_image starts null on a fresh host
##   - render_content_to_image returns null when cache is cold AND schedules a refresh
##     (_cache_refresh_pending flips to true — the actual frame_post_draw never fires
##      in headless, but the scheduling side-effect is verifiable)
##   - render_content_to_image returns null AND does NOT re-schedule when a refresh
##     is already pending (_cache_refresh_pending guard works)
##   - When _cached_panel_image is set directly, render_content_to_image returns it
##   - _schedule_cache_refresh is a no-op when _ui_root is null
##   - _schedule_cache_refresh is a no-op (de-dup) when already pending
##   - add_annotation triggers a cache refresh schedule
##   - update_annotation triggers a cache refresh schedule (on success)
##   - remove_annotation triggers a cache refresh schedule (on success)
##   - set_annotations triggers a cache refresh schedule
##   - set_canvas_and_root triggers a cache refresh schedule

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== HelloAnnotationHost Render Cache Tests ===\n")

	test_cache_starts_null()
	test_render_null_cache_returns_null()
	test_render_null_cache_sets_pending_flag()
	test_render_null_cache_no_double_schedule()
	test_render_returns_cached_image_when_set()
	test_schedule_noop_when_no_ui_root()
	test_schedule_noop_when_already_pending()
	test_do_capture_clears_pending_flag()
	test_add_annotation_schedules_refresh()
	test_update_annotation_schedules_refresh()
	test_remove_annotation_schedules_refresh()
	test_set_annotations_schedules_refresh()
	test_set_canvas_and_root_schedules_refresh()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Helper: create a host with a mock Control as _ui_root ─────────────────────

## Returns a fresh host with _ui_root set to a real Control node so
## _schedule_cache_refresh does not early-exit on the null-root guard.
## The Control has no viewport (headless), so frame_post_draw never fires,
## but the scheduling side-effect (_cache_refresh_pending = true) is
## observable synchronously.
func _host_with_root() -> Helloscene_AnnotationHost:
	var host := Helloscene_AnnotationHost.new()
	var ctrl := Control.new()
	# Wire only _ui_root — _canvas_node not needed for cache tests.
	host._ui_root = ctrl
	return host


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_cache_starts_null() -> void:
	print("test_cache_starts_null:")
	var host := Helloscene_AnnotationHost.new()
	check("_cached_panel_image is null on fresh host", host._cached_panel_image == null)
	check("_cache_refresh_pending is false on fresh host", host._cache_refresh_pending == false)


func test_render_null_cache_returns_null() -> void:
	print("test_render_null_cache_returns_null:")
	var host := Helloscene_AnnotationHost.new()
	# No _ui_root → _schedule_cache_refresh early-exits; pending stays false.
	var result := host.render_content_to_image(Rect2())
	check("render returns null when cache is cold and no ui_root", result == null)


func test_render_null_cache_sets_pending_flag() -> void:
	print("test_render_null_cache_sets_pending_flag:")
	var host := _host_with_root()
	check("pending is false before first render call", host._cache_refresh_pending == false)
	var result := host.render_content_to_image(Rect2())
	check("render returns null (cache cold)", result == null)
	check("_cache_refresh_pending is true after first render call",
		host._cache_refresh_pending == true)


func test_render_null_cache_no_double_schedule() -> void:
	print("test_render_null_cache_no_double_schedule:")
	var host := _host_with_root()
	# First call: schedules a refresh.
	host.render_content_to_image(Rect2())
	check("pending true after first call", host._cache_refresh_pending == true)
	# Second call: pending already true; _schedule_cache_refresh is a no-op.
	# The CONNECT_ONE_SHOT lambda was already registered; calling schedule again
	# would add a second listener — the guard prevents that.
	host.render_content_to_image(Rect2())
	check("pending still true after second call (guard held)", host._cache_refresh_pending == true)


func test_render_returns_cached_image_when_set() -> void:
	print("test_render_returns_cached_image_when_set:")
	var host := Helloscene_AnnotationHost.new()
	var img := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.0, 0.0, 1.0))
	# Simulate a successful post-draw capture by setting the cache directly.
	host._cached_panel_image = img
	var result := host.render_content_to_image(Rect2())
	check("render returns the cached image when set", result == img)
	check("pending remains false when cache is warm", host._cache_refresh_pending == false)


func test_schedule_noop_when_no_ui_root() -> void:
	print("test_schedule_noop_when_no_ui_root:")
	var host := Helloscene_AnnotationHost.new()
	# _ui_root is null — _schedule_cache_refresh must not flip the pending flag
	# (it has nothing to capture) and must not throw.
	host._schedule_cache_refresh()
	check("pending stays false when _ui_root is null", host._cache_refresh_pending == false)


func test_schedule_noop_when_already_pending() -> void:
	print("test_schedule_noop_when_already_pending:")
	var host := _host_with_root()
	# Force pending true manually to simulate an already-queued capture.
	host._cache_refresh_pending = true
	# Calling schedule again must not register a second listener.
	host._schedule_cache_refresh()
	# Pending must remain true (guard prevented the no-op from resetting it).
	check("pending stays true after second schedule call (de-dup)",
		host._cache_refresh_pending == true)


func test_do_capture_clears_pending_flag() -> void:
	print("test_do_capture_clears_pending_flag:")
	var host := _host_with_root()
	host._cache_refresh_pending = true
	# _do_capture_now clears the pending flag first, then attempts the capture.
	# In headless mode the viewport is null so the image is not updated, but the
	# flag reset is the observable part we care about.
	host._do_capture_now()
	check("_cache_refresh_pending is false after _do_capture_now",
		host._cache_refresh_pending == false)
	# Cache stays null because there is no real viewport in headless.
	check("_cached_panel_image stays null (no real viewport in headless)",
		host._cached_panel_image == null)


func test_add_annotation_schedules_refresh() -> void:
	print("test_add_annotation_schedules_refresh:")
	var host := _host_with_root()
	check("pending false before add", host._cache_refresh_pending == false)
	host.add_annotation({"kind": "2d_arrow"})
	check("pending true after add_annotation", host._cache_refresh_pending == true)


func test_update_annotation_schedules_refresh() -> void:
	print("test_update_annotation_schedules_refresh:")
	var host := _host_with_root()
	var id := host.add_annotation({"kind": "2d_arrow"})
	# Reset pending after the add.
	host._cache_refresh_pending = false
	var ok := host.update_annotation(id, {"kind": "2d_text"})
	check("update returned true", ok == true)
	check("pending true after update_annotation", host._cache_refresh_pending == true)


func test_remove_annotation_schedules_refresh() -> void:
	print("test_remove_annotation_schedules_refresh:")
	var host := _host_with_root()
	var id := host.add_annotation({"kind": "2d_arrow"})
	host._cache_refresh_pending = false
	var ok := host.remove_annotation(id)
	check("remove returned true", ok == true)
	check("pending true after remove_annotation", host._cache_refresh_pending == true)


func test_set_annotations_schedules_refresh() -> void:
	print("test_set_annotations_schedules_refresh:")
	var host := _host_with_root()
	check("pending false before set_annotations", host._cache_refresh_pending == false)
	host.set_annotations([{"kind": "2d_arrow"}])
	check("pending true after set_annotations", host._cache_refresh_pending == true)


func test_set_canvas_and_root_schedules_refresh() -> void:
	print("test_set_canvas_and_root_schedules_refresh:")
	var host := Helloscene_AnnotationHost.new()
	check("pending false before set_canvas_and_root", host._cache_refresh_pending == false)
	var canvas := Control.new()
	var panel_root := Control.new()
	host.set_canvas_and_root(canvas, panel_root)
	check("pending true after set_canvas_and_root", host._cache_refresh_pending == true)
