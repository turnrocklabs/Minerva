extends RefCounted
## Stable identities for harness sessions. A session (a harness in a host tab,
## or an agent-container session fronted by one) registers an identity and a
## free-form role; notify, triggers and the session list address it by those.
## Terminal ids and tab names are only where the identity is found right now.
##
## What is stored (user://harness_sessions.json) is the identity, its role, the
## harness it runs and, for a container session, the container session name.
## The terminal an identity is bound to is kept in memory only: terminal ids are
## per Minerva run. After a restart a host-tab session is unbound until it
## registers again from its new tab; a container session binds itself again as
## soon as a tab shows its container in front (bind_containers).
##
## One registry per Minerva process (shared()); tests build their own and point
## store_path somewhere else.
##
## identity_for_terminal() is the one lookup other code uses to learn which
## session a terminal holds; identity_for_container() answers the same for an
## agent-container session by name (AgentSessionStore.info uses both).

## Emitted after any registration, re-binding or forget.
signal changed()

const SCRIPT_PATH := "res://Scripts/Services/Terminal/HarnessSessionRegistry.gd"
const STORE_PATH := "user://harness_sessions.json"
const STORE_VERSION := 1

## Liveness of a registered session, read from the terminal listing:
##   live          — bound to a running terminal whose foreground is its harness
##   other_harness — the terminal now runs a different harness
##   no_harness    — the terminal has a shell or another program in front
##   unknown       — the terminal's foreground cannot be read just now
##   exited        — the terminal's shell has exited
##   unbound       — no terminal holds this session in this Minerva run
const LIVE := "live"
const OTHER_HARNESS := "other_harness"
const NO_HARNESS := "no_harness"
const UNKNOWN := "unknown"
const EXITED := "exited"
const UNBOUND := "unbound"

const MAX_FIELD_LENGTH := 64

static var _shared = null

var store_path: String = STORE_PATH

## identity key (lower case) -> {identity, role, harness, container, name,
## registered_at}. `name` is the tab name at registration, for display only.
var _records: Dictionary = {}
## identity key -> terminal id it is bound to in this run.
var _bound: Dictionary = {}


static func shared():
	if _shared == null:
		_shared = load(SCRIPT_PATH).new()
		_shared.load_store()
	return _shared


# ── Lookups ────────────────────────────────────────────────────────────

## The registered identity of the session in `terminal_id`, or "" when none is.
## A terminal fronting a registered container session is bound on the way.
func identity_for_terminal(terminal_id: String) -> String:
	if terminal_id.is_empty():
		return ""
	for key: String in _bound:
		if str(_bound[key]) == terminal_id:
			return str(_records[key]["identity"])
	var container: String = _container_in(terminal_id)
	var key: String = _key_for_container(container)
	if key.is_empty():
		return ""
	_bind(key, terminal_id)
	return identity_for_container(container)


## The registered identity of agent-container session `container`, or "" when
## none is registered. identity_for_terminal answers with this same record for
## a terminal fronting that container.
func identity_for_container(container: String) -> String:
	var key: String = _key_for_container(container)
	return str(_records[key]["identity"]) if not key.is_empty() else ""


## Every registered agent-container session: container session name ->
## {"identity", "role"}. AgentSessionStore copies these into each session's
## grant record, where the container gateway scopes its Docket access by them.
func container_identities() -> Dictionary:
	var out: Dictionary = {}
	for key: String in _records:
		var container: String = str(_records[key]["container"])
		if not container.is_empty():
			out[container] = {"identity": str(_records[key]["identity"]), "role": str(_records[key]["role"])}
	return out


## The terminal id `identity` is bound to in this run, or "".
func terminal_of(identity: String) -> String:
	return str(_bound.get(identity.strip_edges().to_lower(), ""))


func is_registered(identity: String) -> bool:
	return _records.has(identity.strip_edges().to_lower())


## The identities a Docket `assigned_to` or `directed_to` value names: the
## session whose identity is exactly `principal`, and every session whose role
## is exactly it. Exact, as the container gateway scopes Docket access
## (gateway/docket_scope.py is_direct), so a woken session can read what woke it.
func identities_addressed_by(principal: String) -> PackedStringArray:
	var out := PackedStringArray()
	principal = principal.strip_edges()
	if principal.is_empty():
		return out
	for key: String in _records:
		var record: Dictionary = _records[key]
		if str(record["identity"]) == principal or str(record["role"]) == principal:
			out.append(str(record["identity"]))
	return out


## Every registered session, described against `listing` (minerva_terminal_list
## entries): identity, role, harness, container, terminal_id, name, liveness.
func sessions(listing: Array) -> Array[Dictionary]:
	bind_containers(listing)
	var keys: Array = _records.keys()
	keys.sort()
	var out: Array[Dictionary] = []
	for key: String in keys:
		out.append(_describe(key, listing))
	return out


## Which terminal `to` names when it is a registered identity or a role:
##   {}                                   — neither; the caller tries other addresses
##   {terminal_id, identity, role}        — exactly one live session
##   {error, code}                        — an identity that is not bound, or a
##                                          role with no live session or several
## An identity outranks a role of the same spelling.
func resolve(to: String, listing: Array) -> Dictionary:
	bind_containers(listing)
	var needle: String = to.strip_edges().to_lower()
	if needle.is_empty():
		return {}
	if _records.has(needle):
		var described: Dictionary = _describe(needle, listing)
		if str(described["liveness"]) == UNBOUND:
			return {"code": "session_unbound",
				"error": "Session '%s' is registered but no terminal holds it in this Minerva run; it registers again from its tab (minerva_session_register) or its container is attached" % described["identity"]}
		return {"terminal_id": str(described["terminal_id"]),
			"identity": str(described["identity"]), "role": str(described["role"])}
	var members: Array[Dictionary] = []
	for key: String in _records:
		if str(_records[key]["role"]).to_lower() == needle:
			members.append(_describe(key, listing))
	if members.is_empty():
		return {}
	var live: Array[Dictionary] = []
	var seen := PackedStringArray()
	for member: Dictionary in members:
		seen.append("%s (%s)" % [member["identity"], member["liveness"]])
		if str(member["liveness"]) == LIVE:
			live.append(member)
	if live.is_empty():
		return {"code": "role_unavailable",
			"error": "No live session holds role '%s'. Sessions with that role: %s" % [to, ", ".join(seen)]}
	if live.size() > 1:
		return {"code": "role_ambiguous",
			"error": "Role '%s' is held by %d live sessions: %s. Address one by its identity." % [to, live.size(), ", ".join(seen)]}
	return {"terminal_id": str(live[0]["terminal_id"]),
		"identity": str(live[0]["identity"]), "role": str(live[0]["role"])}


# ── Registration ───────────────────────────────────────────────────────

## Register (or re-register) a session. Either `terminal_id` names the tab it is
## in now — the harness and any container are read from its `listing` entry —
## or, for a container session not in front anywhere, `container` names it.
## An empty identity gets a generated one; the reply carries it. Registering
## binds the identity here and unbinds any other identity this terminal or
## container held. Returns {success, session, rebound_from?, displaced?} or
## {success:false, error}.
func register(identity: String, role: String, terminal_id: String, container: String,
		harness: String, listing: Array) -> Dictionary:
	identity = identity.strip_edges()
	role = role.strip_edges()
	terminal_id = terminal_id.strip_edges()
	container = container.strip_edges()
	harness = harness.strip_edges().to_lower()
	var entry: Dictionary = {}
	if not terminal_id.is_empty():
		entry = _entry(listing, terminal_id)
		if entry.is_empty():
			return _error("No terminal '%s' is open; pass your own $MINERVA_TERMINAL_ID" % terminal_id)
		if harness.is_empty():
			harness = str(entry.get("harness", ""))
		if container.is_empty():
			container = str(entry.get("container", ""))
	elif container.is_empty():
		return _error("terminal_id or container is required: the tab this session is in, or the agent-container session it runs as")
	if identity.is_empty():
		identity = _generated_identity(harness)
	var invalid: String = _validate("identity", identity)
	if invalid.is_empty() and not role.is_empty():
		invalid = _validate("role", role)
	if invalid.is_empty() and identity.is_valid_int():
		invalid = "identity must not be a number: numbers are terminal ids"
	if not invalid.is_empty():
		return _error(invalid)

	var key: String = identity.to_lower()
	var displaced := PackedStringArray()
	for other: String in _records.keys():
		if other == key:
			continue
		var same_terminal: bool = not terminal_id.is_empty() and str(_bound.get(other, "")) == terminal_id
		var same_container: bool = not container.is_empty() and str(_records[other]["container"]) == container
		if same_terminal or same_container:
			_bound.erase(other)
			if same_container:
				_records[other]["container"] = ""
			displaced.append(str(_records[other]["identity"]))
	var previous: String = str(_bound.get(key, ""))
	var existing: Dictionary = _records.get(key, {})
	_records[key] = {
		"identity": identity,
		"role": role,
		"harness": harness,
		"container": container,
		"name": str(entry.get("name", existing.get("name", ""))),
		"registered_at": int(existing.get("registered_at", int(Time.get_unix_time_from_system()))),
	}
	if not terminal_id.is_empty():
		_bound[key] = terminal_id
	else:
		_bound.erase(key)
		bind_containers(listing)
	save_store()
	changed.emit()
	var reply: Dictionary = {"success": true, "session": _describe(key, listing)}
	if not previous.is_empty() and previous != str(_bound.get(key, "")):
		reply["rebound_from"] = previous
	if not displaced.is_empty():
		reply["displaced"] = Array(displaced)
	return reply


## Forget a registration. Returns whether one existed.
func forget(identity: String) -> bool:
	var key: String = identity.strip_edges().to_lower()
	if not _records.has(key):
		return false
	_records.erase(key)
	_bound.erase(key)
	save_store()
	changed.emit()
	return true


## Bind every registered container session to the listing entry that shows its
## container in front, so a container keeps its identity across tab changes
## and Minerva restarts without registering again.
func bind_containers(listing: Array) -> void:
	var moved: bool = false
	for entry: Dictionary in listing:
		var key: String = _key_for_container(str(entry.get("container", "")))
		var tid: String = str(entry.get("id", ""))
		if not key.is_empty() and str(_bound.get(key, "")) != tid:
			_bound[key] = tid
			moved = true
	if moved:
		changed.emit()


# ── Store ──────────────────────────────────────────────────────────────

func load_store() -> void:
	_records.clear()
	_bound.clear()
	if not FileAccess.file_exists(store_path):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(store_path))
	if not (parsed is Dictionary) or not (parsed.get("sessions") is Array):
		push_warning("HarnessSessionRegistry: %s is not a session store; starting empty" % store_path)
		return
	for raw in parsed["sessions"]:
		if not (raw is Dictionary):
			continue
		var identity: String = str(raw.get("identity", ""))
		if not _validate("identity", identity).is_empty():
			continue
		_records[identity.to_lower()] = {
			"identity": identity,
			"role": str(raw.get("role", "")),
			"harness": str(raw.get("harness", "")),
			"container": str(raw.get("container", "")),
			"name": str(raw.get("name", "")),
			"registered_at": int(raw.get("registered_at", 0)),
		}


func save_store() -> void:
	var rows: Array = []
	for key: String in _records:
		rows.append(_records[key])
	var file := FileAccess.open(store_path, FileAccess.WRITE)
	if file == null:
		push_warning("HarnessSessionRegistry: cannot write %s (%s)" % [store_path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(JSON.stringify({"version": STORE_VERSION, "sessions": rows}, "\t"))
	file.close()


# ── Internals ──────────────────────────────────────────────────────────

func _describe(key: String, listing: Array) -> Dictionary:
	var record: Dictionary = _records[key]
	var tid: String = str(_bound.get(key, ""))
	var entry: Dictionary = _entry(listing, tid) if not tid.is_empty() else {}
	if not tid.is_empty() and entry.is_empty():
		# The terminal closed: the session is no longer anywhere.
		_bound.erase(key)
		tid = ""
	var described: Dictionary = {
		"identity": str(record["identity"]),
		"role": str(record["role"]),
		"harness": str(record["harness"]),
		"terminal_id": tid,
		"name": str(entry.get("name", "")),
		"liveness": _liveness(record, entry),
		"registered_at": int(record["registered_at"]),
	}
	if not str(record["container"]).is_empty():
		described["container"] = str(record["container"])
	return described


func _liveness(record: Dictionary, entry: Dictionary) -> String:
	if entry.is_empty():
		return UNBOUND
	if not bool(entry.get("alive", true)):
		return EXITED
	if not entry.has("foreground_process"):
		return UNKNOWN
	var running: String = str(entry.get("harness", ""))
	if running.is_empty():
		return UNKNOWN if str(entry["foreground_process"]).is_empty() else NO_HARNESS
	var expected: String = str(record["harness"])
	if not expected.is_empty() and running != expected:
		return OTHER_HARNESS
	return LIVE


func _bind(key: String, terminal_id: String) -> void:
	_bound[key] = terminal_id
	changed.emit()


func _key_for_container(container: String) -> String:
	if container.is_empty():
		return ""
	for key: String in _records:
		if str(_records[key]["container"]) == container:
			return key
	return ""


## Some record that names a container, or "" when none does (then no
## foreground needs reading).
func _key_for_any_container() -> String:
	for key: String in _records:
		if not str(_records[key]["container"]).is_empty():
			return key
	return ""


## The container session shown in front of `terminal_id`, read from the live
## terminal session; "" when there is none or it cannot be read.
func _container_in(terminal_id: String) -> String:
	if _key_for_any_container().is_empty():
		return ""
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return ""
	var so: Node = tree.root.get_node_or_null("SingletonObject")
	if so == null or not so.has_method("get_terminal_session_registry"):
		return ""
	var registry = so.get_terminal_session_registry()
	var session = registry.get_session(terminal_id) if registry != null else null
	if session == null or not session.foreground_supported():
		return ""
	return str(session.get_foreground_process().get("container", ""))


static func _entry(listing: Array, terminal_id: String) -> Dictionary:
	for entry: Dictionary in listing:
		if str(entry.get("id", "")) == terminal_id:
			return entry
	return {}


## Identities and roles are addresses typed by people and agents and written
## into the notify envelope: letters, digits and . _ : - only.
static func _validate(field: String, value: String) -> String:
	if value.is_empty():
		return "%s is empty" % field
	if value.length() > MAX_FIELD_LENGTH:
		return "%s is %d characters; the cap is %d" % [field, value.length(), MAX_FIELD_LENGTH]
	for i: int in range(value.length()):
		var c: String = value[i]
		if not (c.is_valid_identifier() or c.is_valid_int() or c in [".", "-", ":"]):
			return "%s '%s' may hold only letters, digits and . _ : -" % [field, value]
	return ""


static func _generated_identity(harness: String) -> String:
	return "%s-%06x" % [harness if not harness.is_empty() else "session", randi() % 0x1000000]


static func _error(message: String) -> Dictionary:
	return {"success": false, "error": message}
