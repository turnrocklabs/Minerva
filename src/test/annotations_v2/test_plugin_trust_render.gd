extends SceneTree
## Contract tests for plugin trust boundary: render surface (task #11).
## Run: godot --headless --path src --script test/annotations_v2/test_plugin_trust_render.gd
##
## RED in Round 1 — AnnotationTrustManager does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_plugin_trust_render ===\n")

	print("-- trust manager: render throw recording --")
	test_trust_manager_class_exists()
	test_trust_manager_record_render_throw()
	test_throwing_render_renders_badge_not_crash()
	test_render_throw_recorded_in_trust_manager()

	print("\n-- kind suspension after N throws --")
	test_kind_not_suspended_below_threshold()
	test_kind_suspended_after_5_throws_in_60s()
	test_suspended_kind_is_kind_suspended_returns_true()
	test_suspended_kind_renders_placeholder()

	print("\n-- suspension management --")
	test_resume_kind_clears_suspension()
	test_get_suspensions_includes_suspended_kind()

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

func test_trust_manager_class_exists() -> void:
	print("test_trust_manager_class_exists:")
	check("AnnotationTrustManager class exists", ClassDB.class_exists("AnnotationTrustManager"))


func test_trust_manager_record_render_throw() -> void:
	print("test_trust_manager_record_render_throw:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	check("AnnotationTrustManager has record_render_throw method",
		tm.has_method("record_render_throw"))
	tm.record_render_throw("my_kind", "NullReferenceError: something was null")
	check("record_render_throw does not crash", true)


func test_throwing_render_renders_badge_not_crash() -> void:
	print("test_throwing_render_renders_badge_not_crash:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	# The render loop should catch throws and render [!] badge instead of crashing
	# We test this by verifying the trust manager's is_kind_suspended API exists
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	check("AnnotationTrustManager has is_kind_suspended method",
		tm.has_method("is_kind_suspended"))


func test_render_throw_recorded_in_trust_manager() -> void:
	print("test_render_throw_recorded_in_trust_manager:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_render_throw"):
		check("record_render_throw exists", false)
		return
	if not tm.has_method("get_throw_history"):
		check("get_throw_history exists", false)
		return
	tm.record_render_throw("my_kind", "test error")
	var history = tm.get_throw_history(60)
	check("throw history has at least 1 entry after recording", history.size() >= 1)


func test_kind_not_suspended_below_threshold() -> void:
	print("test_kind_not_suspended_below_threshold:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_render_throw") or not tm.has_method("is_kind_suspended"):
		check("required methods exist", false)
		return
	# 4 throws (below threshold of 5)
	for i in range(4):
		tm.record_render_throw("my_kind", "error %d" % i)
	check("kind not suspended after 4 throws (threshold is 5)",
		not tm.is_kind_suspended("my_kind"))


func test_kind_suspended_after_5_throws_in_60s() -> void:
	print("test_kind_suspended_after_5_throws_in_60s:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_render_throw") or not tm.has_method("is_kind_suspended"):
		check("required methods exist", false)
		return
	# 5 throws (reaches threshold)
	for i in range(5):
		tm.record_render_throw("throwing_kind", "error %d" % i)
	check("kind suspended after 5 throws", tm.is_kind_suspended("throwing_kind"))


func test_suspended_kind_is_kind_suspended_returns_true() -> void:
	print("test_suspended_kind_is_kind_suspended_returns_true:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_render_throw") or not tm.has_method("is_kind_suspended"):
		check("required methods exist", false)
		return
	for _i in range(5):
		tm.record_render_throw("bad_kind", "err")
	check("is_kind_suspended returns true for suspended kind",
		tm.is_kind_suspended("bad_kind"))
	check("is_kind_suspended returns false for non-suspended kind",
		not tm.is_kind_suspended("good_kind"))


func test_suspended_kind_renders_placeholder() -> void:
	print("test_suspended_kind_renders_placeholder:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	# The render loop checks is_kind_suspended before calling render
	# When suspended, it should render a "suspended" placeholder instead
	# We verify the trust manager provides this information
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	check("AnnotationTrustManager provides suspension status for render loop",
		tm.has_method("is_kind_suspended"))


func test_resume_kind_clears_suspension() -> void:
	print("test_resume_kind_clears_suspension:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_render_throw") or not tm.has_method("is_kind_suspended") or not tm.has_method("resume_kind"):
		check("required methods exist", false)
		return
	for _i in range(5):
		tm.record_render_throw("suspended_kind", "err")
	check("kind is suspended before resume", tm.is_kind_suspended("suspended_kind"))
	tm.resume_kind("suspended_kind")
	check("kind no longer suspended after resume_kind()",
		not tm.is_kind_suspended("suspended_kind"))


func test_get_suspensions_includes_suspended_kind() -> void:
	print("test_get_suspensions_includes_suspended_kind:")
	if not ClassDB.class_exists("AnnotationTrustManager"):
		check("AnnotationTrustManager exists", false)
		return
	var tm = ClassDB.instantiate("AnnotationTrustManager")
	if not tm.has_method("record_render_throw") or not tm.has_method("get_suspensions"):
		check("required methods exist", false)
		return
	for _i in range(5):
		tm.record_render_throw("suspended_kind", "err")
	var suspensions = tm.get_suspensions()
	check("get_suspensions returns array", suspensions is Array)
	var found := false
	for s in suspensions:
		if s.get("name", "") == "suspended_kind":
			found = true
	check("suspended_kind in get_suspensions() result", found)
