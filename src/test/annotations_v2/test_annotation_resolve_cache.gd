extends SceneTree
## Behavioral tests for AnnotationResolveCache (task #5).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_resolve_cache.gd

const AnnotationResolveCacheScript = preload("res://Scripts/Services/Annotations/AnnotationResolveCache.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_resolve_cache ===\n")

	print("-- cache: hit/miss --")
	test_cache_hit_returns_cached_result()
	test_cache_miss_calls_host_resolve()
	test_cache_key_includes_view_context()

	print("\n-- cache: invalidation --")
	test_bump_revision_causes_miss_on_next_read()
	test_invalidate_all_clears_cache()
	test_invalidate_by_anchor_type_clears_matching()
	test_invalidate_by_anchor_type_leaves_non_matching()

	print("\n-- cache: stats --")
	test_cache_stats_initial()
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
		printerr("  FAIL: %s - expected %s, got %s" % [description, str(expected), str(actual)])


func _anchor(plugin: String, anchor_type: String, id: Variant) -> Dictionary:
	return {
		"plugin": plugin,
		"type": anchor_type,
		"id": id,
		"snapshot": {"position": [0.0, 0.0]}
	}


func _make_cache() -> RefCounted:
	return AnnotationResolveCacheScript.new()


func test_cache_hit_returns_cached_result() -> void:
	print("test_cache_hit_returns_cached_result:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	var anchor := _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "editor:main")
	var call_count_after_first := host.call_count
	var second: Dictionary = cache.resolve(anchor, host, "editor:main")
	check("cache hit does not call host.resolve_anchor again", host.call_count == call_count_after_first)
	check_eq("cache hit returns cached position", second.get("position", Vector2.ZERO), Vector2(0.0, 0.0))


func test_cache_miss_calls_host_resolve() -> void:
	print("test_cache_miss_calls_host_resolve:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	cache.resolve(_anchor("core", "text.range", {"start": 0, "end": 5}), host, "editor:main")
	check_eq("cache miss calls host.resolve_anchor", host.call_count, 1)


func test_cache_key_includes_view_context() -> void:
	print("test_cache_key_includes_view_context:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	var anchor := _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "editor:main")
	cache.resolve(anchor, host, "editor:side")
	check_eq("different view contexts produce separate cache entries", host.call_count, 2)


func test_bump_revision_causes_miss_on_next_read() -> void:
	print("test_bump_revision_causes_miss_on_next_read:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	var anchor := _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "editor:main")
	var before_bump := host.call_count
	cache.bump_revision()
	cache.resolve(anchor, host, "editor:main")
	check("bump_revision causes re-resolve on next access", host.call_count > before_bump)


func test_invalidate_all_clears_cache() -> void:
	print("test_invalidate_all_clears_cache:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	var anchor := _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "editor:main")
	cache.invalidate()
	cache.resolve(anchor, host, "editor:main")
	check_eq("invalidate all forces re-resolve", host.call_count, 2)


func test_invalidate_by_anchor_type_clears_matching() -> void:
	print("test_invalidate_by_anchor_type_clears_matching:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	var tr_anchor := _anchor("core", "text.range", {"start": 0, "end": 5})
	var gr_anchor := _anchor("core", "graphics.region", "region_1")
	cache.resolve(tr_anchor, host, "main")
	cache.resolve(gr_anchor, host, "main")
	var calls_after_first_two := host.call_count
	cache.invalidate("text.range")
	cache.resolve(tr_anchor, host, "main")
	cache.resolve(gr_anchor, host, "main")
	check_eq("invalidate(text.range) re-resolves only text.range", host.call_count, calls_after_first_two + 1)


func test_invalidate_by_anchor_type_leaves_non_matching() -> void:
	print("test_invalidate_by_anchor_type_leaves_non_matching:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	var tr_anchor := _anchor("core", "text.range", {"start": 0, "end": 5})
	var gr_anchor := _anchor("core", "graphics.region", "region_1")
	cache.resolve(tr_anchor, host, "main")
	cache.resolve(gr_anchor, host, "main")
	cache.invalidate("text.range")
	cache.resolve(gr_anchor, host, "main")
	check_eq("graphics.region stayed cached", host.call_count, 2)


func test_cache_stats_initial() -> void:
	print("test_cache_stats_initial:")
	var stats: Dictionary = _make_cache().stats()
	check_eq("initial misses=0", stats.get("misses", -1), 0)
	check_eq("initial hits=0", stats.get("hits", -1), 0)
	check_eq("initial size=0", stats.get("size", -1), 0)


func test_cache_stats_hits_incremented() -> void:
	print("test_cache_stats_hits_incremented:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	var anchor := _anchor("core", "text.range", {"start": 0, "end": 10})
	cache.resolve(anchor, host, "main")
	cache.resolve(anchor, host, "main")
	cache.resolve(anchor, host, "main")
	check_eq("stats.hits == 2 after two cache hits", cache.stats().get("hits", 0), 2)


func test_cache_stats_misses_incremented() -> void:
	print("test_cache_stats_misses_incremented:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	cache.resolve(_anchor("core", "text.range", {"start": 0, "end": 5}), host, "main")
	cache.resolve(_anchor("core", "text.range", {"start": 10, "end": 20}), host, "main")
	check_eq("stats.misses == 2 after two unique anchors", cache.stats().get("misses", 0), 2)


func test_cache_stats_size_reported() -> void:
	print("test_cache_stats_size_reported:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	cache.resolve(_anchor("core", "text.range", {"start": 0, "end": 5}), host, "main")
	cache.resolve(_anchor("core", "text.range", {"start": 10, "end": 20}), host, "main")
	check_eq("stats.size == 2 after two entries", cache.stats().get("size", 0), 2)


func test_anchor_key_format_scalar_id() -> void:
	print("test_anchor_key_format_scalar_id:")
	var key: String = _make_cache()._anchor_key(_anchor("cad", "edge", 42), "iso")
	check("key contains plugin/type", "cad/edge" in key)
	check("key contains id", "42" in key)
	check("key contains view_context", "iso" in key)


func test_anchor_key_format_includes_view_context() -> void:
	print("test_anchor_key_format_includes_view_context:")
	var key_iso: String = _make_cache()._anchor_key(_anchor("cad", "edge", 1), "iso")
	var key_top: String = _make_cache()._anchor_key(_anchor("cad", "edge", 1), "top")
	check("different view_context produces different keys", key_iso != key_top)


func test_anchor_key_format_non_scalar_id_json_encoded() -> void:
	print("test_anchor_key_format_non_scalar_id_json_encoded:")
	var key: String = _make_cache()._anchor_key(_anchor("core", "text.range", {"start": 10, "end": 25}), "main")
	check("dict id encoded into key", "10" in key and "25" in key)


func test_cache_evicts_oldest_at_5000_entries() -> void:
	print("test_cache_evicts_oldest_at_5000_entries:")
	var cache := _make_cache()
	var host := _CountingHost.new()
	for i in range(5001):
		cache.resolve(_anchor("core", "text.range", {"start": i, "end": i + 1}), host, "main")
	var stats: Dictionary = cache.stats()
	check("cache size does not exceed 5000", stats.get("size", 0) <= 5000)
	check("evictions > 0 after overflow", stats.get("evictions", 0) > 0)


class _CountingHost extends RefCounted:
	var call_count: int = 0

	func resolve_anchor(anchor: Dictionary) -> Dictionary:
		call_count += 1
		var pos: Variant = anchor.get("snapshot", {}).get("position", [0.0, 0.0])
		return {
			"position": Vector2(float(pos[0]), float(pos[1])),
			"bounds": Rect2(float(pos[0]), float(pos[1]), 0.0, 0.0),
			"stale": false,
			"view_metadata": {}
		}
