class_name AutocoderLogFormatter
extends RefCounted

static func format_status_label(review_state: String, status: String, is_running: bool, override_text: String = "") -> String:
	if not override_text.is_empty():
		return override_text

	if is_running:
		return "Running"

	if review_state == "awaiting_user":
		return "Awaiting user"

	if review_state == "ai_review" or status == "in_review":
		return "AI review running"

	if review_state == "complete" or status == "complete":
		return "Complete"

	if status == "error":
		return "Error"

	return "Idle"


static func format_action_summary(action_type: String, payload: Dictionary) -> String:
	match action_type:
		"generation":
			return "Generating code"
		"review_start":
			return "Review started"
		"review_model":
			var details = payload.get("details", {})
			var name = str(details.get("model_display_name", details.get("model_id", "")))
			return "Review model: %s" % (name if not name.is_empty() else "model")
		"review_fix":
			var summary = str(payload.get("summary", ""))
			return summary if not summary.is_empty() else "Applying fix"
		"tool_call":
			var details = payload.get("details", {})
			var tool = str(details.get("tool", "tool_call"))
			return "Tool call: %s" % tool
		_:
			var summary = str(payload.get("summary", ""))
			return summary if not summary.is_empty() else action_type.capitalize()


static func format_action_secondary(action_type: String, payload: Dictionary) -> String:
	var details = payload.get("details", {})

	if action_type == "review_model":
		var issue_count = details.get("issue_count", null)
		var fix_count = details.get("issues_with_fixes", details.get("fixes_count", null))
		var parts: Array[String] = []
		if issue_count != null:
			parts.append("issues: %s" % str(issue_count))
		if fix_count != null:
			parts.append("fixes: %s" % str(fix_count))
		return ", ".join(parts)

	if action_type == "tool_call":
		var description = str(details.get("description", ""))
		if not description.is_empty():
			return description

		var command = str(details.get("command", ""))
		if not command.is_empty():
			return command

		var path = str(details.get("path", ""))
		if not path.is_empty():
			return path

	return ""


static func format_issue_title(issue: Dictionary) -> String:
	var file = str(issue.get("file", ""))
	var line = str(issue.get("line", ""))
	if file.is_empty():
		return "Issue"
	if line.is_empty():
		return file
	return "%s:%s" % [file, line]
