class_name TriggerDefinition
extends RefCounted
## Data class for an agent trigger (timer or event-based).

enum TriggerType { TIMER, EVENT }
enum EventType { NOTE_CREATED, NOTE_CHANGED, CHAT_COMPLETED }
enum ActionType { SPAWN_NEW, MESSAGE_EXISTING }

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


func _init(p_id: String = ""):
	if p_id.is_empty():
		id = AgentDefinition._generate_id()
	else:
		id = p_id


func serialize() -> Dictionary:
	return {
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
	}


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
	return trig
