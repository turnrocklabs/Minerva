class_name PluginHostEventRouter
extends RefCounted
## Delivers host events to the running plugins that subscribed to them.
##
## A plugin receives event E only when its manifest lists E in
## permissions.host_events AND PluginPolicy grants
## PluginDefinition.host_event_grant(E). Every delivery attempt to a plugin
## that declared or was granted E is audited with the capability event types,
## under the grant key as `capability`; a plugin with neither is not
## subscribed and is skipped silently.
##
## Wire form (built by the injected sender, MCPServerConnection.send_host_event):
##   {"jsonrpc":"2.0","method":"minerva/host_event","params":{"event":E,"payload":{...}}}

const EVENT_CHAT_TURN_COMPLETED := "chat.turn_completed"
const EVENT_CHAT_DIRECTORY_CHANGED := "chat.directory_changed"

## Message text is cut to this many UTF-8 bytes so the whole notification
## stays within PluginPayloadLimits.CONTROL_BYTES with room for the other keys.
const TEXT_MAX_BYTES := 60 * 1024

var _policy: PluginPolicy
var _audit_log: PluginAuditLog
## () -> Array[PluginDefinition]: the plugins that are running now.
var _running_plugins: Callable
## (plugin_id: String, event: String, payload: Dictionary) -> Error
var _send: Callable


func _init(policy: PluginPolicy, audit_log: PluginAuditLog,
		running_plugins: Callable, send: Callable) -> void:
	_policy = policy
	_audit_log = audit_log
	_running_plugins = running_plugins
	_send = send


## Deliver `event` with `payload` to each subscribed plugin. Returns the plugin
## ids per result: {"delivered": [...], "denied": [...], "failed": [...]}.
func publish(event: String, payload: Dictionary) -> Dictionary:
	var delivered: Array[String] = []
	var denied: Array[String] = []
	var failed: Array[String] = []
	var result := {"delivered": delivered, "denied": denied, "failed": failed}
	if not PluginDefinition.ALLOWED_HOST_EVENTS.has(event):
		push_warning("[PluginHostEventRouter] Refusing unknown host event '%s'" % event)
		return result
	var bounded := bound_payload(payload)
	var key: String = PluginDefinition.host_event_grant(event)
	var size_error: Dictionary = PluginPayloadLimits.check(bounded)
	var plugins: Array = _running_plugins.call()
	for plugin: PluginDefinition in plugins:
		var declared: bool = plugin.host_events.has(event)
		if not declared and not _policy.is_capability_granted(plugin.id, key):
			continue
		if not declared:
			_audit(plugin.id, PluginAuditLog.EVENT_CAPABILITY_DENIED, key, event, "not_declared")
			denied.append(plugin.id)
			continue
		if not _policy.check_grant(plugin.id, key):
			_audit(plugin.id, PluginAuditLog.EVENT_CAPABILITY_DENIED, key, event,
				PluginErrors.CODE_CAPABILITY_NOT_GRANTED)
			denied.append(plugin.id)
			continue
		if not size_error.is_empty():
			_audit(plugin.id, PluginAuditLog.EVENT_CAPABILITY_FAILED, key, event,
				PluginErrors.CODE_PAYLOAD_TOO_LARGE)
			failed.append(plugin.id)
			continue
		var sent: Error = _send.call(plugin.id, event, bounded)
		if sent == OK:
			_audit(plugin.id, PluginAuditLog.EVENT_CAPABILITY_DISPATCHED, key, event, "")
			delivered.append(plugin.id)
		else:
			_audit(plugin.id, PluginAuditLog.EVENT_CAPABILITY_FAILED, key, event, error_string(sent))
			failed.append(plugin.id)
	return result


## `payload` with its `text` cut to TEXT_MAX_BYTES on a character boundary;
## `truncated` says whether it was cut. Only payloads carrying `text` get the
## `truncated` key. The caller's dictionary is not changed.
static func bound_payload(payload: Dictionary) -> Dictionary:
	var bounded := payload.duplicate(true)
	if not bounded.has("text"):
		return bounded
	var bytes: PackedByteArray = str(bounded["text"]).to_utf8_buffer()
	bounded["truncated"] = bytes.size() > TEXT_MAX_BYTES
	if bounded["truncated"]:
		var end := TEXT_MAX_BYTES
		# 0b10xxxxxx bytes continue a character; cutting before one would split it.
		while end > 0 and (bytes[end] & 0xC0) == 0x80:
			end -= 1
		bounded["text"] = bytes.slice(0, end).get_string_from_utf8()
	return bounded


func _audit(plugin_id: String, event_type: String, key: String, event: String, reason: String) -> void:
	if _audit_log == null:
		return
	var detail := {"capability": key, "host_event": event}
	if not reason.is_empty():
		detail["reason"] = reason
	_audit_log.log_event(plugin_id, event_type, detail)
