extends SceneTree

const AnnotationTrustManagerScript = preload("res://Scripts/Services/Annotations/AnnotationTrustManager.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_plugin_trust_rate_limit ===\n")
	test_threshold_constants()
	test_render_threshold()
	test_resolver_threshold()
	test_apply_tool_threshold()
	test_history_window()
	test_suspension_entry_shape()
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
	check(description, actual == expected)


func _tm() -> RefCounted:
	return AnnotationTrustManagerScript.new()


func test_threshold_constants() -> void:
	var tm := _tm()
	check_eq("render threshold is 5", tm.RENDER_THROW_THRESHOLD, 5)
	check_eq("resolver threshold is 5", tm.RESOLVER_THROW_THRESHOLD, 5)
	check_eq("apply threshold is 3", tm.APPLY_TOOL_THROW_THRESHOLD, 3)
	check_eq("throw window is 60s", tm.THROW_WINDOW_SECONDS, 60)
	check_eq("cooldown is 300s", tm.SUSPENSION_COOLDOWN_SECONDS, 300)


func test_render_threshold() -> void:
	var tm := _tm()
	for _i in range(4):
		tm.record_render_throw("kind", "err")
	check("4 render throws not suspended", not tm.is_kind_suspended("kind"))
	tm.record_render_throw("kind", "err")
	check("5 render throws suspended", tm.is_kind_suspended("kind"))


func test_resolver_threshold() -> void:
	var tm := _tm()
	for _i in range(4):
		tm.record_resolver_throw("cad", "edge", "err")
	check("4 resolver throws not suspended", not tm.is_anchor_type_suspended("cad", "edge"))
	tm.record_resolver_throw("cad", "edge", "err")
	check("5 resolver throws suspended", tm.is_anchor_type_suspended("cad", "edge"))


func test_apply_tool_threshold() -> void:
	var tm := _tm()
	for _i in range(2):
		tm.record_apply_tool_throw("tool", "commit", "err")
	check("2 apply throws not suspended", not tm.is_apply_tool_suspended("tool"))
	tm.record_apply_tool_throw("tool", "commit", "err")
	check("3 apply throws suspended", tm.is_apply_tool_suspended("tool"))


func test_history_window() -> void:
	var tm := _tm()
	tm.record_render_throw("kind", "err")
	check("history 60s returns throw", tm.get_throw_history(60).size() == 1)
	check("history 0s returns empty", tm.get_throw_history(0).is_empty())


func test_suspension_entry_shape() -> void:
	var tm := _tm()
	for _i in range(5):
		tm.record_render_throw("kind", "err")
	var suspensions: Array = tm.get_suspensions()
	check("suspensions not empty", not suspensions.is_empty())
	var s: Dictionary = suspensions[0]
	check("suspension has type", s.has("type"))
	check("suspension has name", s.has("name"))
	check("suspension has throw_count", s.has("throw_count"))
	check("suspension has suspended_at", s.has("suspended_at"))
	check("suspension has error_samples", s.has("error_samples"))
