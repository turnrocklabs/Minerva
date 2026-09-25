class_name MCPExecutionContext
extends RefCounted
## Native call provenance and one shared lifetime across nested dispatch.
## This is host-owned state, never authority supplied in tool arguments.

class Lifetime extends RefCounted:
	signal cancelled
	var reason := ""
	var deadline_ms: int = 0
	## Set when a plugin backend call is sent (begin_dispatch()).
	var dispatched := false
	## Seconds a backend call may take from when it is sent; 0 for no such
	## budget.
	var dispatch_seconds := 0.0
	## What a caller stopped part-way needs to recover from the effects so far
	## (such as the id of an item already created), with the tool that made
	## them: stopped_result() gives it, as it was when the call stopped, as
	## its "recovery". `dispatch_recovery`, when set, becomes `recovery` once
	## the next backend call is sent (begin_dispatch()), so a call stopped
	## before that is not told of an effect never attempted.
	var recovery := {}
	var dispatch_recovery := {}
	var _stopped_recovery := {}

	func stop(value: String) -> void:
		if reason.is_empty():
			reason = value
			# Frozen before anyone hears of the stop, so every stopped result
			# tells the same.
			_stopped_recovery = recovery.duplicate(true)
			cancelled.emit()

class Completion extends RefCounted:
	signal finished
	var done := false
	var result: Dictionary = {}

	func finish(value: Dictionary) -> void:
		if done:
			return
		done = true
		result = value
		finished.emit()

var origin := "module"
var caller_chat_id := ""
var agent_id := ""
var plugin_id := ""
var provider_plugin_id := ""
var call_id := Crypto.new().generate_random_bytes(16).hex_encode()
var lifetime := Lifetime.new()


static func create(source: String, chat_id: String = "", external_agent: String = "",
		timeout_seconds: float = 0.0) -> MCPExecutionContext:
	var context := MCPExecutionContext.new()
	context.origin = source
	context.caller_chat_id = chat_id
	context.agent_id = external_agent
	if timeout_seconds > 0.0:
		context.lifetime.deadline_ms = Time.get_ticks_msec() + ceili(timeout_seconds * 1000.0)
	return context


func for_plugin(owner: String) -> MCPExecutionContext:
	var child := MCPExecutionContext.new()
	child.origin = origin
	child.caller_chat_id = caller_chat_id
	child.agent_id = agent_id
	child.plugin_id = owner
	child.provider_plugin_id = provider_plugin_id
	child.call_id = call_id
	child.lifetime = lifetime
	return child


func for_provider(owner: String) -> MCPExecutionContext:
	var child := for_plugin(plugin_id)
	child.provider_plugin_id = owner
	return child


## Marks the backend call as sent. A lifetime with dispatch_seconds gets its
## deadline now, so the time spent before (policy admission, the host's
## checks) does not shorten the call.
func begin_dispatch() -> void:
	lifetime.dispatched = true
	if not lifetime.dispatch_recovery.is_empty():
		lifetime.recovery = lifetime.dispatch_recovery.duplicate(true)
	if lifetime.dispatch_seconds > 0.0:
		lifetime.deadline_ms = Time.get_ticks_msec() + ceili(lifetime.dispatch_seconds * 1000.0)


func cancel() -> void:
	lifetime.stop("cancelled")


func is_stopped() -> bool:
	if lifetime.deadline_ms > 0 and Time.get_ticks_msec() >= lifetime.deadline_ms:
		lifetime.stop("deadline_exceeded")
	return not lifetime.reason.is_empty()


func stopped_result() -> Dictionary:
	var result := {"success": false, "error": "MCP call %s" % lifetime.reason,
		"error_code": lifetime.reason}
	if not lifetime._stopped_recovery.is_empty():
		result["recovery"] = lifetime._stopped_recovery.duplicate(true)
	return result


func remaining_seconds(default_seconds: float = 120.0) -> float:
	if lifetime.deadline_ms == 0:
		return default_seconds
	var remaining := maxf(0.001, float(lifetime.deadline_ms - Time.get_ticks_msec()) / 1000.0)
	return minf(default_seconds, remaining) if default_seconds > 0.0 else remaining


## Abandon this caller immediately without cancelling other calls. Already
## executing native mutations cannot be rolled back; nested dispatch checks
## the same lifetime before starting another operation.
func run(operation: Callable) -> Dictionary:
	if is_stopped():
		return stopped_result()
	var completion := Completion.new()
	var on_cancel := func() -> void: completion.finish(stopped_result())
	lifetime.cancelled.connect(on_cancel)
	var timer: SceneTreeTimer = null
	var on_deadline := func() -> void: lifetime.stop("deadline_exceeded")
	if lifetime.deadline_ms > 0:
		timer = Engine.get_main_loop().create_timer(remaining_seconds(0.0))
		timer.timeout.connect(on_deadline)
	_complete(operation, completion)
	if not completion.done:
		await completion.finished
	if lifetime.cancelled.is_connected(on_cancel):
		lifetime.cancelled.disconnect(on_cancel)
	if timer != null and timer.timeout.is_connected(on_deadline):
		timer.timeout.disconnect(on_deadline)
	return completion.result


func _complete(operation: Callable, completion: Completion) -> void:
	var result: Dictionary = await operation.call()
	completion.finish(stopped_result() if is_stopped() else result)
