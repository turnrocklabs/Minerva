extends SceneTree
## Performance contract tests for AnnotationResolveCache (task #5).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_resolve_cache_perf.gd
##
## RED in Round 1 — AnnotationResolveCache does not exist yet.
## NOTE: tag=perf — CI may skip perf-tagged tests on slow machines.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: perf]")
	print("=== test_annotation_resolve_cache_perf ===\n")

	print("-- cache class existence --")
	test_cache_class_exists()

	print("\n-- perf: cached resolve < 1ms median over 1000 calls --")
	test_cache_1000_hits_under_1_second()

	print("\n-- perf: cache overhead < 0.5ms per uncached call --")
	test_cache_overhead_under_half_ms()

	print("\n-- perf: render budget cap 1000 annotations --")
	test_render_budget_cap_1000()

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


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _anchor(id_val: int) -> Dictionary:
	return {
		"plugin": "core",
		"type": "text.range",
		"id": {"start": id_val, "end": id_val + 10},
		"snapshot": {"position": [float(id_val), 0.0]}
	}


func _make_cache() -> Variant:
	if not ClassDB.class_exists("AnnotationResolveCache"):
		return null
	return ClassDB.instantiate("AnnotationResolveCache")


# ── Class existence ───────────────────────────────────────────────────────────

func test_cache_class_exists() -> void:
	print("test_cache_class_exists:")
	check("AnnotationResolveCache class exists",
		ClassDB.class_exists("AnnotationResolveCache"))


# ── Perf tests ────────────────────────────────────────────────────────────────

func test_cache_1000_hits_under_1_second() -> void:
	print("test_cache_1000_hits_under_1_second:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve"):
		check("AnnotationResolveCache instantiable with resolve method", false)
		return
	var host = _TrivialHost.new()
	var anchor = _anchor(0)
	# Prime the cache with one miss
	cache.resolve(anchor, host, "main")
	# Now time 1000 hits
	var start_us = Time.get_ticks_usec()
	for _i in range(1000):
		cache.resolve(anchor, host, "main")
	var elapsed_us = Time.get_ticks_usec() - start_us
	var elapsed_ms = elapsed_us / 1000.0
	print("  [perf] 1000 cached resolves: %.2f ms" % elapsed_ms)
	# Budget: 1000 cached resolves < 1000ms total (1ms each)
	check("1000 cached resolves complete in < 1000ms", elapsed_ms < 1000.0)


func test_cache_overhead_under_half_ms() -> void:
	print("test_cache_overhead_under_half_ms:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve"):
		check("AnnotationResolveCache instantiable with resolve method", false)
		return
	# Compare raw host.resolve_anchor vs cache.resolve (miss) overhead
	var host = _TimedHost.new()
	var anchor = _anchor(99)
	var start_us = Time.get_ticks_usec()
	cache.resolve(anchor, host, "main")  # single miss
	var cache_elapsed_us = Time.get_ticks_usec() - start_us
	var host_elapsed_us = host.last_call_duration_us
	var overhead_us = cache_elapsed_us - host_elapsed_us
	var overhead_ms = overhead_us / 1000.0
	print("  [perf] cache overhead for one uncached resolve: %.3f ms" % overhead_ms)
	# Per-resolve cache overhead < 0.5ms
	check("cache overhead per uncached resolve < 0.5ms", overhead_ms < 0.5)


func test_render_budget_cap_1000() -> void:
	print("test_render_budget_cap_1000:")
	if not ClassDB.class_exists("AnnotationResolveCache"):
		check("AnnotationResolveCache exists", false)
		return
	if not ClassDB.class_exists("AnnotationCanvas"):
		check("AnnotationCanvas class exists", false)
		return
	# AnnotationCanvas.RENDER_BUDGET_CAP should be 1000
	# Access via instance since we can't use class name directly
	var canvas = ClassDB.instantiate("AnnotationCanvas")
	if canvas == null:
		check("AnnotationCanvas instantiable", false)
		return
	var cap = canvas.get("RENDER_BUDGET_CAP")
	check("AnnotationCanvas.RENDER_BUDGET_CAP == 1000", cap == 1000)


# ── Mock helpers ──────────────────────────────────────────────────────────────

class _TrivialHost extends RefCounted:
	func resolve_anchor(_anchor: Dictionary) -> Dictionary:
		return {"position": Vector2.ZERO, "bounds": Rect2(), "stale": false, "view_metadata": {}}


class _TimedHost extends RefCounted:
	var last_call_duration_us: int = 0

	func resolve_anchor(_anchor: Dictionary) -> Dictionary:
		var start = Time.get_ticks_usec()
		# Minimal work
		var result = {"position": Vector2.ZERO, "bounds": Rect2(), "stale": false, "view_metadata": {}}
		last_call_duration_us = Time.get_ticks_usec() - start
		return result
