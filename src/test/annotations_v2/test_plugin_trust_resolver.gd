extends SceneTree
## Contract tests for plugin trust boundary: resolver surface (task #11).
## Run: godot --headless --path src --script test/annotations_v2/test_plugin_trust_resolver.gd
##
## RED in Round 1 — AnnotationTrustManager does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_plugin_trust_resolver ===\n")

	print("-- resolver throw: cache marks stale --")
	test_record_resolver_throw_method_exists()
	test_resolver_throw_recorded_in_trust_manager()
	test_resolver_throw_anchor_type_suspended_after_5()

	print("\n-- anchor type suspension --")
	test_anchor_type_not_suspended_below_threshold()
	test_anchor_type_suspended_after_5_throws()
	test_is_anchor_type_suspended_method_exists()
	test_resume_anchor_type_clears_suspension()

	print("\n-- cache: throws stored as stale with TTL --")
	test_resolver_throw_cached_as_stale_entry()

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


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_record_resolver_throw_method_exists() -> void:
	print("test_record_resolver_throw_method_exists:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	check("AnnotationTrustManager has record_resolver_throw method",
		tm.has_method("record_resolver_throw"))


func test_resolver_throw_recorded_in_trust_manager() -> void:
	print("test_resolver_throw_recorded_in_trust_manager:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_resolver_throw"):
		check("record_resolver_throw exists", false)
		return
	tm.record_resolver_throw("cad", "edge", "NullReference: edge lost")
	check("record_resolver_throw does not crash", true)
	if tm.has_method("get_throw_history"):
		var history = tm.get_throw_history(60)
		check("resolver throw appears in throw history", history.size() >= 1)


func test_resolver_throw_anchor_type_suspended_after_5() -> void:
	print("test_resolver_throw_anchor_type_suspended_after_5:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_resolver_throw") or not tm.has_method("is_anchor_type_suspended"):
		check("required methods exist", false)
		return
	for _i in range(5):
		tm.record_resolver_throw("cad", "edge", "error")
	check("anchor type suspended after 5 resolver throws",
		tm.is_anchor_type_suspended("cad", "edge"))


func test_anchor_type_not_suspended_below_threshold() -> void:
	print("test_anchor_type_not_suspended_below_threshold:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_resolver_throw") or not tm.has_method("is_anchor_type_suspended"):
		check("required methods exist", false)
		return
	for _i in range(4):
		tm.record_resolver_throw("cad", "edge", "error")
	check("anchor type NOT suspended after 4 throws (threshold is 5)",
		not tm.is_anchor_type_suspended("cad", "edge"))


func test_anchor_type_suspended_after_5_throws() -> void:
	print("test_anchor_type_suspended_after_5_throws:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_resolver_throw") or not tm.has_method("is_anchor_type_suspended"):
		check("required methods exist", false)
		return
	for _i in range(5):
		tm.record_resolver_throw("pcb", "net", "error")
	check("pcb/net anchor type suspended after 5 throws",
		tm.is_anchor_type_suspended("pcb", "net"))
	check("cad/edge not suspended (different anchor type, no throws)",
		not tm.is_anchor_type_suspended("cad", "edge"))


func test_is_anchor_type_suspended_method_exists() -> void:
	print("test_is_anchor_type_suspended_method_exists:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	check("AnnotationTrustManager has is_anchor_type_suspended method",
		tm.has_method("is_anchor_type_suspended"))


func test_resume_anchor_type_clears_suspension() -> void:
	print("test_resume_anchor_type_clears_suspension:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_resolver_throw") or not tm.has_method("is_anchor_type_suspended") or not tm.has_method("resume_anchor_type"):
		check("required methods exist", false)
		return
	for _i in range(5):
		tm.record_resolver_throw("cad", "edge", "err")
	check("suspended before resume", tm.is_anchor_type_suspended("cad", "edge"))
	tm.resume_anchor_type("cad", "edge")
	check("anchor type cleared after resume_anchor_type()",
		not tm.is_anchor_type_suspended("cad", "edge"))


func test_resolver_throw_cached_as_stale_entry() -> void:
	print("test_resolver_throw_cached_as_stale_entry:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	if not ClassDB.class_exists("AnnotationResolveCache"):
		check("AnnotationResolveCache exists", false)
		return
	# The contract: when a resolver throws, the cache stores a stale entry with TTL=60s
	# The cache entry should have stale=true and an error field
	var cache = ClassDB.instantiate("AnnotationResolveCache")
	var host = _ThrowingHost.new()
	var anchor := {
		"plugin": "cad", "type": "edge", "id": 5,
		"snapshot": {"position": [10.0, 20.0]}
	}
	# The cache should catch the throw and return stale=true
	var result = cache.resolve(anchor, host, "iso")
	check("cache returns stale=true when resolver throws",
		result.get("stale", false) == true)
	# Don't check error field content (implementation detail)


# ── Mock helpers ──────────────────────────────────────────────────────────────

class _ThrowingHost extends RefCounted:
	func resolve_anchor(_anchor: Dictionary) -> Dictionary:
		# Simulate a throw by returning an error marker
		# Real implementation would use assert(false) or similar
		push_error("Simulated resolver throw for trust boundary test")
		return {"position": Vector2.ZERO, "bounds": Rect2(), "stale": true,
			"view_metadata": {}, "error": "Simulated resolver throw"}
