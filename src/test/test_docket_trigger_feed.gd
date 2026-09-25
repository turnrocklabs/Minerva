extends SceneTree
## Headless test of Docket triggers (DOCKET_POLL) under the Docket plugin,
## the embedded DocketManager set aside: item_changed events enter as stdio
## frames the Docket plugin's connection reads (MCPServerConnection's own
## reading and validation), reach the event broker, the feed and the trigger
## manager, whose triggers:
## - fire for the described change of an item as DocketManager signalled it
##   (created with its type, transitioned with both states, updated,
##   comment_added), with their project, item type (created only) and
##   parent filters and message as before; a deleted item reads as none;
##   an undescribed change fires nothing;
## - are bound once to one project's path, by selector, by display name, or
##   "master"; a name two open projects share binds to neither;
## - do not fire, and say why, when the item cannot be read, its project
##   was read again from its file while it was, or the event's opening is
##   no longer the one open (a delete included) or no longer the one the
##   plugin's own list gives its selector to; such a failure stays shown as
##   the last interruption after the next change fires; a repeated event
##   fires once; a gap, a late event, a frame the connection refuses and the
##   plugin stopping or restarting are shown as interruptions.
##
## Run only in a throwaway profile, made before Godot starts, from the
## repository root:
##   ( source scripts/lib/test-profile.sh && root="$(mktemp -d)" && seed_test_profile "$root" \
##     && MINERVA_TEST_PROFILE_ROOT="$root" timeout 300 \
##        "${GODOT:-godot}" --headless --path src --script test/test_docket_trigger_feed.gd )
## The connection validates each frame's numbers with the JSON Schema helper
## (res://bin/minerva-json-schema-helper); without it every event is dropped.
##
## REAL: MCPServerConnection's reading of stdio frames and their validation,
## PluginEventBroker, DocketTriggerFeed, TriggerManager's Docket filters and
## message, DocketHost.item_for_trigger. FAKED: the plugin's stdout (a
## pipe of scripted lines), its answers to docket_get (from `items`) and
## docket_project_list (from `listed`), the
## plugin manager, DocketHost's view of the open projects (set, not set up),
## and a trigger's firing (recorded, not spawned).

const DEF_PATH := "res://Scripts/Services/Agents/TriggerDefinition.gd"
const BROKER_PATH := "res://Scripts/Services/Plugins/PluginEventBroker.gd"
const PROFILE_PATH := "res://Scripts/Services/MCP/MCPProfile.gd"

const MASTER := {"name": "minerva-master", "display_name": "Minerva", "path": "/b10g-test/master.dct", "open_generation": "11"}
const WORK := {"name": "work", "display_name": "Work Items", "path": "/b10g-test/work.dct", "open_generation": "12"}
const SAME_A := {"name": "same", "display_name": "Same", "path": "/b10g-test/same-a.dct", "open_generation": "13"}
const SAME_B := {"name": "same~2", "display_name": "Same", "path": "/b10g-test/same-b.dct", "open_generation": "14"}
const BUG := "019f0000aaaabbbbccccddddeeee1001"
const TASK := "019f0000aaaabbbbccccddddeeee1002"
const NOTE := "019f0000aaaabbbbccccddddeeee1003"
const GONE := "019f0000aaaabbbbccccddddeeee1004"
const PARENT := "work:019f0000aaaabbbbccccddddeeee1000"

## The plugin's stdout: scripted lines, read as a process's would be.
const PIPE_SRC := """
extends RefCounted
var lines: Array[String] = []
func is_running() -> bool:
	return true
func has_output() -> bool:
	return not lines.is_empty()
func read_line() -> String:
	return lines.pop_front()
"""

## The plugin's connection: stdio frames are read by MCPServerConnection
## itself; docket_project_list is answered from `listed`, docket_get from
## `items` ("selector/id" -> item), counted in `reads` and held while `hold`
## is set.
const WIRE_SRC := """
extends "res://Scripts/Services/MCP/MCPServerConnection.gd"
signal released
var items := {}
var listed: Array = []
var reads := 0
var hold := false
func call_tool(tool_name: String, arguments: Dictionary, _timeout_sec: float = 120.0) -> Dictionary:
	await Engine.get_main_loop().process_frame
	if tool_name == "docket_project_list":
		return {"projects": listed.duplicate(true)}
	reads += 1
	if hold:
		await released
	var key := "%s/%s" % [arguments.get("project", ""), arguments.get("id", "")]
	if tool_name != "docket_get" or not items.has(key):
		return {"error": "Item not found: %s" % arguments.get("id", "")}
	return items[key].duplicate(true)
"""

## The plugin manager, answering with that connection.
const PLUGINS_SRC := """
extends "res://Scripts/Services/Plugins/PluginManager.gd"
var connection = null
func get_connection(_id: String) -> MCPServerConnection:
	return connection
"""

## Records each fire and its message instead of spawning an agent.
const MANAGER_SRC := """
extends "res://Scripts/Services/Agents/TriggerManager.gd"
var fired: Array = []
func _fire_trigger(trigger_id: String, _context: Dictionary = {}, _chain_visited: Dictionary = {}, _force: bool = false) -> bool:
	fired.append([trigger_id, get_trigger(trigger_id).initial_message])
	return true
"""

var _pass := 0
var _fail := 0
var _so: Node = null
var _made: Array[Node] = []
var _wire = null
var _manager = null
var _host = null
var _plugins = null
var _stream := "stream-one"
# Frames sent, and frames that reached the broker or were dropped.
var _sent := 0
var _arrived := 0
## The longest any wait here may take, in frames: a wait that runs out fails.
const MAX_FRAMES := 300


func _init() -> void:
	print("=== Docket trigger feed ===\n")
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
		_made.append(made)
	return made


## Waits until `ready` holds, at most MAX_FRAMES frames: whether it held.
func _wait(ready: Callable) -> bool:
	for frame in MAX_FRAMES:
		if ready.call():
			return true
		await process_frame
	return ready.call()


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
	var saved := {"docket_manager": _so.docket_manager, "docket_host": _so.docket_host,
		"plugin_manager": _so.plugin_manager, "plugin_event_broker": _so.plugin_event_broker}
	if _set_up():
		await _test_changes()
		await _test_stream()
	for key in saved:
		_so.set(key, saved[key])
	if _wire != null:
		_wire._subprocess = null
	for node in _made:
		if is_instance_valid(node):
			node.queue_free()


# The Docket plugin as owner: its connection (reading the pipe), the broker,
# DocketHost with four projects open (two named "Same"), and a trigger
# manager with five Docket triggers.
func _set_up() -> bool:
	var pipe = _make(PIPE_SRC)
	_wire = _make(WIRE_SRC)
	_plugins = _make(PLUGINS_SRC)
	_host = _make("extends \"res://Scripts/Services/DocketHost/DocketHost.gd\"")
	var broker = load(BROKER_PATH).new()
	if pipe == null or _wire == null or _plugins == null or _host == null:
		return false
	_wire.plugin_id = "docket"
	_wire.event_broker = broker
	_wire._subprocess = pipe
	_wire.protocol_profile = load(PROFILE_PATH).legacy("2025-03-26", {}, _wire.process_generation())
	_wire.items = {
		"work/" + BUG: {"id": BUG, "type": "bug", "title": "Crash", "status": "new", "tags": ["urgent"]},
		"work/" + TASK: {"id": TASK, "type": "task", "title": "Chore", "status": "open", "parent": PARENT},
		"minerva-master/" + NOTE: {"id": NOTE, "type": "kb", "title": "Note", "status": "active"},
	}
	_wire.listed = [MASTER, WORK, SAME_A, SAME_B]
	_plugins.connection = _wire
	_host._plugin_manager = _plugins
	_host._connection = _wire
	_host._generation = _wire.process_generation()
	_host.projects = [MASTER, WORK, SAME_A, SAME_B]
	_host.master_path = MASTER.path
	_host.state = "ready"
	broker.plugin_event.connect(func(_p, _e, _payload): _arrived += 1)
	broker.plugin_event_dropped.connect(func(_p, _reason): _arrived += 1)
	_so.docket_manager = null
	_so.docket_host = _host
	_so.plugin_manager = _plugins
	_so.plugin_event_broker = broker
	_manager = _make(MANAGER_SRC)
	if _manager == null:
		return false
	root.add_child(_manager)
	var def = load(DEF_PATH)
	for spec in [["all", "", {}], ["bugs", "work", {"docket_filter_types": "bug"}],
			["child", "work items", {"docket_filter_parent": PARENT}], ["same", "same", {}], ["master", "master", {}]]:
		var trig = def.new(spec[0])
		trig.name = spec[0]
		trig.trigger_type = def.TriggerType.DOCKET_POLL
		trig.docket_project = spec[1]
		trig.enabled = true
		for key in spec[2]:
			trig.set(key, spec[2][key])
		_manager.add_trigger(trig)
	return true


func _event(sequence: int, project: Dictionary, id: String, event: String, baseline: Dictionary = {}) -> Dictionary:
	var payload := {"project": project.name, "project_path": project.path, "open_generation": project.open_generation,
		"id": id, "change": event, "event": event, "cause": "external_reload" if event == "reloaded" else "mutation",
		"origin": "", "operation_id": "", "stream": _stream, "sequence": sequence}
	if not baseline.is_empty():
		payload["baseline"] = baseline
	return payload


func _frame(payload: Dictionary, jsonrpc: String = "2.0") -> String:
	return JSON.stringify({"jsonrpc": jsonrpc, "method": "minerva/plugin_event",
		"params": {"event": "item_changed", "payload": payload}})


# Sends `lines` as the plugin's stdout and waits until each has reached the
# broker (or was dropped) and the feed has handled what it queued: the fires
# made meanwhile, sorted by trigger.
func _send(lines: Array) -> Array:
	_manager.fired.clear()
	for line in lines:
		_wire._subprocess.lines.append(line)
	_sent += lines.size()
	_wire._drain_stdout()
	var feed = _manager.docket_feed
	var settled := await _wait(func(): return _arrived == _sent and not feed._working and feed._queue.is_empty())
	check("the frames are read and handled in time", settled, "%d of %d arrived" % [_arrived, _sent])
	var fired: Array = _manager.fired.duplicate()
	fired.sort_custom(func(a, b): return str(a[0]) < str(b[0]))
	return fired


func _ids(fired: Array) -> Array:
	return fired.map(func(entry): return entry[0])


func _message(fired: Array, id: String) -> String:
	for entry in fired:
		if entry[0] == id:
			return str(entry[1])
	return ""


func _status(id: String) -> Dictionary:
	return _manager.docket_feed.status(id)


func _test_changes() -> void:
	var fired := await _send([_frame(_event(1, WORK, BUG, "created", {"kind": "created", "item_type": "bug"}))])
	check("a created bug fires the any-project and the bug triggers, with its type and title",
		_ids(fired) == ["all", "bugs"] and _message(fired, "bugs").contains("Docket event in project 'work'")
		and _message(fired, "bugs").contains("New bug created: 'Crash' (id: %s)" % BUG), str(fired))
	check("names bind once to one project's path: by selector, by display name, 'master' to the master",
		[_manager.get_trigger("bugs").docket_project_path, _manager.get_trigger("child").docket_project_path,
		_manager.get_trigger("master").docket_project_path] == [WORK.path, WORK.path, MASTER.path])
	check("a name two open projects share binds to neither and says so",
		_manager.get_trigger("same").docket_project_path == "" and str(_status("same").problem).contains("2 open projects"),
		str(_status("same")))

	fired = await _send([_frame(_event(2, WORK, TASK, "created", {"kind": "created", "item_type": "task"}))])
	check("a created task passes the parent filter, not the bug type filter", _ids(fired) == ["all", "child"], str(fired))
	fired = await _send([_frame(_event(3, WORK, TASK, "typed_update", {"kind": "updated"}))])
	check("an update fires the bug trigger too: the type filter applies to created items only",
		_ids(fired) == ["all", "bugs", "child"] and _message(fired, "all").contains("'Chore' updated (status: open, id: %s)" % TASK), str(fired))
	fired = await _send([_frame(_event(4, WORK, BUG, "transition", {"kind": "transitioned", "from_status": "new", "to_status": "triaged"}))])
	check("a transition names both states", _ids(fired) == ["all", "bugs"]
		and _message(fired, "bugs").contains("'Crash' transitioned: new → triaged"), str(fired))
	fired = await _send([_frame(_event(5, WORK, TASK, "references_updated"))])
	check("an undescribed change fires nothing", fired.is_empty(), str(fired))
	fired = await _send([_frame(_event(6, MASTER, NOTE, "comment_added", {"kind": "comment_added"}))])
	check("a comment in the master fires the master trigger", _ids(fired) == ["all", "master"]
		and _message(fired, "master").contains("New comment on 'Note'"), str(fired))

	var reads: int = _wire.reads
	fired = await _send([_frame(_event(7, WORK, TASK, "deleted", {"kind": "updated"}))])
	check("a deleted item is not read and reads as none: the parent filter fails and the id stands for its title",
		_wire.reads == reads and _ids(fired) == ["all", "bugs"]
		and _message(fired, "all").contains("'%s' updated (status: , id: %s)" % [TASK, TASK]), str(fired))
	fired = await _send([_frame(_event(8, WORK, GONE, "typed_update", {"kind": "updated"}))])
	check("an item that cannot be read fires nothing and says why",
		fired.is_empty() and str(_status("all").problem).contains("could not be read"), str(_status("all")))
	fired = await _send([_frame(_event(9, WORK, BUG, "typed_update", {"kind": "updated"}))])
	check("the next change handled clears the problem, and the failure stays shown as the last interruption",
		_ids(fired) == ["all", "bugs"] and _status("all").problem == ""
		and str(_status("all").last_interruption).contains("could not be read"), str(_status("all")))


func _test_stream() -> void:
	var fired := await _send([_frame(_event(9, WORK, BUG, "typed_update", {"kind": "updated"}))])
	check("a repeated event fires nothing", fired.is_empty(), str(fired))
	fired = await _send([_frame(_event(11, WORK, BUG, "typed_update", {"kind": "updated"}))])
	check("after a gap the change still fires, and the gap is shown",
		_ids(fired) == ["all", "bugs"] and str(_status("all").last_interruption).contains("1 Docket changes were missed"), str(_status("all")))
	fired = await _send([_frame(_event(10, WORK, BUG, "typed_update", {"kind": "updated"}))])
	check("a late event is handled and shown as out of order",
		_ids(fired) == ["all", "bugs"] and str(_status("all").last_interruption).contains("out of order"), str(_status("all")))
	fired = await _send([_frame(_event(12, WORK, BUG, "typed_update", {"kind": "updated"}), "1.0")])
	check("a frame the connection refuses is shown as not delivered",
		fired.is_empty() and str(_status("all").problem).contains("was not delivered"), str(_status("all")))

	_wire.hold = true
	var reads: int = _wire.reads
	_manager.fired.clear()
	_wire._subprocess.lines.append(_frame(_event(13, WORK, BUG, "typed_update", {"kind": "updated"})))
	_sent += 1
	_wire._drain_stdout()
	var reading := await _wait(func(): return _wire.reads > reads)
	check("the item is being read", reading)
	_wire._subprocess.lines.append(_frame(_event(14, WORK, "", "reloaded")))
	_sent += 1
	_wire._drain_stdout()
	check("the project's reload arrives while it is read", await _wait(func(): return _arrived == _sent))
	_wire.hold = false
	_wire.released.emit()
	var feed = _manager.docket_feed
	check("the held read settles", await _wait(func(): return not feed._working and feed._queue.is_empty()))
	check("a read its project was read again during fires nothing and says why",
		_manager.fired.is_empty() and str(_status("all").problem).contains("read again from its file"), str(_status("all")))

	_plugins.plugin_stopped.emit("docket")
	check("the plugin stopping is shown", str(_status("all").problem).contains("stopped"), str(_status("all")))
	# A new process: a new generation and stream, numbered from 1 again.
	_wire._process_generation += 1
	_wire.protocol_profile = load(PROFILE_PATH).legacy("2025-03-26", {}, _wire.process_generation())
	_host._generation = _wire.process_generation()
	_stream = "stream-two"
	fired = await _send([_frame(_event(1, WORK, BUG, "typed_update", {"kind": "updated"}))])
	check("after a restart changes fire again, and the restart is shown",
		_ids(fired) == ["all", "bugs"] and str(_status("all").last_interruption).contains("restarted"), str(_status("all")))

	# The work project reopened at the same path: its open_generation is
	# now another. A delete queued from the earlier opening is not fired.
	fired = await _send([_frame(_event(2, WORK.merged({"open_generation": "99"}, true), TASK, "deleted", {"kind": "updated"}))])
	check("a delete from an opening no longer open fires nothing and says why",
		fired.is_empty() and str(_status("all").problem).contains("no longer open"), str(_status("all")))
	# The plugin gave the work selector to another opening, and DocketHost's
	# list has not caught up: the item read under it may be another's.
	_wire.listed = [MASTER, WORK.merged({"open_generation": "99"}, true), SAME_A, SAME_B]
	fired = await _send([_frame(_event(3, WORK, BUG, "typed_update", {"kind": "updated"}))])
	_wire.listed = [MASTER, WORK, SAME_A, SAME_B]
	check("a change whose selector the plugin now gives another opening fires nothing and says why",
		fired.is_empty() and str(_status("all").problem).contains("no longer names"), str(_status("all")))
