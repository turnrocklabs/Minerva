extends SceneTree

const AnnotationTrustManagerScript = preload("res://Scripts/Services/Annotations/AnnotationTrustManager.gd")
const AnnotationResolveCacheScript = preload("res://Scripts/Services/Annotations/AnnotationResolveCache.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_plugin_trust_resolver ===\n")
	test_resolver_throw_recorded()
	test_anchor_type_not_suspended_below_threshold()
	test_anchor_type_suspended_after_5_throws()
	test_resume_anchor_type_clears_suspension()
	test_resolver_error_result_cached_as_stale_entry()
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


func _tm() -> RefCounted:
	return AnnotationTrustManagerScript.new()


func test_resolver_throw_recorded() -> void:
	var tm := _tm()
	tm.record_resolver_throw("cad", "edge", "edge lost")
	var history: Array = tm.get_throw_history(60)
	check("resolver throw appears in history", history.size() == 1)
	check("resolver throw name is plugin/type", history[0].get("name", "") == "cad/edge")


func test_anchor_type_not_suspended_below_threshold() -> void:
	var tm := _tm()
	for _i in range(4):
		tm.record_resolver_throw("cad", "edge", "error")
	check("anchor type not suspended after 4 throws", not tm.is_anchor_type_suspended("cad", "edge"))


func test_anchor_type_suspended_after_5_throws() -> void:
	var tm := _tm()
	for _i in range(5):
		tm.record_resolver_throw("pcb", "net", "error")
	check("pcb/net suspended after 5 throws", tm.is_anchor_type_suspended("pcb", "net"))
	check("cad/edge not suspended independently", not tm.is_anchor_type_suspended("cad", "edge"))


func test_resume_anchor_type_clears_suspension() -> void:
	var tm := _tm()
	for _i in range(5):
		tm.record_resolver_throw("cad", "edge", "err")
	check("suspended before resume", tm.is_anchor_type_suspended("cad", "edge"))
	tm.resume_anchor_type("cad", "edge")
	check("not suspended after resume", not tm.is_anchor_type_suspended("cad", "edge"))


func test_resolver_error_result_cached_as_stale_entry() -> void:
	var cache := AnnotationResolveCacheScript.new()
	var host := _ThrowingHost.new()
	var anchor := {"plugin": "cad", "type": "edge", "id": 5, "snapshot": {"position": [10.0, 20.0]}}
	var result: Dictionary = cache.resolve(anchor, host, "iso")
	check("cache returns stale=true when resolver reports error", result.get("stale", false))
	check("cache preserves resolver error", result.has("error"))
	var hits_before: int = cache.stats().get("hits", 0)
	cache.resolve(anchor, host, "iso")
	check("stale error result is cached", cache.stats().get("hits", 0) == hits_before + 1)


class _ThrowingHost extends RefCounted:
	func resolve_anchor(_anchor: Dictionary) -> Dictionary:
		return {"position": Vector2.ZERO, "bounds": Rect2(), "stale": true, "view_metadata": {}, "error": "simulated"}
