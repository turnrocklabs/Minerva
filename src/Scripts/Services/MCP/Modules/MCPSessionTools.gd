extends MCPToolModule
## MCP tools for harness session identity: a session registers a stable
## identity and a role, which minerva_terminal_notify then accepts as its `to`.
## The registry itself is HarnessSessionRegistry; the terminal listing it is
## judged against is minerva_terminal_list's. minerva_terminal_list reports
## every registered session with its liveness. minerva_session_handover moves
## a role to a replacement session (SessionHandover).

const HarnessSessionRegistry := preload("res://Scripts/Services/Terminal/HarnessSessionRegistry.gd")
const SessionHandover := preload("res://Scripts/Services/Terminal/SessionHandover.gd")
const TERMINAL_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"


func get_tool_names() -> Array[String]:
	return ["minerva_session_register", "minerva_session_forget", "minerva_session_handover"]


func register_tools() -> void:
	server._register_tool("minerva_session_register",
		"Register this harness session under a stable identity and a role, so other sessions can notify it by identity or role (minerva_terminal_notify `to`) instead of a terminal id or tab name, which change on restart or rename. Call it again with the same identity after Minerva restarts or from a new tab: the identity moves to that terminal. A container session registered once (container, or its tab while the container is in front) re-binds by itself whenever a tab fronts that container. Registering takes over the terminal: any other identity bound to it is unbound (listed in `displaced`). minerva_terminal_list shows every registered session with its liveness. Identity and role are declared, not verified.",
		{"type": "object", "properties": {
			"identity": {"type": "string", "description": "The stable name to register under (letters, digits, . _ : -; not a bare number). Omit to have one generated; the reply carries it, so keep it."},
			"role": {"type": "string", "description": "Free-form role, e.g. coordinator, worker, reviewer. A notify addressed to a role goes to the one live session holding it."},
			"terminal_id": {"type": "string", "description": "The terminal this session is in now: your $MINERVA_TERMINAL_ID. Required unless container is given."},
			"container": {"type": "string", "description": "Agent-container session name, to register a container session that no tab fronts right now."},
			"harness": {"type": "string", "description": "claude or codex. Omit to use the harness in the terminal's foreground."},
		}}, "terminal")

	server._register_tool("minerva_session_forget",
		"Remove a session registration made by minerva_session_register. The terminal and its harness are untouched.",
		{"type": "object", "properties": {
			"identity": {"type": "string", "description": "The registered identity."},
		}, "required": ["identity"]}, "terminal")

	server._register_tool("minerva_session_handover",
		"Hand a role over to a replacement session, e.g. when the coordinator died and a new one registered. to_identity (registered first with minerva_session_register) takes the role; every other session holding it is marked superseded: nothing is dispatched to it any more, a notify addressed to its identity goes to to_identity, and it keeps no role even if it registers again. Notifications kept for the old identities or the role are re-targeted to to_identity and tried at once (`pointers`). W1 claims the old identities hold on Docket items assigned to the role or to them are moved to to_identity with docket_reassign, reason 'handover', recorded in each item's event log; the old holder's next protected write is then refused by Docket (`claims`: reassigned, failed, checked, and error when Docket is unavailable — the role moves regardless). Declared, not verified.",
		{"type": "object", "properties": {
			"role": {"type": "string", "description": "The role to hand over, e.g. coordinator."},
			"to_identity": {"type": "string", "description": "The registered identity of the replacement session."},
			"actor": {"type": "string", "description": "Who is handing over (your identity), recorded as the actor of each claim move. Default minerva:handover."},
		}, "required": ["role", "to_identity"]}, "terminal")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_session_register": return _register(arguments)
		"minerva_session_forget": return _forget(arguments)
		"minerva_session_handover": return await SessionHandover.run(str(arguments.get("role", "")),
			str(arguments.get("to_identity", "")), str(arguments.get("actor", "")))
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


func _register(arguments: Dictionary) -> Dictionary:
	var listing: Array = load(TERMINAL_TOOLS_PATH).new(null).list_terminals()
	return HarnessSessionRegistry.shared().register(
		str(arguments.get("identity", "")), str(arguments.get("role", "")),
		str(arguments.get("terminal_id", "")), str(arguments.get("container", "")),
		str(arguments.get("harness", "")), listing)


func _forget(arguments: Dictionary) -> Dictionary:
	var identity: String = str(arguments.get("identity", "")).strip_edges()
	if identity.is_empty():
		return MCPToolUtils.error("identity is required")
	if not HarnessSessionRegistry.shared().forget(identity):
		return MCPToolUtils.error("No session '%s' is registered" % identity)
	return {"success": true, "forgotten": identity}
