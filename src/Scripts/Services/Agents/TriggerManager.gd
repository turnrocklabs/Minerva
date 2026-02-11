class_name TriggerManager
extends Node
## Manages agent triggers: timer children for TIMER triggers, signal
## connections for EVENT triggers. Calls AgentSpawner when triggers fire.

signal triggers_changed

var triggers: Array[TriggerDefinition] = []

## Anti-flood: maps trigger_id -> history_id of active (in-progress) chat
var _active_trigger_chats: Dictionary = {}

## Timer node references keyed by trigger_id
var _timer_nodes: Dictionary = {}

## Signal connection state keyed by trigger_id
var _connected_signals: Dictionary = {}


func _ready() -> void:
	# Connect to chat_completed for anti-flood cleanup
	SingletonObject.chat_completed.connect(_on_chat_completed)
	# Connect to agent_chat_finished for CHAT_COMPLETED event triggers
	SingletonObject.agent_chat_finished.connect(_on_agent_chat_finished)


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
	triggers_changed.emit()

#endregion CRUD


#region Activation

func _activate_trigger(trig: TriggerDefinition) -> void:
	match trig.trigger_type:
		TriggerDefinition.TriggerType.TIMER:
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


func _fire_trigger(trigger_id: String, context: Dictionary = {}) -> void:
	var trig = get_trigger(trigger_id)
	if not trig or not trig.enabled:
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


func _action_spawn_new(trig: TriggerDefinition, agent_def: AgentDefinition, message: String, trigger_id: String) -> void:
	var history = AgentSpawner.spawn_agent(agent_def, message, trigger_id)
	if history:
		_active_trigger_chats[trigger_id] = history.HistoryId
		print("[TriggerManager] Fired trigger '%s' -> spawned agent '%s'" % [trigger_id, agent_def.name])


func _action_message_existing(trig: TriggerDefinition, agent_def: AgentDefinition, message: String, trigger_id: String) -> void:
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

#endregion Serialization
