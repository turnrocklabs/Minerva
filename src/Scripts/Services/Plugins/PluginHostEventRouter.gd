class_name PluginHostEventRouter
extends RefCounted
## Delivers host events to the running plugins that subscribed to them.
##
## A plugin receives event E only when its manifest lists E in
## permissions.host_events AND PluginPolicy grants
## PluginDefinition.host_event_grant(E). Every delivery attempt to a plugin
## that declared or was granted E is audited with the capability event types,
## under the grant key as `capability`; a plugin with neither never asked and
## is skipped without an audit entry.
##
## Wire form (built by the injected sender, MCPServerConnection.send_host_event):
##   {"jsonrpc":"2.0","method":"minerva/host_event","params":{"event":E,"payload":{...}}}

const JsonSerialization = preload("res://Scripts/Services/MCP/MCPJsonSerialization.gd")
const PayloadLimits = preload("res://Scripts/Services/Plugins/PluginPayloadLimits.gd")

const EVENT_CHAT_TURN_COMPLETED := "chat.turn_completed"
const EVENT_CHAT_DIRECTORY_CHANGED := "chat.directory_changed"

## Bound on a payload's encoded size, below PluginPayloadLimits.CONTROL_BYTES
## by headroom for the notification envelope around it.
const PAYLOAD_MAX_BYTES: int = PayloadLimits.CONTROL_BYTES - 256

## Audit reason of a plugin whose protocol cannot carry host events.
const REASON_PROTOCOL_UNSUPPORTED := "host_events_unsupported_protocol"

var _policy: PluginPolicy
var _audit_log: PluginAuditLog
## () -> Array[PluginDefinition]: the plugins that are running now.
var _running_plugins: Callable
## (plugin_id: String, event: String, payload: Dictionary) -> Error
var _send: Callable
## (message: String) -> void: shows the user a refusal. Optional.
var _notify: Callable
## Plugin ids refused at their last start (see plugin_started).
var _refused: Dictionary = {}


func _init(policy: PluginPolicy, audit_log: PluginAuditLog,
		running_plugins: Callable, send: Callable, notify: Callable = Callable()) -> void:
	_policy = policy
	_audit_log = audit_log
	_running_plugins = running_plugins
	_send = send
	_notify = notify


## Call when `plugin` has started. A plugin that declares host_events on a
## protocol that cannot carry them is refused here, loudly and once per start,
## and skipped by publish until it starts on one that can.
func plugin_started(plugin: PluginDefinition, accepts_host_events: bool) -> void:
	_refused.erase(plugin.id)
	if plugin.host_events.is_empty() or accepts_host_events:
		return
	_refused[plugin.id] = true
	var message := "Plugin '%s' declares host events %s, but its MCP protocol cannot receive them; it will get none." % [
		plugin.id, str(Array(plugin.host_events))]
	push_error("[PluginHostEventRouter] " + message)
	if _audit_log != null:
		_audit_log.log_event(plugin.id, PluginAuditLog.EVENT_CAPABILITY_DENIED,
			{"capability": "host_events", "reason": REASON_PROTOCOL_UNSUPPORTED})
	if _notify.is_valid():
		_notify.call(message)


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
	var too_large: bool = encoded_size(bounded) > PAYLOAD_MAX_BYTES
	var plugins: Array = _running_plugins.call()
	for plugin: PluginDefinition in plugins:
		if _refused.has(plugin.id):
			continue
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
		if too_large:
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


## UTF-8 bytes of `payload` as the wire encodes it (MCPJsonSerialization,
## which MCPServerConnection writes with): escapes such as a raw ESC's six
## bytes count. A payload that cannot be encoded never fits.
static func encoded_size(payload: Dictionary) -> int:
	var encoded: Dictionary = JsonSerialization.encode(payload)
	if not encoded.get("ok", false):
		return PAYLOAD_MAX_BYTES + 1
	return str(encoded.raw).to_utf8_buffer().size()


## `payload` with its `text` shortened until encoded_size fits
## PAYLOAD_MAX_BYTES; `truncated` says whether it was. Only payloads carrying
## `text` get the `truncated` key. The caller's dictionary is not changed.
static func bound_payload(payload: Dictionary) -> Dictionary:
	var bounded := payload.duplicate(true)
	if not bounded.has("text"):
		return bounded
	var text := str(bounded["text"])
	bounded["text"] = text
	bounded["truncated"] = false
	if encoded_size(bounded) <= PAYLOAD_MAX_BYTES:
		return bounded
	bounded["truncated"] = true
	var fits := 0
	# Every character encodes to at least one byte, so no longer prefix can fit.
	var too_long := mini(text.length(), PAYLOAD_MAX_BYTES)
	while too_long - fits > 1:
		var middle: int = (fits + too_long) >> 1
		bounded["text"] = text.left(middle)
		if encoded_size(bounded) <= PAYLOAD_MAX_BYTES:
			fits = middle
		else:
			too_long = middle
	bounded["text"] = text.left(fits)
	return bounded


func _audit(plugin_id: String, event_type: String, key: String, event: String, reason: String) -> void:
	if _audit_log == null:
		return
	var detail := {"capability": key, "host_event": event}
	if not reason.is_empty():
		detail["reason"] = reason
	_audit_log.log_event(plugin_id, event_type, detail)
