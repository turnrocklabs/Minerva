class_name AutocoderAgentRegistry
extends RefCounted
## Encapsulates agent persistence and lookup.
## Wraps AutocoderAdapter CRUD, translating between SwarmAgentDefinition
## objects and the dict format Core expects.

var _adapter: AutocoderAdapter


func _init(adapter: AutocoderAdapter):
	_adapter = adapter


## Register a new agent. Returns the backend-assigned agent_id, or "" on failure.
func register(def: SwarmAgentDefinition) -> String:
	var agent_id := await _adapter.create_review_agent(
		def.name, def.prompt,
		Array(def.setup_commands),
		def.model, def.tools_enabled
	)
	if not agent_id.is_empty():
		def.agent_id = agent_id
	return agent_id


## Fetch a single agent by ID. Returns null if not found.
func get_agent(id: String) -> SwarmAgentDefinition:
	var agents := await list_agents()
	for agent in agents:
		if agent.agent_id == id:
			return agent
	return null


## List all agents as SwarmAgentDefinition objects.
func list_agents() -> Array[SwarmAgentDefinition]:
	var dicts := await _adapter.list_review_agents()
	var result: Array[SwarmAgentDefinition] = []
	for d in dicts:
		result.append(SwarmAgentDefinition.Deserialize(d))
	return result


## Update an existing agent. Sends only Core fields to backend.
## Swarm field persistence is handled separately (client-side).
func update(def: SwarmAgentDefinition) -> bool:
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
func get_children(parent_id: String) -> Array[SwarmAgentDefinition]:
	var all := await list_agents()
	var children: Array[SwarmAgentDefinition] = []
	for agent in all:
		if agent.parent == parent_id:
			children.append(agent)
	return children


## Get the supervisor of the given agent. Returns null if no parent set.
func get_supervisor(id: String) -> SwarmAgentDefinition:
	var agent := await get_agent(id)
	if agent == null or agent.parent.is_empty():
		return null
	return await get_agent(agent.parent)
