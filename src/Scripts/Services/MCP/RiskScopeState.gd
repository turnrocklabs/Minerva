class_name RiskScopeState
extends RefCounted
## Session-scoped risk state with hybrid expiry (action-count window + time TTL).
## No Node dependencies, no I/O, no signals — purely in-memory runtime state.
##
## Scope entry shape:
##   { "actions_remaining": int, "expires_at_ms": int }

var _scopes: Dictionary = {}  # scope_name (String) → entry (Dictionary)


## Create or refresh a scope.
## max_actions  — number of tick() calls the scope survives.
## max_ttl_ms   — wall-clock lifetime in milliseconds from activation.
func activate(scope_name: String, max_actions: int = 10, max_ttl_ms: int = 300000) -> void:
	_scopes[scope_name] = {
		"actions_remaining": max_actions,
		"expires_at_ms": Time.get_ticks_msec() + max_ttl_ms,
	}


## Returns true if the scope exists, has remaining actions, and is within TTL.
## Removes the scope and returns false if either condition is violated.
func is_active(scope_name: String) -> bool:
	if not _scopes.has(scope_name):
		return false

	var entry: Dictionary = _scopes[scope_name]

	var expired_by_time: bool = Time.get_ticks_msec() >= entry["expires_at_ms"]
	var expired_by_count: bool = entry["actions_remaining"] <= 0

	if expired_by_time or expired_by_count:
		_scopes.erase(scope_name)
		return false

	return true


## Called once per tool execution. Decrements action counts for all active
## scopes and prunes any that reach zero.
func tick() -> void:
	var to_remove: Array[String] = []

	for scope_name in _scopes:
		var entry: Dictionary = _scopes[scope_name]
		entry["actions_remaining"] -= 1
		if entry["actions_remaining"] <= 0:
			to_remove.append(scope_name)

	for scope_name in to_remove:
		_scopes.erase(scope_name)


## Returns the names of all currently active scopes (time- and count-valid).
func get_active_scopes() -> Array[String]:
	var now_ms: int = Time.get_ticks_msec()
	var active: Array[String] = []
	var to_remove: Array[String] = []

	for scope_name in _scopes:
		var entry: Dictionary = _scopes[scope_name]
		if now_ms >= entry["expires_at_ms"] or entry["actions_remaining"] <= 0:
			to_remove.append(scope_name)
		else:
			active.append(scope_name)

	for scope_name in to_remove:
		_scopes.erase(scope_name)

	return active


## Reset all scopes (for session reset).
func clear() -> void:
	_scopes.clear()
