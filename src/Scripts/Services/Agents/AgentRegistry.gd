class_name AgentRegistry
extends RefCounted
## Persistent CRUD for agent definitions.
## Stores at user://agent_registry.json following the OpenRouterModelManager pattern.

signal agents_changed

const CONFIG_PATH := "user://agent_registry.json"

var agents: Array[AgentDefinition] = []


func load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		save_config()
		return

	var file = FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if not file:
		push_error("[AgentRegistry] Failed to open config: %s" % CONFIG_PATH)
		return

	var json_text = file.get_as_text()
	file.close()

	var data = JSON.parse_string(json_text)
	if data == null or not data is Dictionary:
		push_warning("[AgentRegistry] Invalid config, resetting")
		save_config()
		return

	agents.clear()
	for agent_data in data.get("agents", []):
		if agent_data is Dictionary and agent_data.has("id"):
			agents.append(AgentDefinition.deserialize(agent_data))

	print("[AgentRegistry] Loaded %d agent definitions" % agents.size())


func save_config() -> void:
	var serialized: Array[Dictionary] = []
	for agent in agents:
		serialized.append(agent.serialize())

	var data = { "agents": serialized }
	var file = FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()


func add_agent(agent: AgentDefinition) -> void:
	agents.append(agent)
	save_config()
	agents_changed.emit()


func update_agent(agent_id: String, updated: AgentDefinition) -> void:
	for i in agents.size():
		if agents[i].id == agent_id:
			updated.id = agent_id
			agents[i] = updated
			save_config()
			agents_changed.emit()
			return


func remove_agent(agent_id: String) -> void:
	for i in agents.size():
		if agents[i].id == agent_id:
			agents.remove_at(i)
			save_config()
			agents_changed.emit()
			return


func get_agent(agent_id: String) -> AgentDefinition:
	for agent in agents:
		if agent.id == agent_id:
			return agent
	return null


func get_agent_by_name(agent_name: String) -> AgentDefinition:
	for agent in agents:
		if agent.name == agent_name:
			return agent
	return null
