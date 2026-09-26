class_name TriggerDestination
extends RefCounted
## An existing harness session a trigger delivers to instead of an internal
## agent, named so it can never silently bind to a different session:
##   CHAT      a passthrough chat, by its HistoryId. The id is saved with the
##             project and follows the chat to whatever terminal it is bound to
##             now, including the one it relaunched after a restart.
##   TERMINAL  a terminal with no chat, by its terminal id AND this Minerva run
##             AND the harness process it was picked with. Terminal ids only
##             mean something within one run, so after a restart it is
##             unresolved; a harness that exits and is started again there is
##             another session, so it is refused until someone picks it again.

enum Kind { CHAT, TERMINAL }

# Loaded where used, not named: TriggerDefinition holds a TriggerDestination,
# and scripts compiled before the SingletonObject autoload (test harnesses)
# must not pull in these, which refer to it.
const TERMINAL_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"
const NOTIFY_DELIVERY_PATH := "res://Scripts/Services/MCP/Modules/MCPNotifyDelivery.gd"
const TOOL_UTILS_PATH := "res://Scripts/Services/MCP/Modules/MCPToolUtils.gd"

## The MCPTerminalTools that terminal_tools() hands out instead of a fresh
## one; tests set one whose terminal listing is scripted.
static var address_tools: RefCounted = null

## This Minerva run, distinct from every earlier one (tests may stand in a
## later run).
static var current_run := "%d-%d" % [int(Time.get_unix_time_from_system() * 1000.0), randi()]

var kind: Kind = Kind.CHAT
var chat_id: String = ""
var terminal_id: String = ""
var run_id: String = ""
## The harness that was in the foreground when it was picked; a TERMINAL
## destination delivers only while that harness is still there.
var harness: String = ""
## The TERMINAL harness's foreground process group when picked (always known:
## a terminal whose process group cannot be read is not accepted).
var process: int = 0
## What was picked, e.g. "codex@Terminal 3", for display and receipts only.
var label: String = ""


func serialize() -> Dictionary:
	return {"kind": "chat" if kind == Kind.CHAT else "terminal", "chat_id": chat_id,
		"terminal_id": terminal_id, "run_id": run_id, "harness": harness, "process": process, "label": label}


## A destination from its saved form, or null when `data` names none.
static func deserialize(data) -> TriggerDestination:
	if not (data is Dictionary) or data.is_empty():
		return null
	var dest := TriggerDestination.new()
	dest.kind = Kind.TERMINAL if str(data.get("kind", "")) == "terminal" else Kind.CHAT
	dest.chat_id = str(data.get("chat_id", ""))
	dest.terminal_id = str(data.get("terminal_id", ""))
	dest.run_id = str(data.get("run_id", ""))
	dest.harness = str(data.get("harness", ""))
	dest.process = int(data.get("process", 0))
	dest.label = str(data.get("label", ""))
	return dest


## The terminal this destination's identity names now: {terminal_id} or
## {error} saying why there is none. Whether the session there is the
## expected one is availability() (and, at the write, notify).
func resolve() -> Dictionary:
	if kind == Kind.TERMINAL:
		if run_id != current_run:
			return {"error": "'%s' was a terminal of an earlier Minerva run; pick the session again" % label}
		if process <= 0:
			return {"error": "the harness process of '%s' was never identified; pick the session again" % label}
		return {"terminal_id": terminal_id}
	var history = load(TOOL_UTILS_PATH).find_chat_by_id(chat_id)
	if history == null:
		return {"error": "the chat '%s' is not open" % label}
	var bound: String = terminal_of(history)
	if bound.is_empty():
		return {"error": "the chat '%s' is not bound to a terminal" % label}
	return {"terminal_id": bound}


## What a delivery must find at the terminal (MCPTerminalTools.notify's
## `expect`): this chat bound there, or this harness process in front.
func expectation() -> Dictionary:
	if kind == Kind.CHAT:
		return {"chat_id": chat_id}
	return {"harness": harness, "process": process}


## Whether this destination can be delivered to now, judged from `listing`
## (MCPTerminalTools.list_terminals): {ok: true} or {ok: false, reason}. The
## identity may still bind (resolve) while the session is gone or replaced.
func availability(listing: Array) -> Dictionary:
	var resolved: Dictionary = resolve()
	if resolved.has("error"):
		return {"ok": false, "reason": str(resolved.error)}
	var entry: Dictionary = {}
	for candidate: Dictionary in listing:
		if str(candidate.get("id", "")) == str(resolved.terminal_id):
			entry = candidate
	if entry.is_empty():
		return {"ok": false, "reason": "the terminal of '%s' is gone" % label}
	if not entry.get("alive", true):
		return {"ok": false, "reason": "the terminal of '%s' has exited" % label}
	var now: String = str(entry.get("harness", ""))
	if kind == Kind.CHAT:
		return {"ok": true} if not now.is_empty() else {"ok": false, "reason": "no harness runs in the terminal of '%s'" % label}
	if int(entry.get("foreground_pid", 0)) <= 0:
		return {"ok": false, "reason": "the harness process of '%s' cannot be identified just now" % label}
	var broken: String = load(NOTIFY_DELIVERY_PATH)._expectation_broken(expectation(), now,
		int(entry.get("foreground_pid", 0)), str(entry.get("name", "")))
	return {"ok": true} if broken.is_empty() else {"ok": false, "reason": broken}


## The terminal a passthrough chat is bound to, or "" when none: the binding
## is the chat provider's entry id, "terminal-<id>".
static func terminal_of(history) -> String:
	var provider = history.provider if history != null else null
	var prefix: String = load(TERMINAL_TOOLS_PATH).PASSTHROUGH_ENTRY_PREFIX
	var entry_id: String = str(provider.get("entry_id")) if provider != null and "entry_id" in provider else ""
	if entry_id.begins_with(prefix):
		return entry_id.trim_prefix(prefix)
	return ""


## The terminal tools that list and resolve sessions for choosing one.
static func terminal_tools() -> RefCounted:
	return address_tools if address_tools != null else load(TERMINAL_TOOLS_PATH).new(null)


## A destination from an address as minerva_terminal_notify takes it (terminal
## id, tab name, harness@tab name or harness), resolved now to exactly one
## terminal with a harness: {destination} or {error}. The session's chat is
## preferred when it has one, because the chat outlives a restart.
static func from_address(address: String) -> Dictionary:
	var target: Dictionary = await terminal_tools().resolve_address(address)
	if not target.get("success", false):
		return {"error": str(target.get("error", "no such terminal"))}
	var target_harness: String = str(target.get("harness", ""))
	if target_harness.is_empty():
		return {"error": "'%s' has no agent harness in the foreground; a trigger can only deliver to one" % address}
	var dest := TriggerDestination.new()
	dest.harness = target_harness
	dest.label = "%s@%s" % [target_harness, str(target.get("name", ""))]
	var target_chat_id: String = str(target.get("chat_id", ""))
	if target_chat_id.is_empty():
		# Without its process group a restarted harness could not be told
		# from this one, so such a session cannot be named this way.
		if int(target.get("foreground_pid", 0)) <= 0:
			return {"error": "the harness process in '%s' cannot be identified here, so a restarted session could not be told apart; pick a session with a passthrough chat" % str(target.get("name", address))}
		dest.kind = Kind.TERMINAL
		dest.terminal_id = str(target["terminal_id"])
		dest.run_id = current_run
		dest.process = int(target.get("foreground_pid", 0))
	else:
		dest.chat_id = target_chat_id
	return {"destination": dest}
