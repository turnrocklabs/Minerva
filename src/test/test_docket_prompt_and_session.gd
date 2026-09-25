extends SceneTree
## Headless test of Minerva's side of the Docket plugin: the agent system
## prompt read from it, and the session DocketHost keeps there.
##
## Run only in a throwaway profile, made before Godot starts (the app's
## autoloads, the embedded Docket among them, use the profile before this
## script runs), from the repository root:
##   ( source scripts/lib/test-profile.sh && root="$(mktemp -d)" && seed_test_profile "$root" \
##     && MINERVA_TEST_PROFILE_ROOT="$root" timeout 300 \
##        "${GODOT:-godot}" --headless --path src --script test/test_docket_prompt_and_session.gd )
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
func host_request(name: String, params: Dictionary) -> Dictionary:
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

var _pass := 0
var _fail := 0
var _so: Node = null
var _host_render := preload("res://test/helpers/chat_host_render_fixture.gd").new()
## What the sections made, freed once both have run (an early return included).
var _made_nodes: Array[Node] = []
var _made_chats: Array = []
## The longest any wait here may take, in frames: a wait that runs out fails.
const MAX_FRAMES := 300


func _init() -> void:
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
