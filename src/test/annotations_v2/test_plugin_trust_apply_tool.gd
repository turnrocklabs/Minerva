extends SceneTree

const AnnotationHostScript = preload("res://Scripts/Services/Annotations/AnnotationHost.gd")
const AnnotationTrustManagerScript = preload("res://Scripts/Services/Annotations/AnnotationTrustManager.gd")
const AnnotationApplyToolRunnerScript = preload("res://Scripts/Services/Annotations/AnnotationApplyToolRunner.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_plugin_trust_apply_tool ===\n")
	test_default_snapshot_virtuals()
	test_apply_tool_receives_phase_arg()
	test_dry_run_failure_blocks_commit()
	test_commit_failure_triggers_snapshot_restore()
	test_apply_tool_suspended_after_3_throws()
	test_resume_apply_tool_clears_suspension()
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


func test_default_snapshot_virtuals() -> void:
	var host := AnnotationHostScript.new()
	check("default capture_state_snapshot returns null", host.capture_state_snapshot() == null)
	check("default restore_state_snapshot returns false", host.restore_state_snapshot(null) == false)


func test_apply_tool_receives_phase_arg() -> void:
	var phases: Array = []
	var runner := AnnotationApplyToolRunnerScript.new()
	var result: Dictionary = runner.apply("tool", "ann_1", func(_id: String, phase: String) -> Dictionary:
		phases.append(phase)
		return {"ok": true}
	)
	check("apply succeeds", result.get("ok", false))
	check("dry_run phase sent", "dry_run" in phases)
	check("commit phase sent", "commit" in phases)


func test_dry_run_failure_blocks_commit() -> void:
	var phases: Array = []
	var runner := AnnotationApplyToolRunnerScript.new()
	var result: Dictionary = runner.apply("tool", "ann_1", func(_id: String, phase: String) -> Dictionary:
		phases.append(phase)
		if phase == "dry_run":
			return {"ok": false, "error": "dry run failed"}
		return {"ok": true}
	)
	check("dry-run failure returns ok=false", not result.get("ok", true))
	check("commit not called after dry-run failure", not "commit" in phases)


func test_commit_failure_triggers_snapshot_restore() -> void:
	var tm := AnnotationTrustManagerScript.new()
	var runner := AnnotationApplyToolRunnerScript.new(tm)
	var host := _SnapshotHost.new()
	var result: Dictionary = runner.apply("tool", "ann_1", func(_id: String, phase: String) -> Dictionary:
		if phase == "commit":
			return {"ok": false, "error": "commit failed"}
		return {"ok": true}
	, host)
	check("commit failure returns ok=false", not result.get("ok", true))
	check("snapshot captured", host.capture_count == 1)
	check("snapshot restored", host.restore_count == 1)
	check("apply tool throw recorded", tm.get_throw_history(60).size() == 1)


func test_apply_tool_suspended_after_3_throws() -> void:
	var tm := AnnotationTrustManagerScript.new()
	for _i in range(3):
		tm.record_apply_tool_throw("my_apply_tool", "commit", "error")
	check("apply tool suspended after 3 throws", tm.is_apply_tool_suspended("my_apply_tool"))
	var result: Dictionary = AnnotationApplyToolRunnerScript.new(tm).apply("my_apply_tool", "ann", func(_id, _phase): return {"ok": true})
	check("suspended tool blocks apply", not result.get("ok", true))


func test_resume_apply_tool_clears_suspension() -> void:
	var tm := AnnotationTrustManagerScript.new()
	for _i in range(3):
		tm.record_apply_tool_throw("suspended_tool", "commit", "err")
	check("suspended before resume", tm.is_apply_tool_suspended("suspended_tool"))
	tm.resume_apply_tool("suspended_tool")
	check("not suspended after resume", not tm.is_apply_tool_suspended("suspended_tool"))


class _SnapshotHost extends RefCounted:
	var capture_count := 0
	var restore_count := 0

	func capture_state_snapshot() -> Variant:
		capture_count += 1
		return {"snapshot": true}

	func restore_state_snapshot(_snapshot: Variant) -> bool:
		restore_count += 1
		return true
