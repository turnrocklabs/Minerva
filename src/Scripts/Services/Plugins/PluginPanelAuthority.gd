class_name PluginPanelAuthority
extends RefCounted
## The host's side of a backend's private panel channel, for one running
## plugin whose manifest declares it (PluginDefinition.PANEL_AUTHORITY_V1):
## the panel's person-made edits, and the panel's own tool calls, reach the
## backend here as that panel's, apart from the tools/call agents use.
##
## Each process the plugin runs gets a fresh secret in its own environment
## (env_for_generation, through SubProcess.start_with_env); with it this
## host opens a session per live panel registration and registers grants,
## each naming the person (the OS account this host runs as, never anything
## the panel says), the one item the panel has shown and what may be done to
## it (saved, moved to another status, given a file), or, to create one new
## item, a type and no item.
##
## A panel saves only the item it is bound to, in the project of the file
## the host attached it to: it binds an item when it shows it (select_item);
## this host asks the backend which open project that file is (its name and
## the opening, open_generation) and whether the item is one of it (its
## canonical id), and numbers the binding (its epoch). A save names that
## epoch, and the host fills in the bound project and item itself, refusing
## any other; a move to another status (transition_item) and a file
## attached to it (attach_file, its bytes as base64) go the same way.
## A new item (create_item) is made only in the attached file's project,
## under a grant registered for it alone, which the backend ends once it has
## made the item; the backend chooses its id, and the panel then shows and
## binds it like any other. Showing another item, or none, ends the binding
## and revokes its grant, as does the host giving the panel a file (another,
## or the same path again: the attachment revision it counts them by); a
## grant is only registered while the file is still that same opening of
## the project, which the backend checks again as it registers
## (open_generation).
##
## Only the broker's private branch calls handle(), with the panel key and
## registration generation it made, and the panel's attachment; a
## registration's operations end with it (the panel closed, or the key
## registered again), and a new process forgets everything the old one was
## given. Every request checks before it goes and once it is answered,
## failed or not, that its registration, selection, binding, attachment
## (read afresh from the host) and process are still current, so a late
## answer is refused (a save already sent is not undone, only not reported
## as the current item's; a late grant is revoked) and nothing is kept for
## it; a panel found with another attachment loses its binding and grant.
## The secret, sessions and grants never leave this object; the host's own
## methods of the channel go through host_request, which adds the secret.

## What a panel may ask: its tool calls (method_prefix + "call"), binding the
## item it shows, a save of that item, a move to another status or a file
## attached to it (the backend's method_prefix + "update_item" /
## "transition_item" / "attach_file"), and a new item (method_prefix +
## "create_item").
const ACTIONS := ["call", "select_item", "update_item", "transition_item", "attach_file", "create_item"]
## What a bound item's grant allows.
const ITEM_ACTIONS := ["update_item", "transition_item", "attach_file"]
## Argument names only the host puts on the channel; a panel may not send them.
const HOST_ARGUMENTS := ["panel_secret", "panel_grant", "panel_session", "panel", "person", "actions"]
## A grant is registered again this long (ms) before it expires.
const GRANT_MARGIN_MS := 60 * 1000
## The backend's error code for a grant (or secret) it will not honour.
const GRANT_REFUSED := -32001

## One live panel registration and what the backend gave it.
class _Panel extends RefCounted:
	var key := ""
	var generation := 0
	var session := ""
	## The bound item: {project, item (its full id), epoch, attached (the
	## attachment), open_generation (the project's opening)}, or {} for none.
	var binding: Dictionary = {}
	var epoch := 0
	## The binding's grant: {grant, expires_at, epoch}, or {}.
	var grant: Dictionary = {}

var plugin_id: String
## Awaited before a panel's tool call goes, with (tool, arguments): a
## non-empty String refuses it with that message (PluginManager's guard).
var tool_guard: Callable
## Called with (tool) once a panel's tool call has ended, answered or not
## (it may have changed something).
var tool_called: Callable
var _connection  # MCPServerConnection
var _prefix: String
var _secret_env: String
var _secret := ""
var _generation := -1
var _person := ""
# Panel key → its live registration (_Panel).
var _panels: Dictionary = {}


func _init(p_plugin_id: String, connection, config: Dictionary) -> void:
	plugin_id = p_plugin_id
	_connection = connection
	_prefix = str(config.method_prefix)
	_secret_env = str(config.secret_env)


## The environment entries for the plugin's process of `generation`: a new
## secret, which is all that process will accept from this host; whatever
## the previous one was given (sessions, bindings, grants) is forgotten.
func env_for_generation(generation: int) -> Dictionary:
	_secret = Crypto.new().generate_random_bytes(32).hex_encode()
	_generation = generation
	_panels.clear()
	return {_secret_env: _secret}


## The origin the backend gives a change made through panel `panel_key`'s
## session or grants (the panel name this host registers it by).
static func origin_of(panel_key: String) -> String:
	return "panel:%s" % panel_key


## The host's own method `name` of the channel (never a panel's), with
## `params` and the process's secret: {result}, or a refusal when it failed
## or the plugin's process changed before it was answered.
func host_request(name: String, params: Dictionary) -> Dictionary:
	for argument in HOST_ARGUMENTS:
		if params.has(argument):
			return _refusal("host_argument", "%s is added here" % argument)
	if not _is_current():
		return _refusal("backend_restarted", "the plugin's process is not running")
	var generation := _generation
	var sent := params.duplicate()
	sent["panel_secret"] = _secret
	var answered: Dictionary = await _connection.request_method(_prefix + name, sent)
	if generation != _generation or not _is_current():
		return _refusal("backend_restarted", "the plugin's process changed while the host waited")
	if answered.has("error"):
		return _refusal("backend_error", str(answered.error))
	return {"result": answered.get("result", {})}


## The broker registered panel `panel_key` as `generation`: a different
## registration of the key before it has ended.
func panel_opened(panel_key: String, generation: int) -> void:
	var known: _Panel = _panels.get(panel_key)
	if known != null and known.generation != generation:
		panel_closed(panel_key, known.generation)
	if not _panels.has(panel_key):
		var state := _Panel.new()
		state.key = panel_key
		state.generation = generation
		_panels[panel_key] = state


## Registration `generation` of panel `panel_key` ended: it can ask nothing
## more, and what the backend gave it (even what is still on its way) is
## revoked there. A later registration of the key is left alone.
func panel_closed(panel_key: String, generation: int) -> void:
	var known: _Panel = _panels.get(panel_key)
	if known == null or known.generation != generation:
		return
	_panels.erase(panel_key)
	if _is_current():
		_connection.request_method(_prefix + "revoke", {"panel_secret": _secret, "panel": panel_key})


## The host gave registration `generation` of panel `panel_key` a file (maybe
## the one it had): its binding and grant end now, and any step under way
## ends once it next looks.
func attachment_changed(panel_key: String, generation: int) -> void:
	var state: _Panel = _panels.get(panel_key)
	if state != null and state.generation == generation:
		_unbind(state)


## The attachment `attached_of` gives now: {file (simplified; "" for none),
## revision}, or a revision of -1 when there is no host to ask.
static func attachment_of(attached_of: Callable) -> Dictionary:
	var given = attached_of.call() if attached_of.is_valid() else null
	if not given is Dictionary:
		return {"file": "", "revision": -1}
	var file := str(given.get("file", ""))
	return {"file": file.simplify_path() if not file.is_empty() else "", "revision": int(given.get("revision", -1))}


## Action `action` with `params` for registration `generation` of panel
## `panel_key`; `attached_of` () -> Dictionary gives the panel's attachment
## whenever it is asked: {file (the file the host shows it for, "" for
## none), revision (the host's count of the files it was given)}. Returns
## {result} (the backend's), or {error_code, error_message}.
func handle(panel_key: String, generation: int, action: String, params: Dictionary,
		attached_of: Callable = Callable()) -> Dictionary:
	if not action in ACTIONS:
		return _refusal("unknown_action", "%s is not a panel action" % action)
	for name in HOST_ARGUMENTS:
		if params.has(name):
			return _refusal("host_argument", "%s is the host's to give" % name)
	var state: _Panel = _panels.get(panel_key)
	if state == null or state.generation != generation:
		return _refusal("panel_unloading", "the panel is closed")
	if not _is_current():
		return _refusal("backend_restarted", "the plugin's process has changed")
	var attached := attachment_of(attached_of)
	# A panel seen with another attachment than its binding's loses it.
	if not state.binding.is_empty() and attached != state.binding.attached:
		_unbind(state)
	match action:
		"call":
			var tool := str(params.get("name", ""))
			var arguments = params.get("arguments", {})
			if not arguments is Dictionary:
				return _refusal("invalid_request", "a tool's arguments are an object")
			if tool_guard.is_valid():
				var refused := str(await tool_guard.call(tool, arguments))
				if not refused.is_empty():
					return _refusal("refused_by_host", refused)
			var session := await _session_for(state)
			if session.has("error_code"):
				return session
			var answered := await _request(state, "call", {"panel_session": session.session,
				"name": tool, "arguments": arguments, "operation_id": str(params.get("operation_id", ""))})
			if tool_called.is_valid():
				tool_called.call(tool)
			return answered
		"select_item":
			return await _select(state, str(params.get("project", "")), str(params.get("id", "")),
				_Guard.new(state, attached, attached_of))
		"create_item":
			return await _create(state, params, _Guard.new(state, attached, attached_of))
	return await _update(state, action, params, attached, attached_of)


## What a step waits on still holding: the panel's attachment (its revision
## and file), the registration's selection (its epoch) and the binding it
## serves.
class _Guard extends RefCounted:
	var state: _Panel
	var epoch := -1
	var binding: Dictionary = {}
	var attached: Dictionary = {}
	var attached_of: Callable

	func _init(p_state, p_attached: Dictionary, p_attached_of: Callable) -> void:
		state = p_state
		epoch = p_state.epoch
		binding = p_state.binding
		attached = p_attached
		attached_of = p_attached_of

	## "" while it holds, else what changed: "file" or "item".
	func broken() -> String:
		if int(attached.revision) < 0 or PluginPanelAuthority.attachment_of(attached_of) != attached:
			return "file"
		if state.epoch != epoch or state.binding != binding:
			return "item"
		return ""


# Bind `item` of `project` (none when `item` is ""): the previous binding and
# its grant end first; the new one holds once the backend says `project` is
# the open project of the attached file and `item` one of its items, and
# nothing changed meanwhile.
func _select(state: _Panel, project: String, item: String, guard: _Guard) -> Dictionary:
	state.epoch += 1
	state.binding = {}
	_drop_grant(state)
	guard.epoch = state.epoch
	guard.binding = {}
	if item.is_empty():
		return {"result": {"binding": state.epoch}}
	if project.is_empty():
		return _refusal("invalid_request", "an item is bound with its project")
	var opening := await _opening_of(state, guard)
	if opening.has("error_code"):
		return opening
	if opening.project != project:
		return _refusal("wrong_project", "items are edited here only in %s, the file this panel shows" % opening.project)
	var looked := await _tool(state, "docket_item_view", {"project": project, "id": item}, guard)
	if looked.has("error_code"):
		return _refusal("not_an_item", "%s is not an item of %s" % [item, project]) if looked.error_code == "tool_error" else looked
	var canonical := str(looked.value.get("item", {}).get("id", "")) if looked.value.get("item") is Dictionary else ""
	if canonical.is_empty():
		return _refusal("not_an_item", "%s is not an item of %s" % [item, project])
	state.binding = {"project": project, "item": canonical, "epoch": guard.epoch, "attached": guard.attached,
		"open_generation": opening.open_generation}
	return {"result": {"binding": guard.epoch, "project": project, "id": canonical}}


# The open project of the guarded attached file, as the backend says:
# {project, open_generation} or a refusal.
func _opening_of(state: _Panel, guard: _Guard) -> Dictionary:
	if str(guard.attached.file).is_empty():
		return _refusal("not_attached", "this panel shows no file, so it edits nothing")
	var listed := await _tool(state, "docket_project_list", {}, guard)
	if listed.has("error_code"):
		return listed
	for project in listed.value.get("projects", []):
		if project is Dictionary and str(project.get("path", "")).simplify_path() == guard.attached.file:
			return {"project": str(project.get("name", "")), "open_generation": str(project.get("open_generation", ""))}
	return _refusal("not_open", "the file this panel shows is not open in the backend")


# Tool `name` through the registration's session, as the panel: {value} (the
# tool's result), or a refusal (error_code "tool_error" when the tool itself
# answered with an error).
func _tool(state: _Panel, name: String, arguments: Dictionary, guard: _Guard = null) -> Dictionary:
	var session := await _session_for(state, guard)
	if session.has("error_code"):
		return session
	var answered := await _request(state, "call", {"panel_session": session.session, "name": name,
		"arguments": arguments, "operation_id": ""}, guard)
	if answered.has("error_code"):
		return answered
	var result = answered.result
	if not result is Dictionary or bool(result.get("isError", false)):
		return _refusal("tool_error", "%s failed" % name)
	var content = result.get("content")
	var parsed = JSON.parse_string(str(content[0].get("text", ""))) \
		if content is Array and not content.is_empty() and content[0] is Dictionary else null
	return {"value": parsed} if parsed is Dictionary else _refusal("tool_error", "%s gave no result" % name)


# Method `method` (one of ITEM_ACTIONS) for the bound item, for the binding
# the panel names: the project and item are the binding's; a grant the
# backend no longer honours is registered anew, once. A panel with another
# attachment than the binding's loses the binding and its grant.
func _update(state: _Panel, method: String, params: Dictionary, attached: Dictionary, attached_of: Callable) -> Dictionary:
	var binding := state.binding
	if binding.is_empty() or int(params.get("binding", -1)) != int(binding.epoch):
		return _refusal("not_bound", "the panel's item is not bound for editing, or it has changed")
	if attached != binding.attached:
		_unbind(state)  # (handle did already, unless it changed since)
		return _refusal("not_bound", "the panel shows another file now; show the item again to edit it")
	if (params.has("project") and str(params.project) != binding.project) \
			or (params.has("id") and str(params.id) != binding.item):
		return _refusal("binding_mismatch", "a change names only the bound item")
	var saved := params.duplicate(true)
	saved.erase("binding")
	saved["project"] = binding.project
	saved["id"] = binding.item
	var guard := _Guard.new(state, attached, attached_of)
	var answered := await _save(state, method, saved, guard)
	if int(answered.get("rpc_code", 0)) == GRANT_REFUSED and guard.broken().is_empty():
		_drop_grant(state)
		answered = await _save(state, method, saved, guard)
	return answered


func _save(state: _Panel, method: String, saved: Dictionary, guard: _Guard) -> Dictionary:
	var grant := await _grant_for(state, guard)
	if grant.has("error_code"):
		return grant
	var granted := saved.duplicate()
	granted["panel_grant"] = grant.grant
	return await _request(state, method, granted, guard)


# A new item in `params.project`, which must be the attached file's open
# project, from `params.fields` (its type among them): a grant for creating
# one item of that type is registered for it, and revoked if it made none.
func _create(state: _Panel, params: Dictionary, guard: _Guard) -> Dictionary:
	var fields = params.get("fields", {})
	if not fields is Dictionary or str(fields.get("type", "")).is_empty():
		return _refusal("invalid_request", "a new item is sent as its fields, its type among them")
	var person := _host_person()
	if person.is_empty():
		return _refusal("no_person", "this host cannot tell which account it runs as, so it makes no edit")
	var opening := await _opening_of(state, guard)
	if opening.has("error_code"):
		return opening
	if str(params.get("project", "")) != opening.project:
		return _refusal("wrong_project", "items are created here only in %s, the file this panel shows" % opening.project)
	var registered := await _request(state, "register", {"panel_secret": _secret, "panel": state.key,
		"person": person, "project": opening.project, "type": str(fields.type), "actions": ["create_item"],
		"open_generation": opening.open_generation}, guard)
	if registered.has("error_code"):
		return registered
	var grant := str(registered.result.get("panel_grant", "")) if registered.result is Dictionary else ""
	if grant.is_empty():
		return _refusal("backend_error", "the backend registered no grant")
	var created := await _request(state, "create_item", {"panel_grant": grant, "project": opening.project,
		"fields": fields, "operation_id": str(params.get("operation_id", ""))}, guard)
	if created.has("error_code"):
		_revoke_grant(grant)
	return created


# The guarded binding's grant, registered when there is none still good:
# {grant} or a refusal. A grant registered for a binding that ended
# meanwhile is revoked, not kept.
func _grant_for(state: _Panel, guard: _Guard) -> Dictionary:
	var binding := guard.binding
	if int(state.grant.get("epoch", -1)) == int(binding.epoch) and Time.get_ticks_msec() < int(state.grant.expires_at):
		return {"grant": state.grant.grant}
	var person := _host_person()
	if person.is_empty():
		return _refusal("no_person", "this host cannot tell which account it runs as, so it makes no edit")
	# A new grant only for the opening the binding was checked against: a
	# project closed and opened again (even under the same name) ends it.
	var opening := await _opening_of(state, guard)
	if opening.has("error_code"):
		return opening
	if opening.project != binding.project or opening.open_generation != binding.open_generation:
		_unbind(state)
		return _refusal("stale_binding", "the project was closed or opened again; show the item again to edit it")
	var registered := await _request(state, "register", {"panel_secret": _secret, "panel": state.key,
		"person": person, "project": binding.project, "item": binding.item, "actions": ITEM_ACTIONS,
		"open_generation": binding.open_generation}, guard)
	if registered.has("error_code"):
		return registered
	var result = registered.result
	var grant := str(result.get("panel_grant", "")) if result is Dictionary else ""
	if grant.is_empty():
		return _refusal("backend_error", "the backend registered no grant")
	_drop_grant(state)  # one renewed, or registered by a save beside this one
	state.grant = {"grant": grant, "epoch": binding.epoch,
		"expires_at": Time.get_ticks_msec() + int(result.get("expires_in_ms", 0)) - GRANT_MARGIN_MS}
	return {"grant": grant}


# The binding ends and its grant is revoked.
func _unbind(state: _Panel) -> void:
	state.binding = {}
	_drop_grant(state)


func _drop_grant(state: _Panel) -> void:
	if not state.grant.is_empty():
		_revoke_grant(str(state.grant.grant))
	state.grant = {}


func _revoke_grant(grant: String) -> void:
	if _is_current():
		_connection.request_method(_prefix + "revoke", {"panel_secret": _secret, "panel_grant": grant})


func _is_current() -> bool:
	return not _secret.is_empty() and _connection != null \
		and _connection.process_generation() == _generation


func _is_live(state: _Panel) -> bool:
	return _panels.get(state.key) == state and _is_current()


# The registration's session, opened on its first use: {session} or a refusal.
func _session_for(state: _Panel, guard: _Guard = null) -> Dictionary:
	if not state.session.is_empty():
		return {"session": state.session}
	var opened := await _request(state, "open_session", {"panel_secret": _secret, "panel": state.key}, guard)
	if opened.has("error_code"):
		return opened
	var session := str(opened.result.get("panel_session", "")) if opened.result is Dictionary else ""
	if session.is_empty():
		return _refusal("backend_error", "the backend opened no panel session")
	if not state.session.is_empty():
		return {"session": state.session}  # another call opened one meanwhile; the panel's revoke ends both
	state.session = session
	return {"session": session}


# Method `name` of the channel for registration `state`: {result}, or a
# refusal when it failed or when, before it is sent or once it is answered
# (failed or not), the registration has ended, the process changed, or what
# `guard` holds no longer does. What a result that came too late gave stays
# here, never in the refusal: a grant is revoked, a session kept as the
# registration's (its revoke ends it); a save already sent is not undone.
func _request(state: _Panel, name: String, params: Dictionary, guard: _Guard = null) -> Dictionary:
	if not _is_live(state):
		return _refusal("superseded", "the panel closed")
	if guard != null and not guard.broken().is_empty():
		return _broken(state, guard)
	var generation := _generation
	var answered: Dictionary = await _connection.request_method(_prefix + name, params)
	if generation != _generation or not _is_current():
		return _refusal("backend_restarted", "the plugin's process changed while the panel waited")
	if _panels.get(state.key) != state:
		return _refusal("panel_unloading", "the panel closed while it waited")
	if guard != null and not guard.broken().is_empty():
		var late := _broken(state, guard)
		if not answered.has("error"):
			_settle_late(state, name, answered.get("result"))
			# A change the backend made is reported as made, even when refused
			# as superseded.
			var made = answered.get("result")
			if name == "create_item":
				late.error_message += "; the item was made all the same: %s" % (str(made.get("id", "")) if made is Dictionary else "")
			elif name in ITEM_ACTIONS:
				late.error_message += "; what was sent was applied"
		return late
	if answered.has("error"):
		var refused := _refusal("backend_error", str(answered.error))
		var rpc_error = answered.get("rpc_error")
		if rpc_error is Dictionary and rpc_error.has("code"):
			refused["rpc_code"] = int(rpc_error.code)
		return refused
	return {"result": answered.get("result", {})}


# What a late result of method `name` gave: a grant is revoked; a session is
# kept when the registration has none.
func _settle_late(state: _Panel, name: String, result) -> void:
	if not result is Dictionary:
		return
	if name == "register" and not str(result.get("panel_grant", "")).is_empty():
		_revoke_grant(str(result.panel_grant))
	elif name == "open_session" and state.session.is_empty():
		state.session = str(result.get("panel_session", ""))


# The refusal for a broken guard; a panel with another attachment than its
# binding's loses the binding and its grant.
func _broken(state: _Panel, guard: _Guard) -> Dictionary:
	if guard.broken() == "file":
		if state.binding == guard.binding and not guard.binding.is_empty():
			_unbind(state)
		return _refusal("superseded", "the panel shows another file now")
	return _refusal("superseded", "the panel showed another item meanwhile")


# The OS account this host runs as, asked of the system once.
func _host_person() -> String:
	if _person.is_empty() and ClassDB.class_exists("SubProcess"):
		var process: Node = ClassDB.instantiate("SubProcess")
		if process.has_method("os_account_name"):
			_person = str(process.os_account_name())
		process.free()
	return _person


static func _refusal(code: String, message: String) -> Dictionary:
	return {"error_code": code, "error_message": message}
