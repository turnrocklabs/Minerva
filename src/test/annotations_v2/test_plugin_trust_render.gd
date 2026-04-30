extends SceneTree

const AnnotationTrustManagerScript = preload("res://Scripts/Services/Annotations/AnnotationTrustManager.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_plugin_trust_render ===\n")
	test_record_render_throw()
	test_render_throw_history()
	test_kind_not_suspended_below_threshold()
	test_kind_suspended_after_5_throws()
	test_resume_kind_clears_suspension()
	test_get_suspensions_includes_suspended_kind()
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


func test_record_render_throw() -> void:
	var tm := _tm()
	tm.record_render_throw("my_kind", "boom")
	check("record_render_throw does not crash", true)


func test_render_throw_history() -> void:
	var tm := _tm()
	tm.record_render_throw("my_kind", "test error")
	var history: Array = tm.get_throw_history(60)
	check("throw history has recorded render throw", history.size() == 1)
	check("history entry surface is render", history[0].get("type", "") == "render")


func test_kind_not_suspended_below_threshold() -> void:
	var tm := _tm()
	for i in range(4):
		tm.record_render_throw("my_kind", "error %d" % i)
	check("kind not suspended after 4 throws", not tm.is_kind_suspended("my_kind"))


func test_kind_suspended_after_5_throws() -> void:
	var tm := _tm()
	for i in range(5):
		tm.record_render_throw("throwing_kind", "error %d" % i)
	check("kind suspended after 5 throws", tm.is_kind_suspended("throwing_kind"))


func test_resume_kind_clears_suspension() -> void:
	var tm := _tm()
	for _i in range(5):
		tm.record_render_throw("suspended_kind", "err")
	check("kind suspended before resume", tm.is_kind_suspended("suspended_kind"))
	tm.resume_kind("suspended_kind")
	check("kind no longer suspended after resume", not tm.is_kind_suspended("suspended_kind"))


func test_get_suspensions_includes_suspended_kind() -> void:
	var tm := _tm()
	for _i in range(5):
		tm.record_render_throw("suspended_kind", "err")
	var suspensions: Array = tm.get_suspensions()
	var found := false
	for s in suspensions:
		if s.get("name", "") == "suspended_kind":
			found = true
			check("suspension has throw_count", s.has("throw_count"))
			check("suspension has error_samples", s.has("error_samples"))
	check("suspended_kind in suspensions", found)
