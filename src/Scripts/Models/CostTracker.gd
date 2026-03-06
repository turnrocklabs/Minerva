class_name CostTracker
extends RefCounted
## Tracks API call costs across all providers.
## Records a ledger of every external API call with tokens, cost, and metadata.
## Provides query methods for cost aggregation and budget enforcement.

## Emitted after each cost record is added
signal cost_updated(entry: Dictionary)

## Emitted when a chat's spend reaches the warning threshold (default 80%)
signal budget_warning(chat_id: String, spent: float, budget: float)

## Emitted when a chat's spend exceeds its budget
signal budget_exceeded(chat_id: String, spent: float, budget: float)


## In-memory ledger of cost entries for the current month
var _ledger: Array[Dictionary] = []

## Budget state: chat_id -> {budget_usd: float, warn_pct: float}
var _budgets: Dictionary = {}

## Cost accumulated per chat (for fast budget checks without scanning ledger)
var _chat_costs: Dictionary = {}

## Valid budget time periods
const BUDGET_PERIODS := ["hour", "day", "week", "month"]

## Path prefix for ledger files
const _LEDGER_DIR := "user://cost_ledger"

## Path for persisted budget state
const _BUDGETS_PATH := "user://cost_budgets.json"

## Whether we have unsaved changes
var _dirty: bool = false

## Current month key (YYYY_MM) for file naming
var _current_month: String = ""


func _init() -> void:
	_current_month = _get_month_key()
	_load_ledger()
	_load_budgets()
	# Connect to chat_completed signal to track all API responses
	SingletonObject.chat_completed.connect(_on_chat_completed)


## Record a cost entry from a BotResponse (signal handler for non-ChatPane calls)
func _on_chat_completed(bot_response: BotResponse) -> void:
	if bot_response == null or bot_response.provider == null:
		return
	# Skip if ChatPane already recorded this (has chat_id set)
	if not bot_response.provider.chat_id.is_empty():
		return
	# Skip if no tokens (error responses, tool-only responses)
	if bot_response.prompt_tokens == 0 and bot_response.completion_tokens == 0:
		return
	# Skip local provider (free)
	if bot_response.provider.PROVIDER == SingletonObject.API_PROVIDER.LOCAL:
		return

	var provider = bot_response.provider
	var cost_usd: float = (
		bot_response.prompt_tokens * provider.input_token_cost +
		bot_response.completion_tokens * provider.output_token_cost
	) / 1_000_000.0

	var provider_name: String = SingletonObject.PROVIDER_DISPLAY_NAMES.get(
		provider.PROVIDER, "Unknown"
	)

	var entry: Dictionary = {
		"ts": Time.get_datetime_string_from_system(true),
		"provider": provider_name,
		"model": provider.model_name,
		"input_tokens": bot_response.prompt_tokens,
		"output_tokens": bot_response.completion_tokens,
		"cost_usd": cost_usd,
		"chat_id": "",  # Set by caller if available
	}

	_record_entry(entry)


## Record a cost entry with an explicit chat_id (called from ChatPane)
func record_chat_cost(bot_response: BotResponse, chat_id: String) -> void:
	if bot_response == null or bot_response.provider == null:
		return
	if bot_response.prompt_tokens == 0 and bot_response.completion_tokens == 0:
		return
	if bot_response.provider.PROVIDER == SingletonObject.API_PROVIDER.LOCAL:
		return

	var provider = bot_response.provider
	var cost_usd: float = (
		bot_response.prompt_tokens * provider.input_token_cost +
		bot_response.completion_tokens * provider.output_token_cost
	) / 1_000_000.0

	var provider_name: String = SingletonObject.PROVIDER_DISPLAY_NAMES.get(
		provider.PROVIDER, "Unknown"
	)

	var entry: Dictionary = {
		"ts": Time.get_datetime_string_from_system(true),
		"provider": provider_name,
		"model": provider.model_name,
		"input_tokens": bot_response.prompt_tokens,
		"output_tokens": bot_response.completion_tokens,
		"cost_usd": cost_usd,
		"chat_id": chat_id,
	}

	_record_entry(entry)


## Internal: add entry to ledger, update chat costs, check budgets
func _record_entry(entry: Dictionary) -> void:
	# Roll over month if needed
	var month_key := _get_month_key()
	if month_key != _current_month:
		save_ledger()
		_current_month = month_key
		_ledger.clear()

	_ledger.append(entry)
	_dirty = true

	# Update per-chat cost accumulator (lifetime, used by get_cost_for_chat)
	var chat_id: String = entry.get("chat_id", "")
	if not chat_id.is_empty():
		_chat_costs[chat_id] = _chat_costs.get(chat_id, 0.0) + entry["cost_usd"]

		# Check per-chat budget using period-scoped spend
		if _budgets.has(chat_id):
			var budget_info: Dictionary = _budgets[chat_id]
			var budget_usd: float = budget_info.get("budget_usd", 0.0)
			var warn_pct: float = budget_info.get("warn_pct", 0.8)
			var period: String = budget_info.get("period", "day")
			var spent: float = get_spend_for_period(period, chat_id)

			if budget_usd > 0:
				if spent >= budget_usd:
					budget_exceeded.emit(chat_id, spent, budget_usd)
				elif spent >= budget_usd * warn_pct:
					budget_warning.emit(chat_id, spent, budget_usd)

	# Update global accumulator (lifetime)
	_chat_costs["__global__"] = _chat_costs.get("__global__", 0.0) + entry["cost_usd"]
	if _budgets.has("__global__"):
		var g_info: Dictionary = _budgets["__global__"]
		var g_budget: float = g_info.get("budget_usd", 0.0)
		var g_warn: float = g_info.get("warn_pct", 0.8)
		var g_period: String = g_info.get("period", "day")
		var g_spent: float = get_spend_for_period(g_period, "__global__")
		if g_budget > 0:
			if g_spent >= g_budget:
				budget_exceeded.emit("__global__", g_spent, g_budget)
			elif g_spent >= g_budget * g_warn:
				budget_warning.emit("__global__", g_spent, g_budget)

	cost_updated.emit(entry)

	# Auto-save periodically (every 10 entries)
	if _ledger.size() % 10 == 0:
		save_ledger()


#region Budget Management

## Returns UTC datetime string for the rolling window start of the given period.
func _get_period_cutoff(period: String) -> String:
	var seconds: int
	match period:
		"hour":
			seconds = 3600
		"day":
			seconds = 86400
		"week":
			seconds = 7 * 86400
		"month":
			seconds = 30 * 86400
		_:
			seconds = 86400
	var cutoff_unix := Time.get_unix_time_from_system() - seconds
	return Time.get_datetime_string_from_unix_time(int(cutoff_unix), true)


## Sum cost_usd from ledger entries within the given period.
## If chat_id is "" or "__global__", sums all entries.
func get_spend_for_period(period: String, chat_id: String = "__global__") -> float:
	var cutoff := _get_period_cutoff(period)
	var total := 0.0
	var all_chats := chat_id.is_empty() or chat_id == "__global__"
	for entry in _ledger:
		if entry["ts"] < cutoff:
			continue
		if all_chats or entry.get("chat_id", "") == chat_id:
			total += entry["cost_usd"]
	return total


## Set a budget for a chat. Returns the previous budget (0 if none).
func set_budget(chat_id: String, budget_usd: float, warn_pct: float = 0.8, period: String = "day") -> float:
	var previous: float = 0.0
	if _budgets.has(chat_id):
		previous = _budgets[chat_id].get("budget_usd", 0.0)
	if period not in BUDGET_PERIODS:
		period = "day"
	_budgets[chat_id] = {"budget_usd": budget_usd, "warn_pct": warn_pct, "period": period}
	save_budgets()
	return previous


## Extend an existing budget by an additional amount
func extend_budget(chat_id: String, additional_usd: float) -> float:
	if not _budgets.has(chat_id):
		_budgets[chat_id] = {"budget_usd": additional_usd, "warn_pct": 0.8}
	else:
		_budgets[chat_id]["budget_usd"] += additional_usd
	save_budgets()
	return _budgets[chat_id]["budget_usd"]


## Clear the budget for a chat
func clear_budget(chat_id: String) -> void:
	_budgets.erase(chat_id)
	save_budgets()


## Check budget status for a chat. Returns {ok, remaining, pct_used, budget, spent, period}
func check_budget(chat_id: String) -> Dictionary:
	if not _budgets.has(chat_id):
		return {"ok": true, "has_budget": false}

	var budget_usd: float = _budgets[chat_id].get("budget_usd", 0.0)
	if budget_usd <= 0:
		return {"ok": true, "has_budget": false}

	var period: String = _budgets[chat_id].get("period", "day")
	var spent: float = get_spend_for_period(period, chat_id)
	var remaining: float = budget_usd - spent
	var pct_used: float = spent / budget_usd if budget_usd > 0 else 0.0

	return {
		"ok": remaining > 0,
		"has_budget": true,
		"budget": budget_usd,
		"spent": spent,
		"remaining": maxf(remaining, 0.0),
		"pct_used": pct_used,
		"period": period,
	}


## Get budget info for a chat (or empty dict if no budget)
func get_budget(chat_id: String) -> Dictionary:
	return check_budget(chat_id)

#endregion


#region Queries

## Get total cost for today (UTC, matching ledger timestamps)
func get_cost_today() -> float:
	var today: String = Time.get_date_string_from_system(true)
	var total := 0.0
	for entry in _ledger:
		if entry["ts"].begins_with(today):
			total += entry["cost_usd"]
	return total


## Get total cost for a specific chat
func get_cost_for_chat(chat_id: String) -> Dictionary:
	var total := 0.0
	var input_tokens := 0
	var output_tokens := 0
	var call_count := 0
	for entry in _ledger:
		if entry.get("chat_id", "") == chat_id:
			total += entry["cost_usd"]
			input_tokens += entry["input_tokens"]
			output_tokens += entry["output_tokens"]
			call_count += 1
	var budget_info := check_budget(chat_id)
	return {
		"cost_usd": total,
		"input_tokens": input_tokens,
		"output_tokens": output_tokens,
		"call_count": call_count,
		"budget": budget_info,
	}


## Get cost breakdown by provider
func get_cost_by_provider() -> Dictionary:
	var breakdown: Dictionary = {}
	for entry in _ledger:
		var prov: String = entry["provider"]
		breakdown[prov] = breakdown.get(prov, 0.0) + entry["cost_usd"]
	return breakdown


## Get cost breakdown by model
func get_cost_by_model() -> Dictionary:
	var breakdown: Dictionary = {}
	for entry in _ledger:
		var model: String = entry["model"]
		breakdown[model] = breakdown.get(model, 0.0) + entry["cost_usd"]
	return breakdown


## Get detailed per-model breakdown with tokens and cost
func get_model_details() -> Array:
	var models: Dictionary = {}
	for entry in _ledger:
		var model: String = entry["model"]
		if not models.has(model):
			models[model] = {"model": model, "provider": entry["provider"], "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0, "calls": 0}
		models[model]["input_tokens"] += entry["input_tokens"]
		models[model]["output_tokens"] += entry["output_tokens"]
		models[model]["cost_usd"] += entry["cost_usd"]
		models[model]["calls"] += 1
	var result: Array = models.values()
	result.sort_custom(func(a, b): return a["cost_usd"] > b["cost_usd"])
	return result


## Get hourly cost breakdown for today (UTC, matching ledger timestamps)
func get_hourly_costs_today() -> Array:
	var today: String = Time.get_date_string_from_system(true)
	var hours: Dictionary = {}
	for entry in _ledger:
		if not entry["ts"].begins_with(today):
			continue
		var hour: String = entry["ts"].substr(11, 2)  # Extract HH from timestamp
		hours[hour] = hours.get(hour, 0.0) + entry["cost_usd"]
	var result: Array = []
	for h in range(24):
		var key := "%02d" % h
		if hours.has(key):
			result.append({"hour": key, "cost_usd": hours[key]})
	return result


## Get total spend across all loaded ledger entries
func get_total_spend() -> float:
	var total := 0.0
	for entry in _ledger:
		total += entry["cost_usd"]
	return total


## Get the global budget (not per-chat). Returns empty dict if none set.
func get_global_budget() -> Dictionary:
	return check_budget("__global__")


## Set a global spending budget
func set_global_budget(budget_usd: float, warn_pct: float = 0.8, period: String = "day") -> void:
	set_budget("__global__", budget_usd, warn_pct, period)


## Get global spend (all chats combined, for the budget's configured period)
func get_global_spend() -> float:
	if _budgets.has("__global__"):
		var period: String = _budgets["__global__"].get("period", "day")
		return get_spend_for_period(period, "__global__")
	return get_cost_today()


## Get cost summary for a period. Period: "today", "week", "month", "all"
func get_cost_summary(period: String = "today", provider_filter: String = "") -> Dictionary:
	var cutoff: String = ""
	match period:
		"today":
			cutoff = Time.get_date_string_from_system()
		"week":
			var unix := Time.get_unix_time_from_system()
			var week_ago := unix - 7 * 86400
			var dt := Time.get_datetime_dict_from_unix_time(int(week_ago))
			cutoff = "%d-%02d-%02d" % [dt["year"], dt["month"], dt["day"]]
		"month":
			# Current month's ledger is already loaded
			cutoff = ""
		"all":
			cutoff = ""

	var total := 0.0
	var by_provider: Dictionary = {}
	var by_model: Dictionary = {}
	var call_count := 0
	var total_input := 0
	var total_output := 0

	for entry in _ledger:
		if not cutoff.is_empty() and entry["ts"] < cutoff:
			continue
		if not provider_filter.is_empty() and entry["provider"] != provider_filter:
			continue
		total += entry["cost_usd"]
		call_count += 1
		total_input += entry["input_tokens"]
		total_output += entry["output_tokens"]

		var prov: String = entry["provider"]
		by_provider[prov] = by_provider.get(prov, 0.0) + entry["cost_usd"]

		var model: String = entry["model"]
		by_model[model] = by_model.get(model, 0.0) + entry["cost_usd"]

	return {
		"period": period,
		"total_cost_usd": total,
		"call_count": call_count,
		"total_input_tokens": total_input,
		"total_output_tokens": total_output,
		"by_provider": by_provider,
		"by_model": by_model,
	}

#endregion


#region Persistence

## Save ledger to disk
func save_ledger() -> void:
	if not _dirty:
		return
	var path := "%s_%s.json" % [_LEDGER_DIR, _current_month]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify({"entries": _ledger}, "\t"))
		file.close()
		_dirty = false


## Save all state (ledger + budgets). Call on shutdown.
func save_all() -> void:
	save_ledger()
	save_budgets()


## Save budget state to disk
func save_budgets() -> void:
	if _budgets.is_empty():
		# Remove stale file if no budgets
		if FileAccess.file_exists(_BUDGETS_PATH):
			DirAccess.remove_absolute(_BUDGETS_PATH)
		return
	var file := FileAccess.open(_BUDGETS_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_budgets, "\t"))
		file.close()


## Load budget state from disk
func _load_budgets() -> void:
	if not FileAccess.file_exists(_BUDGETS_PATH):
		return
	var file := FileAccess.open(_BUDGETS_PATH, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("[CostTracker] Failed to parse budgets: %s" % _BUDGETS_PATH)
		return
	var data = json.get_data()
	if data is Dictionary:
		_budgets = data


## Load ledger for current month from disk
func _load_ledger() -> void:
	var path := "%s_%s.json" % [_LEDGER_DIR, _current_month]
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		push_warning("[CostTracker] Failed to parse ledger: %s" % path)
		return
	var data = json.get_data()
	if data is Dictionary and data.has("entries"):
		_ledger.assign(data["entries"])
		# Rebuild per-chat cost accumulators
		for entry in _ledger:
			var chat_id: String = entry.get("chat_id", "")
			if not chat_id.is_empty():
				_chat_costs[chat_id] = _chat_costs.get(chat_id, 0.0) + entry.get("cost_usd", 0.0)


func _get_month_key() -> String:
	var dt := Time.get_datetime_dict_from_system()
	return "%d_%02d" % [dt["year"], dt["month"]]

#endregion
