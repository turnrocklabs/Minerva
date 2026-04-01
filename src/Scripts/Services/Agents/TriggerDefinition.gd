class_name TriggerDefinition
extends RefCounted
## Data class for an agent trigger.

enum TriggerType { TIMER, EVENT, TIME, DOCKET_POLL }
enum EventType { NOTE_CREATED, NOTE_CHANGED, CHAT_COMPLETED, MCP_TOOL_EXECUTED, MCP_TOOL_ABOUT_TO_EXECUTE }
enum ActionType { SPAWN_NEW, MESSAGE_EXISTING }
enum ScheduleType { INTERVAL, DAILY, WEEKLY, MONTHLY, YEARLY }

var id: String = ""
var name: String = ""
var agent_id: String = ""
var trigger_type: TriggerType = TriggerType.TIMER
var enabled: bool = false
var interval_seconds: float = 300.0
var event_type: EventType = EventType.NOTE_CREATED
var initial_message: String = ""
var action_type: ActionType = ActionType.SPAWN_NEW
## For CHAT_COMPLETED: only fire when these agent definitions complete (empty = all agent chats).
var watched_agent_ids: Array[String] = []
## Batch execution: list of parameter values to iterate sequentially (empty = single fire).
var batch_params: Array[String] = []
## After batch completes, fire this trigger by ID (empty = no chaining).
var chain_trigger_id: String = ""
## Optional UI label for batch params (e.g. "Ticker Symbols").
var batch_label: String = ""
## Wall-clock schedule type. INTERVAL is used only for TIMER triggers.
var schedule_type: ScheduleType = ScheduleType.INTERVAL
## Time of day for TIME triggers, "HH:MM" in 24h local time.
var schedule_time: String = "09:00"
## Days of week for WEEKLY (0=Mon .. 6=Sun).
var schedule_days: Array[int] = []
## Day of month for MONTHLY and YEARLY schedules.
var schedule_day_of_month: int = 1
## Month for YEARLY schedules (1=Jan .. 12=Dec).
var schedule_month: int = 1
## ISO datetime of last successful fire (persisted for missed-fire detection).
var last_fired_at: String = ""
## If true, fire on next startup if a scheduled time was missed.
var fire_if_missed: bool = true
## Docket project name to poll (e.g., "cad", "minerva")
var docket_project: String = ""
## Optional tag filter for docket poll (comma-separated tags)
var docket_filter_tags: String = ""
## Optional parent item ID — only watch children of this item
var docket_filter_parent: String = ""
## Optional specific item IDs to watch (comma-separated)
var docket_filter_item_ids: String = ""
## Optional item type filter (comma-separated, e.g. "work_item,bug")
var docket_filter_types: String = ""
## Poll interval in seconds (default 60, min 30)
var docket_poll_interval: float = 60.0
## ISO datetime of last successful poll (persisted)
var docket_last_poll_at: String = ""
## Probability of firing for hook events (0.0-1.0, default 1.0)
var hook_fire_probability: float = 1.0
## Regex pattern matching tool name (empty = all tools)
var hook_tool_name_pattern: String = ""
## Route table for PreToolUse matching, JSON: [[tool_regex, arg_name, arg_match_regex, hint_string], ...]
var hook_route_table: String = ""
## Whether this trigger is pending human approval (agents can't enable directly)
var pending_approval: bool = false


func _init(p_id: String = ""):
	if p_id.is_empty():
		id = AgentDefinition._generate_id()
	else:
		id = p_id


func serialize() -> Dictionary:
	var data := {
		"id": id,
		"name": name,
		"agent_id": agent_id,
		"trigger_type": trigger_type,
		"enabled": enabled,
		"interval_seconds": interval_seconds,
		"event_type": event_type,
		"initial_message": initial_message,
		"action_type": action_type,
		"watched_agent_ids": watched_agent_ids,
		"batch_params": batch_params,
		"chain_trigger_id": chain_trigger_id,
		"batch_label": batch_label,
		"schedule_type": schedule_type,
		"schedule_time": schedule_time,
		"schedule_days": schedule_days,
		"schedule_day_of_month": schedule_day_of_month,
		"schedule_month": schedule_month,
		"last_fired_at": last_fired_at,
		"fire_if_missed": fire_if_missed,
		"docket_project": docket_project,
		"docket_filter_tags": docket_filter_tags,
		"docket_filter_parent": docket_filter_parent,
		"docket_filter_item_ids": docket_filter_item_ids,
		"docket_filter_types": docket_filter_types,
		"docket_poll_interval": docket_poll_interval,
		"docket_last_poll_at": docket_last_poll_at,
		"hook_fire_probability": hook_fire_probability,
		"hook_tool_name_pattern": hook_tool_name_pattern,
		"hook_route_table": hook_route_table,
		"pending_approval": pending_approval,
	}
	return data


static func deserialize(data: Dictionary) -> TriggerDefinition:
	var trig = TriggerDefinition.new(data.get("id", ""))
	trig.name = data.get("name", "")
	trig.agent_id = data.get("agent_id", "")
	trig.trigger_type = int(data.get("trigger_type", TriggerType.TIMER))
	trig.enabled = data.get("enabled", false)
	trig.interval_seconds = float(data.get("interval_seconds", 300.0))
	trig.event_type = int(data.get("event_type", EventType.NOTE_CREATED))
	trig.initial_message = data.get("initial_message", "")
	trig.action_type = int(data.get("action_type", ActionType.SPAWN_NEW))
	var ids = data.get("watched_agent_ids", [])
	for aid in ids:
		trig.watched_agent_ids.append(str(aid))
	var bp = data.get("batch_params", [])
	for p in bp:
		trig.batch_params.append(str(p))
	trig.chain_trigger_id = data.get("chain_trigger_id", "")
	trig.batch_label = data.get("batch_label", "")
	trig.schedule_type = int(data.get("schedule_type", ScheduleType.INTERVAL))
	trig.schedule_time = data.get("schedule_time", "09:00")
	var days = data.get("schedule_days", [])
	for d in days:
		trig.schedule_days.append(int(d))
	trig.schedule_day_of_month = int(data.get("schedule_day_of_month", 1))
	trig.schedule_month = int(data.get("schedule_month", 1))
	trig.last_fired_at = data.get("last_fired_at", "")
	trig.fire_if_missed = data.get("fire_if_missed", true)
	trig.docket_project = data.get("docket_project", "")
	trig.docket_filter_tags = data.get("docket_filter_tags", "")
	trig.docket_filter_parent = data.get("docket_filter_parent", "")
	trig.docket_filter_item_ids = data.get("docket_filter_item_ids", "")
	trig.docket_filter_types = data.get("docket_filter_types", "")
	trig.docket_poll_interval = float(data.get("docket_poll_interval", 60.0))
	trig.docket_last_poll_at = data.get("docket_last_poll_at", "")
	trig.hook_fire_probability = float(data.get("hook_fire_probability", 1.0))
	trig.hook_tool_name_pattern = data.get("hook_tool_name_pattern", "")
	trig.hook_route_table = data.get("hook_route_table", "")
	trig.pending_approval = data.get("pending_approval", false)
	# Backward compatibility: older wall-clock schedules were stored as TIMER + non-INTERVAL schedule.
	if trig.trigger_type == TriggerType.TIMER and trig.schedule_type != ScheduleType.INTERVAL:
		trig.trigger_type = TriggerType.TIME
	if trig.trigger_type == TriggerType.TIME and trig.schedule_type == ScheduleType.INTERVAL:
		trig.schedule_type = ScheduleType.DAILY
	return trig
