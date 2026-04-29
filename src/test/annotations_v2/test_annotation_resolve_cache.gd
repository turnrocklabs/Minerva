extends SceneTree
## Contract tests for AnnotationResolveCache (task #5).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_resolve_cache.gd
##
## RED in Round 1 — AnnotationResolveCache does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_resolve_cache ===\n")

	print("-- cache: class existence --")
	test_cache_class_exists()

	print("\n-- cache: hit/miss --")
	test_cache_hit_returns_cached_result()
	test_cache_miss_calls_host_resolve()
	test_cache_miss_on_first_access()
	test_cache_key_includes_view_context()

	print("\n-- cache: invalidation --")
	test_bump_revision_causes_miss_on_next_read()
	test_invalidate_all_clears_cache()
	test_invalidate_by_anchor_type_clears_matching()
	test_invalidate_by_anchor_type_leaves_non_matching()

	print("\n-- cache: stats --")
	test_cache_stats_hits_incremented()
	test_cache_stats_misses_incremented()
	test_cache_stats_size_reported()

	print("\n-- cache: anchor key format --")
	test_anchor_key_format_scalar_id()
	test_anchor_key_format_includes_view_context()
	test_anchor_key_format_non_scalar_id_json_encoded()

	print("\n-- cache: LRU eviction at capacity --")
	test_cache_evicts_oldest_at_5000_entries()

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


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _anchor(plugin: String, type: String, id: Variant) -> Dictionary:
	return {
		"plugin": plugin, "type": type, "id": id,
		"snapshot": {"position": [0.0, 0.0]}
	}


func _resolved(pos_x: float) -> Dictionary:
	return {
		"position": Vector2(pos_x, 0.0),
		"bounds": Rect2(pos_x, 0.0, 0.0, 0.0),
		"stale": false,
		"view_metadata": {}
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


# ── Tests: hit/miss ───────────────────────────────────────────────────────────

func test_cache_hit_returns_cached_result() -> void:
	print("test_cache_hit_returns_cached_result:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve"):
		check("AnnotationResolveCache instantiable with resolve method", false)
		return
	var host = _CountingHost.new()
	var anchor = _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "editor:main")
	var call_count_after_first = host.call_count
	cache.resolve(anchor, host, "editor:main")
	check("cache hit does not call host.resolve_anchor again",
		host.call_count == call_count_after_first)


func test_cache_miss_calls_host_resolve() -> void:
	print("test_cache_miss_calls_host_resolve:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve"):
		check("AnnotationResolveCache instantiable with resolve method", false)
		return
	var host = _CountingHost.new()
	var anchor = _anchor("core", "text.range", {"start": 0, "end": 5})
	cache.resolve(anchor, host, "editor:main")
	check("cache miss calls host.resolve_anchor", host.call_count == 1)


func test_cache_miss_on_first_access() -> void:
	print("test_cache_miss_on_first_access:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("stats"):
		check("AnnotationResolveCache instantiable with stats method", false)
		return
	var stats = cache.stats()
	check_eq("initial misses=0", stats.get("misses", -1), 0)
	check_eq("initial hits=0", stats.get("hits", -1), 0)


func test_cache_key_includes_view_context() -> void:
	print("test_cache_key_includes_view_context:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve"):
		check("AnnotationResolveCache instantiable with resolve method", false)
		return
	var host = _CountingHost.new()
	var anchor = _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "editor:main")
	cache.resolve(anchor, host, "editor:side")
	check("different view contexts produce separate cache entries",
		host.call_count == 2)


# ── Tests: invalidation ───────────────────────────────────────────────────────

func test_bump_revision_causes_miss_on_next_read() -> void:
	print("test_bump_revision_causes_miss_on_next_read:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve") or not cache.has_method("bump_revision"):
		check("AnnotationResolveCache instantiable with required methods", false)
		return
	var host = _CountingHost.new()
	var anchor = _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "editor:main")
	var before_bump = host.call_count
	cache.bump_revision()
	cache.resolve(anchor, host, "editor:main")
	check("bump_revision causes re-resolve on next access",
		host.call_count > before_bump)


func test_invalidate_all_clears_cache() -> void:
	print("test_invalidate_all_clears_cache:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve") or not cache.has_method("invalidate"):
		check("AnnotationResolveCache instantiable with required methods", false)
		return
	var host = _CountingHost.new()
	var anchor = _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "editor:main")
	cache.invalidate()  # empty arg = invalidate all
	cache.resolve(anchor, host, "editor:main")
	check("invalidate() all forces re-resolve", host.call_count == 2)


func test_invalidate_by_anchor_type_clears_matching() -> void:
	print("test_invalidate_by_anchor_type_clears_matching:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve") or not cache.has_method("invalidate"):
		check("AnnotationResolveCache instantiable with required methods", false)
		return
	var host = _CountingHost.new()
	var tr_anchor = _anchor("core", "text.range", {"start": 0, "end": 5})
	var gr_anchor = _anchor("core", "graphics.region", "region_1")
	cache.resolve(tr_anchor, host, "main")
	cache.resolve(gr_anchor, host, "main")
	var calls_after_first_two = host.call_count
	cache.invalidate("text.range")
	cache.resolve(tr_anchor, host, "main")   # should re-resolve
	cache.resolve(gr_anchor, host, "main")   # should still be cached
	check("invalidate(text.range) forces re-resolve of text.range entries",
		host.call_count == calls_after_first_two + 1)


func test_invalidate_by_anchor_type_leaves_non_matching() -> void:
	print("test_invalidate_by_anchor_type_leaves_non_matching:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve") or not cache.has_method("invalidate"):
		check("AnnotationResolveCache instantiable with required methods", false)
		return
	var host = _CountingHost.new()
	var tr_anchor = _anchor("core", "text.range", {"start": 0, "end": 5})
	var gr_anchor = _anchor("core", "graphics.region", "region_1")
	cache.resolve(tr_anchor, host, "main")
	cache.resolve(gr_anchor, host, "main")
	var calls_before = host.call_count
	cache.invalidate("text.range")
	cache.resolve(tr_anchor, host, "main")
	cache.resolve(gr_anchor, host, "main")
	check("invalidate(text.range) does not evict graphics.region from cache",
		host.call_count == calls_before + 1)


# ── Tests: stats ──────────────────────────────────────────────────────────────

func test_cache_stats_hits_incremented() -> void:
	print("test_cache_stats_hits_incremented:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve") or not cache.has_method("stats"):
		check("AnnotationResolveCache instantiable with required methods", false)
		return
	var host = _CountingHost.new()
	var anchor = _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "main")  # miss
	cache.resolve(anchor, host, "main")  # hit
	cache.resolve(anchor, host, "main")  # hit
	var stats = cache.stats()
	check("stats.hits == 2 after two cache hits", stats.get("hits", 0) == 2)


func test_cache_stats_misses_incremented() -> void:
	print("test_cache_stats_misses_incremented:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve") or not cache.has_method("stats"):
		check("AnnotationResolveCache instantiable with required methods", false)
		return
	var host = _CountingHost.new()
	var a1 = _anchor("core", "text.range", {"start": 0, "end": 5})
	var a2 = _anchor("core", "text.range", {"start": 10, "end": 20})
	cache.resolve(a1, host, "main")
	cache.resolve(a2, host, "main")
	var stats = cache.stats()
	check("stats.misses == 2 after two unique anchors", stats.get("misses", 0) == 2)


func test_cache_stats_size_reported() -> void:
	print("test_cache_stats_size_reported:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve") or not cache.has_method("stats"):
		check("AnnotationResolveCache instantiable with required methods", false)
		return
	var host = _CountingHost.new()
	cache.resolve(_anchor("core", "text.range", {"start": 0, "end": 5}), host, "main")
	cache.resolve(_anchor("core", "text.range", {"start": 10, "end": 20}), host, "main")
	var stats = cache.stats()
	check("stats.size == 2 after two entries", stats.get("size", 0) == 2)


# ── Tests: anchor key format ──────────────────────────────────────────────────

func test_anchor_key_format_scalar_id() -> void:
	print("test_anchor_key_format_scalar_id:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("_anchor_key"):
		check("AnnotationResolveCache has _anchor_key method", false)
		return
	var key = cache._anchor_key(_anchor("cad", "edge", 42), "iso")
	check("key contains plugin/type", "cad/edge" in key)
	check("key contains id", "42" in key)
	check("key contains view_context", "iso" in key)


func test_anchor_key_format_includes_view_context() -> void:
	print("test_anchor_key_format_includes_view_context:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("_anchor_key"):
		check("AnnotationResolveCache has _anchor_key method", false)
		return
	var key_iso = cache._anchor_key(_anchor("cad", "edge", 1), "iso")
	var key_top = cache._anchor_key(_anchor("cad", "edge", 1), "top")
	check("different view_context → different keys", key_iso != key_top)


func test_anchor_key_format_non_scalar_id_json_encoded() -> void:
	print("test_anchor_key_format_non_scalar_id_json_encoded:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("_anchor_key"):
		check("AnnotationResolveCache has _anchor_key method", false)
		return
	var anchor = _anchor("core", "text.range", {"start": 10, "end": 25})
	var key = cache._anchor_key(anchor, "main")
	check("dict id encoded into key (contains start or end)", "10" in key or "25" in key)


# ── Tests: LRU eviction ───────────────────────────────────────────────────────

func test_cache_evicts_oldest_at_5000_entries() -> void:
	print("test_cache_evicts_oldest_at_5000_entries:")
	var cache = _make_cache()
	if cache == null or not cache.has_method("resolve") or not cache.has_method("stats"):
		check("AnnotationResolveCache instantiable with required methods", false)
		return
	var host = _CountingHost.new()
	for i in range(5001):
		cache.resolve(_anchor("core", "text.range", {"start": i, "end": i + 1}), host, "main")
	var stats = cache.stats()
	check("cache size does not exceed 5000 after overflow",
		stats.get("size", 0) <= 5000)
	check("evictions > 0 after overflow",
		stats.get("evictions", 0) > 0)


# ── Mock helpers ──────────────────────────────────────────────────────────────

class _CountingHost extends RefCounted:
	var call_count: int = 0

	func resolve_anchor(anchor: Dictionary) -> Dictionary:
		call_count += 1
		var pos = anchor.get("snapshot", {}).get("position", [0.0, 0.0])
		return {
			"position": Vector2(float(pos[0]), float(pos[1])),
			"bounds": Rect2(0, 0, 0, 0),
			"stale": false,
			"view_metadata": {}
		}
