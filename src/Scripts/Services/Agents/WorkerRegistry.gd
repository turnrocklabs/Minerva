class_name WorkerRegistry
extends RefCounted

## Tracks parent-child relationships between supervisor and worker chats.
## Used for completion routing (wake parent when child finishes) and
## the Worker Status editor panel.

class WorkerInfo:
	var worker_id: String          ## unique ID for this worker
	var worker_chat_id: String     ## HistoryId of the worker chat
	var parent_chat_id: String     ## HistoryId of the supervisor chat
	var worker_name: String        ## display name
	var task_summary: String       ## truncated task description
	var provider_name: String      ## model/provider name
	var max_tool_rounds: int       ## quota
	var timeout_seconds: float     ## wall-clock timeout (-1 = no timeout)
	var spawned_at: String         ## ISO datetime
	var status: String             ## "running", "completed", "error", "quota_exhausted", "rate_limited", "cancelled", "timeout"
	var termination_message: String
	var tokens_used: int
	var rounds_used: int
	var cobrowser_tab_id: int = -1      ## -1 = no tab assigned
	var cobrowser_agent_id: String = ""  ## empty = no agent_id


class BudgetInfo:
	var max_concurrent_workers: int = 5      ## how many workers can run at once
	var max_total_workers: int = -1          ## lifetime cap, -1 = unlimited
	var max_total_tokens: int = -1           ## token cap across all workers, -1 = unlimited
	var total_workers_spawned: int = 0
	var total_tokens_used: int = 0
	var approval_threshold: int = 3          ## after this many workers, require approval
	var _initial_approval_threshold: int = 3 ## remembers original threshold for doubling
	var requires_approval: bool = false      ## set true when threshold reached


signal worker_spawned(worker_info)
signal worker_finished(worker_info)

var _workers: Dictionary = {}     ## worker_id -> WorkerInfo
var _by_chat_id: Dictionary = {}  ## worker_chat_id -> worker_id (reverse lookup)
var _by_parent: Dictionary = {}   ## parent_chat_id -> Array[worker_id]
var _parent_budgets: Dictionary = {}  ## parent_chat_id -> BudgetInfo


func register_worker(info: WorkerInfo) -> void:
	_workers[info.worker_id] = info
	_by_chat_id[info.worker_chat_id] = info.worker_id
	if not _by_parent.has(info.parent_chat_id):
		_by_parent[info.parent_chat_id] = []
	_by_parent[info.parent_chat_id].append(info.worker_id)
	worker_spawned.emit(info)


func get_worker(worker_id: String) -> WorkerInfo:
	return _workers.get(worker_id, null)


func get_worker_by_chat(chat_id: String) -> WorkerInfo:
	var wid = _by_chat_id.get(chat_id, "")
	if wid.is_empty():
		return null
	return _workers.get(wid, null)


func get_workers_for_parent(parent_chat_id: String) -> Array:
	var ids: Array = _by_parent.get(parent_chat_id, [])
	var result: Array = []
	for wid in ids:
		var info = _workers.get(wid, null)
		if info:
			result.append(info)
	return result


func get_all_workers() -> Array:
	return _workers.values()


func update_worker_status(worker_id: String, status: String, message: String = "", tokens: int = 0, rounds: int = 0) -> void:
	var info = _workers.get(worker_id, null)
	if not info:
		return
	info.status = status
	if not message.is_empty():
		info.termination_message = message
	if tokens > 0:
		info.tokens_used = tokens
	if rounds > 0:
		info.rounds_used = rounds
	if is_terminal_status(status):
		# Accumulate worker tokens into parent budget
		if tokens > 0 and not info.parent_chat_id.is_empty():
			var budget = get_or_create_budget(info.parent_chat_id)
			budget.total_tokens_used += tokens
		worker_finished.emit(info)


func is_terminal_status(status: String) -> bool:
	return status in ["completed", "error", "quota_exhausted", "rate_limited", "cancelled", "timeout"]


#region Budget Tracking

func get_or_create_budget(parent_chat_id: String) -> BudgetInfo:
	if not _parent_budgets.has(parent_chat_id):
		_parent_budgets[parent_chat_id] = BudgetInfo.new()
	return _parent_budgets[parent_chat_id]


func check_budget(parent_chat_id: String) -> Dictionary:
	var budget := get_or_create_budget(parent_chat_id)

	# Check concurrent workers (count running workers for this parent)
	var running_count := 0
	var parent_worker_ids: Array = _by_parent.get(parent_chat_id, [])
	for wid in parent_worker_ids:
		var info = _workers.get(wid, null)
		if info and info.status == "running":
			running_count += 1

	if running_count >= budget.max_concurrent_workers:
		return {
			"allowed": false,
			"reason": "Concurrent worker limit reached: %d/%d running" % [running_count, budget.max_concurrent_workers],
			"budget_summary": get_budget_summary(parent_chat_id),
		}

	# Check total workers vs max
	if budget.max_total_workers >= 0 and budget.total_workers_spawned >= budget.max_total_workers:
		return {
			"allowed": false,
			"reason": "Total worker limit reached: %d/%d spawned" % [budget.total_workers_spawned, budget.max_total_workers],
			"budget_summary": get_budget_summary(parent_chat_id),
		}

	# Check total tokens vs max
	if budget.max_total_tokens >= 0 and budget.total_tokens_used >= budget.max_total_tokens:
		return {
			"allowed": false,
			"reason": "Token budget exhausted: %d/%d tokens used" % [budget.total_tokens_used, budget.max_total_tokens],
			"budget_summary": get_budget_summary(parent_chat_id),
		}

	# Check approval threshold
	if budget.requires_approval:
		return {
			"allowed": false,
			"reason": "Approval required: %d workers spawned (threshold: %d). Call minerva_approve_workers to continue." % [budget.total_workers_spawned, budget.approval_threshold],
			"requires_approval": true,
			"budget_summary": get_budget_summary(parent_chat_id),
		}

	return {
		"allowed": true,
		"reason": "",
		"budget_summary": get_budget_summary(parent_chat_id),
	}


func consume_budget(parent_chat_id: String, tokens: int = 0) -> void:
	var budget := get_or_create_budget(parent_chat_id)
	budget.total_workers_spawned += 1
	if tokens > 0:
		budget.total_tokens_used += tokens
	# Check if we've hit the approval threshold
	if budget.approval_threshold >= 0 and budget.total_workers_spawned >= budget.approval_threshold:
		budget.requires_approval = true


func set_budget(parent_chat_id: String, max_concurrent: int, max_total: int, max_tokens: int, approval_after: int) -> void:
	var budget := get_or_create_budget(parent_chat_id)
	budget.max_concurrent_workers = max_concurrent
	budget.max_total_workers = max_total
	budget.max_total_tokens = max_tokens
	budget.approval_threshold = approval_after
	budget._initial_approval_threshold = approval_after


func approve_workers(parent_chat_id: String) -> Dictionary:
	if not _parent_budgets.has(parent_chat_id):
		return {"success": false, "error": "No budget found for chat: %s" % parent_chat_id}
	var budget: BudgetInfo = _parent_budgets[parent_chat_id]
	if not budget.requires_approval:
		return {"success": false, "error": "No pending approval gate for chat: %s" % parent_chat_id}
	budget.requires_approval = false
	# Double the threshold for the next gate
	if budget.approval_threshold >= 0:
		budget.approval_threshold += budget._initial_approval_threshold
	return {
		"success": true,
		"message": "Approved. Next approval gate at %d workers." % budget.approval_threshold,
		"budget_summary": get_budget_summary(parent_chat_id),
	}


func get_budget_summary(parent_chat_id: String) -> Dictionary:
	var budget := get_or_create_budget(parent_chat_id)

	# Count currently running workers
	var running_count := 0
	var parent_worker_ids: Array = _by_parent.get(parent_chat_id, [])
	for wid in parent_worker_ids:
		var info = _workers.get(wid, null)
		if info and info.status == "running":
			running_count += 1

	return {
		"concurrent_workers_running": running_count,
		"max_concurrent_workers": budget.max_concurrent_workers,
		"total_workers_spawned": budget.total_workers_spawned,
		"max_total_workers": budget.max_total_workers,
		"total_tokens_used": budget.total_tokens_used,
		"max_total_tokens": budget.max_total_tokens,
		"approval_threshold": budget.approval_threshold,
		"requires_approval": budget.requires_approval,
	}

#endregion
