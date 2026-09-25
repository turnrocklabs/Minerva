extends SceneTree
## Headless test of plugin content seeding (PluginContentSeeding and its
## seeders) when the Docket plugin owns Minerva's projects: DocketHost is the
## owner, the embedded DocketManager set aside, and every seeding call goes
## through PluginSeedingDocket to the project it was bound to.
## - lifecycle: an install seeds skills in the master and knowledge in its
##   named project, every call naming its project; an update keeps a person's
##   customised skill and article and silently updates pristine knowledge; a
##   move to another project retires the old records and, once committed,
##   hands the person's article over to them there; an uninstall deletes
##   pristine records, keeps customised ones as the person's, leaves nothing
##   of the plugin's anywhere, and drops its cleanup record;
## - an interrupted update and its recovery: a change Docket made and then
##   answered with its own error stops the update with nothing more sent, and
##   is reported uncertain with its project file and its exact arguments; the
##   manager's recovery from the update's journal in staging, meeting a
##   failed save, narrows that journal on disk to the article's entry, and its
##   retry puts it back, sealed, over the update's text but never over a
##   person's later edit, leaving one record per key and no journal; a
##   removal journal that does not list the projects
##   it reached gets no Docket access at all; one whose project was closed
##   and another opened under its name does not touch that other file;
## - interruptions: a project reopened as another file under the same
##   selector while the update awaited Docket stops the update before it
##   writes to either file; a failed read stops it before any write; with
##   the plugin stopped, an install and an uninstall report their content
##   not done, reaching Docket not at all, and the uninstall keeps its
##   cleanup for later.
##
## Run only in a throwaway profile, made before Godot starts, from the
## repository root:
##   ( source scripts/lib/test-profile.sh && root="$(mktemp -d)" && seed_test_profile "$root" \
##     && MINERVA_TEST_PROFILE_ROOT="$root" timeout 300 \
##        "${GODOT:-godot}" --headless --path src --script test/test_plugin_owner_seeding.gd )
##
## REAL: PluginContentSeeding, PluginSkillSeeder, PluginKnowledgeSeeder,
## PluginSeedingDocket, DocketHost (setup, the fresh project list around every
## call, seeding_target, call_bound), PluginManager.remove_plugin and
## reconcile_recovered, PluginInstallTransaction's journals (in the profile's
## plugin staging), and the MCP result adapter's error normalisation (not the
## transport's isError envelope, left to a packaged Docket). FAKED (STORE_SRC
## and the doubles below): the Docket plugin's backend over in-memory items
## in open projects, where a flush can be made to fail, a query of a type to
## fail, one change to be made and then answered with Docket's error, and a
## hook can change the open projects after a call; its private channel; the
## plugin manager DocketHost is given; the plugin database; the plugin tool
## registry, set aside (the manager's recovery syncs a plugin's manifest tools
## there). Not covered: a
## real Docket process or package, or the consent dialog.

const USER_FILES := ["user://docket_host_session.json", "user://docket_host_session.json.new"]
const TXN_GD := "res://Scripts/Services/Plugins/PluginInstallTransaction.gd"
const PM_GD := "res://Scripts/Services/Plugins/PluginManager.gd"
const SEEDING_GD := "res://Scripts/Services/Plugins/PluginContentSeeding.gd"
const WORK_A := "/s4-test/work.dct"
const WORK_B := "/s4-test/work-b.dct"
const WORK_C := "/s4-test/work-c.dct"
const OTHER := "/s4-test/other.dct"

## The Docket plugin's backend over in-memory items, each in the project file
## at its `_path`; a call names its project by selector (`project`, absent
## for the master), resolved among `projects` when it is handled. `sent`
## lists every seeding call (not the project list, nor the calls DocketHost's
## setup makes, which it refuses), in order; `reached` counts all calls per
## tool. A flush of a selector in `failing_flush`, and a query of a
## type in `failing_query_types`, fail. `fail_after` ({tool, id, field}) makes
## the first matching change, then answers with Docket's error text as the
## MCP result adapter normalises it (`failed_at` is that call's index in
## `sent`). `after_call` runs after each call is handled.
const STORE_SRC := """
extends RefCounted
var generation := 1
var master := {"name": "master", "display_name": "Master", "path": "", "open_generation": "1"}
var projects := []
var items := {}
var sent := []
var reached := {}
var failing_flush := []
var failing_query_types := []
var fail_after := {}
var failed_at := -1
var after_call := Callable()
var next_id := 100
func process_generation() -> int:
	return generation
func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	reached[tool] = reached.get(tool, 0) + 1
	var answer := _handle(tool, arguments)
	if after_call.is_valid():
		after_call.call(tool, arguments)
	return answer
func _handle(tool: String, arguments: Dictionary) -> Dictionary:
	if tool == "docket_project_list":
		return {"success": true, "projects": projects.duplicate(true)}
	if not tool in ["docket_flush", "docket_query", "docket_get", "docket_create", "docket_update",
			"docket_transition", "docket_delete"]:
		return {"success": false, "error": "unexpected tool %s" % tool}
	sent.append([tool, arguments.duplicate(true)])
	var selector := str(arguments.get("project", "master"))
	var path := ""
	for project in projects:
		if project.name == selector:
			path = project.path
	if path.is_empty():
		return {"success": false, "error": "Unknown project: %s" % selector}
	var id := str(arguments.get("id", ""))
	var here: bool = items.has(id) and items[id]._path == path
	match tool:
		"docket_flush":
			if selector in failing_flush:
				return {"success": false, "error": "could not write %s" % selector, "failed": [selector]}
			return {"success": true, "flushed": [selector]}
		"docket_query":
			var filter: Dictionary = arguments.get("filter", {})
			if str(filter.get("type", "")) in failing_query_types:
				return {"success": false, "error": "the query failed"}
			var found := []
			for item in items.values():
				if item._path == path and filter.keys().all(func(field) -> bool: return item.get(field) == filter[field]):
					found.append({"id": item.id, "type": item.type})
			return {"success": true, "items": found}
		"docket_get":
			return items[id].merged({"success": true}) if here else {"success": false, "error": "Item not found: %s" % id}
		"docket_create":
			next_id += 1
			id = "019f0000aaaabbbbccccddddeee%05d" % next_id
			var created := arguments.duplicate(true)
			created.erase("project")
			created.merge({"id": id, "status": "draft", "_path": path}, true)
			items[id] = created
			return {"success": true, "id": id, "status": "draft", "title": str(created.get("title", ""))}
	if not here:
		return {"success": false, "error": "Item not found: %s" % id}
	match tool:
		"docket_update":
			for key in arguments:
				if not key in ["id", "project"]:
					items[id][key] = arguments[key]
		"docket_transition":
			items[id].status = str(arguments.get("to", ""))
		"docket_delete":
			items.erase(id)
	if fail_after.get("tool") == tool and fail_after.get("id") == id and arguments.has(fail_after.get("field")):
		fail_after = {}
		failed_at = sent.size() - 1
		return MCPToolResultAdapter.normalize_application_error({"text": "Docket could not finish the change", "success": false})
	return {"success": true, "id": id}
"""

## The plugin's private channel: the schema is accepted, the master installed.
const AUTHORITY_SRC := """
extends RefCounted
var store = null
func host_request(name: String, params: Dictionary) -> Dictionary:
	if name == "declare_schema":
		return {"result": {"version": params.version}}
	store.master.path = str(params.path)
	return {"result": {"status": "installed", "path": params.path, "project": store.master,
		"conflicts": [], "capability_gaps": []}}
"""

## The plugin manager DocketHost is given.
const HOST_MANAGER_SRC := """
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
	return {"running": connection != null}
func set_backend_tool_guard(_id: String, _guard: Callable) -> void:
	pass
"""


## The plugin database PluginManager reads: definitions by id.
class MemoryDB extends RefCounted:
	var plugins := {}

	func add(def) -> void:
		plugins[def.id] = def

	func has_plugin(id: String) -> bool:
		return plugins.has(id)

	func get_by_id(id: String):
		return plugins.get(id)

	func get_all() -> Array:
		return plugins.values()

	func remove(id: String) -> bool:
		return plugins.erase(id)

	func is_stale() -> bool:
		return false


var _pass := 0
var _fail := 0
var _so: Node = null
var _made: Array[Node] = []
var _store = null
var _host = null
var _host_manager = null
var _db: MemoryDB = null
var _pm = null
var _staging := ""
## PluginContentSeeding, loaded once the autoloads it reads are up.
var Seeding = null
## The longest any wait here may take, in frames: a wait that runs out fails.
const MAX_FRAMES := 300


func _init() -> void:
	print("=== Plugin content seeding under the Docket plugin ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail = "") -> bool:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		print("FAIL: %s%s" % [label, ("  — " + str(detail)) if str(detail) else ""])
	return ok


func _make(source: String):
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		check("a test double compiles", false, source.left(80))
		return null
	var made = script.new()
	if made is Node:
		_made.append(made)
	return made


func _wait(ready: Callable) -> bool:
	for frame in MAX_FRAMES:
		if ready.call():
			return true
		await process_frame
	return ready.call()


func _run() -> void:
	await process_frame
	_so = root.get_node_or_null("/root/SingletonObject")
	if not check("the SingletonObject autoload is live", _so != null):
		return
	var profile := OS.get_environment("MINERVA_TEST_PROFILE_ROOT")
	var user_dir := OS.get_user_data_dir()
	if profile.is_empty() or not user_dir.begins_with(profile.trim_suffix("/") + "/"):
		check("Godot's user directory is in the throwaway profile (see the header)", false, user_dir)
		return
	Seeding = load(SEEDING_GD)
	_staging = ProjectSettings.globalize_path(MarketplaceClient.STAGING_DIR)
	if not check("the throwaway profile holds no pending plugin content yet",
			load(TXN_GD).content_pending(_staging).is_empty()):
		return
	for path in USER_FILES:
		if not check("the throwaway profile holds no %s yet" % path, not FileAccess.file_exists(path)):
			return
	var saved_manager = _so.docket_manager
	var saved_host = _so.docket_host
	var saved_registry = _so.plugin_tool_registry
	_so.plugin_tool_registry = null
	if await _set_up():
		await _test_lifecycle()
		await _test_interrupted_update()
		await _test_interruptions()
	_so.docket_manager = saved_manager
	_so.docket_host = saved_host
	_so.plugin_tool_registry = saved_registry
	if _pm != null:
		_pm.free()
	for node in _made:
		if is_instance_valid(node):
			node.queue_free()
	for path in USER_FILES:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# The plugin as owner (DocketHost over the store), with the master, the
# Work project (at WORK_A) and Other open, and a PluginManager over MemoryDB.
func _set_up() -> bool:
	_store = _make(STORE_SRC)
	var authority = _make(AUTHORITY_SRC)
	_host_manager = _make(HOST_MANAGER_SRC)
	_host = _make("extends \"res://Scripts/Services/DocketHost/DocketHost.gd\"")
	if _store == null or authority == null or _host_manager == null or _host == null:
		return false
	_store.projects = [_store.master, _project("work", WORK_A), _project("other", OTHER, "Other")]
	authority.store = _store
	_host_manager.connection = _store
	_host_manager.authority = authority
	root.add_child(_host_manager)
	root.add_child(_host)
	_so.docket_manager = null
	_so.docket_host = _host
	_host.start(_host_manager, false)
	_host_manager.plugin_ready.emit("docket")
	var ready := await _wait(func(): return _host.state in ["ready", "degraded"])
	if not check("DocketHost sets up the plugin as the owner", ready, "%s %s" % [_host.state, _host.problems]):
		return false
	_db = MemoryDB.new()
	_pm = load(PM_GD).new()
	_pm._db = _db
	return true


func _project(selector: String, path: String, display := "Work", opening := "1") -> Dictionary:
	return {"name": selector, "display_name": display, "path": path, "open_generation": opening}


func _def(id: String, version: String, knowledge_project: String, skill_steps: String,
		article: String, tip: String) -> PluginDefinition:
	var manifest := {"id": id, "name": id, "version": version,
		"backend": {"transport": "stdio", "entrypoint": "x"}, "ui": {"panels": [], "ipc_messages": []},
		"tools": [], "skills": [], "knowledge_project": knowledge_project,
		"knowledge": [
			{"key": "minerva_%s_guide" % id, "type": "kb", "title": "Guide", "article": article},
			{"key": "minerva_%s_tip" % id, "type": "hint", "title": "Tip", "value": tip}]}
	if not skill_steps.is_empty():
		manifest.skills = [{"id": "minerva_%s_note" % id, "title": "Take a note", "summary": "Notes",
			"system_prompt": "You take notes.", "outcome": "A note", "preconditions": "", "steps": skill_steps,
			"tool_deps": [], "target": "all", "optimization": {}}]
	return PluginDefinition.from_dict(manifest)


## The store's record of `id`'s manifest `key` in the project file at `path`
## ("" for any), or {}.
func _record(key: String, path := "") -> Dictionary:
	for item in _store.items.values():
		if item.get("key") == key and (path.is_empty() or item._path == path):
			return item
	return {}


func _records_of(plugin_id: String) -> Array:
	return _store.items.values().filter(func(item) -> bool: return item.get("source") == "plugin:" + plugin_id)


func _pending(plugin_id: String) -> Array:
	return load(TXN_GD).content_pending(_staging).filter(func(entry) -> bool: return entry.id == plugin_id)


func _journal_dir(name: String) -> String:
	return ProjectSettings.globalize_path("user://s4-journals").path_join(name)


# ---------------------------------------------------------------------------

func _test_lifecycle() -> void:
	print("\n-- lifecycle: install, update, move, uninstall --")
	var id := "seedlife"
	var v1 := _def(id, "1.0.0", "Work", "1. v1", "guide v1", "tip v1")
	_db.add(v1)
	var start: int = _store.sent.size()
	var installed: Dictionary = await Seeding.seed_install(_pm, v1, true, {})
	var sent: Array = _store.sent.slice(start)
	var skill := _record("minerva_seedlife_note", _store.master.path)
	var guide := _record("minerva_seedlife_guide", WORK_A)
	check("an install seeds the skill in the master and the knowledge in Work, sealed, completely",
		Seeding.complete(installed) and installed.get("skills_seeded") == 1
		and installed.get("knowledge", {}).get("seeded") == 2 and skill.get("status") == "active"
		and guide.get("status") == "active" and not _record("minerva_seedlife_tip", WORK_A).is_empty()
		and guide.get("pristine_hash") == PluginKnowledgeSeeder.content_hash(guide), [installed, guide])
	check("every seeding call named its project, the master's flush included",
		sent.all(func(call) -> bool: return not str(call[1].get("project", "")).is_empty())
		and sent.any(func(call) -> bool: return call[0] == "docket_flush" and call[1].project == "master")
		and sent.any(func(call) -> bool: return call[0] == "docket_flush" and call[1].project == "work"), sent)

	# A person customises the skill and the article.
	skill.merge({"customised": true, "steps": "my steps"}, true)
	guide.article = "MY GUIDE"
	var v2 := _def(id, "2.0.0", "Work", "1. v2", "guide v2", "tip v2")
	_db.add(v2)
	var updated: Dictionary = await Seeding.reconcile(_pm, v1, v2,
		{"collected": true, "update_decisions": {}}, false)
	check("an update the person declined keeps their skill and article, and updates the pristine tip",
		not updated.has("content_incomplete") and updated.get("reconcile", {}).get("prompted_declined") == 1
		and updated.get("knowledge", {}).get("prompted_declined") == 1
		and updated.get("knowledge", {}).get("silent_updated") == 1 and skill.steps == "my steps"
		and guide.article == "MY GUIDE" and _record("minerva_seedlife_tip", WORK_A).get("value") == "tip v2", updated)

	var v3 := _def(id, "3.0.0", "Other", "1. v2", "guide v2", "tip v2")
	_db.add(v3)
	var journal_dir := _journal_dir("op_move")
	var moved: Dictionary = await Seeding.reconcile(_pm, v2, v3,
		{"collected": true, "update_decisions": {}, "journal_dir": journal_dir}, false)
	check("a move retires Work's records and seeds Other's",
		not moved.has("content_incomplete") and moved.get("knowledge_retired", {}).get("retired") == 2
		and moved.get("knowledge", {}).get("seeded") == 2 and guide.get("deprecated") == true
		and _record("minerva_seedlife_guide", OTHER).get("status") == "active", moved)
	var journal: Dictionary = load(TXN_GD).content_journal(journal_dir)
	var committed: String = await Seeding.content_committed_problem(journal)
	check("once the move commits, Work keeps only the person's article, live and theirs",
		committed.is_empty() and _record("minerva_seedlife_tip", WORK_A).is_empty()
		and guide.get("source") == "user" and guide.article == "MY GUIDE" and guide.get("deprecated") == false,
		[committed, guide])
	load(TXN_GD).content_done(load(TXN_GD).content_path(journal_dir))

	var removed: Dictionary = await _pm.remove_plugin(id)
	check("an uninstall completes: nothing of the plugin's is left, its cleanup record is gone",
		removed.get("ok", false) and Seeding.complete(removed) and _records_of(id).is_empty()
		and _pending(id).is_empty() and not _db.has_plugin(id), removed)
	check("the person's skill and article stay, as theirs",
		skill.get("source") == "user" and skill.steps == "my steps"
		and _store.items.has(guide.id) and guide.article == "MY GUIDE", [skill, guide])


func _test_interrupted_update() -> void:
	print("\n-- an interrupted update and its recovery --")
	var id := "seedfix"
	var v1 := _def(id, "1.0.0", "Work", "", "fix v1", "tipfix v1")
	_db.add(v1)
	var installed: Dictionary = await Seeding.seed_install(_pm, v1, true, {})
	var guide := _record("minerva_seedfix_guide", WORK_A)
	var tip := _record("minerva_seedfix_tip", WORK_A)
	if not check("the plugin's knowledge is seeded", Seeding.complete(installed)
			and not guide.is_empty() and not tip.is_empty(), installed):
		return
	# The records as seeded (key, id, file, source), and the article's seal.
	var seeded := [["minerva_seedfix_guide", guide.id, WORK_A, "plugin:seedfix"],
		["minerva_seedfix_tip", tip.id, WORK_A, "plugin:seedfix"]]
	var v1_seal: String = guide.pristine_hash

	# Docket makes the article's change, then answers it with its own error.
	# Its journal is saved in staging as an ended install operation leaves it
	# (no operation directory), for the manager's recovery.
	var v2 := _def(id, "2.0.0", "Work", "", "fix v2", "tipfix v2")
	_store.fail_after = {"tool": "docket_update", "id": guide.id, "field": "article"}
	var updated: Dictionary = await Seeding.reconcile(_pm, v1, v2, {"journal_dir": _staging.path_join("op_fix")}, true)
	var uncertain: Array = updated.get("content_uncertain", [])
	var original := {"id": guide.id, "project": "Work", "title": "Guide", "article": "fix v2", "summary": "",
		"topic": "", "tags": [], "pristine_content": v2.knowledge[0], "deprecated": false}
	var translated := original.duplicate(true)
	translated.project = "work"
	check("a change answered with Docket's error is uncertain, as it was asked: the update stops, visibly",
		not updated.get("content_incomplete", "").is_empty() and uncertain.size() == 1
		and uncertain[0] == {"tool": "docket_update", "arguments": original, "project_path": WORK_A}, updated)
	var failed_at: int = _store.failed_at
	check("that change was sent once, under Work's selector, and nothing after it; Docket did make it",
		failed_at >= 0 and _store.sent.size() == failed_at + 1 and _store.sent[failed_at] == ["docket_update", translated]
		and guide.article == "fix v2" and tip.value == "tipfix v1",
		[_store.sent.slice(max(failed_at, 0)), guide.article, tip.value])

	# v1 is installed again; the person edits the tip, and Work cannot be
	# saved at first.
	tip.value = "MY TIP"
	_store.failing_flush = ["work"]
	await _pm.reconcile_recovered()
	_store.failing_flush = []
	var waiting := _pending(id)
	# The article's entry as the update saved it: its text before (with its
	# seal) and the text the update was writing.
	var guide_entry := {"id": guide.id, "type": "kb", "accepted": false, "project": "Work",
		"fields": {"title": "Guide", "article": "fix v1", "summary": "", "topic": "", "tags": [],
			"pristine_hash": v1_seal, "pristine_content": v1.knowledge[0]},
		"after": {"title": "Guide", "article": "fix v2", "summary": "", "topic": "", "tags": []}}
	check("the manager's recovery that cannot save Work keeps the journal, narrowed on disk to the article's entry",
		waiting.size() == 1 and waiting[0].path == _staging.path_join("content-pending/op_fix.json")
		and "did not confirm" in waiting[0].reason and waiting[0].journal.get("entries") == [guide_entry]
		and waiting[0].journal.get("paths") == {"": _store.master.path, "Work": WORK_A}, waiting)
	await _pm.reconcile_recovered()
	var fixture: Array = []
	for item in _store.items.values():
		if item.get("key") in ["minerva_seedfix_guide", "minerva_seedfix_tip"]:
			fixture.append([item.key, item.id, item._path, item.get("source")])
	check("its retry puts the article back, sealed, keeps the person's tip; the records are those seeded, no journal",
		_pending(id).is_empty() and fixture.size() == seeded.size() and seeded.all(func(row) -> bool: return row in fixture)
		and guide.article == "fix v1" and guide.get("pristine_hash") == v1_seal and v1_seal == PluginKnowledgeSeeder.content_hash(guide)
		and tip.value == "MY TIP", [_pending(id), fixture])

	# A removal journal from before removals listed their open projects.
	var legacy: String = _staging.path_join(load(TXN_GD).CONTENT_PENDING).path_join("removed_seedgone_1.json")
	DirAccess.make_dir_recursive_absolute(legacy.get_base_dir())
	load(TXN_GD).requeue_content(legacy, "seedgone", {"paths": {"": _store.master.path}}, false, "")
	var reached_before: Dictionary = _store.reached.duplicate()
	await _pm.reconcile_recovered()
	var legacy_waiting := _pending("seedgone")
	check("a removal journal that does not list its projects gets no Docket access and stays pending",
		_store.reached == reached_before and legacy_waiting.size() == 1 and "project files" in legacy_waiting[0].reason,
		[_store.reached, legacy_waiting])
	load(TXN_GD).content_done(legacy)

	# An uninstall that cannot save Work leaves its cleanup; Work is then
	# closed and another file opened under its name, holding the plugin's
	# records too.
	_store.failing_flush = ["work"]
	var removed: Dictionary = await _pm.remove_plugin(id)
	_store.failing_flush = []
	if not check("an uninstall that cannot save Work keeps its cleanup, marked as a removal",
			removed.get("ok", false) and not Seeding.complete(removed) and _pending(id).size() == 1
			and _pending(id)[0].journal.get("removal") == true, removed):
		return
	_store.projects = [_store.master, _project("work2", WORK_B), _project("other", OTHER, "Other")]
	var copy := {"id": "019f0000aaaabbbbccccddddeee09999", "type": "kb", "key": "minerva_seedfix_guide",
		"title": "Guide", "article": "B's copy", "source": "plugin:seedfix", "status": "active", "_path": WORK_B}
	copy["pristine_hash"] = PluginKnowledgeSeeder.content_hash(copy)
	_store.items[copy.id] = copy
	var sent_before: int = _store.sent.size()
	await _pm.reconcile_recovered()
	check("its retry never touches the file now named Work; the cleanup stays, Work's file not open",
		_store.items.has(copy.id) and copy.article == "B's copy" and _pending(id).size() == 1
		and "Docket project 'Work' is not open" in _pending(id)[0].reason
		and _store.sent.slice(sent_before).all(func(call) -> bool: return call[1].get("project") != "work2"),
		[_pending(id), _store.sent.slice(sent_before)])
	load(TXN_GD).content_done(_pending(id)[0].path)
	_store.items.erase(copy.id)


func _test_interruptions() -> void:
	print("\n-- interruptions: a rebind, a failed read, the plugin stopped --")
	var id := "seedwait"
	_store.projects = [_store.master, _project("work", WORK_A, "Work", "2"), _project("other", OTHER, "Other")]
	var v1 := _def(id, "1.0.0", "Work", "", "wait v1", "tipwait v1")
	_db.add(v1)
	var installed: Dictionary = await Seeding.seed_install(_pm, v1, true, {})
	var guide := _record("minerva_seedwait_guide", WORK_A)
	if not check("the plugin's knowledge is seeded in Work", Seeding.complete(installed)
			and not guide.is_empty(), installed):
		return

	# While the update awaits the master's save, Work closes and another file
	# opens under the same selector.
	var v2 := _def(id, "2.0.0", "Work", "", "wait v2", "tipwait v2")
	var rebound := [-1]
	_store.after_call = func(tool: String, arguments: Dictionary) -> void:
		if rebound[0] < 0 and tool == "docket_flush" and arguments.get("project") == "master":
			rebound[0] = _store.sent.size()
			_store.projects = [_store.master, _project("work", WORK_C), _project("other", OTHER, "Other")]
	var updated: Dictionary = await Seeding.reconcile(_pm, v1, v2, {}, true)
	_store.after_call = Callable()
	check("a project reopened as another file stops the update before it writes to either",
		rebound[0] >= 0 and not updated.get("content_incomplete", "").is_empty()
		and updated.get("content_uncertain", []).is_empty() and guide.article == "wait v1"
		and _store.sent.size() == rebound[0]
		and _store.items.values().all(func(item) -> bool: return item._path != WORK_C), [updated, rebound])

	_store.projects = [_store.master, _project("work", WORK_A, "Work", "3"), _project("other", OTHER, "Other")]
	_store.failing_query_types = ["hint"]
	var sent_before: int = _store.sent.size()
	var unread: Dictionary = await Seeding.reconcile(_pm, v1, v2, {}, true)
	_store.failing_query_types = []
	check("a failed read stops the update before any write",
		"could not be read" in unread.get("content_incomplete", "") and _store.sent.slice(sent_before).all(
			func(call) -> bool: return call[0] in ["docket_query", "docket_get"]), unread)

	_host_manager.connection = null
	_host_manager.plugin_stopped.emit("docket")
	var reached_before: Dictionary = _store.reached.duplicate()
	var other := _def("seedlate", "1.0.0", "Work", "", "late", "late tip")
	var skipped: Dictionary = await Seeding.seed_install(_pm, other, true, {})
	var removed: Dictionary = await _pm.remove_plugin(id)
	var waiting := _pending(id)
	check("with the plugin stopped, an install and an uninstall say their content was not done",
		"unavailable" in skipped.get("content_skipped", "") and removed.get("ok", false)
		and "unavailable" in removed.get("content_skipped", ""), [skipped, removed])
	check("neither reached Docket, and the uninstall keeps its cleanup, its open projects unknown",
		_store.reached == reached_before and waiting.size() == 1 and waiting[0].journal.get("enumerated") == null,
		waiting)
	for entry in waiting:
		load(TXN_GD).content_done(entry.path)
