class_name AnnotationApplyToolRunner
extends RefCounted
## Trust-aware dry-run/commit wrapper for annotation apply tools.

const AnnotationTrustManagerScript = preload("res://Scripts/Services/Annotations/AnnotationTrustManager.gd")

var trust_manager: Object = null


func _init(p_trust_manager: Object = null) -> void:
	trust_manager = p_trust_manager if p_trust_manager != null else AnnotationTrustManagerScript.new()


func apply(tool_id: String, annotation_id: String, hook: Callable, host: Object = null) -> Dictionary:
	if trust_manager != null and trust_manager.is_apply_tool_suspended(tool_id):
		return {"ok": false, "error": "%s suspended" % tool_id}
	if not hook.is_valid():
		return {"ok": false, "error": "invalid apply hook"}

	var dry_run := _call_hook(tool_id, hook, annotation_id, "dry_run")
	if not dry_run.get("ok", false):
		return dry_run

	var snapshot: Variant = null
	if host != null and host.has_method("capture_state_snapshot"):
		snapshot = host.call("capture_state_snapshot")

	var commit := _call_hook(tool_id, hook, annotation_id, "commit")
	if not commit.get("ok", false):
		if host != null and host.has_method("restore_state_snapshot") and snapshot != null:
			host.call("restore_state_snapshot", snapshot)
		return commit

	return {"ok": true}


func _call_hook(tool_id: String, hook: Callable, annotation_id: String, phase: String) -> Dictionary:
	var result: Variant = hook.call(annotation_id, phase)
	if result is Dictionary:
		var dict: Dictionary = result
		if not dict.has("ok"):
			dict["ok"] = true
		if not dict.get("ok", false) and trust_manager != null:
			trust_manager.record_apply_tool_throw(tool_id, phase, str(dict.get("error", "apply tool failed")))
		return dict
	return {"ok": false, "error": "apply hook returned non-dictionary"}
