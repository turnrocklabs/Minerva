extends MCPToolModule
## MCP verbs for agent-container sessions: create, start, stop, status, info,
## readiness, list, build, grant/revoke (note and notify grants, changed
## live) and attach (front a session in a terminal tab). Each is the MCP twin
## of a control in Preferences > Containers > Agent Sessions or of the
## terminal tab menu's "Attach agent session here"; all drive
## AgentSessionStore, which runs the launcher Minerva ships.

const AgentSessionStore := preload("res://Scripts/Services/AgentSessions/AgentSessionStore.gd")

## A person typing in the target tab this recently holds an MCP attach, so
## the command never lands in the middle of their line.
const ATTACH_TYPED_WINDOW_MS := 3000

const _NAME := {"type": "string", "description": "Session name: 1-32 lowercase letters, digits and -."}


func get_tool_names() -> Array[String]:
	return ["minerva_agent_session_create", "minerva_agent_session_start",
		"minerva_agent_session_stop", "minerva_agent_session_status",
		"minerva_agent_session_info", "minerva_agent_session_readiness",
		"minerva_agent_session_list", "minerva_agent_session_build",
		"minerva_agent_session_grant", "minerva_agent_session_revoke",
		"minerva_agent_session_attach"]


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

	server._register_tool("minerva_agent_session_attach",
		"Front a running agent-container session in a Minerva terminal tab (the MCP twin of the tab menu's 'Attach agent session here'). Minerva writes the attach command into that tab, which must be at a shell prompt, and the launcher there holds the session's lease and its one tmux client. The newest attach wins: if another tab fronts the session now, this takes it over; that tab's tmux client is detached, it says the session is now attached from another tab and returns to its shell, and notify replies follow the new tab. A takeover that fails leaves the old tab fronting. Refused with a reason when the session is not running, the tab is running anything but a shell (a harness, another session), or a person typed in it within the last 3 s. The session outlives Minerva: after a restart, attach it from any fresh tab and its harness is on screen as it was; grants need no re-binding. Returns {id, terminal_id, took_over_from} (took_over_from is the terminal that held it, or empty), or already_attached when the tab already fronts it.",
		{"type": "object", "properties": {
			"name": _NAME,
			"terminal": {"type": "string", "description": "The tab to attach in: a terminal id or a tab name (minerva_terminal_list)."},
		}, "required": ["name", "terminal"]}, "containers")

	server._register_tool("minerva_agent_session_status",
		"One agent-container session: harness, folders (host path, path in the container, clone or mount), start folder, Docket projects, mode, state (running, stopped, unknown), the attached terminal, and attach_command.",
		{"type": "object", "properties": {"name": _NAME}, "required": ["name"]}, "containers")

	server._register_tool("minerva_agent_session_info",
		"Inspect one agent-container session without changing it: everything status returns, plus session_identity (the identity registered for it in the harness session registry, the one notify routes by; with the attached terminal's answer and whether they agree), path_mappings (host folder, the path the harness sees, what is mounted; the session home is /agent-home), git_identity (the author git reports in the start folder, measured in the running container) and toolchain_profile. map_paths answers host paths with the container path the harness sees (null when no session folder holds one).",
		{"type": "object", "properties": {
			"name": _NAME,
			"map_paths": {"type": "array", "items": {"type": "string"}, "description": "Host paths to translate into container paths."},
		}, "required": ["name"]}, "containers")

	server._register_tool("minerva_agent_session_readiness",
		"Read-only readiness check of an agent-container session: the toolchain profile's tools and minimum versions, the folders and the Git author identity, measured inside the running container with docker exec; its Docket projects against the Docket service; and a registered session identity. Returns ready, checks [{check, name, ok, detail}] and missing. Starts no application, test suite or container; a stopped session reports only what can be checked from the host.",
		{"type": "object", "properties": {
			"name": _NAME,
			"profile": {"type": "string", "description": "Toolchain profile to check against (profiles.json in the agent kit). Default: default."},
		}, "required": ["name"]}, "containers")

	server._register_tool("minerva_agent_session_list",
		"Every agent-container session record with its live state, plus whether the agent image is built (image.built) or building.",
		{"type": "object", "properties": {}}, "containers")

	server._register_tool("minerva_agent_session_build",
		"Build the agent image from the recipes this Minerva ships. Returns at once; the first build can take a long while. Poll minerva_agent_session_list for image.built and building.",
		{"type": "object", "properties": {}}, "containers")

	var grant_properties: Dictionary = {
		"name": _NAME,
		"note_read": {"type": "array", "items": {"type": "string"}, "description": "Minerva note ids (minerva_list_notes note_id) the session may read."},
		"note_write": {"type": "array", "items": {"type": "string"}, "description": "Minerva note ids the session may write and append to; write implies read."},
		"notify": {"type": "boolean", "description": "true names the notify grant (to grant or revoke): the session may notify any Minerva tab with a harness in front except its own; there is no per-target list. false or omitted leaves it as it is."},
	}
	server._register_tool("minerva_agent_session_grant",
		"Grant an agent-container session access, running or not: notes it may read, notes it may write, and/or the notify grant. The session's gateway reads its grants on every call, so its next call can use them; no re-attach. Returns the session's grants {note_read, note_write, notify}; status, info and list show them too.",
		{"type": "object", "properties": grant_properties, "required": ["name"]}, "containers")

	server._register_tool("minerva_agent_session_revoke",
		"Revoke an agent-container session's grants, running or not: a note_read entry, a note_write entry (the next write to that note is refused, naming the grant it needs) and/or the notify grant. A note still in the other list keeps that access. Applies to the session's next call. Returns the session's grants.",
		{"type": "object", "properties": grant_properties, "required": ["name"]}, "containers")


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
		"minerva_agent_session_info":
			result = await store.info(name, _strings(arguments.get("map_paths", [])))
		"minerva_agent_session_readiness":
			result = await store.readiness(name, str(arguments.get("profile", "")).strip_edges())
		"minerva_agent_session_list":
			result = await store.list_sessions()
		"minerva_agent_session_attach":
			var terminal: TerminalSession = _terminal(str(arguments.get("terminal", "")).strip_edges())
			if terminal == null:
				return MCPToolUtils.error("no terminal has the id or tab name '%s' (minerva_terminal_list)"
					% str(arguments.get("terminal", "")))
			result = await store.attach(name, terminal, ATTACH_TYPED_WINDOW_MS)
		"minerva_agent_session_grant", "minerva_agent_session_revoke":
			var note_read: PackedStringArray = _strings(arguments.get("note_read", []))
			var note_write: PackedStringArray = _strings(arguments.get("note_write", []))
			var notify: bool = arguments.get("notify", false) == true
			if tool_name == "minerva_agent_session_grant":
				result = await store.grant(name, note_read, note_write, notify)
			else:
				result = await store.revoke(name, note_read, note_write, notify)
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


## The terminal session with this id, else the one tab with this name; null
## when none or several tabs carry the name.
static func _terminal(address: String) -> TerminalSession:
	var registry = SingletonObject.get_terminal_session_registry()
	if registry == null or address.is_empty():
		return null
	if registry.has_session(address):
		return registry.get_session(address) as TerminalSession
	var found: Array[TerminalSession] = []
	for session: Variant in registry.list_sessions():
		if session is TerminalSession and (session as TerminalSession).session_name == address:
			found.append(session as TerminalSession)
	return found[0] if found.size() == 1 else null


static func _strings(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array:
		for item: Variant in value:
			var text: String = str(item).strip_edges()
			if not text.is_empty():
				out.append(text)
	return out
