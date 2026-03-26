class_name ToolBudgetManager
extends RefCounted
## Manages the active tools array with LRU eviction and token budget enforcement.
## Tools are activated via minerva_tool_search and pruned when budget is exceeded.

const DEFAULT_BUDGET: int = 3000  # max tokens for tool schemas
const PROTECTED_TOOL: String = "minerva_tool_search"  # never pruned

## Active tool entry: {schema: Dictionary, last_used_turn: int, token_cost: int}
var _active_tools: Dictionary = {}
var _current_turn: int = 0
var _token_budget: int = DEFAULT_BUDGET


func _init(budget: int = DEFAULT_BUDGET) -> void:
	_token_budget = budget


## Activate a tool — add its schema to the active set.
## Auto-prunes LRU tools if adding would exceed budget.
func activate_tool(name: String, schema: Dictionary) -> void:
	if _active_tools.has(name):
		_active_tools[name].last_used_turn = _current_turn
		return  # already active, just refresh

	var cost: int = _estimate_tokens(schema)

	# Prune until we have room
	while get_token_usage() + cost > _token_budget:
		var pruned: bool = _prune_one()
		if not pruned:
			break  # can't prune anything (only protected tools left)

	_active_tools[name] = {
		"schema": schema,
		"last_used_turn": _current_turn,
		"token_cost": cost,
	}


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


## Advance to the next turn.
func advance_turn() -> void:
	_current_turn += 1


## Get current turn number.
func get_current_turn() -> int:
	return _current_turn


## Reset to initial state (compaction). Only tool_search survives if it was active.
func reset() -> void:
	var search_entry = _active_tools.get(PROTECTED_TOOL)
	_active_tools.clear()
	if search_entry:
		_active_tools[PROTECTED_TOOL] = search_entry
	_current_turn = 0


## Set the token budget.
func set_budget(budget: int) -> void:
	_token_budget = budget


## Get the token budget.
func get_budget() -> int:
	return _token_budget


# ── Internal ──────────────────────────────────────────────────────────

## Prune the least recently used non-protected tool. Returns true if something was pruned.
func _prune_one() -> bool:
	var oldest_name: String = ""
	var oldest_turn: int = _current_turn + 1  # higher than any possible turn

	for name in _active_tools:
		if name == PROTECTED_TOOL:
			continue
		if _active_tools[name].last_used_turn < oldest_turn:
			oldest_turn = _active_tools[name].last_used_turn
			oldest_name = name

	if oldest_name.is_empty():
		return false

	_active_tools.erase(oldest_name)
	return true


## Estimate token cost of a tool schema (~4 chars per token on JSON).
func _estimate_tokens(schema: Dictionary) -> int:
	var json_str: String = JSON.stringify(schema)
	return maxi(1, json_str.length() / 4)
