class_name MCPApplicationError
extends RefCounted
## Normalize the two historical application error text aliases without
## replacing structured error data or bounded diagnostics.

static func normalize(value: Dictionary) -> Dictionary:
	var failed := (not bool(value.get("success", true)) if value.has("success") \
		else value.has("error") or bool(value.get("isError", false)))
	if not failed:
		return value
	var message := str(value.get("error_message", ""))
	var error_value: Variant = value.get("error")
	if message.is_empty():
		if error_value is String:
			message = error_value
		elif error_value is Dictionary:
			message = str((error_value as Dictionary).get("message", ""))
	if message.is_empty() and value.get("text") is String:
		message = str(value.text)
	if not message.is_empty():
		value["error_message"] = message.left(512)
		if not value.has("error"):
			value["error"] = value["error_message"]
	return value
