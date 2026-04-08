class_name MCPAgentTools
extends MCPToolModule
## MCP tool module for the Agent, Worker, and Trigger domains.
## Handles agent registry CRUD, worker spawning/tracking, and trigger management.

## Tracks last check_worker state per worker for delta responses
var _last_check_state: Dictionary = {}
## Rate limit: last unix timestamp per worker_id for check_worker calls
var _check_worker_timestamps: Dictionary = {}
## Minimum seconds between check_worker calls for the same worker
const CHECK_WORKER_COOLDOWN_SEC: float = 120.0


func get_tool_names() -> Array[String]:
	return [
		# Agent tools
		"minerva_list_agents",
		"minerva_create_agent",
		"minerva_update_agent",
		"minerva_delete_agent",
		"minerva_spawn_agent",
		# Worker tools
		"minerva_spawn_worker",
		"minerva_check_worker",
		"minerva_list_workers",
		"minerva_set_worker_budget",
		"minerva_get_worker_budget",
		"minerva_approve_workers",
		# Trigger tools
		"minerva_list_triggers",
		"minerva_create_trigger",
		"minerva_update_trigger",
		"minerva_delete_trigger",
		"minerva_fire_trigger",
		"minerva_get_batch_status",
	]


func register_tools() -> void:
	_register_agent_tools()
	_register_worker_tools()
	_register_trigger_tools()


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		# Agent registry tools
		"minerva_list_agents":
			return _list_agents(arguments)
		"minerva_create_agent":
			return _create_agent(arguments)
		"minerva_update_agent":
			return _update_agent(arguments)
		"minerva_delete_agent":
			return _delete_agent(arguments)
		"minerva_spawn_agent":
			return _spawn_agent(arguments)
		# Worker tools
		"minerva_spawn_worker":
			return await _spawn_worker(arguments)
		"minerva_check_worker":
			return _check_worker(arguments)
		"minerva_list_workers":
			return _list_workers(arguments)
		"minerva_set_worker_budget":
			return _set_worker_budget(arguments)
		"minerva_get_worker_budget":
			return _get_worker_budget(arguments)
		"minerva_approve_workers":
			return _approve_workers(arguments)
		# Trigger tools
		"minerva_list_triggers":
			return _list_triggers(arguments)
		"minerva_create_trigger":
			return _create_trigger(arguments)
		"minerva_update_trigger":
			return _update_trigger(arguments)
		"minerva_delete_trigger":
			return _delete_trigger(arguments)
		"minerva_fire_trigger":
			return _fire_trigger_mcp(arguments)
		"minerva_get_batch_status":
			return _get_batch_status(arguments)

	return MCPToolUtils.error("Tool '%s' not implemented in MCPAgentTools" % tool_name)


## Connect the worker completion signal so this module routes worker completions to parent chats.
## Call from MinervaMCPServer.connect_server().
func connect_signals() -> void:
	if not SingletonObject.agent_chat_finished.is_connected(_on_worker_chat_finished):
		SingletonObject.agent_chat_finished.connect(_on_worker_chat_finished)


## Disconnect the worker completion signal.
## Call from MinervaMCPServer.disconnect_server().
func disconnect_signals() -> void:
	if SingletonObject.agent_chat_finished.is_connected(_on_worker_chat_finished):
		SingletonObject.agent_chat_finished.disconnect(_on_worker_chat_finished)


#region Agent Tool Registration

func _register_agent_tools() -> void:
	server._register_tool("minerva_list_agents",
		"List all agent definitions in the registry.",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	, "agents")

	server._register_tool("minerva_create_agent",
		"Create a new agent definition in the registry. Returns the agent ID. Provider enum IDs: HUMAN=0, NEMOTRON_NANO=1, DEVSTRAL_SMALL=2, GPT_NANO=3, GPT_STANDARD=4, GPT_DEEP=5, GEMINI_FLASH=7, GEMINI_PRO=8, CLAUDE_HAIKU=10, CLAUDE_SONNET=11, CLAUDE_OPUS=12, TURNROCK=13, CLAUDE_CODE_SONNET=18, CLAUDE_CODE_OPUS=19. For TURNROCK provider, also set core_service_id and core_action_name. For OpenRouter models use their dynamic ID (>=1000).",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the agent"
				},
				"system_prompt": {
					"type": "string",
					"description": "System prompt that defines the agent's behavior"
				},
				"provider_enum_id": {
					"type": "integer",
					"description": "Provider model enum ID (see tool description for values)"
				},
				"core_service_id": {
					"type": "string",
					"description": "Core/TurnRock service ID (e.g. 'model-chat'). Required when provider_enum_id=13 (TURNROCK)."
				},
				"core_action_name": {
					"type": "string",
					"description": "Core/TurnRock action/model name (e.g. 'glm-4.7-flash:latest'). Required when provider_enum_id=13 (TURNROCK)."
				},
				"temperature": {
					"type": "number",
					"description": "Temperature (0.0-2.0). Default 1.0"
				},
				"top_p": {
					"type": "number",
					"description": "Top-p sampling (0.0-1.0). Default 1.0"
				},
				"frequency_penalty": {
					"type": "number",
					"description": "Frequency penalty (-2.0 to 2.0). Default 0.0"
				},
				"presence_penalty": {
					"type": "number",
					"description": "Presence penalty (-2.0 to 2.0). Default 0.0"
				},
				"max_tool_call_rounds": {
					"type": "integer",
					"description": "Max agentic tool call rounds. Default 10"
				},
				"enabled_tools": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Allowlist of MCP tool names. Empty = all tools enabled."
				},
				"memory_tab_name": {
					"type": "string",
					"description": "Project-scoped notes tab name for agent memory. Created and locked to the agent on spawn."
				},
				"drawer_tab_name": {
					"type": "string",
					"description": "App-scoped drawer notes tab name for agent memory. Created and locked to the agent on spawn."
				}
			},
			"required": ["name", "system_prompt", "provider_enum_id"]
		}
	, "agents")

	server._register_tool("minerva_update_agent",
		"Update an existing agent definition. Only the provided fields are changed; omitted fields keep their current values.",
		{
			"type": "object",
			"properties": {
				"agent_id": {
					"type": "string",
					"description": "ID of the agent to update"
				},
				"name": {
					"type": "string",
					"description": "New display name"
				},
				"system_prompt": {
					"type": "string",
					"description": "New system prompt"
				},
				"provider_enum_id": {
					"type": "integer",
					"description": "New provider model enum ID"
				},
				"core_service_id": {
					"type": "string",
					"description": "New Core/TurnRock service ID"
				},
				"core_action_name": {
					"type": "string",
					"description": "New Core/TurnRock action/model name"
				},
				"temperature": {
					"type": "number",
					"description": "New temperature"
				},
				"top_p": {
					"type": "number",
					"description": "New top-p"
				},
				"frequency_penalty": {
					"type": "number",
					"description": "New frequency penalty"
				},
				"presence_penalty": {
					"type": "number",
					"description": "New presence penalty"
				},
				"max_tool_call_rounds": {
					"type": "integer",
					"description": "New max tool call rounds"
				},
				"enabled_tools": {
					"type": "array",
					"items": {"type": "string"},
					"description": "New tool allowlist"
				},
				"memory_tab_name": {
					"type": "string",
					"description": "New project-scoped memory tab name"
				},
				"drawer_tab_name": {
					"type": "string",
					"description": "New app-scoped drawer memory tab name"
				}
			},
			"required": ["agent_id"]
		}
	, "agents")

	server._register_tool("minerva_delete_agent",
		"Delete an agent definition from the registry.",
		{
			"type": "object",
			"properties": {
				"agent_id": {
					"type": "string",
					"description": "ID of the agent to delete"
				}
			},
			"required": ["agent_id"]
		}
	, "agents")

	server._register_tool("minerva_spawn_agent",
		"Spawn a new chat from a registered agent definition. Creates a fully configured agent chat and optionally sends an initial message. Requires agent_id from minerva_list_agents and chat_id from minerva_list_chats or minerva_create_chat.",
		{
			"type": "object",
			"properties": {
				"agent_id": {
					"type": "string",
					"description": "ID of the agent definition to spawn. Use either agent_id or agent_name."
				},
				"agent_name": {
					"type": "string",
					"description": "Name of the agent definition to spawn. Used if agent_id is not provided."
				},
				"initial_message": {
					"type": "string",
					"description": "Optional message to send immediately after spawning."
				}
			},
			"required": []
		}
	, "agents")

#endregion


#region Worker Tool Registration

func _register_worker_tools() -> void:
	server._register_tool("minerva_spawn_worker",
		"Spawn a managed sub-agent worker. Creates a new chat, configures it, sends the task, and tracks the parent-child relationship. The supervisor will be automatically notified when the worker finishes. Returns worker_id for tracking.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the worker chat"
				},
				"system_prompt": {
					"type": "string",
					"description": "System prompt written FROM THE WORKER'S PERSPECTIVE"
				},
				"task": {
					"type": "string",
					"description": "The task message to send to the worker"
				},
				"provider": {
					"type": "string",
					"description": "Provider name or 'current'. Default: 'current'"
				},
				"provider_enum_id": {
					"type": "integer",
					"description": "Alternative provider by enum ID (e.g. 11=CLAUDE_SONNET, 12=CLAUDE_OPUS). Takes precedence over provider name."
				},
				"max_tool_rounds": {
					"type": "integer",
					"description": "Max tool call rounds. Default: 25"
				},
				"timeout_seconds": {
					"type": "number",
					"description": "Wall-clock timeout in seconds. Default: -1 (no timeout)"
				},
				"cobrowser_tab_id": {
					"type": "integer",
					"description": "Browser tab ID assigned to this worker. If set, all cobrowser calls from this worker will automatically include this tab_id."
				},
				"cobrowser_agent_id": {
					"type": "string",
					"description": "Browser agent ID for this worker. If set, all cobrowser calls from this worker will automatically include this agent_id."
				},
				"skills": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Optional list of skill names/IDs to pre-configure for this worker. When provided, resolves each skill's tool dependencies and instructions, locks the worker to those tools only (static mode — no dynamic tool discovery), and prepends skill instructions to the system prompt. Use this for workers that must use a fixed tool set (e.g. GPT-5.4 workers that cannot do dynamic tool search)."
				}
			},
			"required": ["name", "system_prompt", "task"]
		}
	, "chat")

	server._register_tool("minerva_check_worker",
		"Check worker status, rounds used, tokens used, and last response preview (~100 tokens). Preferred over minerva_get_chat_history for monitoring — much cheaper.",
		{
			"type": "object",
			"properties": {
				"worker_id": {
					"type": "string",
					"description": "The worker_id returned from minerva_spawn_worker"
				}
			},
			"required": ["worker_id"]
		}
	, "chat")

	server._register_tool("minerva_list_workers",
		"List all spawned workers, optionally filtered by parent chat.",
		{
			"type": "object",
			"properties": {
				"parent_chat_id": {
					"type": "string",
					"description": "Filter to workers spawned by this chat. Omit to list all workers."
				}
			},
			"required": []
		}
	, "chat")

	server._register_tool("minerva_set_worker_budget",
		"Set resource limits for worker spawning from a specific chat. Controls max concurrent workers, total worker cap, token budget, and approval thresholds.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The supervisor chat to set budget for. Default: current chat."
				},
				"max_concurrent_workers": {
					"type": "integer",
					"description": "Max simultaneous workers. Default: 5."
				},
				"max_total_workers": {
					"type": "integer",
					"description": "Lifetime worker cap. -1 = unlimited."
				},
				"max_total_tokens": {
					"type": "integer",
					"description": "Total token budget across all workers. -1 = unlimited."
				},
				"approval_after": {
					"type": "integer",
					"description": "Require human approval after this many workers. Default: 3. -1 = never."
				}
			},
			"required": []
		}
	, "chat")

	server._register_tool("minerva_get_worker_budget",
		"Get current budget status for a chat's worker spawning. Shows concurrent workers, total spawned, token usage, and approval gate status.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The chat to check. Default: current chat."
				}
			},
			"required": []
		}
	, "chat")

	server._register_tool("minerva_approve_workers",
		"Approve continued worker spawning after an approval gate was reached. Resets the approval requirement until the next threshold.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The supervisor chat to approve."
				}
			},
			"required": ["chat_id"]
		}
	, "chat")

#endregion


#region Trigger Tool Registration

func _register_trigger_tools() -> void:
	server._register_tool("minerva_list_triggers",
		"List all trigger definitions. Shows id, name, agent, type, enabled status, batch params count, and chain target.",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	, "triggers")

	server._register_tool("minerva_create_trigger",
		"Create a new trigger definition. Trigger types: TIMER=0, EVENT=1, TIME=2. Event types: NOTE_CREATED=0, NOTE_CHANGED=1, CHAT_COMPLETED=2, MCP_TOOL_EXECUTED=3, MCP_TOOL_ABOUT_TO_EXECUTE=4. Action types: SPAWN_NEW=0, MESSAGE_EXISTING=1.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the trigger"
				},
				"agent_id": {
					"type": "string",
					"description": "ID of the agent definition to run when triggered"
				},
				"trigger_type": {
					"type": "integer",
					"description": "0=TIMER, 1=EVENT, 2=TIME. Default 0"
				},
				"interval_seconds": {
					"type": "number",
					"description": "Timer interval in seconds (min 5). Default 300"
				},
				"event_type": {
					"type": "integer",
					"description": "0=NOTE_CREATED, 1=NOTE_CHANGED, 2=CHAT_COMPLETED, 3=MCP_TOOL_EXECUTED, 4=MCP_TOOL_ABOUT_TO_EXECUTE. Default 0"
				},
				"action_type": {
					"type": "integer",
					"description": "0=SPAWN_NEW, 1=MESSAGE_EXISTING. Default 0"
				},
				"initial_message": {
					"type": "string",
					"description": "Message template. Vars: {param}, {batch_index}, {batch_total}, {agent_name}, {last_response}, {history_name}"
				},
				"batch_params": {
					"type": "array",
					"items": {"type": "string"},
					"description": "List of parameter values for batch execution. Empty = single fire."
				},
				"batch_label": {
					"type": "string",
					"description": "Optional UI label for batch params (e.g. 'Ticker Symbols')"
				},
				"chain_trigger_id": {
					"type": "string",
					"description": "Trigger ID to fire after this trigger (or batch) completes"
				},
				"watched_agent_ids": {
					"type": "array",
					"items": {"type": "string"},
					"description": "For CHAT_COMPLETED events: only fire when these agent IDs complete (empty = all)"
				},
				"enabled": {
					"type": "boolean",
					"description": "Whether the trigger is active. Default false"
				},
				"schedule_type": {
					"type": "integer",
					"description": "0=INTERVAL (for TIMER), 1=DAILY, 2=WEEKLY, 3=MONTHLY, 4=YEARLY. Use 1-4 with trigger_type=TIME."
				},
				"schedule_time": {
					"type": "string",
					"description": "Local time of day for TIME triggers, 'HH:MM' in 24h format. Default '09:00'."
				},
				"schedule_days": {
					"type": "array",
					"items": {"type": "integer"},
					"description": "Days of week for WEEKLY (0=Mon .. 6=Sun)."
				},
				"schedule_day_of_month": {
					"type": "integer",
					"description": "Day of month for MONTHLY/YEARLY schedules (1-31)."
				},
				"schedule_month": {
					"type": "integer",
					"description": "Month for YEARLY schedules (1-12)."
				},
				"fire_if_missed": {
					"type": "boolean",
					"description": "Fire on next startup if scheduled time was missed. Default true."
				},
				"docket_project": {
					"type": "string",
					"description": "For DOCKET_POLL: docket project name to poll (e.g. 'cad', 'minerva')"
				},
				"docket_filter_parent": {
					"type": "string",
					"description": "For DOCKET_POLL: only watch children of this parent item ID"
				},
				"docket_filter_item_ids": {
					"type": "string",
					"description": "For DOCKET_POLL: only watch these specific item IDs (comma-separated)"
				},
				"docket_filter_types": {
					"type": "string",
					"description": "For DOCKET_POLL: only watch these item types (comma-separated, e.g. 'work_item,bug')"
				},
				"docket_filter_tags": {
					"type": "string",
					"description": "For DOCKET_POLL: only watch items with these tags (comma-separated)"
				},
				"docket_poll_interval": {
					"type": "number",
					"description": "For DOCKET_POLL: poll interval in seconds (min 30, default 60)"
				},
				"hook_fire_probability": {
					"type": "number",
					"description": "Probability of firing (0.0-1.0). Default 1.0. Use 0.1 for 10% nudge rate."
				},
				"hook_tool_name_pattern": {
					"type": "string",
					"description": "Regex pattern matching tool name. Empty = all tools."
				},
				"hook_route_table": {
					"type": "string",
					"description": "JSON route table for PreToolUse: [[tool_regex, arg_name, arg_match_regex, hint], ...]"
				},
				"pending_approval": {
					"type": "boolean",
					"description": "Whether trigger is pending human approval. Read-only for internal agents."
				}
			},
			"required": ["name", "agent_id"]
		}
	, "triggers")

	server._register_tool("minerva_update_trigger",
		"Update an existing trigger definition. Only provided fields are changed.",
		{
			"type": "object",
			"properties": {
				"trigger_id": {
					"type": "string",
					"description": "ID of the trigger to update"
				},
				"name": { "type": "string", "description": "New display name" },
				"agent_id": { "type": "string", "description": "New agent definition ID" },
				"trigger_type": { "type": "integer", "description": "0=TIMER, 1=EVENT, 2=TIME, 3=DOCKET_POLL" },
				"interval_seconds": { "type": "number", "description": "Timer interval" },
				"event_type": { "type": "integer", "description": "0=NOTE_CREATED, 1=NOTE_CHANGED, 2=CHAT_COMPLETED, 3=MCP_TOOL_EXECUTED, 4=MCP_TOOL_ABOUT_TO_EXECUTE" },
				"action_type": { "type": "integer", "description": "0=SPAWN_NEW, 1=MESSAGE_EXISTING" },
				"initial_message": { "type": "string", "description": "Message template" },
				"batch_params": { "type": "array", "items": {"type": "string"}, "description": "Batch parameter list" },
				"batch_label": { "type": "string", "description": "UI label for batch params" },
				"chain_trigger_id": { "type": "string", "description": "Chain target trigger ID" },
				"watched_agent_ids": { "type": "array", "items": {"type": "string"}, "description": "Agent filter for CHAT_COMPLETED" },
				"enabled": { "type": "boolean", "description": "Active state" },
				"schedule_type": { "type": "integer", "description": "0=INTERVAL, 1=DAILY, 2=WEEKLY, 3=MONTHLY, 4=YEARLY" },
				"schedule_time": { "type": "string", "description": "HH:MM in local time" },
				"schedule_days": { "type": "array", "items": {"type": "integer"}, "description": "Days of week 0=Mon..6=Sun" },
				"schedule_day_of_month": { "type": "integer", "description": "Day of month for MONTHLY/YEARLY schedules" },
				"schedule_month": { "type": "integer", "description": "Month for YEARLY schedules (1-12)" },
				"fire_if_missed": { "type": "boolean", "description": "Fire on startup if missed" },
				"docket_project": { "type": "string", "description": "For DOCKET_POLL: project name" },
				"docket_filter_parent": { "type": "string", "description": "For DOCKET_POLL: parent item ID filter" },
				"docket_filter_item_ids": { "type": "string", "description": "For DOCKET_POLL: specific item IDs (comma-separated)" },
				"docket_filter_types": { "type": "string", "description": "For DOCKET_POLL: item types (comma-separated)" },
				"docket_filter_tags": { "type": "string", "description": "For DOCKET_POLL: tag filter (comma-separated)" },
				"docket_poll_interval": { "type": "number", "description": "For DOCKET_POLL: poll interval seconds" },
				"hook_fire_probability": { "type": "number", "description": "Probability of firing (0.0-1.0). Default 1.0. Use 0.1 for 10% nudge rate." },
				"hook_tool_name_pattern": { "type": "string", "description": "Regex pattern matching tool name. Empty = all tools." },
				"hook_route_table": { "type": "string", "description": "JSON route table for PreToolUse: [[tool_regex, arg_name, arg_match_regex, hint], ...]" },
				"pending_approval": { "type": "boolean", "description": "Whether trigger is pending human approval. Read-only for internal agents." }
			},
			"required": ["trigger_id"]
		}
	, "triggers")

	server._register_tool("minerva_delete_trigger",
		"Delete a trigger definition by ID.",
		{
			"type": "object",
			"properties": {
				"trigger_id": {
					"type": "string",
					"description": "ID of the trigger to delete"
				}
			},
			"required": ["trigger_id"]
		}
	, "triggers")

	server._register_tool("minerva_fire_trigger",
		"Manually fire a trigger immediately, bypassing timer/event conditions. Works even if the trigger is disabled.",
		{
			"type": "object",
			"properties": {
				"trigger_id": {
					"type": "string",
					"description": "ID of the trigger to fire"
				}
			},
			"required": ["trigger_id"]
		}
	, "triggers")

	server._register_tool("minerva_get_batch_status",
		"Check the progress of an active batch execution for a trigger.",
		{
			"type": "object",
			"properties": {
				"trigger_id": {
					"type": "string",
					"description": "ID of the trigger to check batch status for"
				}
			},
			"required": ["trigger_id"]
		}
	, "triggers")

#endregion


#region Agent Handler Implementations

func _list_agents(_args: Dictionary) -> Dictionary:
	var registry = SingletonObject.agent_registry
	if not registry:
		return MCPToolUtils.error("Agent registry not available")

	var result: Array = []
	for agent in registry.agents:
		result.append({
			"id": agent.id,
			"name": agent.name,
			"provider_enum_id": agent.provider_enum_id,
			"core_service_id": agent.core_service_id,
			"core_action_name": agent.core_action_name,
			"memory_tab_name": agent.memory_tab_name,
			"drawer_tab_name": agent.drawer_tab_name,
			"max_tool_call_rounds": agent.max_tool_call_rounds,
			"enabled_tools_count": agent.enabled_tools.size(),
		})

	return {
		"success": true,
		"agents": result,
		"count": result.size()
	}


func _create_agent(args: Dictionary) -> Dictionary:
	var registry = SingletonObject.agent_registry
	if not registry:
		return MCPToolUtils.error("Agent registry not available")

	var agent_name: String = args.get("name", "")
	if agent_name.is_empty():
		return MCPToolUtils.error("name is required")

	var agent = AgentDefinition.new()
	agent.name = agent_name
	agent.system_prompt = args.get("system_prompt", "")
	agent.provider_enum_id = MCPToolUtils.coerce_int(args.get("provider_enum_id", 0))
	agent.core_service_id = args.get("core_service_id", "")
	agent.core_action_name = args.get("core_action_name", "")
	agent.temperature = float(args.get("temperature", 1.0))
	agent.top_p = float(args.get("top_p", 1.0))
	agent.frequency_penalty = float(args.get("frequency_penalty", 0.0))
	agent.presence_penalty = float(args.get("presence_penalty", 0.0))
	agent.max_tool_call_rounds = MCPToolUtils.coerce_int(args.get("max_tool_call_rounds", 10))
	agent.memory_tab_name = args.get("memory_tab_name", "")
	agent.drawer_tab_name = args.get("drawer_tab_name", "")

	var tools: Array = args.get("enabled_tools", [])
	for t in tools:
		agent.enabled_tools.append(str(t))

	registry.add_agent(agent)

	return {
		"success": true,
		"agent_id": agent.id,
		"name": agent.name
	}


func _update_agent(args: Dictionary) -> Dictionary:
	var registry = SingletonObject.agent_registry
	if not registry:
		return MCPToolUtils.error("Agent registry not available")

	var agent_id: String = args.get("agent_id", "")
	if agent_id.is_empty():
		return MCPToolUtils.error("agent_id is required")

	var agent = registry.get_agent(agent_id)
	if not agent:
		return MCPToolUtils.error("Agent not found: %s" % agent_id)

	if args.has("name"):
		agent.name = args["name"]
	if args.has("system_prompt"):
		agent.system_prompt = args["system_prompt"]
	if args.has("provider_enum_id"):
		agent.provider_enum_id = int(args["provider_enum_id"])
	if args.has("core_service_id"):
		agent.core_service_id = args["core_service_id"]
	if args.has("core_action_name"):
		agent.core_action_name = args["core_action_name"]
	if args.has("temperature"):
		agent.temperature = float(args["temperature"])
	if args.has("top_p"):
		agent.top_p = float(args["top_p"])
	if args.has("frequency_penalty"):
		agent.frequency_penalty = float(args["frequency_penalty"])
	if args.has("presence_penalty"):
		agent.presence_penalty = float(args["presence_penalty"])
	if args.has("max_tool_call_rounds"):
		agent.max_tool_call_rounds = int(args["max_tool_call_rounds"])
	if args.has("memory_tab_name"):
		agent.memory_tab_name = args["memory_tab_name"]
	if args.has("drawer_tab_name"):
		agent.drawer_tab_name = args["drawer_tab_name"]
	if args.has("enabled_tools"):
		agent.enabled_tools.clear()
		for t in args["enabled_tools"]:
			agent.enabled_tools.append(str(t))

	registry.update_agent(agent_id, agent)

	return {
		"success": true,
		"agent_id": agent_id,
		"message": "Agent updated"
	}


func _delete_agent(args: Dictionary) -> Dictionary:
	var registry = SingletonObject.agent_registry
	if not registry:
		return MCPToolUtils.error("Agent registry not available")

	var agent_id: String = args.get("agent_id", "")
	if agent_id.is_empty():
		return MCPToolUtils.error("agent_id is required")

	var agent = registry.get_agent(agent_id)
	if not agent:
		return MCPToolUtils.error("Agent not found: %s" % agent_id)

	registry.remove_agent(agent_id)

	return {
		"success": true,
		"message": "Agent '%s' deleted" % agent.name
	}


func _spawn_agent(args: Dictionary) -> Dictionary:
	var registry = SingletonObject.agent_registry
	if not registry:
		return MCPToolUtils.error("Agent registry not available")

	var agent_def: AgentDefinition = null

	var agent_id: String = args.get("agent_id", "")
	var agent_name: String = args.get("agent_name", "")

	if not agent_id.is_empty():
		agent_def = registry.get_agent(agent_id)
	elif not agent_name.is_empty():
		agent_def = registry.get_agent_by_name(agent_name)

	if not agent_def:
		return MCPToolUtils.error("Agent not found (id='%s', name='%s')" % [agent_id, agent_name])

	var initial_message: String = args.get("initial_message", "")

	var history = AgentSpawner.spawn_agent(agent_def, initial_message)
	if not history:
		return MCPToolUtils.error("Failed to spawn agent '%s'" % agent_def.name)

	return {
		"success": true,
		"chat_id": history.HistoryId,
		"agent_name": agent_def.name,
		"agent_id": agent_def.id
	}

#endregion


#region Worker Handler Implementations

func _spawn_worker(args: Dictionary) -> Dictionary:
	# 1. Validate required fields
	var worker_name: String = args.get("name", "")
	var system_prompt: String = args.get("system_prompt", "")
	var task: String = args.get("task", "")

	if worker_name.is_empty():
		return MCPToolUtils.error("name is required. Example: minerva_spawn_worker(name=\"MyWorker\", system_prompt=\"You are a research assistant.\", task=\"Find USB-C cables on Amazon\", provider=\"chatgpt\", skills=[\"Co-Browser Automation\"])")
	var auto_defaults: Dictionary = {}
	if system_prompt.is_empty():
		system_prompt = "You are an AI worker named '%s'. Complete the assigned task efficiently and report results clearly." % worker_name
		auto_defaults["system_prompt"] = "auto-generated"
	if task.is_empty():
		return MCPToolUtils.error("task is required. The task is the first user message sent to the worker.")

	var max_tool_rounds: int = MCPToolUtils.coerce_int(args.get("max_tool_rounds", 25))
	var timeout_seconds: float = float(args.get("timeout_seconds", -1))

	# 2. Determine parent_chat_id — prefer caller identity from tool dispatch chain,
	# fall back to current_tab only if no caller identity is available
	var chat_pane = SingletonObject.Chats
	if not chat_pane:
		return MCPToolUtils.error("Chat pane not available")

	var parent_chat_id: String = ""
	if not server._current_caller_chat_id.is_empty():
		parent_chat_id = server._current_caller_chat_id
	elif chat_pane.current_tab >= 0 and chat_pane.current_tab < SingletonObject.ChatList.size():
		parent_chat_id = SingletonObject.ChatList[chat_pane.current_tab].HistoryId

	# 2b. Check budget before spawning
	if not parent_chat_id.is_empty():
		var registry_check = SingletonObject.worker_registry
		if registry_check:
			var budget_check = registry_check.check_budget(parent_chat_id)
			if not budget_check.allowed:
				var result: Dictionary = {
					"success": false,
					"error": "Budget exceeded: %s" % budget_check.reason,
					"budget": budget_check.budget_summary,
				}
				if budget_check.get("requires_approval", false):
					result["requires_approval"] = true
				return result

	# 3. Resolve provider (reuse _create_chat logic via server)
	var provider_name: String = args.get("provider", "current")
	var create_args: Dictionary = {
		"name": worker_name,
		"provider": provider_name,
	}
	if args.has("provider_enum_id"):
		create_args["provider_enum_id"] = args["provider_enum_id"]

	var create_result: Dictionary = await server.call_tool("minerva_create_chat", create_args)
	if not create_result.get("success", false):
		return create_result

	var chat_id: String = create_result.get("chat_id", "")
	var history = MCPToolUtils.find_chat_by_id(chat_id)
	if not history:
		return MCPToolUtils.error("Failed to find newly created chat")

	# 4. Resolve skills (optional) — prepend instructions to system_prompt and compute tool lock
	var requested_skills_raw = args.get("skills", [])
	var requested_skills: Array = []
	if requested_skills_raw is Array:
		requested_skills = requested_skills_raw
	elif requested_skills_raw is String and not requested_skills_raw.is_empty():
		requested_skills = [requested_skills_raw]
	var resolved_tools: Array[String] = []
	var static_tool_mode: bool = false
	if not requested_skills.is_empty():
		# Find the skill tools module to call resolve_skills()
		var skill_tools_module = null
		for module in server._modules:
			if module is MCPSkillTools:
				skill_tools_module = module
				break
		if skill_tools_module:
			var skill_names_typed: Array[String] = []
			for sn in requested_skills:
				skill_names_typed.append(str(sn))
			var resolved: Dictionary = skill_tools_module.resolve_skills(skill_names_typed)
			var skill_instructions: String = resolved.get("instructions", "")
			resolved_tools.assign(resolved.get("tools", []))
			# Prepend skill instructions to system_prompt
			if not skill_instructions.is_empty():
				system_prompt = skill_instructions + "\n\n---\n\n" + system_prompt
			static_tool_mode = true

	# 4b. Set system prompt (potentially with skill instructions prepended)
	var prompt_result: Dictionary = await server.call_tool("minerva_set_system_prompt", {"chat_id": chat_id, "prompt": system_prompt})
	if not prompt_result.get("success", false):
		return prompt_result

	# 5. Set agent mode with max_tool_rounds
	var agent_result: Dictionary = await server.call_tool("minerva_set_agent_mode", {
		"chat_id": chat_id,
		"enabled": true,
		"max_rounds": max_tool_rounds,
	})
	if not agent_result.get("success", false):
		return agent_result

	# 5b. Apply static tool mode if skills were provided
	if static_tool_mode:
		var mcp = SingletonObject.get_mcp_manager()
		if mcp:
			var all_tools = mcp.get_available_tools()
			# Discovery tools are always suppressed in static mode
			var discovery_tools := ["minerva_tool_search", "minerva_list_skills", "minerva_get_skill"]
			var disabled: Array[String] = []
			for tool_def in all_tools:
				var tool_name: String = str(tool_def.name) if tool_def is MCPToolDefinition else str(tool_def)
				if tool_name not in resolved_tools or tool_name in discovery_tools:
					disabled.append(tool_name)
			history.DisabledTools = disabled
			history.StaticToolMode = true
			print("[MCPAgentTools] Static tool mode: %d tools enabled, %d disabled for worker '%s'" % [resolved_tools.size(), disabled.size(), worker_name])

	# 6. Create WorkerInfo and register in WorkerRegistry
	var worker_id: String = AgentDefinition._generate_id()
	var registry = SingletonObject.worker_registry

	var WorkerRegistryScript = preload("res://Scripts/Services/Agents/WorkerRegistry.gd")
	var info = WorkerRegistryScript.WorkerInfo.new()
	info.worker_id = worker_id
	info.worker_chat_id = chat_id
	info.parent_chat_id = parent_chat_id
	info.worker_name = worker_name
	info.task_summary = task.left(200)
	info.provider_name = create_result.get("provider", "unknown")
	info.max_tool_rounds = max_tool_rounds
	info.timeout_seconds = timeout_seconds
	info.spawned_at = Time.get_datetime_string_from_system(true)
	info.status = "running"
	info.termination_message = ""
	info.tokens_used = 0
	info.rounds_used = 0
	info.cobrowser_tab_id = MCPToolUtils.coerce_int(args.get("cobrowser_tab_id", -1))
	var agent_id_arg: String = args.get("cobrowser_agent_id", "")
	if agent_id_arg.is_empty():
		# Auto-generate agent_id from worker name for cobrowser tab claiming
		agent_id_arg = worker_name.to_lower().replace(" ", "_")
	info.cobrowser_agent_id = agent_id_arg

	registry.register_worker(info)

	# 6b. Consume budget for this spawn
	if not parent_chat_id.is_empty():
		registry.consume_budget(parent_chat_id)

	# 7. Send task message (follow _send_message pattern)
	var tab_idx = MCPToolUtils.find_chat_tab_index(chat_id)
	if tab_idx == -1:
		registry.update_worker_status(worker_id, "error", "Chat tab not found after creation")
		return MCPToolUtils.error("Worker chat tab not found")

	var original_tab = chat_pane.current_tab
	chat_pane.current_tab = tab_idx

	print("[MinervaMCPServer] Spawned worker '%s' (worker_id=%s, chat_id=%s, parent=%s)" % [worker_name, worker_id, chat_id, parent_chat_id])
	chat_pane.execute_regular_chat(task)

	# Restore original tab after the current frame (same pattern as _send_message)
	chat_pane.call_deferred("set_current_tab", original_tab)

	# 8. Set up timeout if configured
	if timeout_seconds > 0:
		_setup_worker_timeout(worker_id, timeout_seconds)

	var spawn_result: Dictionary = {
		"success": true,
		"worker_id": worker_id,
		"chat_id": chat_id,
		"name": worker_name,
		"parent_chat_id": parent_chat_id,
		"message": "Worker spawned and task sent. Use minerva_check_worker or minerva_list_workers to monitor progress."
	}
	if not auto_defaults.is_empty():
		spawn_result["auto_defaults"] = auto_defaults
	return spawn_result


func _setup_worker_timeout(worker_id: String, timeout_seconds: float) -> void:
	# Create a one-shot timer for worker timeout
	var timer := Timer.new()
	timer.wait_time = timeout_seconds
	timer.one_shot = true
	timer.timeout.connect(func():
		var registry = SingletonObject.worker_registry
		var info = registry.get_worker(worker_id)
		if info and not registry.is_terminal_status(info.status):
			registry.update_worker_status(worker_id, "timeout", "Worker exceeded %ds timeout" % int(timeout_seconds))
			print("[MinervaMCPServer] Worker '%s' timed out after %ds" % [info.worker_name, int(timeout_seconds)])
		timer.queue_free()
	)
	# Add to scene tree so it can tick
	if SingletonObject and SingletonObject.is_inside_tree():
		SingletonObject.add_child(timer)
		timer.start()


func _check_worker(args: Dictionary) -> Dictionary:
	var worker_id: String = args.get("worker_id", "")
	if worker_id.is_empty():
		return MCPToolUtils.error("worker_id is required")

	var registry = SingletonObject.worker_registry
	var info = registry.get_worker(worker_id)
	if not info:
		return MCPToolUtils.error("Worker not found: %s" % worker_id)

	# Rate limit: 1 call per worker every CHECK_WORKER_COOLDOWN_SEC seconds.
	# Terminal statuses always pass (so post-completion checks work).
	var now := Time.get_unix_time_from_system()
	var last_check: float = _check_worker_timestamps.get(worker_id, 0.0)
	var elapsed := now - last_check
	if last_check > 0.0 and elapsed < CHECK_WORKER_COOLDOWN_SEC and not registry.is_terminal_status(info.status):
		var wait_secs := int(CHECK_WORKER_COOLDOWN_SEC - elapsed)
		return {
			"success": false,
			"error": "Rate limited. Next check for '%s' available in %ds. You will be notified automatically when the worker completes." % [info.worker_name, wait_secs],
			"status": info.status,
			"rounds_used": info.rounds_used,
		}
	_check_worker_timestamps[worker_id] = now

	var result: Dictionary = {
		"success": true,
		"worker_id": info.worker_id,
		"worker_name": info.worker_name,
		"status": info.status,
		"chat_id": info.worker_chat_id,
		"parent_chat_id": info.parent_chat_id,
		"provider": info.provider_name,
		"max_tool_rounds": info.max_tool_rounds,
		"rounds_used": info.rounds_used,
		"tokens_used": info.tokens_used,
		"spawned_at": info.spawned_at,
		"task_summary": info.task_summary,
	}

	if not info.termination_message.is_empty():
		result["termination_message"] = info.termination_message

	# Peek at the worker chat's last assistant message for a summary
	var history = MCPToolUtils.find_chat_by_id(info.worker_chat_id)
	if history:
		result["message_count"] = history.HistoryItemList.size()
		var last_assistant_msg: String = ""
		for i in range(history.HistoryItemList.size() - 1, -1, -1):
			var item = history.HistoryItemList[i]
			if item.Role == 1:  # ChatRole.ASSISTANT = 1
				last_assistant_msg = item.Message
				break
		if not last_assistant_msg.is_empty():
			# Truncate to keep response size reasonable
			result["last_response_preview"] = last_assistant_msg.left(500)

	# Delta detection: if status and message_count unchanged, return lean response
	var state_key: String = info.worker_id
	var current_state: Dictionary = {"status": info.status, "message_count": result.get("message_count", -1)}
	var prev_state: Dictionary = _last_check_state.get(state_key, {})
	_last_check_state[state_key] = current_state

	if not prev_state.is_empty() and prev_state == current_state:
		# Nothing changed — return minimal response to save tokens
		return {
			"success": true,
			"worker_id": info.worker_id,
			"status": info.status,
			"rounds_used": info.rounds_used,
			"tokens_used": info.tokens_used,
			"message_count": result.get("message_count", 0),
			"message": "No change since last check.",
		}

	return result


func _list_workers(args: Dictionary) -> Dictionary:
	var registry = SingletonObject.worker_registry
	var parent_chat_id: String = args.get("parent_chat_id", "")

	var workers: Array
	if not parent_chat_id.is_empty():
		workers = registry.get_workers_for_parent(parent_chat_id)
	else:
		workers = registry.get_all_workers()

	var result: Array = []
	for info in workers:
		result.append({
			"worker_id": info.worker_id,
			"worker_name": info.worker_name,
			"status": info.status,
			"chat_id": info.worker_chat_id,
			"parent_chat_id": info.parent_chat_id,
			"provider": info.provider_name,
			"spawned_at": info.spawned_at,
			"task_summary": info.task_summary,
		})

	return {
		"success": true,
		"workers": result,
		"count": result.size(),
	}


func _resolve_chat_id_for_budget(args: Dictionary) -> String:
	var chat_id: String = args.get("chat_id", "")
	if chat_id.is_empty():
		var chat_pane = SingletonObject.Chats
		if chat_pane and chat_pane.current_tab >= 0 and chat_pane.current_tab < SingletonObject.ChatList.size():
			chat_id = SingletonObject.ChatList[chat_pane.current_tab].HistoryId
	return chat_id


func _set_worker_budget(args: Dictionary) -> Dictionary:
	var registry = SingletonObject.worker_registry
	if not registry:
		return MCPToolUtils.error("Worker registry not initialized")

	var chat_id := _resolve_chat_id_for_budget(args)
	if chat_id.is_empty():
		return MCPToolUtils.error("Could not determine chat_id. Provide chat_id or ensure a chat is active.")

	var max_concurrent: int = MCPToolUtils.coerce_int(args.get("max_concurrent_workers", 5))
	var max_total: int = MCPToolUtils.coerce_int(args.get("max_total_workers", -1))
	var max_tokens: int = MCPToolUtils.coerce_int(args.get("max_total_tokens", -1))
	var approval_after: int = MCPToolUtils.coerce_int(args.get("approval_after", 3))

	registry.set_budget(chat_id, max_concurrent, max_total, max_tokens, approval_after)

	return {
		"success": true,
		"chat_id": chat_id,
		"message": "Worker budget set for chat %s" % chat_id,
		"budget": registry.get_budget_summary(chat_id),
	}


func _get_worker_budget(args: Dictionary) -> Dictionary:
	var registry = SingletonObject.worker_registry
	if not registry:
		return MCPToolUtils.error("Worker registry not initialized")

	var chat_id := _resolve_chat_id_for_budget(args)
	if chat_id.is_empty():
		return MCPToolUtils.error("Could not determine chat_id. Provide chat_id or ensure a chat is active.")

	return {
		"success": true,
		"chat_id": chat_id,
		"budget": registry.get_budget_summary(chat_id),
	}


func _approve_workers(args: Dictionary) -> Dictionary:
	var registry = SingletonObject.worker_registry
	if not registry:
		return MCPToolUtils.error("Worker registry not initialized")

	var chat_id: String = args.get("chat_id", "")
	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")

	var result: Dictionary = registry.approve_workers(chat_id)
	if result.get("success", false):
		result["chat_id"] = chat_id
	return result

#endregion


#region Worker Completion Routing

## Handler for agent_chat_finished signal — routes worker completions to parent chats.
func _on_worker_chat_finished(history_id: String, _agent_definition_id: String) -> void:
	var registry = SingletonObject.worker_registry
	if not registry:
		return

	var worker = registry.get_worker_by_chat(history_id)
	if not worker:
		return  # Not a tracked worker — manual chat or trigger-spawned agent

	# Extract termination info from the chat
	var chat_history = MCPToolUtils.find_chat_by_id(history_id)
	var reason := "completed"
	var message := ""
	var total_output_tokens := 0
	var total_rounds := 0

	if chat_history:
		reason = chat_history.termination_reason if not chat_history.termination_reason.is_empty() else "completed"
		message = chat_history.termination_message

		# Count output tokens and tool rounds from history items
		for item in chat_history.HistoryItemList:
			total_output_tokens += item.OutputTokens
			if item.Role == ChatHistoryItem.ChatRole.MODEL or item.Role == ChatHistoryItem.ChatRole.ASSISTANT:
				if not item.ToolCalls.is_empty():
					total_rounds += 1

	# Update worker status in registry
	registry.update_worker_status(worker.worker_id, reason, message, total_output_tokens, total_rounds)

	# Inject synthetic completion message into parent chat
	_inject_completion_into_parent(worker, reason, message, chat_history)


## Build a synthetic user message and inject it into the parent (supervisor) chat,
## waking the supervisor with information about what the worker did.
func _inject_completion_into_parent(worker, reason: String, message: String, chat_history) -> void:
	var parent_chat = MCPToolUtils.find_chat_by_id(worker.parent_chat_id)
	if not parent_chat:
		push_warning("[WorkerCompletion] Parent chat not found: %s" % worker.parent_chat_id)
		return

	# Get worker's last assistant message — full text so supervisor can use it directly
	# without needing to call get_chat_history + get_chat_messages (saves ~5 rounds)
	var last_response := ""
	if chat_history:
		for i in range(chat_history.HistoryItemList.size() - 1, -1, -1):
			var item = chat_history.HistoryItemList[i]
			if item.Role == ChatHistoryItem.ChatRole.MODEL or item.Role == ChatHistoryItem.ChatRole.ASSISTANT:
				last_response = item.Message
				break

	# Compute duration
	var duration_text := ""
	if not worker.spawned_at.is_empty():
		var spawned_dt := Time.get_datetime_dict_from_datetime_string(worker.spawned_at, true)
		if not spawned_dt.is_empty():
			var spawned_unix := Time.get_unix_time_from_datetime_dict(spawned_dt)
			var now_unix := Time.get_unix_time_from_system()
			var elapsed := int(now_unix - spawned_unix)
			if elapsed >= 60:
				var minutes := int(elapsed / 60.0)
				duration_text = "%dm%ds" % [minutes, elapsed % 60]
			else:
				duration_text = "%ds" % elapsed

	# Build synthetic message
	var status_label: String = {
		"completed": "completed successfully",
		"error": "finished with error",
		"cancelled": "was cancelled",
		"quota_exhausted": "hit max tool rounds",
		"rate_limited": "was rate limited",
		"timeout": "timed out",
	}.get(reason, "finished (%s)" % reason)

	var synthetic := '[Sub-agent "%s" %s]' % [worker.worker_name, status_label]
	if not duration_text.is_empty():
		synthetic += " Duration: %s." % duration_text
	if worker.tokens_used > 0:
		synthetic += " Tokens: %d." % worker.tokens_used
	if not message.is_empty():
		synthetic += "\nReason: %s" % message
	if not last_response.is_empty():
		synthetic += "\nWorker's last response:\n%s" % last_response

	# Send the synthetic message to the parent chat, waking the supervisor
	var chat_pane = SingletonObject.Chats
	if not chat_pane:
		push_warning("[WorkerCompletion] Chat pane not available")
		return

	var tab_idx := MCPToolUtils.find_chat_tab_index(worker.parent_chat_id)
	if tab_idx == -1:
		push_warning("[WorkerCompletion] Parent chat tab not found: %s" % worker.parent_chat_id)
		return

	var original_tab: int = chat_pane.current_tab
	chat_pane.current_tab = tab_idx
	print("[WorkerCompletion] Injecting completion for worker '%s' into parent chat '%s'" % [worker.worker_name, parent_chat.HistoryName])
	chat_pane.execute_regular_chat(synthetic)
	chat_pane.call_deferred("set_current_tab", original_tab)

#endregion


#region Trigger Handler Implementations

func _list_triggers(_args: Dictionary) -> Dictionary:
	var tm = SingletonObject.trigger_manager
	if not tm:
		return MCPToolUtils.error("Trigger manager not available")

	var result: Array[Dictionary] = []
	var registry = SingletonObject.agent_registry
	for trig in tm.triggers:
		var agent_name := ""
		if registry:
			var agent_def = registry.get_agent(trig.agent_id)
			if agent_def:
				agent_name = agent_def.name
		var entry: Dictionary = {
			"id": trig.id,
			"name": trig.name,
			"agent_id": trig.agent_id,
			"agent_name": agent_name,
			"trigger_type": trig.trigger_type,
			"enabled": trig.enabled,
			"action_type": trig.action_type,
			"initial_message": trig.initial_message,
		}
		if trig.trigger_type == TriggerDefinition.TriggerType.TIMER:
			entry["interval_seconds"] = trig.interval_seconds
		elif trig.trigger_type == TriggerDefinition.TriggerType.TIME:
			entry["schedule_type"] = trig.schedule_type
			entry["schedule_time"] = trig.schedule_time
			entry["fire_if_missed"] = trig.fire_if_missed
			entry["last_fired_at"] = trig.last_fired_at
			if trig.schedule_type == TriggerDefinition.ScheduleType.WEEKLY:
				entry["schedule_days"] = trig.schedule_days
			elif trig.schedule_type == TriggerDefinition.ScheduleType.MONTHLY:
				entry["schedule_day_of_month"] = trig.schedule_day_of_month
			elif trig.schedule_type == TriggerDefinition.ScheduleType.YEARLY:
				entry["schedule_day_of_month"] = trig.schedule_day_of_month
				entry["schedule_month"] = trig.schedule_month
		else:
			entry["event_type"] = trig.event_type
			entry["watched_agent_ids"] = trig.watched_agent_ids
		if not trig.batch_params.is_empty():
			entry["batch_params"] = trig.batch_params
			entry["batch_label"] = trig.batch_label
		if not trig.chain_trigger_id.is_empty():
			entry["chain_trigger_id"] = trig.chain_trigger_id
		result.append(entry)

	return {"success": true, "triggers": result, "count": result.size()}


func _create_trigger(args: Dictionary) -> Dictionary:
	var tm = SingletonObject.trigger_manager
	if not tm:
		return MCPToolUtils.error("Trigger manager not available")

	var trig_name: String = args.get("name", "")
	var agent_id: String = args.get("agent_id", "")
	if agent_id.is_empty():
		return MCPToolUtils.error("agent_id is required")

	var trig = TriggerDefinition.new()
	trig.name = trig_name
	trig.agent_id = agent_id
	trig.trigger_type = MCPToolUtils.coerce_int(args.get("trigger_type", TriggerDefinition.TriggerType.TIMER))
	trig.interval_seconds = float(args.get("interval_seconds", 300.0))
	trig.event_type = MCPToolUtils.coerce_int(args.get("event_type", TriggerDefinition.EventType.NOTE_CREATED))
	trig.action_type = MCPToolUtils.coerce_int(args.get("action_type", TriggerDefinition.ActionType.SPAWN_NEW))
	trig.initial_message = args.get("initial_message", "")
	trig.batch_label = args.get("batch_label", "")
	trig.chain_trigger_id = args.get("chain_trigger_id", "")
	trig.enabled = args.get("enabled", false)
	trig.schedule_type = MCPToolUtils.coerce_int(args.get("schedule_type", TriggerDefinition.ScheduleType.INTERVAL))
	if trig.trigger_type == TriggerDefinition.TriggerType.TIME and trig.schedule_type == TriggerDefinition.ScheduleType.INTERVAL:
		trig.schedule_type = TriggerDefinition.ScheduleType.DAILY
	trig.schedule_time = args.get("schedule_time", "09:00")
	trig.schedule_day_of_month = MCPToolUtils.coerce_int(args.get("schedule_day_of_month", 1))
	trig.schedule_month = MCPToolUtils.coerce_int(args.get("schedule_month", 1))
	trig.fire_if_missed = args.get("fire_if_missed", true)

	# Docket poll fields
	trig.docket_project = args.get("docket_project", "")
	trig.docket_filter_parent = args.get("docket_filter_parent", "")
	trig.docket_filter_item_ids = args.get("docket_filter_item_ids", "")
	trig.docket_filter_types = args.get("docket_filter_types", "")
	trig.docket_filter_tags = args.get("docket_filter_tags", "")
	trig.docket_poll_interval = float(args.get("docket_poll_interval", 60.0))
	# Hook fields
	trig.hook_fire_probability = float(args.get("hook_fire_probability", 1.0))
	trig.hook_tool_name_pattern = args.get("hook_tool_name_pattern", "")
	trig.hook_route_table = args.get("hook_route_table", "")
	trig.pending_approval = args.get("pending_approval", false)

	var bp: Array = args.get("batch_params", [])
	for p in bp:
		trig.batch_params.append(str(p))

	var wids: Array = args.get("watched_agent_ids", [])
	for wid in wids:
		trig.watched_agent_ids.append(str(wid))

	var sdays: Array = args.get("schedule_days", [])
	for d in sdays:
		trig.schedule_days.append(int(d))

	tm.add_trigger(trig)

	return {
		"success": true,
		"trigger_id": trig.id,
		"name": trig.name
	}


func _update_trigger(args: Dictionary) -> Dictionary:
	var tm = SingletonObject.trigger_manager
	if not tm:
		return MCPToolUtils.error("Trigger manager not available")

	var trigger_id: String = args.get("trigger_id", "")
	if trigger_id.is_empty():
		return MCPToolUtils.error("trigger_id is required")

	var existing = tm.get_trigger(trigger_id)
	if not existing:
		return MCPToolUtils.error("Trigger not found: %s" % trigger_id)

	# Clone into a new TriggerDefinition with same ID
	var trig = TriggerDefinition.new(trigger_id)
	trig.name = args.get("name", existing.name)
	trig.agent_id = args.get("agent_id", existing.agent_id)
	trig.trigger_type = MCPToolUtils.coerce_int(args.get("trigger_type", existing.trigger_type))
	trig.interval_seconds = float(args.get("interval_seconds", existing.interval_seconds))
	trig.event_type = MCPToolUtils.coerce_int(args.get("event_type", existing.event_type))
	trig.action_type = MCPToolUtils.coerce_int(args.get("action_type", existing.action_type))
	trig.initial_message = args.get("initial_message", existing.initial_message)
	trig.batch_label = args.get("batch_label", existing.batch_label)
	trig.chain_trigger_id = args.get("chain_trigger_id", existing.chain_trigger_id)
	trig.enabled = args.get("enabled", existing.enabled)
	trig.schedule_type = MCPToolUtils.coerce_int(args.get("schedule_type", existing.schedule_type))
	if trig.trigger_type == TriggerDefinition.TriggerType.TIME and trig.schedule_type == TriggerDefinition.ScheduleType.INTERVAL:
		trig.schedule_type = TriggerDefinition.ScheduleType.DAILY
	trig.schedule_time = args.get("schedule_time", existing.schedule_time)
	trig.schedule_day_of_month = MCPToolUtils.coerce_int(args.get("schedule_day_of_month", existing.schedule_day_of_month))
	trig.schedule_month = MCPToolUtils.coerce_int(args.get("schedule_month", existing.schedule_month))
	trig.fire_if_missed = args.get("fire_if_missed", existing.fire_if_missed)
	trig.last_fired_at = existing.last_fired_at

	# Docket poll fields
	trig.docket_project = args.get("docket_project", existing.docket_project)
	trig.docket_filter_parent = args.get("docket_filter_parent", existing.docket_filter_parent)
	trig.docket_filter_item_ids = args.get("docket_filter_item_ids", existing.docket_filter_item_ids)
	trig.docket_filter_types = args.get("docket_filter_types", existing.docket_filter_types)
	trig.docket_filter_tags = args.get("docket_filter_tags", existing.docket_filter_tags)
	trig.docket_poll_interval = float(args.get("docket_poll_interval", existing.docket_poll_interval))
	trig.docket_last_poll_at = existing.docket_last_poll_at
	# Hook event fields
	trig.hook_fire_probability = float(args.get("hook_fire_probability", existing.hook_fire_probability))
	trig.hook_tool_name_pattern = args.get("hook_tool_name_pattern", existing.hook_tool_name_pattern)
	trig.hook_route_table = args.get("hook_route_table", existing.hook_route_table)
	trig.pending_approval = args.get("pending_approval", existing.pending_approval)

	if args.has("batch_params"):
		var bp: Array = args["batch_params"]
		for p in bp:
			trig.batch_params.append(str(p))
	else:
		trig.batch_params = existing.batch_params.duplicate()

	if args.has("watched_agent_ids"):
		var wids: Array = args["watched_agent_ids"]
		for wid in wids:
			trig.watched_agent_ids.append(str(wid))
	else:
		trig.watched_agent_ids = existing.watched_agent_ids.duplicate()

	if args.has("schedule_days"):
		var sdays: Array = args["schedule_days"]
		for d in sdays:
			trig.schedule_days.append(int(d))
	else:
		trig.schedule_days = existing.schedule_days.duplicate()

	tm.update_trigger(trigger_id, trig)

	return {"success": true, "trigger_id": trigger_id}


func _delete_trigger(args: Dictionary) -> Dictionary:
	var tm = SingletonObject.trigger_manager
	if not tm:
		return MCPToolUtils.error("Trigger manager not available")

	var trigger_id: String = args.get("trigger_id", "")
	if trigger_id.is_empty():
		return MCPToolUtils.error("trigger_id is required")

	var existing = tm.get_trigger(trigger_id)
	if not existing:
		return MCPToolUtils.error("Trigger not found: %s" % trigger_id)

	tm.remove_trigger(trigger_id)
	return {"success": true, "trigger_id": trigger_id}


func _fire_trigger_mcp(args: Dictionary) -> Dictionary:
	var tm = SingletonObject.trigger_manager
	if not tm:
		return MCPToolUtils.error("Trigger manager not available")

	var trigger_id: String = args.get("trigger_id", "")
	if trigger_id.is_empty():
		return MCPToolUtils.error("trigger_id is required")

	var trig = tm.get_trigger(trigger_id)
	if not trig:
		return MCPToolUtils.error("Trigger not found: %s" % trigger_id)

	tm._fire_trigger(trigger_id, {}, {}, true)  # force=true bypasses enabled check for manual fire

	var is_batch = not trig.batch_params.is_empty()
	return {
		"success": true,
		"trigger_id": trigger_id,
		"is_batch": is_batch,
		"batch_size": trig.batch_params.size() if is_batch else 0,
		"message": "Trigger fired" + (" (batch of %d)" % trig.batch_params.size() if is_batch else "")
	}


func _get_batch_status(args: Dictionary) -> Dictionary:
	var tm = SingletonObject.trigger_manager
	if not tm:
		return MCPToolUtils.error("Trigger manager not available")

	var trigger_id: String = args.get("trigger_id", "")
	if trigger_id.is_empty():
		return MCPToolUtils.error("trigger_id is required")

	var status = tm.get_batch_status(trigger_id)
	status["success"] = true
	return status

#endregion
