class_name AutocoderLogStore
extends RefCounted

var current_status: String = ""
var review_state: String = ""
var ai_review_summary: String = ""
var review_result: Dictionary = {}
var patch_uri: String = ""
var archive_uri: String = ""

var actions_by_id: Dictionary = {}
var issues: Array[Dictionary] = []

var raw_events: Array[Dictionary] = []
var llm_events: Array[Dictionary] = []

var _seen_action_status: Dictionary = {}
var _seen_issue_keys: Dictionary = {}


func reset() -> void:
	current_status = ""
	review_state = ""
	ai_review_summary = ""
	review_result = {}
	patch_uri = ""
	archive_uri = ""
	actions_by_id.clear()
	issues.clear()
	raw_events.clear()
	llm_events.clear()
	_seen_action_status.clear()
	_seen_issue_keys.clear()


func apply_iteration(payload: Dictionary) -> Dictionary:
	var updates := {
		"new_issues": []
	}

	if payload.has("status"):
		var status_value = payload.get("status", "")
		current_status = "" if status_value == null else str(status_value)

	if payload.has("review_state"):
		var review_value = payload.get("review_state", "")
		review_state = "" if review_value == null else str(review_value)

	if payload.has("ai_review_summary"):
		var summary_value = payload.get("ai_review_summary", "")
		ai_review_summary = "" if summary_value == null else str(summary_value)

	var result = payload.get("review_result", null)
	if result is Dictionary:
		review_result = result
		updates["new_issues"] = _extract_issues_from_review_result(result)

	var found_patch = str(payload.get("patch_uri", ""))
	var found_archive = str(payload.get("archive_uri", ""))

	if result is Dictionary:
		if found_patch.is_empty():
			found_patch = str(result.get("patch_uri", ""))
		if found_archive.is_empty():
			found_archive = str(result.get("archive_uri", ""))

	if not found_patch.is_empty():
		patch_uri = found_patch
	if not found_archive.is_empty():
		archive_uri = found_archive

	return updates


func register_action(payload: Dictionary) -> Dictionary:
	var action_id = str(payload.get("action_id", ""))
	var status = str(payload.get("status", ""))

	if not _should_accept_action(action_id, status):
		return {"accepted": false}

	var action_type = str(payload.get("action_type", ""))
	if not action_id.is_empty():
		actions_by_id[action_id] = payload

	if action_type == "review_finding":
		var issue = _issue_from_action(payload)
		if _add_issue(issue):
			return {"accepted": true, "kind": "issue", "issue": issue, "action_type": action_type}
		return {"accepted": false}

	if action_type == "tool_call":
		return {"accepted": true, "kind": "tool", "action_type": action_type}

	return {"accepted": true, "kind": "action", "action_type": action_type}


func has_running_action() -> bool:
	if review_state == "ai_review" or current_status == "in_review":
		return true

	for action in actions_by_id.values():
		if str(action.get("status", "")) == "in_progress":
			return true

	return false


func get_snapshot() -> String:
	var snapshot = {
		"status": current_status,
		"review_state": review_state,
		"summary": ai_review_summary,
		"patch_uri": patch_uri,
		"archive_uri": archive_uri,
		"actions": actions_by_id.size(),
		"issues": issues.size(),
		"raw_events": raw_events.size(),
		"llm_events": llm_events.size()
	}
	return JSON.stringify(snapshot)


func _should_accept_action(action_id: String, status: String) -> bool:
	if action_id.is_empty():
		return true

	var key = "%s:%s" % [action_id, status]
	if _seen_action_status.has(key):
		return false

	_seen_action_status[key] = true
	return true


func _issue_from_action(payload: Dictionary) -> Dictionary:
	var details = payload.get("details", {})
	return {
		"file": str(details.get("file", "")),
		"line": str(details.get("line", "")),
		"severity": str(details.get("severity", "")),
		"summary": str(payload.get("summary", details.get("summary", ""))),
		"code_excerpt": str(details.get("code_excerpt", "")),
		"has_fix": bool(details.get("has_fix", false))
	}


func _extract_issues_from_review_result(result: Dictionary) -> Array[Dictionary]:
	var new_issues: Array[Dictionary] = []
	var review_list: Array = []

	if result.has("reviews") and result.get("reviews") is Array:
		review_list = result.get("reviews", [])
	elif result.has("issues") and result.get("issues") is Array:
		review_list = [{"issues": result.get("issues", [])}]

	for review in review_list:
		if not (review is Dictionary):
			continue
		var issues_data = review.get("issues", [])
		if not (issues_data is Array):
			continue
		for issue_data in issues_data:
			if not (issue_data is Dictionary):
				continue
			var issue = {
				"file": str(issue_data.get("file", "")),
				"line": str(issue_data.get("line", "")),
				"severity": str(issue_data.get("severity", "")),
				"summary": str(issue_data.get("summary", issue_data.get("message", ""))),
				"code_excerpt": str(issue_data.get("code_excerpt", "")),
				"has_fix": bool(issue_data.get("has_fix", false))
			}
			if _add_issue(issue):
				new_issues.append(issue)

	return new_issues


func _add_issue(issue: Dictionary) -> bool:
	var key = "%s:%s:%s:%s" % [
		issue.get("file", ""),
		issue.get("line", ""),
		issue.get("severity", ""),
		issue.get("summary", "")
	]

	if _seen_issue_keys.has(key):
		return false

	_seen_issue_keys[key] = true
	issues.append(issue)
	return true
