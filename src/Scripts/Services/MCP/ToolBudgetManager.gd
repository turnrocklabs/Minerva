class_name ToolBudgetManager
extends RefCounted
## Manages the active tools array with LRU eviction and token budget enforcement.
## Tools are activated via minerva_tool_search and pruned when budget is exceeded.

const DEFAULT_BUDGET: int = 10000  # max tokens for tool schemas
const DEFAULT_MAX_IDLE_TURNS: int = 0  # 0 = disabled, >0 = evict tools unused for N turns
## Tools that are never pruned from the active set.
const PROTECTED_TOOLS: Array[String] = ["minerva_tool_search", "minerva_list_skills", "minerva_get_skill"]

## Active tool entry: {schema: Dictionary, last_used_turn: int, token_cost: int}
var _active_tools: Dictionary = {}
## Skill/search batches keep their admitted tools together through the next
## model-facing turn. Entries expire automatically; permanent tools stay in
## PROTECTED_TOOLS.
var _protected_until_turn: Dictionary = {}
var _current_turn: int = 0
var _token_budget: int = DEFAULT_BUDGET
var _max_idle_turns: int = DEFAULT_MAX_IDLE_TURNS


func _init(budget: int = DEFAULT_BUDGET) -> void:
	_token_budget = budget


## Activate a tool and report whether it remains callable. LRU entries may be
## evicted to make room, but an over-budget schema is never inserted. An
## active tool whose schema changed is admitted afresh at its new cost; if
## that does not fit, it is no longer active rather than kept stale.
func activate_tool(name: String, schema: Dictionary) -> Dictionary:
	if _active_tools.has(name):
		if _active_tools[name].schema == schema:
			_active_tools[name].last_used_turn = _current_turn
			return {"active": true, "name": name,
				"token_cost": int(_active_tools[name].token_cost), "evicted": []}
		_active_tools.erase(name)

	var cost: int = _estimate_tokens(schema)
	var evicted: Array[String] = []
	# Do not evict ordinary tools when this schema cannot fit alongside the
	# workflows that are currently leased. Such eviction cannot make the
	# requested activation succeed.
	if _protected_token_usage() + cost > _token_budget:
		return {"active": false, "name": name, "token_cost": cost,
			"reason": "tool schema does not fit alongside protected workflows",
			"evicted": evicted}

	# Prune until we have room
	while get_token_usage() + cost > _token_budget:
		var pruned: String = _prune_one()
		if pruned.is_empty():
			break  # can't prune anything (only protected tools left)
		evicted.append(pruned)

	if get_token_usage() + cost > _token_budget:
		return {"active": false, "name": name, "token_cost": cost,
			"reason": "tool schema does not fit the active token budget",
			"evicted": evicted}

	_active_tools[name] = {
		"schema": schema,
		"last_used_turn": _current_turn,
		"token_cost": cost,
	}
	return {"active": true, "name": name, "token_cost": cost,
		"evicted": evicted}


## Admit a related set without allowing later members to evict earlier ones.
## Successfully admitted tools stay protected through the next provider tool
## refresh, then return to ordinary LRU behavior.
func activate_group(schemas: Array[Dictionary]) -> Dictionary:
	var requested: Array[String] = []
	var by_name: Dictionary = {}
	for schema: Dictionary in schemas:
		var name := str(schema.get("name", ""))
		if name.is_empty() or by_name.has(name):
			continue
		requested.append(name)
		by_name[name] = schema

	var previous_leases: Dictionary = {}
	for name: String in requested:
		previous_leases[name] = int(_protected_until_turn.get(name, -1))
		_protected_until_turn[name] = maxi(int(_protected_until_turn.get(name, -1)),
			_current_turn + 1)

	var activated: Array[String] = []
	var rejected: Array[Dictionary] = []
	var evicted: Array[String] = []
	for name: String in requested:
		var outcome: Dictionary = activate_tool(name, by_name[name])
		for evicted_name: String in outcome.get("evicted", []):
			if evicted_name not in evicted:
				evicted.append(evicted_name)
		if outcome.get("active", false) and is_active(name):
			activated.append(name)
		else:
			rejected.append({"name": name, "token_cost": outcome.get("token_cost", 0),
				"reason": outcome.get("reason", "tool was not admitted")})
			var previous_expiry: int = int(previous_leases.get(name, -1))
			if previous_expiry >= 0:
				_protected_until_turn[name] = previous_expiry
			else:
				_protected_until_turn.erase(name)

	return {"activated": activated, "rejected": rejected, "evicted": evicted,
		"token_usage": get_token_usage(), "token_budget": _token_budget}


## Mark a tool as used this turn (updates LRU).
func mark_used(name: String) -> void:
	if _active_tools.has(name):
		_active_tools[name].last_used_turn = _current_turn


## Get all active tool schemas (for the API request tools array).
func get_active_schemas() -> Array[Dictionary]:
	var schemas: Array[Dictionary] = []
	for name in _active_tools:
		schemas.append(_active_tools[name].schema)
	return schemas


## Get current total token usage.
func get_token_usage() -> int:
	var total: int = 0
	for name in _active_tools:
		total += _active_tools[name].token_cost
	return total


## Get count of active tools.
func get_active_count() -> int:
	return _active_tools.size()


## Check if a tool is active.
func is_active(name: String) -> bool:
	return _active_tools.has(name)


## Try to use a tool. Returns the schema if active, or an error dict if pruned.
func try_call(name: String) -> Dictionary:
	if _active_tools.has(name):
		_active_tools[name].last_used_turn = _current_turn
		return {"active": true, "schema": _active_tools[name].schema}
	return {
		"active": false,
		"error": "Tool '%s' is not loaded. Call minerva_tool_search('%s') to activate it." % [name, name]
	}


## Advance to the next turn. Evicts tools idle for too long.
func advance_turn() -> void:
	_current_turn += 1
	for name: String in _protected_until_turn.keys():
		if int(_protected_until_turn[name]) < _current_turn:
			_protected_until_turn.erase(name)
	if _max_idle_turns > 0:
		var to_evict: Array[String] = []
		for name in _active_tools:
			if _is_protected(name):
				continue
			if _current_turn - _active_tools[name].last_used_turn > _max_idle_turns:
				to_evict.append(name)
		for name in to_evict:
			_active_tools.erase(name)


## Get current turn number.
func get_current_turn() -> int:
	return _current_turn


## Reset to initial state (compaction). Only tool_search survives if it was active.
func reset() -> void:
	var saved: Dictionary = {}
	for pname in PROTECTED_TOOLS:
		if _active_tools.has(pname):
			saved[pname] = _active_tools[pname]
	_active_tools.clear()
	_active_tools.merge(saved)
	_protected_until_turn.clear()
	_current_turn = 0


## Set the token budget and enforce a reduction immediately. A reduction that
## cannot contain the currently protected workflow is rejected without
## changing the budget or evicting unrelated tools.
func set_budget(budget: int) -> Dictionary:
	var requested := maxi(0, budget)
	var previous := _token_budget
	if _protected_token_usage() > requested:
		return {"applied": false, "requested_budget": requested,
			"token_budget": previous, "token_usage": get_token_usage(),
			"evicted": [],
			"reason": "requested budget is smaller than protected workflow schemas"}

	var evicted: Array[String] = []
	while get_token_usage() > requested:
		var pruned := _prune_one()
		if pruned.is_empty():
			return {"applied": false, "requested_budget": requested,
				"token_budget": previous, "token_usage": get_token_usage(),
				"evicted": evicted,
				"reason": "requested budget cannot be enforced"}
		evicted.append(pruned)
	_token_budget = requested
	return {"applied": true, "requested_budget": requested,
		"token_budget": _token_budget, "token_usage": get_token_usage(),
		"evicted": evicted}


## Get the token budget.
func get_budget() -> int:
	return _token_budget


## Set the max idle turns before eviction. 0 = disabled.
func set_max_idle_turns(turns: int) -> void:
	_max_idle_turns = turns


## Get the max idle turns setting.
func get_max_idle_turns() -> int:
	return _max_idle_turns


# ── Internal ──────────────────────────────────────────────────────────

## Prune the least recently used non-protected tool. Returns its name or "".
func _prune_one() -> String:
	var oldest_name: String = ""
	var oldest_turn: int = _current_turn + 1  # higher than any possible turn

	for name in _active_tools:
		if _is_protected(name):
			continue
		if _active_tools[name].last_used_turn < oldest_turn:
			oldest_turn = _active_tools[name].last_used_turn
			oldest_name = name

	if oldest_name.is_empty():
		return ""

	_active_tools.erase(oldest_name)
	_protected_until_turn.erase(oldest_name)
	return oldest_name


func _is_protected(name: String) -> bool:
	return name in PROTECTED_TOOLS \
		or int(_protected_until_turn.get(name, -1)) >= _current_turn


func _protected_token_usage() -> int:
	var total := 0
	for name: String in _active_tools:
		if _is_protected(name):
			total += int(_active_tools[name].token_cost)
	return total


## Calibrated provider-neutral fallback. UTF-8 bytes are conservative for
## non-ASCII schemas; provider-specific tokenizers belong at the provider seam.
func _estimate_tokens(schema: Dictionary) -> int:
	var json_str: String = JSON.stringify(schema)
	return maxi(1, ceili(float(json_str.to_utf8_buffer().size()) / 4.0))
