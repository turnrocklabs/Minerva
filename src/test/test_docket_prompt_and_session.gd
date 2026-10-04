extends "res://test/helpers/docket_owner_suite.gd"
## Headless test of Minerva's side of the Docket plugin: the agent system
## prompt read from it, and the session DocketHost keeps there.
##
## Run only in a throwaway profile, made before Godot starts (the app's
## autoloads, the embedded Docket among them, use the profile before this
## script runs), from the repository root:
##   ( source scripts/lib/test-profile.sh && root="$(mktemp -d)" && seed_test_profile "$root" \
##     && MINERVA_TEST_PROFILE_ROOT="$root" timeout 300 \
##        "${GODOT:-godot}" --headless --path src res://test/helpers/docket_owner_scene.tscn -- prompt_and_session )
## The test fails at once unless Godot's user directory is under
## MINERVA_TEST_PROFILE_ROOT and holds none of the files it writes.
##
## PROMPT (sections A-C) — REAL: ChatPane.create_prompt, _build_agent_system_prompt,
## _docket_base_prompt, generate_content_from_provider and the turn token
## helpers. FAKED: the Docket owner (a DocketHost whose system_prompt answers
## what the test queues, and waits while the test holds its gate) and the
## provider (it counts generate_content calls; it never reaches a network).
## The pane skips ChatPane._ready, which needs the booted UI scene.
##
## SESSION (sections D-F) — REAL: DocketHost (setup, session file, reconcile,
## Retry/Locate/Forget, prompt read). FAKED: the plugin manager, the plugin's
## connection and its private channel, answering as the Docket plugin does
## (project add/list/remove, prompt queries) over an in-memory set of open
## projects. The session files DocketHost reads and writes live in user://,
## beside the preferences (a person's vault password among them); the test
## removes what it wrote.

const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const CHAT_HISTORY_ITEM_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const VBOX_CHAT_PATH := "res://Scripts/UI/Controls/vboxChat.gd"
const DOCKET_HOST_PATH := "res://Scripts/Services/DocketHost/DocketHost.gd"
const USER_FILES := ["user://docket_host_session.json", "user://docket_host_session.json.new", "user://docket_prefs.json"]

const PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"
func _ready() -> void:
	pass
func _update_stop_button() -> void:
	pass
func _update_compact_button() -> void:
	pass
"""

## Counts the requests that reached it; sends nothing anywhere.
const PROVIDER_SRC := """
extends "res://Scripts/Services/Providers/PluginProvider.gd"
var system_prompt := ""
var generated := 0
func generate_content(_prompt: Array[Variant], _additional_params: Dictionary = {}) -> BotResponse:
	generated += 1
	var response := BotResponse.new()
	response.text = "answer"
	return response
"""

## The Docket owner as ChatPane sees it: each read takes the next queued
## answer, once the gate is open.
const OWNER_SRC := """
extends "res://Scripts/Services/DocketHost/DocketHost.gd"
var answers: Array = []
var gate_open := true
var reads := 0
func system_prompt(_key: String, _model_id: String = "") -> Dictionary:
	reads += 1
	while not gate_open:
		await get_tree().process_frame
	return answers.pop_front()
"""

## The plugin's connection: open projects by path, prompts by path, projects
## that fail to open, and a listing that can be made to fail.
const CONNECTION_SRC := """
extends RefCounted
var public_calls := []
var generation := 1
var open := {}
var prompts := {}
var unopenable := {}
var listing_fails := false
var _next := 0
func process_generation() -> int:
	return generation
func open_project(path: String) -> Dictionary:
	if not open.has(path):
		_next += 1
		open[path] = {"name": path.get_file().get_basename(), "display_name": path.get_file().get_basename(),
			"path": path, "open_generation": str(_next)}
	return open[path]
func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	public_calls.append(JSON.stringify({"tool": tool, "arguments": arguments}))
	match tool:
		"docket_project_list":
			return {"error": "listing failed"} if listing_fails else {"success": true, "projects": open.values()}
		"docket_project_add":
			var path := str(arguments.path)
			if unopenable.has(path):
				return {"success": false, "error": "File not found: %s" % path}
			return open_project(path).merged({"success": true})
		"docket_project_remove":
			for path in open.keys():
				if open[path].name == str(arguments.name):
					open.erase(path)
					return {"success": true, "closed": arguments.name}
			return {"success": false, "error": "Unknown project"}
		"docket_query":
			for path in open:
				if open[path].name == str(arguments.project):
					return {"success": true, "items": prompts.get(path, []), "count": prompts.get(path, []).size()}
			return {"success": false, "error": "Unknown project"}
	return {"success": false, "error": "unexpected tool %s" % tool}
"""

## The plugin's private channel: the schema is accepted, the master installed
## and opened.
const AUTHORITY_SRC := """
extends RefCounted
var connection = null
var initialized := true
var hold := ""
var gate_open := true
var entered := 0
var private_methods := []
func host_request(name: String, params: Dictionary) -> Dictionary:
	if name.begins_with("vault_"):
		entered += 1
		private_methods.append(name)
		var project: Dictionary = connection.open.get(params.path, {})
		var descriptor := {"path": params.path, "open_generation": project.get("open_generation", ""), "fingerprint": "fixed-vault-fingerprint"}
		var reply := {"result": descriptor.merged({"unlocked": name == "vault_unlock"})}
		if not initialized or project.is_empty():
			reply = {"error": {"message": "Vault request refused"}}
		elif name == "vault_unlock" and (params.get("password") != "D3a-private-session-sentinel" or params.open_generation != descriptor.open_generation or params.fingerprint != descriptor.fingerprint):
			reply = {"error": {"message": "Vault unlock refused"}}
		while name == hold and not gate_open:
			await Engine.get_main_loop().process_frame
		return reply
	if name == "declare_schema":
		return {"result": {"version": params.version}}
	var project: Dictionary = connection.open_project(str(params.path))
	return {"result": {"status": "installed", "path": project.path, "project": project, "conflicts": [], "capability_gaps": []}}
"""

const PLUGIN_MANAGER_SRC := """
extends Node
signal plugin_ready(id: String)
signal plugin_stopped(id: String)
signal plugin_crashed(id: String)
signal backend_tool_called(id: String, tool: String)
var connection = null
var authority = null
func get_connection(_id: String):
	return connection
func get_panel_authority(_id: String):
	return authority
func get_plugin_status(_id: String) -> Dictionary:
	return {"running": true}
func set_backend_tool_guard(_id: String, _guard: Callable) -> void:
	pass
"""

const VAULT_PASSWORD := "D3a-private-session-sentinel"
## Real Preferences scene and inherited methods; only unrelated popup startup is skipped.
const PREFS_SRC := """
extends "res://Scripts/UI/Views/PreferencesPopup.gd"
func _ready() -> void:
	pass
"""

var _pass := 0
var _fail := 0
var _so: Node = null
var _host_render := preload("res://test/helpers/chat_host_render_fixture.gd").new()
## What the sections made, freed once both have run (an early return included).
var _made_nodes: Array[Node] = []
var _made_chats: Array = []
## The longest any wait here may take, in frames: a wait that runs out fails.
const MAX_FRAMES := 300


func _ready() -> void:
	print("=== Docket prompt and session ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		print("FAIL: %s%s" % [label, ("  — " + detail) if detail else ""])


func _make(source: String):
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		check("a test double compiles", false, source.left(80))
		return null
	var made = script.new()
	if made is Node:
		_made_nodes.append(made)
	return made


func _run() -> void:
	await process_frame
	_so = root.get_node_or_null("/root/SingletonObject")
	check("the SingletonObject autoload is live", _so != null)
	if _so == null:
		return
	var profile := OS.get_environment("MINERVA_TEST_PROFILE_ROOT")
	var user_dir := OS.get_user_data_dir()
	if profile.is_empty() or not user_dir.begins_with(profile.trim_suffix("/") + "/"):
		check("Godot's user directory is in the throwaway profile (see the header)", false, user_dir)
		return
	for path in USER_FILES:
		if FileAccess.file_exists(path):
			check("the throwaway profile holds no %s yet" % path, false)
			return
	_host_render.install(_so)
	var previous_host = _so.docket_host
	await _test_prompt()
	_so.docket_host = previous_host
	await _test_session()
	await _test_vault()
	_so.docket_host = previous_host
	for chat in _made_chats:
		_so.ChatList.erase(chat)
	for node in _made_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_clear_user_files()
	_host_render.restore()


# Waits until `done` answers true, for at most MAX_FRAMES: whether it did.
func _wait(done: Callable) -> bool:
	for frame in MAX_FRAMES:
		if done.call():
			return true
		await process_frame
	return done.call()


# -- Prompt ------------------------------------------------------------------

func _test_prompt() -> void:
	var pane: Node = _make(PANE_SRC)
	root.add_child(pane)
	var provider = _make(PROVIDER_SRC)
	var history = load(CHAT_HISTORY_PATH).new(provider)
	history.HistoryName = "docket prompt"
	history.AgentModeEnabled = true
	history.AgenticSystemPromptEnabled = true
	var vbox = load(VBOX_CHAT_PATH).new(pane)
	vbox.chat_history = history
	pane.add_child(vbox)
	history.VBox = vbox
	_so.ChatList.append(history)
	_made_chats.append(history)
	var owner: Node = _make(OWNER_SRC)
	owner.state = "ready"
	root.add_child(owner)
	_so.docket_host = owner

	# A: a failed read makes the prompt a refusal, answered with its reason
	# each time it would be sent (a resend or retry of the same prompt
	# included), with no request to the provider, whose own system prompt is
	# left alone.
	provider.system_prompt = "earlier"
	owner.answers = [{"error": "the prompts of work could not be read"}]
	var token: int = pane._begin_chat_turn(history)
	var refused: Array = await pane.create_prompt(_user_item("hello"), true, null, Callable(), history, token)
	var first = await pane.generate_content_from_provider(history, refused)
	var again = await pane.generate_content_from_provider(history, refused)
	check("A: a failed Docket read refuses, with its reason, every send of that prompt",
		str(first.error).contains("the prompts of work could not be read") and str(again.error).contains("the prompts of work could not be read")
		and first.get_meta("error_code", "") == "system_prompt_unavailable", "%s / %s" % [first.error, again.error])
	check("A: no request reached the provider, and its system prompt is untouched",
		provider.generated == 0 and provider.system_prompt == "earlier",
		"generated=%d system_prompt=%s" % [provider.generated, provider.system_prompt])
	pane._release_chat_turn(history, token)

	# B: only a successful read decides the prompt — Docket's when it defines
	# one, the built-in one when it defines none.
	owner.answers = [{"prompt": "DOCKET BASE"}]
	token = pane._begin_chat_turn(history)
	var sent: Array = await pane.create_prompt(_user_item("hello"), true, null, Callable(), history, token)
	await pane.generate_content_from_provider(history, sent)
	check("B: Docket's prompt is the system prompt, and the request is sent",
		provider.system_prompt.begins_with("DOCKET BASE") and provider.generated == 1, provider.system_prompt.left(60))
	pane._release_chat_turn(history, token)
	owner.answers = [{"prompt": ""}]
	token = pane._begin_chat_turn(history)
	await pane.create_prompt(_user_item("hello"), true, null, Callable(), history, token)
	check("B: Docket defining none gives the built-in prompt",
		provider.system_prompt.begins_with(pane.get_script().AGENT_SYSTEM_PROMPT_FALLBACK.left(40)), provider.system_prompt.left(60))
	pane._release_chat_turn(history, token)

	# C: a read still under way when its turn is stopped and a new one starts
	# changes nothing when it completes — neither its prompt nor its error
	# reaches the prompt it returns or the provider.
	for late in [{"prompt": "OLD TURN"}, {"error": "late failure"}]:
		owner.gate_open = false
		owner.answers = [late]
		var reads_before: int = owner.reads
		var old_token: int = pane._begin_chat_turn(history)
		var outcome := {}
		var old_turn := func() -> void:
			outcome.list = await pane.create_prompt(_user_item("old"), true, null, Callable(), history, old_token)
			outcome.done = true
		old_turn.call()
		if not await _wait(func() -> bool: return owner.reads > reads_before):
			check("C: the old turn's read started", false)
			return
		pane._cancel_chat_turn(history)
		var new_token: int = pane._begin_chat_turn(history)
		provider.system_prompt = "NEW TURN"
		owner.gate_open = true
		if not await _wait(func() -> bool: return outcome.get("done", false)):
			check("C: the old turn's read finished", false)
			return
		check("C: a stopped turn's late %s leaves the new turn's prompt as it was, and gives none" % late.keys()[0],
			provider.system_prompt == "NEW TURN" and outcome.list.is_empty(),
			"system_prompt=%s list=%s" % [provider.system_prompt, outcome.list])
		pane._release_chat_turn(history, new_token)


func _user_item(text: String):
	var item = load(CHAT_HISTORY_ITEM_PATH).new()
	item.Message = text
	return item


# -- Session -----------------------------------------------------------------

func _test_session() -> void:
	var host_script = load(DOCKET_HOST_PATH)

	# D: what a saved session reads as: absent is empty, a file that is there
	# but blank or not a version-1 session is an error, a whole ".new" left by
	# a failed move stands in for an absent file, and the embedded Docket's
	# session is read from its preferences, marked as such, without writing
	# them.
	_clear_user_files()
	check("D: no saved session is an empty one", host_script._load_session() == {"paths": PackedStringArray()})
	_write("user://docket_prefs.json", "   ")
	check("D: blank preferences are unreadable, not empty", host_script._load_session().has("error"))
	_write("user://docket_prefs.json", JSON.stringify({"session_paths": ["/p/a.dct", "/p/b.dct"], "vault_password": "kept"}))
	var prefs_before := FileAccess.get_file_as_bytes("user://docket_prefs.json")
	var legacy: Dictionary = host_script._load_session()
	check("D: the embedded Docket's session is read, in order, as legacy, and its preferences are not written",
		legacy.get("legacy", false) and legacy.paths == PackedStringArray(["/p/a.dct", "/p/b.dct"])
		and FileAccess.get_file_as_bytes("user://docket_prefs.json") == prefs_before, str(legacy))
	_write("user://docket_host_session.json.new", JSON.stringify({"version": 1, "paths": ["/p/c.dct"]}))
	check("D: a whole .new stands in for an absent session file",
		host_script._load_session().get("paths") == PackedStringArray(["/p/c.dct"]))
	_write("user://docket_host_session.json", "")
	check("D: a session file that is there but empty is unreadable", host_script._load_session().has("error"))
	_write("user://docket_host_session.json", JSON.stringify({"version": 2, "paths": ["/p/c.dct"]}))
	check("D: a session file of another version is unreadable", host_script._load_session().has("error"))

	# E: setup restores the session; a project that does not reopen stays in
	# it, visible, and keeps prompts from being read until a person retries,
	# locates or forgets it; Forget and Locate are in the saved session when
	# they report success.
	_clear_user_files()
	_write("user://docket_host_session.json", JSON.stringify({"version": 1, "paths": ["/p/a.dct", "/p/gone.dct", "/p/moved.dct"]}))
	var connection = _make(CONNECTION_SRC)
	connection.unopenable = {"/p/gone.dct": true, "/p/moved.dct": true}
	var authority = _make(AUTHORITY_SRC)
	authority.connection = connection
	var manager: Node = _make(PLUGIN_MANAGER_SRC)
	manager.connection = connection
	manager.authority = authority
	root.add_child(manager)
	var host: Node = host_script.new()
	_made_nodes.append(host)
	root.add_child(host)
	host.start(manager, false)
	if not await _wait(func() -> bool: return not host.state in ["starting", "unavailable"]):
		check("E: the host set the plugin's process up", false, host.state)
		return
	var failed := _failed_paths(host)
	check("E: a project that does not reopen stays in the session, visibly",
		host.state == "degraded" and failed == ["/p/gone.dct", "/p/moved.dct"], "%s %s" % [host.state, failed])
	var blocked: Dictionary = await host.system_prompt("agentic-base")
	check("E: its prompts may be missing, so the prompt read is an error", blocked.has("error"), str(blocked))
	check("E: forgetting it saves the session without it before it says so",
		await host.forget_project("/p/gone.dct") == "" and _saved_session() == ["/p/a.dct", "/p/moved.dct"], str(_saved_session()))
	connection.unopenable.erase("/p/moved.dct")
	check("E: a retry that opens keeps the entry",
		await host.retry_project("/p/moved.dct") == "" and _failed_paths(host).is_empty() and _saved_session() == ["/p/a.dct", "/p/moved.dct"],
		str(_saved_session()))
	connection.open.erase("/p/moved.dct")
	await host.system_prompt("agentic-base")
	check("E: a project closed by someone else leaves the session at the next read",
		_saved_session() == ["/p/a.dct"], str(_saved_session()))
	# The plugin restarts with a saved entry that no longer opens.
	_write("user://docket_host_session.json", JSON.stringify({"version": 1, "paths": ["/p/a.dct", "/p/lost.dct"]}))
	connection.unopenable = {"/p/lost.dct": true}
	connection.generation += 1
	manager.plugin_ready.emit("docket")
	if not await _wait(func() -> bool: return host.state != "starting"):
		check("E: the host set the restarted process up", false, host.state)
		return
	check("E: locating a replacement puts it in the failed entry's place",
		await host.locate_project("/p/lost.dct", "/p/found.dct") == "" and _saved_session() == ["/p/a.dct", "/p/found.dct"],
		str(_saved_session()))

	# F: prompts come from the master, overridden by the session's projects;
	# a listing that fails is an error, and a project opened meanwhile by
	# someone else counts once the session has it.
	var master_path: String = host.master_path
	connection.prompts = {master_path: [{"key": "agentic-base", "prompt_text": "MASTER"}],
		"/p/found.dct": [{"key": "agentic-base", "prompt_text": "FOUND"}]}
	var layered: Dictionary = await host.system_prompt("agentic-base")
	check("F: a session project's prompt overrides the master's", layered.get("prompt") == "FOUND", str(layered))
	connection.listing_fails = true
	var unlisted: Dictionary = await host.system_prompt("agentic-base")
	check("F: when the open projects cannot be listed, the prompt read is an error", unlisted.has("error"), str(unlisted))
	connection.listing_fails = false
	connection.open_project("/p/new.dct")
	connection.prompts["/p/new.dct"] = [{"key": "agentic-base", "prompt_text": "NEW"}]
	var joined: Dictionary = await host.system_prompt("agentic-base")
	check("F: a project opened by someone else joins the session and its prompt counts",
		joined.get("prompt") == "NEW" and "/p/new.dct" in _saved_session(), "%s %s" % [joined, _saved_session()])


# -- Hosted vault: real host/helper/UI, explicitly fake private backend --------

func _vault_form():
	var form = load("res://Scenes/windows/PreferencesPopup.tscn").instantiate()
	var fixture := GDScript.new()
	fixture.source_code = PREFS_SRC
	check("G: real Preferences scene fixture compiles", fixture.reload() == OK)
	form.set_script(fixture)
	form.visible = false
	_made_nodes.append(form)
	root.add_child(form)
	return form


func _fill_vault(form, password: String) -> void:
	form._vault_password.text = password
	form._vault_confirm.text = password
	form._vault_hint.text = password


func _submit_vault(form, hosted: bool = true) -> void:
	form._vault_message.text = ""
	form.get_node("%SetVaultPasswordButton").pressed.emit()
	check("G: real Preferences scene button completes its vault attempt",
		await _wait(func() -> bool: return not form.get_node("%SetVaultPasswordButton").disabled and (not hosted or not form._vault_message.text.is_empty())))


func _vault_attempt(host) -> Dictionary:
	var outcome := {}
	var run := func() -> void:
		outcome.message = await host.unlock_vault(VAULT_PASSWORD)
		outcome.done = true
	run.call()
	return outcome


func _profile_has_password(path: String) -> bool:
	for file in DirAccess.get_files_at(path):
		if FileAccess.get_file_as_string(path.path_join(file)).contains(VAULT_PASSWORD):
			return true
	for directory in DirAccess.get_directories_at(path):
		if _profile_has_password(path.path_join(directory)):
			return true
	return false


func _test_vault() -> void:
	_clear_user_files()
	var connection = _make(CONNECTION_SRC)
	var authority = _make(AUTHORITY_SRC)
	authority.connection = connection
	var manager: Node = _make(PLUGIN_MANAGER_SRC)
	manager.connection = connection
	manager.authority = authority
	root.add_child(manager)
	var host: Node = load(DOCKET_HOST_PATH).new()
	_made_nodes.append(host)
	root.add_child(host)
	host.start(manager, false)
	check("G: fake-backed hosted master is ready", await _wait(func() -> bool: return host.state == "ready"))
	var previous_dm = _so.docket_manager
	_so.docket_manager = null
	_so.docket_host = host
	var form = _vault_form()
	_write("user://docket_prefs.json", JSON.stringify({"vault_password": "legacy-untouched", "vault_password_hint": "legacy-hint"}))
	var before := FileAccess.get_file_as_bytes("user://docket_prefs.json")
	form._refresh_vault_status()
	check("G: hosted Preferences does not load legacy password/hint and labels session unlock",
		form._vault_hint.text.is_empty() and not form._vault_hint.editable
		and form.get_node("%SetVaultPasswordButton").text == "Unlock for Session"
		and not form._vault_confirm.get_parent().visible)
	_fill_vault(form, "wrong-password")
	await _submit_vault(form)
	check("G: wrong password visibly refuses and clears every credential widget",
		form._vault_message.text == "Vault unlock refused; check the existing vault password."
		and form._vault_password.text.is_empty() and form._vault_confirm.text.is_empty() and form._vault_hint.text.is_empty()
		and host._vault_session._password.is_empty())
	authority.initialized = false
	_fill_vault(form, VAULT_PASSWORD)
	await _submit_vault(form)
	check("G: an uninitialized vault visibly refuses without retaining the password",
		form._vault_message.text == "Vault refused: an initialized, readable existing vault is required."
		and host._vault_session._password.is_empty())
	authority.initialized = true
	_fill_vault(form, VAULT_PASSWORD)
	form._vault_confirm.text = ""
	await _submit_vault(form)
	check("G: correct single password privately unlocks the exact existing opening for this session",
		host.vault_status() == "Vault: unlocked for this session only (password kept in memory)."
		and host._vault_session._password == VAULT_PASSWORD
		and authority.private_methods.slice(-2) == ["vault_challenge", "vault_unlock"])
	check("G: successful hosted UI clears widgets and preserves existing plaintext preferences byte-for-byte",
		form._vault_password.text.is_empty() and form._vault_confirm.text.is_empty() and form._vault_hint.text.is_empty()
		and FileAccess.get_file_as_bytes("user://docket_prefs.json") == before)
	_fill_vault(form, "")
	await _submit_vault(form)
	check("G: empty hosted input refuses and clears the form",
		form._vault_message.text == "Enter a nonempty password." and form._vault_password.text.is_empty()
		and form._vault_confirm.text.is_empty() and form._vault_hint.text.is_empty())
	await host.unlock_vault(VAULT_PASSWORD)
	var settled_calls: int = authority.private_methods.size()
	connection.open_project("/p/vault-session.dct")
	manager.backend_tool_called.emit("docket", "docket_project_add")
	check("G: ordinary session project reconciliation preserves settled unlocked state without resending",
		await _wait(func() -> bool: return not host._reconciling)
		and host.vault_status().begins_with("Vault: unlocked") and authority.private_methods.size() == settled_calls)
	check("G: oversized UTF-8 input is refused locally", await host.unlock_vault("é".repeat(513)) == "Vault refused: enter a password of at most 1024 UTF-8 bytes.")
	# Hold old responses across each lifecycle boundary, never printing payloads.
	for method in ["vault_challenge", "vault_unlock"]:
		for boundary in ["process", "opening", "session"]:
			authority.hold = method
			authority.gate_open = false
			var entered: int = authority.entered
			var pending := _vault_attempt(host)
			check("H: held private request reached fake backend", await _wait(func() -> bool: return authority.entered > entered and authority.private_methods.back() == method))
			if boundary == "process":
				manager.plugin_stopped.emit("docket")
				connection.generation += 1
			elif boundary == "opening":
				connection.open[host.master_path].open_generation += "-reopened"
			else:
				host._session_changes += 1
			authority.gate_open = true
			check("H: held private request finishes", await _wait(func() -> bool: return pending.get("done", false)))
			check("H: stale %s after %s change cannot publish unlocked state" % [method, boundary],
				pending.get("message") == "Vault request expired; try again." and host._vault_session._unlocked.is_empty())
			authority.hold = ""
			if boundary == "process":
				manager.plugin_ready.emit("docket")
				check("H: restart automatically re-challenges retained password", await _wait(func() -> bool: return host.vault_status().begins_with("Vault: unlocked")))
	var retained: String = host._vault_session._password
	manager.plugin_crashed.emit("docket")
	check("I: child loss clears unlocked status but retains successful session credential",
		host._vault_session._unlocked.is_empty() and retained == VAULT_PASSWORD and host._vault_session._password == retained)
	var restarted = _make(CONNECTION_SRC)
	restarted.generation = 99
	manager.connection = restarted
	authority = _make(AUTHORITY_SRC)
	authority.connection = restarted
	manager.authority = authority
	var count: int = authority.private_methods.size()
	manager.plugin_ready.emit("docket")
	check("I: new connection and new authority receive automatic fresh challenge then resend",
		await _wait(func() -> bool: return host.vault_status().begins_with("Vault: unlocked"))
		and authority.private_methods.slice(count) == ["vault_challenge", "vault_unlock"])
	# A new opening seen by a real refresh also re-challenges automatically.
	count = authority.private_methods.size()
	restarted.open[host.master_path].open_generation += "-next"
	await host._refresh(restarted, restarted.generation)
	check("I: a new master opening automatically re-challenges before unlock",
		await _wait(func() -> bool: return host.vault_status().begins_with("Vault: unlocked"))
		and authority.private_methods.slice(count) == ["vault_challenge", "vault_unlock"])
	count = authority.private_methods.size()
	host._reconciling = true
	restarted.open[host.master_path].open_generation += "-busy"
	await host._refresh(restarted, restarted.generation)
	await process_frame
	check("I: a resume during reconciliation waits without losing the retained credential",
		authority.private_methods.size() == count and not host.vault_status().begins_with("Vault: unlocked")
		and host._vault_session._password == VAULT_PASSWORD)
	host._reconciling = false
	host._publish()
	check("I: settled publish re-arms a resume deferred by reconciliation",
		await _wait(func() -> bool: return host.vault_status().begins_with("Vault: unlocked"))
		and authority.private_methods.slice(count) == ["vault_challenge", "vault_unlock"])
	# A real reconcile publishes while a held unlock is still busy.
	authority.hold = "vault_unlock"
	authority.gate_open = false
	var busy_entered: int = authority.entered
	var busy_attempt := _vault_attempt(host)
	check("I: held unlock starts before actual session reconciliation",
		await _wait(func() -> bool: return authority.entered > busy_entered and authority.private_methods.back() == "vault_unlock"))
	restarted.open_project("/p/during-unlock.dct")
	manager.backend_tool_called.emit("docket", "docket_project_add")
	await process_frame
	authority.hold = ""
	authority.gate_open = true
	check("I: actual reconciliation expires held unlock while retaining the successful credential",
		await _wait(func() -> bool: return busy_attempt.get("done", false))
		and busy_attempt.get("message") == "Vault request expired; try again." and host._vault_session._password == VAULT_PASSWORD)
	check("I: publication during busy unlock eventually re-challenges retained credential",
		await _wait(func() -> bool: return host.vault_status().begins_with("Vault: unlocked")))
	var public_clean := not JSON.stringify(connection.public_calls + restarted.public_calls).contains(VAULT_PASSWORD)
	var history_clean := true
	for chat in _made_chats:
		for item in chat.HistoryItemList:
			history_clean = history_clean and not item.Message.contains(VAULT_PASSWORD)
	check("J: password absent from new profile/session/log files, public tool calls and chat history",
		not _profile_has_password("user://") and public_clean and history_clean)
	host._exit_tree()
	check("J: explicit host exit drops retained credential and unlocked references",
		host._vault_session._password.is_empty() and host._vault_session._unlocked.is_empty())
	_so.docket_manager = previous_dm
	var embedded = _vault_form()
	embedded._refresh_vault_status()
	check("J: embedded Preferences still loads the existing hint", embedded._vault_hint.text == "legacy-hint")
	_fill_vault(embedded, "embedded-password")
	await _submit_vault(embedded, false)
	check("J: embedded Preferences still persists its password and hint",
		UserPrefs.load_vault_password() == "embedded-password" and UserPrefs.load_vault_password_hint() == "embedded-password")


func _failed_paths(host) -> Array:
	var paths := []
	for failed in host.failed_projects():
		paths.append(failed.path)
	return paths


func _saved_session() -> Array:
	var data = JSON.parse_string(FileAccess.get_file_as_string("user://docket_host_session.json"))
	return Array(data.paths) if data is Dictionary and data.get("paths") is Array else []


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _clear_user_files() -> void:
	for path in USER_FILES:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
