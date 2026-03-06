class_name TriggerManager
extends Node
## Manages agent triggers: timer children for TIMER triggers, signal
## connections for EVENT triggers. Calls AgentSpawner when triggers fire.

signal triggers_changed
signal batch_progress(trigger_id: String, index: int, total: int, param: String)
signal batch_completed(trigger_id: String, completed: int, total: int)

var triggers: Array[TriggerDefinition] = []

## Anti-flood: maps trigger_id -> history_id of active (in-progress) chat
var _active_trigger_chats: Dictionary = {}

## Timer node references keyed by trigger_id
var _timer_nodes: Dictionary = {}

## Signal connection state keyed by trigger_id
var _connected_signals: Dictionary = {}

## Active batch executions keyed by trigger_id
var _active_batches: Dictionary = {}

## Pending single-fire chains: trigger_id -> { chain_trigger_id, chain_visited }
var _pending_single_chains: Dictionary = {}

## 60-second poll timer for wall-clock schedule evaluation
var _schedule_check_timer: Timer


class BatchState:
	var trigger_id: String
	var params: Array[String]
	var current_index: int = 0
	var completed_count: int = 0
	var active_history_id: String = ""
	var all_history_ids: Array[String] = []
	var context_accumulator: Array[Dictionary] = []
	## Cycle detection: set of trigger IDs visited in this chain
	var chain_visited: Dictionary = {}
	## Optional context passed into the batch start
	var initial_context: Dictionary = {}


func _ready() -> void:
	# Connect to chat_completed for anti-flood cleanup
	SingletonObject.chat_completed.connect(_on_chat_completed)
	# Connect to agent_chat_finished for CHAT_COMPLETED event triggers
	SingletonObject.agent_chat_finished.connect(_on_agent_chat_finished)
	# Safety net: clean up batches/anti-flood if a chat is force-stopped
	SingletonObject.stop_all_requests.connect(_on_stop_request)

	# Wall-clock schedule poll timer (checks every 60 seconds)
	_schedule_check_timer = Timer.new()
	_schedule_check_timer.name = "ScheduleCheckTimer"
	_schedule_check_timer.wait_time = 60.0
	_schedule_check_timer.one_shot = false
	_schedule_check_timer.timeout.connect(_on_schedule_check)
	add_child(_schedule_check_timer)
	_schedule_check_timer.start()


#region CRUD

func add_trigger(trig: TriggerDefinition) -> void:
	triggers.append(trig)
	if trig.enabled:
		_activate_trigger(trig)
	triggers_changed.emit()


func update_trigger(trigger_id: String, updated: TriggerDefinition) -> void:
	for i in triggers.size():
		if triggers[i].id == trigger_id:
			_deactivate_trigger(triggers[i])
			updated.id = trigger_id
			triggers[i] = updated
			if updated.enabled:
				_activate_trigger(updated)
			triggers_changed.emit()
			return


func remove_trigger(trigger_id: String) -> void:
	for i in triggers.size():
		if triggers[i].id == trigger_id:
			_deactivate_trigger(triggers[i])
			triggers.remove_at(i)
			triggers_changed.emit()
			return


func get_trigger(trigger_id: String) -> TriggerDefinition:
	for trig in triggers:
		if trig.id == trigger_id:
			return trig
	return null


func set_trigger_enabled(trigger_id: String, enabled: bool) -> void:
	var trig = get_trigger(trigger_id)
	if not trig:
		return
	trig.enabled = enabled
	if enabled:
		_activate_trigger(trig)
	else:
		_deactivate_trigger(trig)
	triggers_changed.emit()


func clear_all() -> void:
	for trig in triggers:
		_deactivate_trigger(trig)
	triggers.clear()
	_active_trigger_chats.clear()
	_active_batches.clear()
	_pending_single_chains.clear()
	triggers_changed.emit()

#endregion CRUD


#region Activation

func _activate_trigger(trig: TriggerDefinition) -> void:
	match trig.trigger_type:
		TriggerDefinition.TriggerType.TIMER:
			# Only start a Godot Timer for INTERVAL schedules; DAILY/WEEKLY use the poll timer
			if trig.schedule_type == TriggerDefinition.ScheduleType.INTERVAL:
				_start_timer(trig)
		TriggerDefinition.TriggerType.EVENT:
			_connect_event(trig)


func _deactivate_trigger(trig: TriggerDefinition) -> void:
	match trig.trigger_type:
		TriggerDefinition.TriggerType.TIMER:
			_stop_timer(trig)
		TriggerDefinition.TriggerType.EVENT:
			_disconnect_event(trig)


func _start_timer(trig: TriggerDefinition) -> void:
	_stop_timer(trig)
	var timer = Timer.new()
	timer.name = "AgentTimer_%s" % trig.id
	timer.wait_time = maxf(trig.interval_seconds, 5.0)  # min 5s
	timer.one_shot = false
	timer.timeout.connect(_on_timer_fired.bind(trig.id))
	add_child(timer)
	_timer_nodes[trig.id] = timer
	timer.start()
	print("[TriggerManager] Started timer for trigger '%s' (%.0fs)" % [trig.id, timer.wait_time])


func _stop_timer(trig: TriggerDefinition) -> void:
	if _timer_nodes.has(trig.id):
		var timer: Timer = _timer_nodes[trig.id]
		if is_instance_valid(timer):
			timer.stop()
			timer.queue_free()
		_timer_nodes.erase(trig.id)


func _connect_event(trig: TriggerDefinition) -> void:
	_disconnect_event(trig)
	match trig.event_type:
		TriggerDefinition.EventType.NOTE_CHANGED:
			SingletonObject.note_changed.connect(_on_event_note_changed.bind(trig.id))
			_connected_signals[trig.id] = true
		TriggerDefinition.EventType.CHAT_COMPLETED:
			# Handled via _on_agent_chat_finished connected in _ready
			_connected_signals[trig.id] = true
		TriggerDefinition.EventType.NOTE_CREATED:
			# Connect to note_toggled as a proxy for note creation
			SingletonObject.note_toggled.connect(_on_event_note_created.bind(trig.id))
			_connected_signals[trig.id] = true
	print("[TriggerManager] Connected event trigger '%s' (type=%d)" % [trig.id, trig.event_type])


func _disconnect_event(trig: TriggerDefinition) -> void:
	if not _connected_signals.has(trig.id):
		return
	match trig.event_type:
		TriggerDefinition.EventType.NOTE_CHANGED:
			if SingletonObject.note_changed.is_connected(_on_event_note_changed):
				SingletonObject.note_changed.disconnect(_on_event_note_changed)
		TriggerDefinition.EventType.NOTE_CREATED:
			if SingletonObject.note_toggled.is_connected(_on_event_note_created):
				SingletonObject.note_toggled.disconnect(_on_event_note_created)
	_connected_signals.erase(trig.id)

#endregion Activation


#region Trigger Callbacks

func _on_timer_fired(trigger_id: String) -> void:
	_fire_trigger(trigger_id)


func _on_event_note_changed(_note, trigger_id: String) -> void:
	_fire_trigger(trigger_id)


func _on_event_note_created(_note, _on: bool, trigger_id: String) -> void:
	if _on:
		_fire_trigger(trigger_id)


func _on_chat_completed(_response) -> void:
	# Clean up anti-flood tracking for completed chats
	var completed_triggers: Array[String] = []
	for trigger_id in _active_trigger_chats:
		var history_id: String = _active_trigger_chats[trigger_id]
		var found = false
		for chat in SingletonObject.ChatList:
			if chat.HistoryId == history_id:
				found = true
				break
		if not found:
			completed_triggers.append(trigger_id)

	for trigger_id in completed_triggers:
		_active_trigger_chats.erase(trigger_id)


func _on_agent_chat_finished(history_id: String, agent_definition_id: String) -> void:
	# Check if this history belongs to an active batch
	for trigger_id in _active_batches.keys():
		var batch: BatchState = _active_batches[trigger_id]
		if batch.active_history_id == history_id:
			# Collect context from completed agent
			var ctx = _build_completion_context(history_id, agent_definition_id)
			batch.context_accumulator.append(ctx)
			batch.completed_count += 1
			batch.all_history_ids.append(history_id)
			batch.active_history_id = ""
			# Advance to next param via deferred call to avoid deep stacks
			call_deferred("_fire_batch_next", trigger_id)
			# Don't clear anti-flood here — batch manages its own state
			break

	# Check if this history belongs to a pending single-fire chain
	for trigger_id in _pending_single_chains.keys():
		if _active_trigger_chats.get(trigger_id, "") == history_id:
			var chain_info: Dictionary = _pending_single_chains[trigger_id]
			_pending_single_chains.erase(trigger_id)
			_active_trigger_chats.erase(trigger_id)
			var chain_target: String = chain_info["chain_trigger_id"]
			var visited: Dictionary = chain_info.get("chain_visited", {})
			visited[trigger_id] = true
			if visited.has(chain_target):
				push_warning("[TriggerManager] Cycle detected: trigger '%s' already visited in chain, stopping." % chain_target)
			else:
				var ctx = _build_completion_context(history_id, agent_definition_id)
				call_deferred("_fire_trigger", chain_target, ctx, visited)
			break

	# Clear anti-flood for any trigger whose active chat matches this history
	for trigger_id in _active_trigger_chats.keys():
		if _active_trigger_chats[trigger_id] == history_id:
			_active_trigger_chats.erase(trigger_id)

	# Fire CHAT_COMPLETED triggers that match this agent
	for trig in triggers:
		if not trig.enabled:
			continue
		if trig.trigger_type != TriggerDefinition.TriggerType.EVENT:
			continue
		if trig.event_type != TriggerDefinition.EventType.CHAT_COMPLETED:
			continue

		# Check watched_agent_ids filter
		if not trig.watched_agent_ids.is_empty():
			if agent_definition_id not in trig.watched_agent_ids:
				continue

		# Build context for template variables
		var context := _build_completion_context(history_id, agent_definition_id)
		_fire_trigger(trig.id, context)


func _on_stop_request(history_id: String) -> void:
	# Safety net: if a stopped chat belongs to an active batch, clean up the batch
	# so it doesn't stay stuck forever. The primary signal (agent_chat_finished)
	# is emitted by ChatPane's stop handler, but this catches edge cases.
	for trigger_id in _active_batches.keys():
		var batch: BatchState = _active_batches[trigger_id]
		if batch.active_history_id == history_id:
			print("[TriggerManager] Batch '%s' had active chat stopped, cleaning up" % trigger_id)
			batch.active_history_id = ""
			# Don't advance — just clean up. agent_chat_finished will handle advancement.
			break

	# Also clear anti-flood for single-fire triggers
	for trigger_id in _active_trigger_chats.keys():
		if _active_trigger_chats[trigger_id] == history_id:
			_active_trigger_chats.erase(trigger_id)
			break


func _build_completion_context(history_id: String, agent_definition_id: String) -> Dictionary:
	var context: Dictionary = {
		"agent_name": "",
		"last_response": "",
		"history_name": "",
	}

	# Look up agent name from registry
	var registry = SingletonObject.agent_registry
	if registry:
		var agent_def = registry.get_agent(agent_definition_id)
		if agent_def:
			context["agent_name"] = agent_def.name

	# Look up last response from chat history
	for chat in SingletonObject.ChatList:
		if chat.HistoryId == history_id:
			context["history_name"] = chat.HistoryName
			# Find last bot response
			for i in range(chat.HistoryItemList.size() - 1, -1, -1):
				var item = chat.HistoryItemList[i]
				if item.Role == ChatHistoryItem.ChatRole.MODEL or item.Role == ChatHistoryItem.ChatRole.ASSISTANT:
					context["last_response"] = item.Message
					break
			break

	return context


func _apply_template(message: String, context: Dictionary) -> String:
	var result = message
	for key in context:
		result = result.replace("{%s}" % key, str(context[key]))
	return result


func _fire_trigger(trigger_id: String, context: Dictionary = {}, chain_visited: Dictionary = {}, force: bool = false) -> void:
	var trig = get_trigger(trigger_id)
	if not trig:
		return
	if not trig.enabled and not force:
		return

	# Anti-flood for batch triggers: don't re-fire while a batch is running
	if _active_batches.has(trigger_id):
		print("[TriggerManager] Skipping trigger '%s' - batch still running" % trigger_id)
		return

	# Anti-flood: don't fire if same trigger already has an active chat
	if _active_trigger_chats.has(trigger_id):
		var active_history_id: String = _active_trigger_chats[trigger_id]
		for chat in SingletonObject.ChatList:
			if chat.HistoryId == active_history_id:
				print("[TriggerManager] Skipping trigger '%s' - chat still active" % trigger_id)
				return
		# Chat no longer exists, clear tracking
		_active_trigger_chats.erase(trigger_id)

	# Branch: batch execution vs single fire
	if not trig.batch_params.is_empty():
		_start_batch(trig, context, chain_visited)
		return

	# Look up agent definition
	var registry = SingletonObject.agent_registry
	if not registry:
		push_error("[TriggerManager] No agent registry available")
		return

	var agent_def = registry.get_agent(trig.agent_id)
	if not agent_def:
		push_warning("[TriggerManager] Agent '%s' not found for trigger '%s'" % [trig.agent_id, trigger_id])
		return

	# Apply template variables to initial message
	var message = trig.initial_message
	if not context.is_empty():
		message = _apply_template(message, context)

	match trig.action_type:
		TriggerDefinition.ActionType.SPAWN_NEW:
			_action_spawn_new(trig, agent_def, message, trigger_id)
		TriggerDefinition.ActionType.MESSAGE_EXISTING:
			_action_message_existing(trig, agent_def, message, trigger_id)

	# Single-fire chaining (non-batch trigger with chain_trigger_id)
	if not trig.chain_trigger_id.is_empty() and trig.batch_params.is_empty():
		# Defer chaining — the agent hasn't finished yet.
		# Chaining for single-fire is handled in _on_agent_chat_finished via _pending_single_chains.
		_pending_single_chains[trigger_id] = { "chain_trigger_id": trig.chain_trigger_id, "chain_visited": chain_visited.duplicate() }


func _action_spawn_new(_trig: TriggerDefinition, agent_def: AgentDefinition, message: String, trigger_id: String) -> void:
	var history = AgentSpawner.spawn_agent(agent_def, message, trigger_id)
	if history:
		_active_trigger_chats[trigger_id] = history.HistoryId
		print("[TriggerManager] Fired trigger '%s' -> spawned agent '%s'" % [trigger_id, agent_def.name])


func _action_message_existing(_trig: TriggerDefinition, agent_def: AgentDefinition, message: String, trigger_id: String) -> void:
	if message.is_empty():
		print("[TriggerManager] MESSAGE_EXISTING trigger '%s' has empty message, skipping" % trigger_id)
		return

	# Find the most recent existing chat for this agent definition
	var target_history: ChatHistory = null
	var target_idx: int = -1
	for i in range(SingletonObject.ChatList.size() - 1, -1, -1):
		var chat: ChatHistory = SingletonObject.ChatList[i]
		if chat.AgentDefinitionId == agent_def.id:
			target_history = chat
			target_idx = i
			break

	# If no existing chat found, spawn a new one (without message) then send message
	if not target_history:
		target_history = AgentSpawner.spawn_agent(agent_def, "", trigger_id)
		if not target_history:
			push_error("[TriggerManager] MESSAGE_EXISTING: Could not spawn fallback agent '%s'" % agent_def.name)
			return
		target_idx = SingletonObject.ChatList.find(target_history)

	# Track as active
	_active_trigger_chats[trigger_id] = target_history.HistoryId

	# Switch to the target chat tab and send the message
	var chats = SingletonObject.Chats
	if chats and target_idx >= 0:
		chats.current_tab = target_idx
		chats.call_deferred("execute_regular_chat", message)
		print("[TriggerManager] Fired trigger '%s' -> messaged existing agent '%s'" % [trigger_id, agent_def.name])

#endregion Trigger Callbacks


#region Batch Execution

func _start_batch(trig: TriggerDefinition, context: Dictionary, chain_visited: Dictionary) -> void:
	var batch = BatchState.new()
	batch.trigger_id = trig.id
	for p in trig.batch_params:
		batch.params.append(p)
	batch.current_index = 0
	batch.completed_count = 0
	batch.initial_context = context.duplicate()
	batch.chain_visited = chain_visited.duplicate()
	batch.chain_visited[trig.id] = true
	_active_batches[trig.id] = batch
	print("[TriggerManager] Starting batch for trigger '%s' (%d params)" % [trig.id, batch.params.size()])
	_fire_batch_next(trig.id)


func _fire_batch_next(trigger_id: String) -> void:
	if not _active_batches.has(trigger_id):
		return

	var batch: BatchState = _active_batches[trigger_id]
	if batch.current_index >= batch.params.size():
		_on_batch_completed(trigger_id)
		return

	var trig = get_trigger(trigger_id)
	if not trig:
		_active_batches.erase(trigger_id)
		return

	var registry = SingletonObject.agent_registry
	if not registry:
		push_error("[TriggerManager] No agent registry for batch step")
		_active_batches.erase(trigger_id)
		return

	var agent_def = registry.get_agent(trig.agent_id)
	if not agent_def:
		push_warning("[TriggerManager] Agent '%s' not found for batch trigger '%s'" % [trig.agent_id, trigger_id])
		_active_batches.erase(trigger_id)
		return

	var param = batch.params[batch.current_index]
	var context = batch.initial_context.duplicate()
	context["param"] = param
	context["batch_index"] = str(batch.current_index)
	context["batch_total"] = str(batch.params.size())

	var message = _apply_template(trig.initial_message, context)

	batch_progress.emit(trigger_id, batch.current_index, batch.params.size(), param)
	print("[TriggerManager] Batch '%s' step %d/%d param='%s'" % [trigger_id, batch.current_index + 1, batch.params.size(), param])

	batch.current_index += 1

	match trig.action_type:
		TriggerDefinition.ActionType.SPAWN_NEW:
			var history = AgentSpawner.spawn_agent(agent_def, message, trigger_id)
			if history:
				batch.active_history_id = history.HistoryId
			else:
				push_warning("[TriggerManager] Batch spawn failed for param '%s', skipping" % param)
				call_deferred("_fire_batch_next", trigger_id)
		TriggerDefinition.ActionType.MESSAGE_EXISTING:
			var target_history: ChatHistory = null
			var target_idx: int = -1
			for i in range(SingletonObject.ChatList.size() - 1, -1, -1):
				var chat: ChatHistory = SingletonObject.ChatList[i]
				if chat.AgentDefinitionId == agent_def.id:
					target_history = chat
					target_idx = i
					break
			if not target_history:
				target_history = AgentSpawner.spawn_agent(agent_def, "", trigger_id)
				if not target_history:
					push_warning("[TriggerManager] Batch MESSAGE_EXISTING: fallback spawn failed for param '%s'" % param)
					call_deferred("_fire_batch_next", trigger_id)
					return
				target_idx = SingletonObject.ChatList.find(target_history)
			batch.active_history_id = target_history.HistoryId
			var chats = SingletonObject.Chats
			if chats and target_idx >= 0:
				chats.current_tab = target_idx
				chats.call_deferred("execute_regular_chat", message)


func _on_batch_completed(trigger_id: String) -> void:
	if not _active_batches.has(trigger_id):
		return

	var batch: BatchState = _active_batches[trigger_id]
	var completed = batch.completed_count
	var total = batch.params.size()

	print("[TriggerManager] Batch completed for trigger '%s': %d/%d" % [trigger_id, completed, total])
	batch_completed.emit(trigger_id, completed, total)

	# Build chaining context from accumulated results
	var chain_context: Dictionary = {
		"batch_completed": str(completed),
		"batch_total": str(total),
	}
	# Include last response from the final batch item
	if not batch.context_accumulator.is_empty():
		var last_ctx = batch.context_accumulator[batch.context_accumulator.size() - 1]
		chain_context["last_response"] = last_ctx.get("last_response", "")
		chain_context["agent_name"] = last_ctx.get("agent_name", "")
		chain_context["history_name"] = last_ctx.get("history_name", "")

	var chain_visited = batch.chain_visited.duplicate()
	_active_batches.erase(trigger_id)

	# Chain to next trigger if configured
	var trig = get_trigger(trigger_id)
	if trig and not trig.chain_trigger_id.is_empty():
		if chain_visited.has(trig.chain_trigger_id):
			push_warning("[TriggerManager] Cycle detected: trigger '%s' already visited in chain, stopping." % trig.chain_trigger_id)
		else:
			print("[TriggerManager] Chaining from '%s' -> '%s'" % [trigger_id, trig.chain_trigger_id])
			call_deferred("_fire_trigger", trig.chain_trigger_id, chain_context, chain_visited)


func get_batch_status(trigger_id: String) -> Dictionary:
	if not _active_batches.has(trigger_id):
		return {"active": false}
	var batch: BatchState = _active_batches[trigger_id]
	return {
		"active": true,
		"trigger_id": trigger_id,
		"current_index": batch.current_index,
		"completed_count": batch.completed_count,
		"total": batch.params.size(),
		"current_param": batch.params[batch.current_index - 1] if batch.current_index > 0 and batch.current_index <= batch.params.size() else "",
		"active_history_id": batch.active_history_id,
	}

#endregion Batch Execution


#region Wall-Clock Schedules

## Called every 60 seconds by _schedule_check_timer.
func _on_schedule_check() -> void:
	for trig in triggers:
		if not trig.enabled:
			continue
		if trig.trigger_type != TriggerDefinition.TriggerType.TIMER:
			continue
		if trig.schedule_type == TriggerDefinition.ScheduleType.INTERVAL:
			continue
		if _should_fire_schedule(trig):
			trig.last_fired_at = Time.get_datetime_string_from_system(false)
			_fire_trigger(trig.id)


## Evaluate whether a DAILY or WEEKLY trigger should fire now.
func _should_fire_schedule(trig: TriggerDefinition) -> bool:
	var now := Time.get_datetime_dict_from_system(false)  # local time
	var now_hhmm := "%02d:%02d" % [now["hour"], now["minute"]]

	# Current time must be >= schedule_time (within the same minute window)
	if now_hhmm < trig.schedule_time:
		return false

	# For WEEKLY, check day-of-week (Godot: 0=Sun, 1=Mon .. 6=Sat; we use 0=Mon .. 6=Sun)
	if trig.schedule_type == TriggerDefinition.ScheduleType.WEEKLY:
		if trig.schedule_days.is_empty():
			return false
		# Convert Godot weekday (0=Sun) to our convention (0=Mon)
		var godot_weekday: int = now["weekday"]
		var our_weekday: int = (godot_weekday + 6) % 7  # Sun(0)->6, Mon(1)->0, ...
		if our_weekday not in trig.schedule_days:
			return false

	# Check if we already fired for this scheduled occurrence
	if not trig.last_fired_at.is_empty():
		var today_schedule_str := "%04d-%02d-%02dT%s:00" % [now["year"], now["month"], now["day"], trig.schedule_time]
		if trig.last_fired_at >= today_schedule_str:
			return false  # Already fired for this scheduled time

	return true


## Check for missed fires after project load / deserialization.
func check_missed_fires() -> void:
	for trig in triggers:
		if not trig.enabled:
			continue
		if trig.trigger_type != TriggerDefinition.TriggerType.TIMER:
			continue
		if trig.schedule_type == TriggerDefinition.ScheduleType.INTERVAL:
			continue
		if not trig.fire_if_missed:
			continue

		var most_recent := _most_recent_scheduled_time(trig)
		if most_recent.is_empty():
			continue

		if trig.last_fired_at.is_empty() or trig.last_fired_at < most_recent:
			print("[TriggerManager] Firing missed schedule for '%s' (was due at %s)" % [trig.name, most_recent])
			trig.last_fired_at = Time.get_datetime_string_from_system(false)
			call_deferred("_fire_trigger", trig.id)


## Compute the most recent scheduled time before now for a DAILY/WEEKLY trigger.
func _most_recent_scheduled_time(trig: TriggerDefinition) -> String:
	var now := Time.get_datetime_dict_from_system(false)
	var now_hhmm := "%02d:%02d" % [now["hour"], now["minute"]]

	if trig.schedule_type == TriggerDefinition.ScheduleType.DAILY:
		if now_hhmm >= trig.schedule_time:
			return "%04d-%02d-%02dT%s:00" % [now["year"], now["month"], now["day"], trig.schedule_time]
		# Yesterday's schedule
		var yesterday_unix := Time.get_unix_time_from_system() - 86400
		var yesterday := Time.get_datetime_dict_from_unix_time(int(yesterday_unix))
		return "%04d-%02d-%02dT%s:00" % [yesterday["year"], yesterday["month"], yesterday["day"], trig.schedule_time]

	elif trig.schedule_type == TriggerDefinition.ScheduleType.WEEKLY:
		if trig.schedule_days.is_empty():
			return ""
		# Walk backwards up to 7 days to find the most recent matching day
		for days_back in range(0, 8):
			var check_unix := Time.get_unix_time_from_system() - days_back * 86400
			var check_dt := Time.get_datetime_dict_from_unix_time(int(check_unix))
			var godot_wd: int = check_dt["weekday"]
			var our_wd: int = (godot_wd + 6) % 7
			if our_wd in trig.schedule_days:
				var check_hhmm := "%02d:%02d" % [check_dt["hour"], check_dt["minute"]]
				# If it's today, only if we're past the schedule time
				if days_back == 0 and now_hhmm < trig.schedule_time:
					continue
				return "%04d-%02d-%02dT%s:00" % [check_dt["year"], check_dt["month"], check_dt["day"], trig.schedule_time]

	return ""

#endregion Wall-Clock Schedules


#region Serialization (per-project)

func serialize() -> Array:
	var result: Array = []
	for trig in triggers:
		result.append(trig.serialize())
	return result


func deserialize(data: Array) -> void:
	clear_all()
	for item in data:
		if item is Dictionary:
			var trig = TriggerDefinition.deserialize(item)
			triggers.append(trig)
			if trig.enabled:
				_activate_trigger(trig)
	print("[TriggerManager] Deserialized %d triggers" % triggers.size())
	# Check for missed wall-clock schedules after project load
	call_deferred("check_missed_fires")

#endregion Serialization
