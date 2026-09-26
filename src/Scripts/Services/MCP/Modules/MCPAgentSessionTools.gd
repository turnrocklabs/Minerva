extends MCPToolModule
## MCP verbs for agent-container sessions: create, start, stop, status, list
## and build. Each is the MCP twin of a control in Preferences > Containers >
## Agent Sessions; both drive AgentSessionStore, which runs the launcher
## Minerva ships. Attaching a session in a tab is done with the
## `attach_command` that start, status and list return.

const AgentSessionStore := preload("res://Scripts/Services/AgentSessions/AgentSessionStore.gd")

const _NAME := {"type": "string", "description": "Session name: 1-32 lowercase letters, digits and -."}


func get_tool_names() -> Array[String]:
	return ["minerva_agent_session_create", "minerva_agent_session_start",
		"minerva_agent_session_stop", "minerva_agent_session_status",
		"minerva_agent_session_list", "minerva_agent_session_build"]


func register_tools() -> void:
	server._register_tool("minerva_agent_session_create",
		"Create an agent-container session record: a harness (claude or codex) in a hardened container that mounts the given host folders. A folder that is a git checkout is cloned once into the session's work directory and the clone is mounted (the checkout itself never is); any other folder is mounted as it is. Docket projects default to the .dct files found near the top of the folders. The record survives Minerva restarts. Creating does not start it: call minerva_agent_session_start.",
		{"type": "object", "properties": {
			"name": _NAME,
			"harness": {"type": "string", "enum": ["claude", "codex"]},
			"folders": {"type": "array", "items": {"type": "string"}, "description": "Absolute host folder paths to mount (at least one)."},
			"start_in": {"type": "string", "description": "Host folder the harness starts in; inside one of the folders. Default: the first folder."},
			"projects": {"type": "array", "items": {"type": "string"}, "description": "Docket project names the session may use. Default: discovered from the folders' .dct files."},
			"mode": {"type": "string", "enum": ["start", "resume", "shell"], "description": "What the session shell runs first: the harness, its resume picker, or nothing. Default start."},
		}, "required": ["name", "harness", "folders"]}, "containers")

	server._register_tool("minerva_agent_session_start",
		"Start an agent-container session created with minerva_agent_session_create (or by the launcher earlier). The first start clones checkout folders and can take minutes. Needs the agent image: see minerva_agent_session_list's image.built and minerva_agent_session_build. The reply's attach_command attaches the session when run in a Minerva terminal tab.",
		{"type": "object", "properties": {
			"name": _NAME,
			"mode": {"type": "string", "enum": ["start", "resume", "shell"], "description": "Override the record's mode for this start."},
		}, "required": ["name"]}, "containers")

	server._register_tool("minerva_agent_session_stop",
		"Stop an agent-container session's containers. Its record, harness home (login, transcripts) and clones are kept; start it again by name.",
		{"type": "object", "properties": {"name": _NAME}, "required": ["name"]}, "containers")

	server._register_tool("minerva_agent_session_status",
		"One agent-container session: harness, folders (host path, path in the container, clone or mount), start folder, Docket projects, mode, state (running, stopped, unknown), the attached terminal, and attach_command.",
		{"type": "object", "properties": {"name": _NAME}, "required": ["name"]}, "containers")

	server._register_tool("minerva_agent_session_list",
		"Every agent-container session record with its live state, plus whether the agent image is built (image.built) or building.",
		{"type": "object", "properties": {}}, "containers")

	server._register_tool("minerva_agent_session_build",
		"Build the agent image from the recipes this Minerva ships. Returns at once; the first build can take a long while. Poll minerva_agent_session_list for image.built and building.",
		{"type": "object", "properties": {}}, "containers")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	var store: RefCounted = AgentSessionStore.shared()
	var name: String = str(arguments.get("name", "")).strip_edges()
	var result: Dictionary
	match tool_name:
		"minerva_agent_session_create":
			result = await store.create(name, str(arguments.get("harness", "")),
				_strings(arguments.get("folders", [])), str(arguments.get("start_in", "")).strip_edges(),
				_strings(arguments.get("projects", [])), str(arguments.get("mode", "")).strip_edges())
		"minerva_agent_session_start":
			result = await store.start(name, str(arguments.get("mode", "")).strip_edges())
		"minerva_agent_session_stop":
			result = await store.stop(name)
		"minerva_agent_session_status":
			result = await store.status(name)
		"minerva_agent_session_list":
			result = await store.list_sessions()
		"minerva_agent_session_build":
			if store.building:
				return MCPToolUtils.error("the agent image is already building")
			store.build()   # not awaited: the build outlives this call
			return {"success": true, "building": true}
		_:
			return MCPToolUtils.error("Unknown tool: %s" % tool_name)
	if not bool(result.get("ok", false)):
		return MCPToolUtils.error(str(result.get("error", "the launcher failed")))
	result.erase("message")
	result["success"] = true
	return result


static func _strings(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array:
		for item: Variant in value:
			var text: String = str(item).strip_edges()
			if not text.is_empty():
				out.append(text)
	return out
