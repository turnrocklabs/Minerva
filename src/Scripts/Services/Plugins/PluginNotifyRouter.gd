## PluginNotifyRouter — translates host.notify JSON-RPC notifications (plugin → host)
## into Minerva toast notifications and Activity:MCP log entries.
##
## Wire format (plugin stdout, JSON-RPC 2.0 notification — no "id" field):
##   {"jsonrpc":"2.0","method":"host.notify",
##    "params":{"level":"info|warning|error","message":"...","details":<optional>}}
##
## Rules:
##   - level is case-insensitive; unknown level → push_warning + treat as info
##   - empty/missing message → push_warning + skip toast
##   - details (optional) → included in Activity log but not the toast
extends RefCounted

## Route a parsed host.notify message for the given plugin.
## Call this from the STDIO dispatcher whenever method == "host.notify".
static func route(plugin_id: String, params: Dictionary) -> void:
	var raw_level: String = str(params.get("level", "info")).to_lower().strip_edges()
	var message: String = str(params.get("message", "")).strip_edges()
	var details = params.get("details", null)

	# --- validate message ---
	if message.is_empty():
		push_warning("[PluginNotifyRouter] plugin '%s' sent host.notify with empty message — skipped" % plugin_id)
		return

	# --- resolve level ---
	var toast_type: int  # ToastNotification.Type value (int to avoid class_name dep)
	match raw_level:
		"info":
			toast_type = 0  # ToastNotification.Type.INFO
		"warning", "warn":
			toast_type = 1  # ToastNotification.Type.WARNING
		"error":
			toast_type = 2  # ToastNotification.Type.ERROR
		_:
			push_warning("[PluginNotifyRouter] plugin '%s' sent unknown level '%s' — treating as info" % [plugin_id, raw_level])
			toast_type = 0  # fallback to INFO

	# --- toast ---
	# SingletonObject.create_toast_notification uses ToastNotification.Type which
	# is an enum with integer values INFO=0, WARNING=1, ERROR=2.
	# We call via the stable public API; dynamic integer cast avoids the off-tree
	# class_name dependency.
	if SingletonObject and SingletonObject.has_method("create_toast_notification"):
		SingletonObject.call("create_toast_notification", message, toast_type)
	else:
		# Fallback: at least log to console
		match toast_type:
			2:
				push_error("[Plugin:%s] %s" % [plugin_id, message])
			1:
				push_warning("[Plugin:%s] %s" % [plugin_id, message])
			_:
				print("[Plugin:%s] %s" % [plugin_id, message])

	# --- Activity:MCP log ---
	_append_to_activity_log(plugin_id, raw_level, message, details)


## Append a structured entry to the Activity:MCP editor tab (or "Activity: MCP"
## if no agent_id is available).  Mirrors the format used by EditorPane._on_mcp_tool_executed.
static func _append_to_activity_log(plugin_id: String, level: String, message: String, details) -> void:
	# Resolve editor_pane through the standard singleton path.
	# TODO(host.notify): If EditorPane exposes a dedicated append_notification()
	# method in future, route through that instead of accessing code_edit directly.
	var ep = null
	if SingletonObject and SingletonObject.get("editor_pane") != null:
		ep = SingletonObject.editor_pane

	if ep == null or not ep.has_method("_get_or_create_activity_log"):
		# Activity surface not ready — log to console only.
		print("[PluginNotifyRouter] Activity surface unavailable; [%s] plugin=%s level=%s: %s" % [
			_timestamp(), plugin_id, level, message])
		return

	var editor = ep._get_or_create_activity_log("")  # "" → "Activity: MCP" tab

	if editor == null or editor.get("code_edit") == null:
		print("[PluginNotifyRouter] Activity editor/code_edit missing; [%s] plugin=%s level=%s: %s" % [
			_timestamp(), plugin_id, level, message])
		return

	var lines: PackedStringArray = []
	lines.append("── %s  host.notify [%s] ──" % [_timestamp(), level.to_upper()])
	lines.append("  plugin: %s" % plugin_id)
	lines.append("  message: %s" % message)
	if details != null:
		var details_str: String = JSON.stringify(details) if details is Dictionary or details is Array else str(details)
		if details_str.length() > 300:
			details_str = details_str.substr(0, 297) + "..."
		lines.append("  details: %s" % details_str)
	lines.append("")  # blank line between entries

	var entry: String = "\n".join(lines)
	var ce = editor.code_edit
	if ce.text.is_empty():
		ce.text = entry
	else:
		ce.text += "\n" + entry

	# Auto-scroll to bottom
	ce.set_caret_line(ce.get_line_count() - 1)


static func _timestamp() -> String:
	var t := Time.get_time_dict_from_system()
	return "%02d:%02d:%02d" % [t.hour, t.minute, t.second]
