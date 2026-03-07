class_name AgentDefinition
extends RefCounted
## Data class for a reusable agent template.
## Stores name, system prompt, provider, model settings, and tool allowlist.

var id: String = ""
var name: String = ""
var system_prompt: String = ""
var provider_enum_id: int = 0
var core_service_id: String = ""   # For Core/TurnRock: Service.client_id
var core_action_name: String = ""  # For Core/TurnRock: Action.name
var temperature: float = 1.0
var top_p: float = 1.0
var frequency_penalty: float = 0.0
var presence_penalty: float = 0.0
var max_tool_call_rounds: int = 10
var enabled_tools: Array[String] = []
var tool_sets: Array[String] = []  # Tool set filter for this agent (empty = use global default)
var skills: Array[String] = []  # Skill IDs to activate for this agent (empty = use global default)
var memory_tab_name: String = ""   # Project-scoped notes tab locked to this agent
var drawer_tab_name: String = ""   # App-scoped drawer notes tab locked to this agent


func _init(p_id: String = ""):
	if p_id.is_empty():
		id = _generate_id()
	else:
		id = p_id


static func _generate_id() -> String:
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	return str(rng.randi()).sha256_text().left(16)


func serialize() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"system_prompt": system_prompt,
		"provider_enum_id": provider_enum_id,
		"core_service_id": core_service_id,
		"core_action_name": core_action_name,
		"temperature": temperature,
		"top_p": top_p,
		"frequency_penalty": frequency_penalty,
		"presence_penalty": presence_penalty,
		"max_tool_call_rounds": max_tool_call_rounds,
		"enabled_tools": enabled_tools,
		"tool_sets": tool_sets,
		"skills": skills,
		"memory_tab_name": memory_tab_name,
		"drawer_tab_name": drawer_tab_name,
	}


static func deserialize(data: Dictionary) -> AgentDefinition:
	var def = AgentDefinition.new(data.get("id", ""))
	def.name = data.get("name", "")
	def.system_prompt = data.get("system_prompt", "")
	def.provider_enum_id = int(data.get("provider_enum_id", 0))
	def.core_service_id = data.get("core_service_id", "")
	def.core_action_name = data.get("core_action_name", "")
	def.temperature = float(data.get("temperature", 1.0))
	def.top_p = float(data.get("top_p", 1.0))
	def.frequency_penalty = float(data.get("frequency_penalty", 0.0))
	def.presence_penalty = float(data.get("presence_penalty", 0.0))
	def.max_tool_call_rounds = int(data.get("max_tool_call_rounds", 10))
	var tools = data.get("enabled_tools", [])
	for t in tools:
		def.enabled_tools.append(str(t))
	var sets = data.get("tool_sets", [])
	for s in sets:
		def.tool_sets.append(str(s))
	var skill_ids = data.get("skills", [])
	for sk in skill_ids:
		def.skills.append(str(sk))
	def.memory_tab_name = data.get("memory_tab_name", "")
	def.drawer_tab_name = data.get("drawer_tab_name", "")
	return def
