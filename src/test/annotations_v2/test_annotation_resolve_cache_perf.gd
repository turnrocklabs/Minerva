extends SceneTree
## Performance contract tests for AnnotationResolveCache (task #5).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_resolve_cache_perf.gd

const AnnotationResolveCacheScript = preload("res://Scripts/Services/Annotations/AnnotationResolveCache.gd")
const AnnotationCanvasScript = preload("res://Scripts/Services/Annotations/AnnotationCanvas.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: perf]")
	print("=== test_annotation_resolve_cache_perf ===\n")

	test_cache_1000_hits_under_1_second()
	test_cache_overhead_under_half_ms()
	test_render_budget_cap_1000()

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


func _anchor(id_val: int) -> Dictionary:
	return {
		"plugin": "core",
		"type": "text.range",
		"id": {"start": id_val, "end": id_val + 10},
		"snapshot": {"position": [float(id_val), 0.0]}
	}


func _make_cache() -> RefCounted:
	return AnnotationResolveCacheScript.new()


func test_cache_1000_hits_under_1_second() -> void:
	print("test_cache_1000_hits_under_1_second:")
	var cache := _make_cache()
	var host := _TrivialHost.new()
	var anchor := _anchor(0)
	cache.resolve(anchor, host, "main")
	var start_us := Time.get_ticks_usec()
	for _i in range(1000):
		cache.resolve(anchor, host, "main")
	var elapsed_ms := (Time.get_ticks_usec() - start_us) / 1000.0
	print("  [perf] 1000 cached resolves: %.2f ms" % elapsed_ms)
	check("1000 cached resolves complete in < 1000ms", elapsed_ms < 1000.0)


func test_cache_overhead_under_half_ms() -> void:
	print("test_cache_overhead_under_half_ms:")
	var cache := _make_cache()
	var host := _TimedHost.new()
	var anchor := _anchor(99)
	var start_us := Time.get_ticks_usec()
	cache.resolve(anchor, host, "main")
	var cache_elapsed_us := Time.get_ticks_usec() - start_us
	var overhead_ms := (cache_elapsed_us - host.last_call_duration_us) / 1000.0
	print("  [perf] cache overhead for one uncached resolve: %.3f ms" % overhead_ms)
	check("cache overhead per uncached resolve < 0.5ms", overhead_ms < 0.5)


func test_render_budget_cap_1000() -> void:
	print("test_render_budget_cap_1000:")
	check("AnnotationCanvas.RENDER_BUDGET_CAP == 1000", AnnotationCanvasScript.RENDER_BUDGET_CAP == 1000)


class _TrivialHost extends RefCounted:
	func resolve_anchor(_anchor: Dictionary) -> Dictionary:
		return {"position": Vector2.ZERO, "bounds": Rect2(), "stale": false, "view_metadata": {}}


class _TimedHost extends RefCounted:
	var last_call_duration_us: int = 0

	func resolve_anchor(_anchor: Dictionary) -> Dictionary:
		var start_us := Time.get_ticks_usec()
		var result := {"position": Vector2.ZERO, "bounds": Rect2(), "stale": false, "view_metadata": {}}
		last_call_duration_us = Time.get_ticks_usec() - start_us
		return result
