extends SceneTree
## A scene panel's private channel to its plugin's backend, from the panel's
## MinervaIPC.request_private through the broker's private branch and
## PluginPanelAuthority to a fixture backend connection that records every
## private request and answers as the Docket panel protocol does. The
## fixture backend has two open projects, p (/files/p.dct) and q
## (/files/q.dct); the panels are attached to p's file, as their editor's.
##
## Run: godot --headless --path src --script test/test_plugin_panel_authority.gd
##
## ORACLES
##   - a panel's tool call opens a session named by its own panel key and
##     goes with it;
##   - a panel saves only the item it has bound, in the project of its
##     attached file: binding asks the backend which open project that file
##     is and for the item's full id; binding an item of another project, or
##     in a panel attached to no file, is refused; a save before binding,
##     after unbinding, with an outdated binding, or naming another item is
##     refused unsent, as is one after the panel's file changed; the save
##     goes with a grant registered for exactly the bound item (its full id
##     and the project's opening), its save and move actions and the host's
##     person; a move goes the same way; a new item is made only in the
##     attached file's project, under a grant registered for creating one
##     item of its type alone; a second panel gets a session and grants of
##     its own;
##   - names only the host gives, a tool outside the panel's channels, and a
##     plugin that declares no channel are refused without reaching the
##     backend; an ordinary request never uses the channel;
##   - a grant the backend no longer honours is registered anew once, not
##     again, and not at all once the project was opened again;
##   - binding another item while a save waits ends that save (unsent before
##     it goes; answered after, it is refused but said to have been applied),
##     and a grant it got is revoked,
##     never handed to the panel; so does the panel being given another file
##     and then its own again (its binding and grant go too), and a failure
##     answered after the selection changed is reported as that;
##     closing the panel and registering its key again while a save waits
##     ends it unsent, and the new registration inherits nothing; a closed
##     panel is revoked at the backend; an answer after the process changed
##     is refused.

## The broker is loaded at run time, after the first frame: its scripts name
## the SingletonObject autoload, which a --script run registers only after it
## has compiled this script, so naming the class here would fail to compile.
const BROKER_SCRIPT := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const PLUGIN := "docket"
const PLAIN_PLUGIN := "plain"
const PERSON := "host-account"
const P_FILE := "/files/p.dct"

var _pass := 0
var _fail := 0
# The fixture editors the panels are attached through (held, as the broker
# keeps them weakly).
var _editors: Array = []


func _init() -> void:
	print("=== private panel channel (broker + PluginPanelAuthority) ===\n")
	await process_frame
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


## The backend: records each private request; answers at once unless held.
class FixtureConnection extends RefCounted:
	signal released
	var generation := 1
	var requests: Array = []
	var hold := ""
	var sessions := 0
	var grants := 0
	# How many saves to refuse as a grant the backend does not honour.
	var refuse_updates := 0
	# Answer every tool call through the channel with an error.
	var fail_calls := false
	# Differs each time p is opened.
	var p_opening := "open-1"

	func process_generation() -> int:
		return generation

	func request_method(method: String, params: Dictionary, _timeout_sec: float = 120.0) -> Dictionary:
		requests.append({"method": method, "params": params.duplicate(true)})
		if method.ends_with(hold) and not hold.is_empty():
			await released
		match method.trim_prefix("docket/panel/"):
			"open_session":
				sessions += 1
				return {"result": {"panel_session": "session-%d" % sessions}}
			"register":
				grants += 1
				return {"result": {"panel_grant": "grant-%d" % grants, "expires_in_ms": 900000}}
			"update_item":
				if refuse_updates > 0:
					refuse_updates -= 1
					return {"error": "no such grant", "rpc_error": {"code": -32001, "message": "no such grant"}}
				return {"result": {"id": params.id, "item_token": "t", "stream": "s", "event_watermark": 1}}
			"transition_item":
				return {"result": {"id": params.id, "status": params.target, "item_token": "t"}}
			"create_item":
				return {"result": {"id": "new-1", "item_token": "t"}}
			"call":
				if fail_calls:
					return {"error": "backend unavailable", "rpc_error": {"code": -32603, "message": "backend unavailable"}}
				return {"result": _tool(params.name, params.arguments)}
			"revoke":
				return {"result": {"revoked": 1}}
		return {"error": "Method not found"}

	func _tool(name: String, arguments: Dictionary) -> Dictionary:
		var value: Dictionary = {}
		if name == "docket_project_list":
			value = {"projects": [{"name": "p", "path": "/files/p.dct", "open_generation": p_opening},
				{"name": "q", "path": "/files/q.dct", "open_generation": "open-q"}]}
		elif name == "docket_item_view":
			if not arguments.id in ["i1", "i2"]:
				return {"content": [{"type": "text", "text": "missing"}], "isError": true}
			value = {"item": {"id": "full-%s" % arguments.id}}
		return {"content": [{"type": "text", "text": JSON.stringify(value)}], "stream": "s", "event_watermark": 1}

	func of(method: String) -> Array:
		return requests.filter(func(r: Dictionary) -> bool: return r.method == "docket/panel/" + method)

	func tools(name: String) -> Array:
		return of("call").filter(func(r: Dictionary) -> bool: return r.params.name == name)


class FixtureDB extends RefCounted:
	var definitions: Dictionary = {}

	func get_by_id(plugin_id: String) -> PluginDefinition:
		return definitions.get(plugin_id, null)


class FixtureManager extends RefCounted:
	var db := FixtureDB.new()
	var authorities: Dictionary = {}

	func get_db():
		return db

	func get_connection(_id: String):
		return null

	func get_panel_authority(id: String):
		return authorities.get(id, null)


# Counts the documents it is given as Editor does.
class FixtureEditor extends RefCounted:
	signal attachment_changed()
	var attachment_revision := 0
	var file := "":
		set(value):
			var replaced: bool = value != file
			file = value
			if replaced:
				attachment_revision += 1
				attachment_changed.emit()


class FixturePanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)


func _definition(plugin_id: String, authority: bool) -> PluginDefinition:
	var data := {
		"id": plugin_id, "name": plugin_id, "version": "1.0.0", "host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": "./bin/backend", "args": []},
		"ui": {"panels": [{"name": "main", "kind": "godot_scene", "entry_scene": "panel.tscn",
			"scripts": ["panel.gd"], "ipc_channels": ["docket_comment"], "save_mode": "none"}],
			"ipc_messages": ["docket_comment"]},
		"tools": [],
	}
	if authority:
		data["panel_authority"] = PluginDefinition.PANEL_AUTHORITY_V1.duplicate()
	var definition := PluginDefinition.from_dict(data)
	definition.state = PluginDefinition.State.RUNNING
	return definition


# A panel of `plugin_id` registered as `key`, attached to `file` ("" for none).
func _panel(broker, plugin_id: String, key: String, file: String = P_FILE) -> MinervaIPC:
	var panel := FixturePanel.new()
	root.add_child(panel)
	var editor := FixtureEditor.new()
	editor.file = file
	_editors.append(editor)
	broker.register_panel(panel, plugin_id, key, PackedStringArray(["docket_comment"]), "main", editor)
	return panel.get_node("_MinervaIPC") as MinervaIPC


func _binding_of(reply: Dictionary) -> int:
	return int(reply.get("result", {}).get("binding", -1))


func _run() -> void:
	var manager := FixtureManager.new()
	manager.db.definitions[PLUGIN] = _definition(PLUGIN, true)
	manager.db.definitions[PLAIN_PLUGIN] = _definition(PLAIN_PLUGIN, false)
	check("the manifest's panel_authority is taken exactly", not manager.db.definitions[PLUGIN].panel_authority.is_empty()
		and manager.db.definitions[PLUGIN].validate().is_empty(), str(manager.db.definitions[PLUGIN].validate()))
	var backend := FixtureConnection.new()
	var authority := PluginPanelAuthority.new(PLUGIN, backend, PluginDefinition.PANEL_AUTHORITY_V1)
	var env := authority.env_for_generation(backend.generation)
	var secret := str(env.get("DOCKET_PANEL_SECRET", ""))
	check("each process gets a 256-bit secret in its environment", secret.length() == 64)
	authority._person = PERSON
	manager.authorities[PLUGIN] = authority
	var broker_script = load(BROKER_SCRIPT)
	if not broker_script is GDScript or not broker_script.can_instantiate():
		check("the broker's script compiles once the autoloads are up", false)
		return
	var broker = broker_script.new(manager, null, null, null)
	var a := _panel(broker, PLUGIN, "main#1")
	var b := _panel(broker, PLUGIN, "main#2")

	# A panel's call, as that panel.
	var called := await a.request_private("call", {"name": "docket_comment", "arguments": {"text": "x"}, "operation_id": "op1"})
	var opened: Array = backend.of("open_session")
	check("a panel's call goes with a session opened for its own key",
		called.get("success", false) and opened.size() == 1 and opened[0].params == {"panel_secret": secret, "panel": "main#1"}
		and backend.of("call")[0].params.panel_session == "session-1", str(backend.requests))

	# Binding: the attached file's project, the item's full id.
	var sent := backend.requests.size()
	var unbound := await a.request_private("update_item", {"binding": 1, "changes": {"title": "t"}})
	check("a save before binding is refused unsent", unbound.get("error_code") == "not_bound" and backend.requests.size() == sent, str(unbound))
	var missing := await a.request_private("select_item", {"project": "p", "id": "nope"})
	check("binding an item its project does not have is refused", missing.get("error_code") == "not_an_item", str(missing))
	var elsewhere := await a.request_private("select_item", {"project": "q", "id": "i1"})
	check("binding an item of another open project than the attached file's is refused",
		elsewhere.get("error_code") == "wrong_project", str(elsewhere))
	var detached := await _panel(broker, PLUGIN, "main#4", "").request_private("select_item", {"project": "p", "id": "i1"})
	check("a panel attached to no file binds nothing", detached.get("error_code") == "not_attached", str(detached))
	var bound := await a.request_private("select_item", {"project": "p", "id": "i1"})
	check("binding asks the backend which project the attached file is, and for the item, through the panel's session",
		bound.get("success", false) and bound.result.id == "full-i1"
		and backend.tools("docket_project_list")[-1].params.panel_session == "session-1"
		and backend.tools("docket_item_view")[-1].params.arguments == {"project": "p", "id": "i1"}, str(bound))
	var epoch := _binding_of(bound)
	var saved := await a.request_private("update_item", {"binding": epoch, "changes": {"title": "t"}, "operation_id": "op2"})
	var registered: Array = backend.of("register")
	var update: Dictionary = backend.of("update_item")[0].params
	check("the save goes with a grant for exactly the bound item, its save and move actions and the host's person",
		saved.get("success", false) and registered.size() == 1 and registered[0].params == {"panel_secret": secret,
			"panel": "main#1", "person": PERSON, "project": "p", "item": "full-i1", "actions": ["update_item", "transition_item"],
			"open_generation": "open-1"}
		and update.panel_grant == "grant-1" and update.project == "p" and update.id == "full-i1" and not update.has("binding"),
		str(backend.requests))
	sent = backend.requests.size()
	var other := await a.request_private("update_item", {"binding": epoch, "project": "p", "id": "full-i2", "changes": {}})
	check("a save naming another item than the bound one is refused unsent",
		other.get("error_code") == "binding_mismatch" and backend.requests.size() == sent, str(other))
	_editors[0].file = "/files/saved-as.dct"
	var moved := await a.request_private("update_item", {"binding": epoch, "changes": {}})
	_editors[0].file = P_FILE
	check("a save after the panel's file changed is refused unsent, and the binding's grant revoked",
		moved.get("error_code") == "not_bound" and backend.requests.size() == sent + 1
		and backend.requests[-1].params == {"panel_secret": secret, "panel_grant": "grant-1"}, str(moved))
	var kept := await a.request_private("update_item", {"binding": epoch, "changes": {}})
	check("and the binding is gone once seen with another file", kept.get("error_code") == "not_bound", str(kept))
	bound = await a.request_private("select_item", {"project": "p", "id": "i1"})
	epoch = _binding_of(bound)
	var b_bound := await b.request_private("select_item", {"project": "p", "id": "i1"})
	await b.request_private("update_item", {"binding": _binding_of(b_bound), "changes": {}})
	check("another panel gets a session and a grant of its own", backend.of("open_session")[-1].params.panel == "main#2"
		and backend.of("register")[-1].params.panel == "main#2" and backend.of("update_item")[-1].params.panel_grant == "grant-2")
	check("the backend's secret is never in a reply", not JSON.stringify([called, bound, saved]).contains(secret))

	# Refusals that never reach the backend.
	var before := backend.requests.size()
	var forged := await a.request_private("update_item", {"binding": epoch, "person": "someone else"})
	var undeclared := await a.request_private("call", {"name": "docket_create", "arguments": {}})
	var plain := await _panel(broker, PLAIN_PLUGIN, "main#3").request_private("call", {"name": "docket_comment", "arguments": {}})
	check("a host-only name, an undeclared tool and a plugin without the channel are refused unsent",
		forged.get("error_code") == "host_argument" and undeclared.get("error_code") == PluginErrors.CODE_PERMISSION_DENIED
		and plain.get("error_code") == "no_private_channel" and backend.requests.size() == before,
		"%s %s %s" % [forged, undeclared, plain])
	# An ordinary request goes the ordinary way (no backend connection in
	# this fixture), never through the channel.
	var ordinary := await b.request_bulk("docket_comment", {"text": "x"})
	check("an ordinary request does not use the private channel",
		ordinary.get("error_code") == PluginErrors.CODE_PLUGIN_NOT_RUNNING and backend.requests.size() == before,
		str(ordinary))

	# A move of the bound item goes like a save; a new item is made in the
	# attached file's project only, under a grant for creating one alone.
	var transitioned := await a.request_private("transition_item", {"binding": epoch, "target": "triaged", "note": "",
		"changes": {"title": "t"}})
	var move: Dictionary = backend.of("transition_item")[-1].params
	check("a move goes for exactly the bound item, with its grant",
		transitioned.get("success", false) and move.project == "p" and move.id == "full-i1" and move.target == "triaged"
		and move.panel_grant == "grant-%d" % backend.grants and not move.has("binding"), str(move))
	var creates := backend.of("register").size()
	var elsewhere_new := await a.request_private("create_item", {"project": "q", "fields": {"type": "bug", "title": "n"}})
	var created := await a.request_private("create_item", {"project": "p", "fields": {"type": "bug", "title": "n"},
		"operation_id": "op3"})
	check("a new item is made in the attached file's project only, under a grant for creating one of its type",
		elsewhere_new.get("error_code") == "wrong_project" and created.get("success", false) and created.result.id == "new-1"
		and backend.of("register").size() == creates + 1
		and backend.of("register")[-1].params == {"panel_secret": secret, "panel": "main#1", "person": PERSON,
			"project": "p", "type": "bug", "actions": ["create_item"], "open_generation": "open-1"}
		and backend.of("create_item")[-1].params == {"panel_grant": "grant-%d" % backend.grants, "project": "p",
			"fields": {"type": "bug", "title": "n"}, "operation_id": "op3"}, "%s %s" % [elsewhere_new, created])

	# A grant the backend dropped is registered anew, once, and only for the
	# same opening of the project.
	await a.request_private("update_item", {"binding": epoch, "changes": {}})  # so a has a grant
	backend.refuse_updates = 1
	var registers := backend.of("register").size()
	var resaved := await a.request_private("update_item", {"binding": epoch, "changes": {}})
	check("a grant the backend no longer honours is registered anew", resaved.get("success", false)
		and backend.of("register").size() == registers + 1, str(resaved))
	backend.refuse_updates = 2
	var updates := backend.of("update_item").size()
	var refused := await a.request_private("update_item", {"binding": epoch, "changes": {}})
	check("but only once", not refused.get("success", true) and backend.of("register").size() == registers + 2
		and backend.of("update_item").size() == updates + 2, str(refused))
	var reopen_bound := await a.request_private("select_item", {"project": "p", "id": "i1"})
	await a.request_private("update_item", {"binding": _binding_of(reopen_bound), "changes": {}})
	registers = backend.of("register").size()
	backend.p_opening = "open-2"
	backend.refuse_updates = 1
	var reopened := await a.request_private("update_item", {"binding": _binding_of(reopen_bound), "changes": {}})
	check("and not when the project was opened again under its name", reopened.get("error_code") == "stale_binding"
		and backend.of("register").size() == registers, str(reopened))
	backend.p_opening = "open-1"

	# Outdated bindings.
	var first := await a.request_private("select_item", {"project": "p", "id": "i1"})
	await a.request_private("select_item", {"project": "p", "id": "i2"})
	updates = backend.of("update_item").size()
	var outdated := await a.request_private("update_item", {"binding": _binding_of(first), "changes": {}})
	await a.request_private("select_item", {"project": "", "id": ""})
	var after_unbind := await a.request_private("update_item", {"binding": _binding_of(first) + 1, "changes": {}})
	check("a save with an outdated binding, or after unbinding, is refused unsent",
		outdated.get("error_code") == "not_bound" and after_unbind.get("error_code") == "not_bound"
		and backend.of("update_item").size() == updates, "%s %s" % [outdated, after_unbind])

	# Binding another item while a save waits for its grant, then for its answer.
	var fresh := await a.request_private("select_item", {"project": "p", "id": "i1"})
	backend.hold = "register"
	updates = backend.of("update_item").size()
	var switched := {}
	var saving := func() -> void:
		switched.merge(await a.request_private("update_item", {"binding": _binding_of(fresh), "changes": {}}))
	saving.call()
	await process_frame
	await process_frame
	var rebound := await a.request_private("select_item", {"project": "p", "id": "i2"})
	backend.hold = ""
	backend.released.emit()
	await process_frame
	var late_grant := "grant-%d" % backend.grants
	check("binding another item ends a save waiting for its grant, unsent", rebound.get("success", false)
		and switched.get("error_code") == "superseded" and backend.of("update_item").size() == updates, str(switched))
	check("and the grant it got is revoked, never handed to the panel", backend.of("revoke").any(func(r: Dictionary) -> bool:
		return r.params == {"panel_secret": secret, "panel_grant": late_grant}) and not str(switched).contains(late_grant),
		str(switched))
	backend.hold = "update_item"
	var answered_late := {}
	var sending := func() -> void:
		answered_late.merge(await a.request_private("update_item", {"binding": _binding_of(rebound), "changes": {}}))
	sending.call()
	await process_frame
	await process_frame
	await a.request_private("select_item", {"project": "p", "id": "i1"})
	backend.hold = ""
	backend.released.emit()
	await process_frame
	check("a save answered after another item was bound is refused as superseded, and said to have been applied",
		answered_late.get("error_code") == "superseded" and str(answered_late.get("error_message", "")).contains("was applied"),
		str(answered_late))

	# The panel is given another file and then its own again while a save
	# waits for its grant.
	var attached_bound := await a.request_private("select_item", {"project": "p", "id": "i1"})
	backend.hold = "register"
	updates = backend.of("update_item").size()
	var grants := backend.grants
	var moved_save := {}
	var moving := func() -> void:
		moved_save.merge(await a.request_private("update_item", {"binding": _binding_of(attached_bound), "changes": {}}))
	moving.call()
	await process_frame
	await process_frame
	_editors[0].file = "/files/other.dct"
	_editors[0].file = P_FILE
	backend.hold = ""
	backend.released.emit()
	await process_frame
	var moved_grant := "grant-%d" % backend.grants
	var revived := await a.request_private("update_item", {"binding": _binding_of(attached_bound), "changes": {}})
	check("a save whose panel is given another file and its own again while it waits ends unsent, its grant revoked, its binding gone",
		moved_save.get("error_code") == "superseded" and backend.of("update_item").size() == updates
		and backend.grants == grants + 1 and not str(moved_save).contains(moved_grant)
		and backend.of("revoke").any(func(r: Dictionary) -> bool: return r.params.get("panel_grant") == moved_grant)
		and revived.get("error_code") == "not_bound", "%s %s" % [moved_save, revived])

	# A lookup that fails after the panel moved on reports that, not the failure.
	backend.fail_calls = true
	backend.hold = "call"
	var failed_late := {}
	var looking := func() -> void:
		failed_late.merge(await a.request_private("select_item", {"project": "p", "id": "i2"}))
	looking.call()
	await process_frame
	await process_frame
	await a.request_private("select_item", {"project": "", "id": ""})
	backend.hold = ""
	backend.released.emit()
	await process_frame
	backend.fail_calls = false
	check("a failed lookup answered after the selection changed is refused as superseded",
		failed_late.get("error_code") == "superseded", str(failed_late))

	# The key closed and registered again while a save waits.
	var last := await a.request_private("select_item", {"project": "p", "id": "i2"})
	backend.hold = "register"
	updates = backend.of("update_item").size()
	var old_save := {}
	var closing := func() -> void:
		old_save.merge(await a.request_private("update_item", {"binding": _binding_of(last), "changes": {}}))
	closing.call()
	await process_frame
	await process_frame
	broker.unregister_panel(PLUGIN, "main#1")
	check("a closed panel is revoked at the backend", backend.of("revoke").any(func(r: Dictionary) -> bool:
		return r.params == {"panel_secret": secret, "panel": "main#1"}))
	var sessions := backend.of("open_session").size()
	var again := _panel(broker, PLUGIN, "main#1")
	await again.request_private("call", {"name": "docket_comment", "arguments": {}})
	backend.hold = ""
	backend.released.emit()
	await process_frame
	check("the old registration's save ends unsent, and the new one inherits nothing",
		old_save.get("error_code") == "panel_unloading" and backend.of("update_item").size() == updates
		and backend.of("open_session").size() == sessions + 1 and backend.of("open_session")[-1].params.panel == "main#1",
		"%s %s" % [old_save, backend.of("open_session")])

	# A process that changes while a call waits.
	backend.hold = "call"
	var late := {}
	var restarting := func() -> void:
		late.merge(await b.request_private("call", {"name": "docket_comment", "arguments": {}}))
	restarting.call()
	await process_frame
	await process_frame
	backend.generation += 1
	backend.released.emit()
	await process_frame
	check("an answer after the process changed is refused", late.get("error_code") == "backend_restarted", str(late))
	for key in ["main#1", "main#2", "main#4"]:
		broker.unregister_panel(PLUGIN, key)
	broker.unregister_panel(PLAIN_PLUGIN, "main#3")
