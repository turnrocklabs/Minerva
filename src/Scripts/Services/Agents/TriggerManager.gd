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

## PLUGIN_EVENT signal connection state: trigger_id -> true
var _plugin_event_signal_connected: Dictionary = {}

## Consecutive fire counts for PLUGIN_EVENT triggers: trigger_id -> int
var _plugin_event_consecutive_counts: Dictionary = {}

## Paused PLUGIN_EVENT triggers: trigger_id -> true (paused after hitting consecutive_fire_limit)
var _plugin_event_paused: Dictionary = {}

## Active batch executions keyed by trigger_id
var _active_batches: Dictionary = {}

## Pending single-fire chains: trigger_id -> { chain_trigger_id, chain_visited }
var _pending_single_chains: Dictionary = {}

## Signal connections for DOCKET_POLL triggers (trigger_id -> true)
var _docket_signal_connected: Dictionary = {}

## Per-session dedup for PreToolUse route hints: trigger_id -> Set of fired route indices
var _hook_route_shown: Dictionary = {}

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
	# Hook event triggers: connect to MCP tool signals
	SingletonObject.mcp_tool_executed.connect(_on_hook_tool_executed)
	SingletonObject.mcp_tool_about_to_execute.connect(_on_hook_tool_about_to_execute)
	# PLUGIN_EVENT triggers: connect to plugin_event_broker if available
	_connect_plugin_event_broker()

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
	_docket_signal_connected.clear()
	_hook_route_shown.clear()
	_plugin_event_signal_connected.clear()
	_plugin_event_consecutive_counts.clear()
	_plugin_event_paused.clear()
	triggers_changed.emit()

#endregion CRUD


#region Activation

func _activate_trigger(trig: TriggerDefinition) -> void:
	match trig.trigger_type:
		TriggerDefinition.TriggerType.TIMER:
			_start_timer(trig)
		TriggerDefinition.TriggerType.TIME:
			pass
		TriggerDefinition.TriggerType.EVENT:
			_connect_event(trig)
		TriggerDefinition.TriggerType.DOCKET_POLL:
			_activate_docket_poll(trig)
		TriggerDefinition.TriggerType.PLUGIN_EVENT:
			_activate_plugin_event(trig)


func _deactivate_trigger(trig: TriggerDefinition) -> void:
	match trig.trigger_type:
		TriggerDefinition.TriggerType.TIMER:
			_stop_timer(trig)
		TriggerDefinition.TriggerType.TIME:
			pass
		TriggerDefinition.TriggerType.EVENT:
			_disconnect_event(trig)
		TriggerDefinition.TriggerType.DOCKET_POLL:
			_deactivate_docket_poll(trig)
		TriggerDefinition.TriggerType.PLUGIN_EVENT:
			_deactivate_plugin_event(trig)


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

	# Check for human-initiated turn to reset PLUGIN_EVENT consecutive counters
	# (must happen BEFORE _active_trigger_chats cleanup so we can still check)
	_reset_plugin_event_consecutive_if_human(history_id, agent_definition_id)

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


func _fire_trigger(trigger_id: String, context: Dictionary = {}, chain_visited: Dictionary = {}, force: bool = false) -> bool:
	var trig = get_trigger(trigger_id)
	if not trig:
		return false
	if not trig.enabled and not force:
		return false

	# Anti-flood for batch triggers: don't re-fire while a batch is running
	if _active_batches.has(trigger_id):
		print("[TriggerManager] Skipping trigger '%s' - batch still running" % trigger_id)
		return false

	# Anti-flood: don't fire if same trigger already has an active chat
	if _active_trigger_chats.has(trigger_id):
		var active_history_id: String = _active_trigger_chats[trigger_id]
		for chat in SingletonObject.ChatList:
			if chat.HistoryId == active_history_id:
				print("[TriggerManager] Skipping trigger '%s' - chat still active" % trigger_id)
				return false
		# Chat no longer exists, clear tracking
		_active_trigger_chats.erase(trigger_id)

	# Branch: batch execution vs single fire
	if not trig.batch_params.is_empty():
		_start_batch(trig, context, chain_visited)
		return true

	# Look up agent definition
	var registry = SingletonObject.agent_registry
	if not registry:
		push_error("[TriggerManager] No agent registry available")
		return false

	var agent_def = registry.get_agent(trig.agent_id)
	if not agent_def:
		push_warning("[TriggerManager] Agent '%s' not found for trigger '%s'" % [trig.agent_id, trigger_id])
		return false

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
	return true


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


#region Hook Event Handlers

func _on_hook_tool_executed(tool_name: String, _arguments: Dictionary, _result: Dictionary, _agent_id: String) -> void:
	if triggers.is_empty():
		return
	for trig in triggers:
		if not trig.enabled:
			continue
		if trig.trigger_type != TriggerDefinition.TriggerType.EVENT:
			continue
		if trig.event_type != TriggerDefinition.EventType.MCP_TOOL_EXECUTED:
			continue
		# Check tool name pattern
		if not trig.hook_tool_name_pattern.is_empty():
			var regex = RegEx.new()
			if regex.compile(trig.hook_tool_name_pattern) == OK:
				if not regex.search(tool_name):
					continue
			else:
				continue  # bad regex, skip
		# Probabilistic firing
		if trig.hook_fire_probability < 1.0:
			if randf() > trig.hook_fire_probability:
				continue
		# Fire with context
		var context: Dictionary = {"tool_name": tool_name, "agent_id": _agent_id}
		_fire_trigger(trig.id, context)


func _on_hook_tool_about_to_execute(tool_name: String, arguments: Dictionary) -> void:
	if triggers.is_empty():
		return
	for trig in triggers:
		if not trig.enabled:
			continue
		if trig.trigger_type != TriggerDefinition.TriggerType.EVENT:
			continue
		if trig.event_type != TriggerDefinition.EventType.MCP_TOOL_ABOUT_TO_EXECUTE:
			continue
		if trig.hook_route_table.is_empty():
			continue
		# Parse route table
		var routes = JSON.parse_string(trig.hook_route_table)
		if not routes is Array:
			continue
		# Initialize dedup tracking for this trigger
		if not _hook_route_shown.has(trig.id):
			_hook_route_shown[trig.id] = {}
		var shown: Dictionary = _hook_route_shown[trig.id]

		for i in routes.size():
			if shown.has(i):
				continue  # already shown this session
			var route = routes[i]
			if not route is Array or route.size() < 4:
				continue
			var tool_pattern: String = route[0]
			var arg_name: String = route[1]
			var arg_match: String = route[2]
			var hint: String = route[3]

			# Match tool name
			if not tool_pattern.is_empty():
				var regex = RegEx.new()
				if regex.compile(tool_pattern) != OK or not regex.search(tool_name):
					continue

			# Match argument
			if not arg_name.is_empty() and not arg_match.is_empty():
				var val: String = str(arguments.get(arg_name, ""))
				var arg_regex = RegEx.new()
				if arg_regex.compile(arg_match) != OK or not arg_regex.search(val):
					continue

			# Match found — mark shown and fire
			shown[i] = true
			var context: Dictionary = {"tool_name": tool_name, "hint": hint}
			# Override message with the hint
			var original_message := trig.initial_message
			trig.initial_message = hint
			_fire_trigger(trig.id, context)
			trig.initial_message = original_message
			break  # only fire first matching route per event

#endregion Hook Event Handlers


#region PLUGIN_EVENT Triggers

## Connect to SingletonObject.plugin_event_broker once after ready.
## Safe to call multiple times — checks for existing connection.
func _connect_plugin_event_broker() -> void:
	var broker = SingletonObject.get("plugin_event_broker")
	if broker == null:
		return
	if not broker.plugin_event.is_connected(_on_plugin_event_broker_signal):
		broker.plugin_event.connect(_on_plugin_event_broker_signal)
	print("[TriggerManager] Connected to plugin_event_broker.plugin_event")


func _activate_plugin_event(trig: TriggerDefinition) -> void:
	# Ensure the broker-level signal is connected (idempotent).
	_connect_plugin_event_broker()
	_plugin_event_signal_connected[trig.id] = true
	# Reset consecutive count on (re-)activation so stale counts don't carry over.
	_plugin_event_consecutive_counts[trig.id] = 0
	_plugin_event_paused.erase(trig.id)
	print("[TriggerManager] Activated PLUGIN_EVENT trigger '%s' (plugin_id='%s', event='%s', limit=%d)" % [
		trig.id, trig.plugin_id, trig.plugin_event_name, trig.consecutive_fire_limit])


func _deactivate_plugin_event(trig: TriggerDefinition) -> void:
	_plugin_event_signal_connected.erase(trig.id)
	_plugin_event_consecutive_counts.erase(trig.id)
	_plugin_event_paused.erase(trig.id)


## Fired by PluginEventBroker.plugin_event for every plugin event.
## Fans out to all active PLUGIN_EVENT triggers that match.
func _on_plugin_event_broker_signal(p_id: String, event_name: String, payload: Dictionary) -> void:
	if triggers.is_empty():
		return
	for trig in triggers:
		if not trig.enabled:
			continue
		if trig.trigger_type != TriggerDefinition.TriggerType.PLUGIN_EVENT:
			continue
		if not _plugin_event_signal_connected.has(trig.id):
			continue

		# Filter by plugin_id (empty = any)
		if not trig.plugin_id.is_empty() and trig.plugin_id != p_id:
			continue
		# Filter by event_name (empty = any)
		if not trig.plugin_event_name.is_empty() and trig.plugin_event_name != event_name:
			continue

		# Check consecutive_fire_limit (0 = unlimited)
		if _plugin_event_paused.has(trig.id):
			print("[TriggerManager] PLUGIN_EVENT trigger '%s' is paused (hit consecutive_fire_limit=%d)" % [trig.id, trig.consecutive_fire_limit])
			continue

		# Build context from event payload
		var context: Dictionary = {
			"plugin_id": p_id,
			"event_name": event_name,
		}
		# Merge payload keys into context so {terminal_id} etc. work in initial_message
		for k in payload:
			context[k] = payload[k]

		# Increment counter before firing so the limit check reflects the pending fire
		var count: int = _plugin_event_consecutive_counts.get(trig.id, 0) + 1
		_plugin_event_consecutive_counts[trig.id] = count

		_fire_trigger(trig.id, context)

		# After firing, check if we have now hit the limit
		var limit: int = trig.consecutive_fire_limit
		if limit > 0 and count >= limit:
			_plugin_event_paused[trig.id] = true
			print("[TriggerManager] PLUGIN_EVENT trigger '%s' paused after %d consecutive fires — awaiting human message in target chat" % [trig.id, count])


## Called when agent_chat_finished fires for a history that was NOT in _active_trigger_chats.
## This indicates a human-initiated turn in the given chat, which re-arms PLUGIN_EVENT triggers
## whose target agent_definition_id matches.
func _reset_plugin_event_consecutive_if_human(history_id: String, agent_definition_id: String) -> void:
	if _plugin_event_paused.is_empty() and _plugin_event_consecutive_counts.is_empty():
		return
	# If this history_id was NOT fired by any trigger, it was human-initiated.
	var was_triggered: bool = false
	for tid in _active_trigger_chats:
		if _active_trigger_chats[tid] == history_id:
			was_triggered = true
			break
	if was_triggered:
		return  # Trigger-initiated turn — don't reset

	# Human turn confirmed: reset consecutive counters for PLUGIN_EVENT triggers
	# whose agent_id matches the finishing chat's agent_definition_id.
	var reset_count: int = 0
	for trig in triggers:
		if trig.trigger_type != TriggerDefinition.TriggerType.PLUGIN_EVENT:
			continue
		if not trig.enabled:
			continue
		# Match: either same agent_id, or (for MESSAGE_EXISTING) the agent matches
		if trig.agent_id == agent_definition_id or agent_definition_id.is_empty():
			if _plugin_event_paused.has(trig.id) or _plugin_event_consecutive_counts.get(trig.id, 0) > 0:
				_plugin_event_paused.erase(trig.id)
				_plugin_event_consecutive_counts[trig.id] = 0
				reset_count += 1
				print("[TriggerManager] PLUGIN_EVENT trigger '%s' re-armed after human message in chat '%s'" % [trig.id, history_id])
	if reset_count > 0:
		print("[TriggerManager] Reset consecutive counts for %d PLUGIN_EVENT trigger(s)" % reset_count)

#endregion PLUGIN_EVENT Triggers


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
		if trig.trigger_type != TriggerDefinition.TriggerType.TIME:
			continue
		var scheduled_occurrence := _scheduled_occurrence_now(trig)
		if scheduled_occurrence.is_empty():
			continue
		if not trig.last_fired_at.is_empty() and trig.last_fired_at >= scheduled_occurrence:
			continue
		if _fire_trigger(trig.id):
			trig.last_fired_at = scheduled_occurrence

	# DOCKET_POLL triggers now use direct DocketManager signals — no polling needed


## Return the scheduled occurrence string if the trigger should fire now, else "".
func _scheduled_occurrence_now(trig: TriggerDefinition) -> String:
	var now := Time.get_datetime_dict_from_system(false)  # local time
	var now_hhmm := "%02d:%02d" % [now["hour"], now["minute"]]

	if now_hhmm < trig.schedule_time:
		return ""
	var occurrence := _scheduled_occurrence_for_date(trig, now)
	if occurrence.is_empty():
		return ""
	return occurrence


## Check for missed fires after project load / deserialization.
func check_missed_fires() -> void:
	for trig in triggers:
		if not trig.enabled:
			continue
		if trig.trigger_type != TriggerDefinition.TriggerType.TIME:
			continue
		if not trig.fire_if_missed:
			continue

		var most_recent := _most_recent_scheduled_time(trig)
		if most_recent.is_empty():
			continue

		if trig.last_fired_at.is_empty() or trig.last_fired_at < most_recent:
			print("[TriggerManager] Firing missed schedule for '%s' (was due at %s)" % [trig.name, most_recent])
			if _fire_trigger(trig.id):
				trig.last_fired_at = most_recent


## Compute the most recent scheduled time before now for a TIME trigger.
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
				# If it's today, only if we're past the schedule time
				if days_back == 0 and now_hhmm < trig.schedule_time:
					continue
				return "%04d-%02d-%02dT%s:00" % [check_dt["year"], check_dt["month"], check_dt["day"], trig.schedule_time]
	elif trig.schedule_type == TriggerDefinition.ScheduleType.MONTHLY:
		var year := int(now["year"])
		var month := int(now["month"])
		for _i in range(0, 24):
			var max_day := _days_in_month(year, month)
			if trig.schedule_day_of_month <= max_day:
				var day := trig.schedule_day_of_month
				if year == now["year"] and month == now["month"]:
					if now["day"] > day or (now["day"] == day and now_hhmm >= trig.schedule_time):
						return _format_occurrence(year, month, day, trig.schedule_time)
				else:
					return _format_occurrence(year, month, day, trig.schedule_time)
			month -= 1
			if month < 1:
				month = 12
				year -= 1
	elif trig.schedule_type == TriggerDefinition.ScheduleType.YEARLY:
		var year := int(now["year"])
		for _i in range(0, 10):
			if trig.schedule_day_of_month <= _days_in_month(year, trig.schedule_month):
				if year == now["year"]:
					if now["month"] > trig.schedule_month:
						return _format_occurrence(year, trig.schedule_month, trig.schedule_day_of_month, trig.schedule_time)
					if now["month"] == trig.schedule_month:
						if now["day"] > trig.schedule_day_of_month or (now["day"] == trig.schedule_day_of_month and now_hhmm >= trig.schedule_time):
							return _format_occurrence(year, trig.schedule_month, trig.schedule_day_of_month, trig.schedule_time)
				else:
					return _format_occurrence(year, trig.schedule_month, trig.schedule_day_of_month, trig.schedule_time)
			year -= 1

	return ""


func _scheduled_occurrence_for_date(trig: TriggerDefinition, dt: Dictionary) -> String:
	match trig.schedule_type:
		TriggerDefinition.ScheduleType.DAILY:
			return _format_occurrence(dt["year"], dt["month"], dt["day"], trig.schedule_time)
		TriggerDefinition.ScheduleType.WEEKLY:
			if trig.schedule_days.is_empty():
				return ""
			var our_weekday := _our_weekday(dt)
			if our_weekday not in trig.schedule_days:
				return ""
			return _format_occurrence(dt["year"], dt["month"], dt["day"], trig.schedule_time)
		TriggerDefinition.ScheduleType.MONTHLY:
			if int(dt["day"]) != trig.schedule_day_of_month:
				return ""
			return _format_occurrence(dt["year"], dt["month"], dt["day"], trig.schedule_time)
		TriggerDefinition.ScheduleType.YEARLY:
			if int(dt["month"]) != trig.schedule_month or int(dt["day"]) != trig.schedule_day_of_month:
				return ""
			return _format_occurrence(dt["year"], dt["month"], dt["day"], trig.schedule_time)
	return ""


func _format_occurrence(year: int, month: int, day: int, hhmm: String) -> String:
	return "%04d-%02d-%02dT%s:00" % [year, month, day, hhmm]


func _our_weekday(dt: Dictionary) -> int:
	var godot_weekday: int = int(dt["weekday"])
	return (godot_weekday + 6) % 7


func _days_in_month(year: int, month: int) -> int:
	match month:
		1, 3, 5, 7, 8, 10, 12:
			return 31
		4, 6, 9, 11:
			return 30
		2:
			if _is_leap_year(year):
				return 29
			return 28
	return 30


func _is_leap_year(year: int) -> bool:
	if year % 400 == 0:
		return true
	if year % 100 == 0:
		return false
	return year % 4 == 0

#endregion Wall-Clock Schedules


#region Docket Signals

func _activate_docket_poll(trig: TriggerDefinition) -> void:
	## Connect to DocketManager signals for real-time event-driven triggers.
	_deactivate_docket_poll(trig)
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		push_warning("[TriggerManager] DocketManager not available for trigger '%s'" % trig.id)
		return
	dm.item_created.connect(_on_docket_event_created.bind(trig.id))
	dm.item_transitioned.connect(_on_docket_event_transitioned.bind(trig.id))
	dm.item_updated.connect(_on_docket_event_updated.bind(trig.id))
	dm.comment_added.connect(_on_docket_event_comment.bind(trig.id))
	_docket_signal_connected[trig.id] = true
	print("[TriggerManager] Connected docket signals for trigger '%s' (project=%s)" % [trig.id, trig.docket_project])


func _deactivate_docket_poll(trig: TriggerDefinition) -> void:
	if not _docket_signal_connected.has(trig.id):
		return
	var dm: DocketManager = SingletonObject.docket_manager
	if dm:
		if dm.item_created.is_connected(_on_docket_event_created):
			dm.item_created.disconnect(_on_docket_event_created)
		if dm.item_transitioned.is_connected(_on_docket_event_transitioned):
			dm.item_transitioned.disconnect(_on_docket_event_transitioned)
		if dm.item_updated.is_connected(_on_docket_event_updated):
			dm.item_updated.disconnect(_on_docket_event_updated)
		if dm.comment_added.is_connected(_on_docket_event_comment):
			dm.comment_added.disconnect(_on_docket_event_comment)
	_docket_signal_connected.erase(trig.id)


func _on_docket_event_created(item_id: String, item_type: String, project: String, trigger_id: String) -> void:
	_handle_docket_event(trigger_id, project, item_id, "created", item_type)


func _on_docket_event_transitioned(item_id: String, old_status: String, new_status: String, project: String, trigger_id: String) -> void:
	_handle_docket_event(trigger_id, project, item_id, "transitioned", "", old_status, new_status)


func _on_docket_event_updated(item_id: String, project: String, trigger_id: String) -> void:
	_handle_docket_event(trigger_id, project, item_id, "updated")


func _on_docket_event_comment(item_id: String, project: String, trigger_id: String) -> void:
	_handle_docket_event(trigger_id, project, item_id, "comment_added")


func _handle_docket_event(trigger_id: String, project: String, item_id: String, event_type: String, item_type: String = "", old_status: String = "", new_status: String = "") -> void:
	var trig := get_trigger(trigger_id)
	if not trig or not trig.enabled:
		return

	# Project filter
	if not trig.docket_project.is_empty() and trig.docket_project != project:
		return

	# Item ID filter
	if not trig.docket_filter_item_ids.is_empty():
		var ids := trig.docket_filter_item_ids.split(",")
		var matched := false
		for id_str in ids:
			if id_str.strip_edges() == item_id:
				matched = true
				break
		if not matched:
			return

	# Type filter
	if not trig.docket_filter_types.is_empty() and not item_type.is_empty():
		var types := trig.docket_filter_types.split(",")
		var matched := false
		for t in types:
			if t.strip_edges() == item_type:
				matched = true
				break
		if not matched:
			return

	# Parent filter — requires DB lookup
	if not trig.docket_filter_parent.is_empty():
		var dm: DocketManager = SingletonObject.docket_manager
		if dm:
			var db := dm.get_db(project)
			if db:
				var item := db.get_item(item_id)
				if item.is_empty() or str(item.get("parent", "")) != trig.docket_filter_parent:
					return

	# Tag filter — requires DB lookup
	if not trig.docket_filter_tags.is_empty():
		var dm: DocketManager = SingletonObject.docket_manager
		if dm:
			var db := dm.get_db(project)
			if db:
				var item := db.get_item(item_id)
				var item_tags: Array = item.get("tags", [])
				var filter_tags := trig.docket_filter_tags.split(",")
				for ftag in filter_tags:
					if not ftag.strip_edges().is_empty() and ftag.strip_edges() not in item_tags:
						return

	# Anti-flood: don't fire if trigger already has active chat
	if _active_trigger_chats.has(trigger_id):
		var active_hid: String = _active_trigger_chats[trigger_id]
		for chat in SingletonObject.ChatList:
			if chat.HistoryId == active_hid:
				return
		_active_trigger_chats.erase(trigger_id)

	# Build synthetic message
	var synthetic := _build_docket_signal_message(project, item_id, event_type, old_status, new_status)

	# Fire trigger with synthetic message
	var original_message := trig.initial_message
	trig.initial_message = synthetic
	_fire_trigger(trigger_id)
	trig.initial_message = original_message


func _build_docket_signal_message(project: String, item_id: String, event_type: String, old_status: String = "", new_status: String = "") -> String:
	var lines: PackedStringArray = []
	lines.append("Docket event in project '%s':" % project)
	lines.append("")

	# Try to fetch item details for a richer message
	var dm: DocketManager = SingletonObject.docket_manager
	var title := item_id
	var item_type := ""
	var status := ""
	if dm:
		var db := dm.get_db(project)
		if db:
			var item := db.get_item(item_id)
			if not item.is_empty():
				title = str(item.get("title", item_id))
				item_type = str(item.get("type", ""))
				status = str(item.get("status", ""))

	match event_type:
		"created":
			lines.append("- New %s created: '%s' (id: %s)" % [item_type, title, item_id])
		"transitioned":
			lines.append("- '%s' transitioned: %s → %s (id: %s)" % [title, old_status, new_status, item_id])
		"updated":
			lines.append("- '%s' updated (status: %s, id: %s)" % [title, status, item_id])
		"comment_added":
			lines.append("- New comment on '%s' (id: %s)" % [title, item_id])
		_:
			lines.append("- %s: '%s' (id: %s)" % [event_type, title, item_id])

	return "\n".join(lines)

#endregion Docket Signals


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
