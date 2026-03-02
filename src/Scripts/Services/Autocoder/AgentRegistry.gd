class_name AgentRegistry
extends RefCounted
## Encapsulates agent persistence and lookup.
## Wraps AutocoderAdapter CRUD, translating between AgentDefinition
## objects and the dict format Core expects.

var _adapter: AutocoderAdapter


func _init(adapter: AutocoderAdapter):
	_adapter = adapter


## Register a new agent. Returns the backend-assigned agent_id, or "" on failure.
func register(def: AgentDefinition) -> String:
	var agent_id := await _adapter.create_review_agent(
		def.name, def.prompt,
		Array(def.setup_commands),
		def.model, def.tools_enabled
	)
	if not agent_id.is_empty():
		def.agent_id = agent_id
	return agent_id


## Fetch a single agent by ID. Returns null if not found.
func get_agent(id: String) -> AgentDefinition:
	var agents := await list_agents()
	for agent in agents:
		if agent.agent_id == id:
			return agent
	return null


## List all agents as AgentDefinition objects.
func list_agents() -> Array[AgentDefinition]:
	var dicts := await _adapter.list_review_agents()
	var result: Array[AgentDefinition] = []
	for d in dicts:
		result.append(AgentDefinition.Deserialize(d))
	return result


## Update an existing agent. Sends only Core fields to backend.
## Swarm field persistence is handled separately (client-side).
func update(def: AgentDefinition) -> bool:
	return await _adapter.update_review_agent(
		def.agent_id, def.name, def.prompt,
		Array(def.setup_commands) if not def.setup_commands.is_empty() else null,
		def.model,
		def.tools_enabled
	)


## Delete an agent by ID.
func delete(id: String) -> bool:
	return await _adapter.delete_review_agent(id)


## Get all agents whose parent is the given agent_id (direct children).
func get_children(parent_id: String) -> Array[AgentDefinition]:
	var all := await list_agents()
	var children: Array[AgentDefinition] = []
	for agent in all:
		if agent.parent == parent_id:
			children.append(agent)
	return children


## Get the supervisor of the given agent. Returns null if no parent set.
func get_supervisor(id: String) -> AgentDefinition:
	var agent := await get_agent(id)
	if agent == null or agent.parent.is_empty():
		return null
	return await get_agent(agent.parent)
