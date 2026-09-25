class_name DocketTriggerFeed
extends RefCounted
## DOCKET_POLL triggers under the Docket plugin, when no embedded
## DocketManager runs. The plugin's item_changed events that carry a baseline
## descriptor (one per ordinary create, transition, update, comment, delete,
## hint_set or quality call) fire them as DocketManager's signal for that
## call did: created, transitioned, updated or comment_added.
##
## A trigger's project name is bound once to one open project's path ("master"
## to the master's); until it names exactly one, the trigger watches nothing.
## Events are handled one at a time, the item read afresh through DocketHost.
## Whatever makes a fire unreliable (a failed read, a gap or reordering in the
## event stream, a dropped event, a full queue, the plugin stopping) is shown
## as the trigger's problem instead; nothing missed is replayed.

const PLUGIN_ID := "docket"
const EVENT := "item_changed"
## Most events waiting to be handled; beyond it they are dropped (visibly).
const QUEUE_LIMIT := 256
## How far back a stream's sequence numbers are remembered, to tell a repeat
## from a change that arrived late.
const SEEN_LIMIT := 1024
## A descriptor's kind, as the trigger's message and filters take it.
const KINDS := ["created", "transitioned", "updated", "comment_added"]

var _manager: TriggerManager
var _connected := false
var _queue: Array[Dictionary] = []
var _working := false
# The stream events are numbered on: the process generation they came from,
# its stream id, the highest sequence number seen, and those seen.
var _generation := -1
var _stream := ""
var _last := 0
var _seen: Dictionary = {}
# project_path -> projects read again from their file so far: a read that
# overlaps one is not trusted.
var _reloads: Dictionary = {}
# trigger_id -> {problem, last_interruption}: why it cannot be relied on now
# ("" once a change is handled cleanly for it), and the last interruption,
# kept.
var _status: Dictionary = {}


func _init(manager: TriggerManager) -> void:
	_manager = manager


## Listens to the event broker and the plugin manager once both exist.
func connect_sources() -> void:
	var broker = SingletonObject.get("plugin_event_broker")
	var plugins = SingletonObject.get("plugin_manager")
	if _connected or broker == null or plugins == null:
		return
	broker.plugin_event.connect(_on_event)
	broker.plugin_event_dropped.connect(_on_dropped)
	plugins.plugin_stopped.connect(_on_gone)
	plugins.plugin_crashed.connect(_on_gone)
	_connected = true


## Trigger `trigger_id` (a DOCKET_POLL one) is served from now on.
func activate(trigger_id: String) -> void:
	connect_sources()
	forget(trigger_id)


## Trigger `trigger_id` is no longer served: its problem is dropped, its last
## interruption kept.
func forget(trigger_id: String) -> void:
	if _status.has(trigger_id):
		_status[trigger_id]["problem"] = ""


## Trigger `trigger_id`'s state: {problem, last_interruption}, each "" when
## there is none. Besides what its last change met, Docket not being ready
## and a project it cannot watch (bound but not open, or not yet bound) are
## problems.
func status(trigger_id: String) -> Dictionary:
	var found: Dictionary = _status.get(trigger_id, {})
	var problem := str(found.get("problem", ""))
	var trig := _manager.get_trigger(trigger_id)
	var host = SingletonObject.get("docket_host")
	if problem.is_empty() and trig != null and trig.enabled:
		if host == null or not host.state in ["ready", "degraded"]:
			problem = "Docket is %s" % (host.state if host != null else "not available")
		elif not trig.docket_project_path.is_empty():
			if not trig.docket_project_path in _open_paths(host):
				problem = "%s is not open" % trig.docket_project_path
		elif not trig.docket_project.is_empty():
			problem = _unbound(trig.docket_project, _matches(host, trig.docket_project))
	return {"problem": problem, "last_interruption": str(found.get("last_interruption", ""))}


func _on_event(plugin_id: String, event_name: String, payload: Dictionary) -> void:
	if plugin_id != PLUGIN_ID or event_name != EVENT or SingletonObject.docket_manager != null:
		return
	var generation := _process_generation()
	if not _continuous(generation, payload):
		return
	var path := str(payload.get("project_path", ""))
	if str(payload.get("cause", "")) == "external_reload":
		_reloads[path] = int(_reloads.get(path, 0)) + 1
		return
	if not payload.get("baseline") is Dictionary or _served().is_empty():
		return
	if _queue.size() >= QUEUE_LIMIT:
		_interrupt("more Docket changes arrived than could wait to be handled; some were not")
		return
	_queue.append({"event": payload, "generation": generation, "reloads": int(_reloads.get(path, 0))})
	if not _working:
		_work()


func _on_dropped(plugin_id: String, reason: String) -> void:
	if plugin_id == PLUGIN_ID and SingletonObject.docket_manager == null:
		_interrupt("a Docket change was not delivered: %s" % reason)


func _on_gone(plugin_id: String) -> void:
	if plugin_id == PLUGIN_ID and SingletonObject.docket_manager == null:
		_queue.clear()
		_interrupt("the Docket plugin stopped")


func _process_generation() -> int:
	var plugins = SingletonObject.get("plugin_manager")
	var connection = plugins.get_connection(PLUGIN_ID) if plugins != null else null
	return connection.process_generation() if connection != null else -1


# Follows the event stream with `payload` (from process `generation`),
# before anything is filtered out: false for an event already seen. A
# malformed number, a new stream, a gap and a late event interrupt the
# served triggers; a new stream is then followed from this event.
func _continuous(generation: int, payload: Dictionary) -> bool:
	var number = payload.get("sequence")
	var stream := str(payload.get("stream", ""))
	if not (number is int or number is float) or stream.is_empty():
		_interrupt("Docket sent a change it did not number")
		return false
	var sequence := int(number)
	if generation != _generation or stream != _stream:
		if _generation != -1:
			_interrupt("the Docket plugin's process restarted" if generation != _generation
				else "Docket's event stream started again")
		_generation = generation
		_stream = stream
		_last = sequence
		_seen = {sequence: true}
		return true
	if _seen.has(sequence):
		return false
	_seen[sequence] = true
	if _seen.size() > 2 * SEEN_LIMIT:
		for old in _seen.keys():
			if int(old) < _last - SEEN_LIMIT:
				_seen.erase(old)
	if sequence > _last + 1:
		_interrupt("%d Docket changes were missed" % (sequence - _last - 1))
	elif sequence < _last:
		_interrupt("Docket changes arrived out of order")
	_last = maxi(_last, sequence)
	return true


# The enabled DOCKET_POLL triggers.
func _served() -> Array[TriggerDefinition]:
	var served: Array[TriggerDefinition] = []
	for trig in _manager.triggers:
		if trig.enabled and trig.trigger_type == TriggerDefinition.TriggerType.DOCKET_POLL:
			served.append(trig)
	return served


func _interrupt(reason: String) -> void:
	var served := _served()
	if served.is_empty():
		return
	push_warning("[DocketTriggerFeed] %s" % reason)
	for trig in served:
		_mark(trig.id, reason, true)


func _mark(trigger_id: String, problem: String, interruption: bool) -> void:
	var found: Dictionary = _status.get_or_add(trigger_id, {})
	found["problem"] = problem
	if interruption:
		found["last_interruption"] = "%s: %s" % [Time.get_datetime_string_from_system(true), problem]


func _work() -> void:
	_working = true
	while not _queue.is_empty():
		await _handle(_queue.pop_front())
	_working = false


func _handle(job: Dictionary) -> void:
	if job.generation != _process_generation():
		return  # its process is gone, which has interrupted the triggers
	var event: Dictionary = job.event
	var baseline: Dictionary = event.baseline
	var kind := str(baseline.get("kind", ""))
	var id := str(event.get("id", ""))
	if not kind in KINDS or id.is_empty():
		_interrupt("Docket sent a change it did not describe as expected: %s" % [baseline])
		return
	var item_type := str(baseline.get("item_type", "")) if kind == "created" else ""
	var candidates: Array = []
	for trig in _served():
		if not trig.docket_project.is_empty() and _bound(trig) != str(event.get("project_path", "")):
			continue
		if TriggerManager.docket_ids_and_type_pass(trig, id, item_type):
			candidates.append([trig, _manager.revision(trig.id)])
	if candidates.is_empty():
		return
	# Nothing awaits between this and the fires, so the opening confirmed is
	# still the one open when they are made.
	var confirmed := await _confirmed(event, id, job.reloads)
	if confirmed.has("error"):
		for candidate in candidates:
			_mark(candidate[0].id, "a change of %s was not handled: %s" % [id, confirmed.error], true)
		return
	var item: Dictionary = confirmed.item
	for candidate in candidates:
		var trig: TriggerDefinition = candidate[0]
		if _manager.get_trigger(trig.id) != trig or _manager.revision(trig.id) != candidate[1] or not trig.enabled:
			continue
		_manager.fire_docket_event(trig, str(event.get("project", "")), id, kind, item_type,
			str(baseline.get("from_status", "")), str(baseline.get("to_status", "")), item)
		if _status.has(trig.id):
			_status[trig.id]["problem"] = ""


# `event`'s opening confirmed as the one open now, by the plugin's own list
# (DocketHost), and the item `id` as it is now: {item} ({} for a deleted
# item, which is not read) or {error}. When the project was read again from
# its file after the event was queued (its count of reloads no longer
# `reloads`), neither is trusted.
func _confirmed(event: Dictionary, id: String, reloads: int) -> Dictionary:
	var host = SingletonObject.get("docket_host")
	if host == null:
		return {"error": "Docket is not available"}
	var found: Dictionary = {"item": {}}
	if str(event.get("event", "")) == "deleted":
		var problem: String = await host.confirm_opening(event)
		if not problem.is_empty():
			found = {"error": problem}
	else:
		found = await host.item_for_trigger(event, id)
	if not found.has("error") and int(_reloads.get(str(event.get("project_path", "")), 0)) != reloads:
		return {"error": "%s was read again from its file while %s was handled" % [event.get("project", ""), id]}
	return found


# The path `trig`'s project name is bound to, binding it now when the name
# names exactly one open project; "" (and a problem) while it cannot be.
func _bound(trig: TriggerDefinition) -> String:
	if not trig.docket_project_path.is_empty():
		return trig.docket_project_path
	var host = SingletonObject.get("docket_host")
	if host == null:
		return ""
	var paths := _matches(host, trig.docket_project)
	if paths.size() != 1:
		_mark(trig.id, _unbound(trig.docket_project, paths), false)
		return ""
	trig.docket_project_path = paths[0]
	return paths[0]


# The paths of the open projects `name` names: the master's for "master",
# else each whose selector, stored name or display name it is (in any case).
static func _matches(host, name: String) -> Array[String]:
	var paths: Array[String] = []
	if name == "master":
		var master: Dictionary = host.master_project()
		if not master.is_empty():
			paths.append(str(master.path))
		return paths
	for project: Dictionary in host.projects:
		var path := str(project.get("path", ""))
		if not path in paths and (str(project.get("name", "")).nocasecmp_to(name) == 0
				or str(project.get("display_name", "")).nocasecmp_to(name) == 0):
			paths.append(path)
	return paths


static func _unbound(name: String, paths: Array[String]) -> String:
	return "project '%s' names %s, so nothing is watched" % [name,
		"no open project" if paths.is_empty() else "%d open projects" % paths.size()]


static func _open_paths(host) -> Array[String]:
	var paths: Array[String] = []
	for project: Dictionary in host.projects:
		paths.append(str(project.get("path", "")))
	return paths
