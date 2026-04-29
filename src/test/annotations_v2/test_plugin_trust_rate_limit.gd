extends SceneTree
## Contract tests for plugin trust boundary: rate-limit thresholds (task #11).
## Run: godot --headless --path src --script test/annotations_v2/test_plugin_trust_rate_limit.gd
##
## RED in Round 1 — AnnotationTrustManager does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_plugin_trust_rate_limit ===\n")

	print("-- render: N=5 threshold --")
	test_render_threshold_is_5()
	test_render_4_throws_not_suspended()
	test_render_5_throws_suspended()
	test_render_6_throws_still_suspended()

	print("\n-- resolver: N=5 threshold --")
	test_resolver_threshold_is_5()
	test_resolver_4_throws_not_suspended()
	test_resolver_5_throws_suspended()

	print("\n-- apply-tool: N=3 threshold --")
	test_apply_tool_threshold_is_3()
	test_apply_tool_2_throws_not_suspended()
	test_apply_tool_3_throws_suspended()

	print("\n-- cooldown period --")
	test_suspension_cooldown_property_exists()
	test_throws_outside_window_dont_count()

	print("\n-- diagnostics --")
	test_get_throw_history_window_param()
	test_suspension_entry_has_required_fields()

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


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_tm() -> Variant:
	if not ClassDB.class_exists("AnnotationTrustManager"):
		return null
	return ClassDB.instantiate("AnnotationTrustManager")


func _get_const(tm: Object, const_name: String) -> Variant:
	if tm == null:
		return null
	return tm.get(const_name)


# ── Render threshold tests ────────────────────────────────────────────────────

func test_render_threshold_is_5() -> void:
	print("test_render_threshold_is_5:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	var threshold = _get_const(tm, "RENDER_THROW_THRESHOLD")
	check("AnnotationTrustManager.RENDER_THROW_THRESHOLD == 5",
		threshold == 5)


func test_render_4_throws_not_suspended() -> void:
	print("test_render_4_throws_not_suspended:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	if not tm.has_method("record_render_throw") or not tm.has_method("is_kind_suspended"):
		check("required methods exist", false)
		return
	for _i in range(4):
		tm.record_render_throw("test_kind", "err")
	check("4 render throws: kind NOT suspended", not tm.is_kind_suspended("test_kind"))


func test_render_5_throws_suspended() -> void:
	print("test_render_5_throws_suspended:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	if not tm.has_method("record_render_throw") or not tm.has_method("is_kind_suspended"):
		check("required methods exist", false)
		return
	for _i in range(5):
		tm.record_render_throw("test_kind", "err")
	check("5 render throws: kind IS suspended", tm.is_kind_suspended("test_kind"))


func test_render_6_throws_still_suspended() -> void:
	print("test_render_6_throws_still_suspended:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	if not tm.has_method("record_render_throw") or not tm.has_method("is_kind_suspended"):
		check("required methods exist", false)
		return
	for _i in range(6):
		tm.record_render_throw("test_kind", "err")
	check("6 render throws: kind STILL suspended", tm.is_kind_suspended("test_kind"))


# ── Resolver threshold tests ──────────────────────────────────────────────────

func test_resolver_threshold_is_5() -> void:
	print("test_resolver_threshold_is_5:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	var threshold = _get_const(tm, "RESOLVER_THROW_THRESHOLD")
	check("AnnotationTrustManager.RESOLVER_THROW_THRESHOLD == 5",
		threshold == 5)


func test_resolver_4_throws_not_suspended() -> void:
	print("test_resolver_4_throws_not_suspended:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	if not tm.has_method("record_resolver_throw") or not tm.has_method("is_anchor_type_suspended"):
		check("required methods exist", false)
		return
	for _i in range(4):
		tm.record_resolver_throw("cad", "edge", "err")
	check("4 resolver throws: anchor type NOT suspended", not tm.is_anchor_type_suspended("cad", "edge"))


func test_resolver_5_throws_suspended() -> void:
	print("test_resolver_5_throws_suspended:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	if not tm.has_method("record_resolver_throw") or not tm.has_method("is_anchor_type_suspended"):
		check("required methods exist", false)
		return
	for _i in range(5):
		tm.record_resolver_throw("cad", "edge", "err")
	check("5 resolver throws: anchor type IS suspended", tm.is_anchor_type_suspended("cad", "edge"))


# ── Apply-tool threshold tests ────────────────────────────────────────────────

func test_apply_tool_threshold_is_3() -> void:
	print("test_apply_tool_threshold_is_3:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	var threshold = _get_const(tm, "APPLY_TOOL_THROW_THRESHOLD")
	check("AnnotationTrustManager.APPLY_TOOL_THROW_THRESHOLD == 3",
		threshold == 3)


func test_apply_tool_2_throws_not_suspended() -> void:
	print("test_apply_tool_2_throws_not_suspended:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	if not tm.has_method("record_apply_tool_throw") or not tm.has_method("is_apply_tool_suspended"):
		check("required methods exist", false)
		return
	for _i in range(2):
		tm.record_apply_tool_throw("my_tool", "commit", "err")
	check("2 apply-tool throws: tool NOT suspended", not tm.is_apply_tool_suspended("my_tool"))


func test_apply_tool_3_throws_suspended() -> void:
	print("test_apply_tool_3_throws_suspended:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	if not tm.has_method("record_apply_tool_throw") or not tm.has_method("is_apply_tool_suspended"):
		check("required methods exist", false)
		return
	for _i in range(3):
		tm.record_apply_tool_throw("my_tool", "commit", "err")
	check("3 apply-tool throws: tool IS suspended", tm.is_apply_tool_suspended("my_tool"))


# ── Cooldown period tests ─────────────────────────────────────────────────────

func test_suspension_cooldown_property_exists() -> void:
	print("test_suspension_cooldown_property_exists:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	# Contract: suspension cooldown is 5 minutes (300 seconds)
	var val = _get_const(tm, "SUSPENSION_COOLDOWN_SECONDS")
	check("AnnotationTrustManager.SUSPENSION_COOLDOWN_SECONDS == 300",
		val == 300)


func test_throws_outside_window_dont_count() -> void:
	print("test_throws_outside_window_dont_count:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	# Throws outside the 60s window should not count toward suspension
	# We can't easily test this without mocking time, but we verify the
	# window parameter is documented
	var val = _get_const(tm, "THROW_WINDOW_SECONDS")
	check("AnnotationTrustManager.THROW_WINDOW_SECONDS == 60",
		val == 60)


# ── Diagnostics tests ─────────────────────────────────────────────────────────

func test_get_throw_history_window_param() -> void:
	print("test_get_throw_history_window_param:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	if not tm.has_method("get_throw_history"):
		check("get_throw_history exists", false)
		return
	tm.record_render_throw("kind", "err")
	var history_60 = tm.get_throw_history(60)
	var history_0 = tm.get_throw_history(0)
	check("get_throw_history(60) returns throws in last 60s", history_60.size() >= 1)
	check("get_throw_history(0) returns empty (no throws in 0s window)",
		history_0.size() == 0)


func test_suspension_entry_has_required_fields() -> void:
	print("test_suspension_entry_has_required_fields:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = _make_tm()
	if tm == null:
		check("AnnotationTrustManager instantiable", false)
		return
	if not tm.has_method("record_render_throw") or not tm.has_method("get_suspensions"):
		check("required methods exist", false)
		return
	for _i in range(5):
		tm.record_render_throw("test_kind", "error message")
	var suspensions = tm.get_suspensions()
	if suspensions.size() > 0:
		var s = suspensions[0]
		check("suspension entry has type", s.has("type"))
		check("suspension entry has name", s.has("name"))
		check("suspension entry has throw_count", s.has("throw_count"))
		check("suspension entry has suspended_at", s.has("suspended_at"))
		check("suspension entry has error_samples", s.has("error_samples"))
	else:
		check("suspensions not empty after 5 throws", false)
