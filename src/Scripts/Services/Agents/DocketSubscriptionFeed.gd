class_name DocketSubscriptionFeed
extends RefCounted
## Wake-mode DOCKET_POLL triggers (TriggerDefinition.docket_wake_sessions)
## fed from docket.app's change feed: docket_subscribe, docket_changes_since
## and docket_ack, called on the MCP server `server` (default "docket").
## Off by default (`enabled` in state_path). It runs beside the embedded
## DocketManager signals and the Docket plugin feed, which stay as they are:
## those see changes made through Minerva's own Docket, this one changes made
## through docket.app, whose event log is the only one that numbers them.
##
## Identity. Minerva subscribes once per installation, named
## "minerva@install-<id>" from a random id kept in state_path. The
## subscription names no terminal, tab or session and filters nothing (every
## project docket.app has loaded); routing to sessions stays in DocketWakeups.
##
## Reading. Every poll_s the feed reads pages until `more` is false. Each
## event's item is read with docket_get (its events included) and handed to
## the served triggers whose filters pass, under the change key the embedded
## path derives for the same change (DocketWakeups.change_key_of): docket.app
## writes an event's timestamp as the item's updated_at, and a transition's
## from/to come from its event note "<from> → <to>". A change a session
## already took under that key is not sent to it again.
## Kinds map as: created, moved, promoted -> created; transition,
## status_repaired -> transitioned; comment_added, comment_reply ->
## comment_added; any other -> updated.
##
## Acknowledgement. Each event carries a DocketWakeups.Receipt. docket_ack is
## sent for it once every wake-up pointer carrying it is handed_to_harness in
## the NotifyDeliveryLedger, or at once when it wakes nobody. A pointer that
## ends unconfirmed, or an item that could not be read, never acks, so the
## event stays pending in docket_subscription_status.
##
## Cursor. The cursor is saved after each page has been handed over, so a
## restart, or enabling the feed again after it was disabled, resumes after
## the last page read and docket.app replays everything since. Receipts live
## in memory: an event not yet acked when Minerva exits stays pending in
## docket.app and is not read again. An expired cursor (retention, or a
## rewound file) resumes at docket.app's recovery position and the loss is
## reported in `problem`; an unknown subscriber (its record gone) subscribes
## again at the current head, also reported.

const STATE_PATH := "user://docket_subscription_feed.json"
const DEFAULT_SERVER := "docket"
const DEFAULT_POLL_S := 5.0
const MIN_POLL_S := 1.0
const PAGE_LIMIT := 50
## Pages read in one poll before waiting for the next.
const MAX_PAGES := 20
const CALL_TIMEOUT_S := 20.0
const KIND_MAP := {
	"created": "created", "moved": "created", "promoted": "created",
	"transition": "transitioned", "status_repaired": "transitioned",
	"comment_added": "comment_added", "comment_reply": "comment_added",
}
const TRANSITION_ARROW := " → "

## Where the settings, identity, subscriber and cursor are kept; tests point
## it at a scratch file.
var state_path: String = STATE_PATH
var enabled: bool = false
var server: String = DEFAULT_SERVER
var poll_s: float = DEFAULT_POLL_S
var installation_id: String = ""
var subscriber: String = ""
var cursor: String = ""
## What went wrong last, "" when the last poll was clean.
var problem: String = ""
## Calls a docket.app tool: func(tool: String, arguments: Dictionary) ->
## Dictionary ({error} on failure). Unset: the MCP server `server`.
var caller: Callable

var _wakeups: DocketWakeups
var _triggers: Callable
var _running: bool = false
var _polling: bool = false


## `triggers` returns the current Array[TriggerDefinition] to serve from.
func _init(wakeups: DocketWakeups, triggers: Callable) -> void:
	_wakeups = wakeups
	_triggers = triggers


## Loads the state and, when enabled, starts polling.
func start() -> void:
	_load()
	if enabled and not _running:
		_run()


## Turns the feed on or off and saves that. Off stops polling after the
## current poll; the subscriber and cursor are kept for the next time.
func set_enabled(on: bool) -> String:
	enabled = on
	var error: String = _save()
	if enabled and not _running:
		_run()
	return error


## The name the subscription is registered under.
func identity() -> String:
	if installation_id.is_empty():
		installation_id = Crypto.new().generate_random_bytes(8).hex_encode()
		_save()
	return "minerva@install-" + installation_id


func _run() -> void:
	_running = true
	var tree := Engine.get_main_loop() as SceneTree
	while enabled and tree != null:
		await poll_once()
		await tree.create_timer(maxf(poll_s, MIN_POLL_S)).timeout
	_running = false


## Reads every page available now and hands its events over.
func poll_once() -> void:
	if _polling:
		return
	_polling = true
	problem = ""
	if subscriber.is_empty():
		_subscribe_problem(await _subscribe())
	var pages: int = 0
	while not subscriber.is_empty() and pages < MAX_PAGES:
		pages += 1
		var page: Dictionary = await _call("docket_changes_since",
			{"subscriber": subscriber, "cursor": cursor, "limit": PAGE_LIMIT})
		if page.has("error"):
			problem = "docket_changes_since failed: %s" % page.error
			if str(page.error).begins_with("Unknown subscriber"):
				subscriber = ""
				cursor = ""
				var error: String = await _subscribe()
				problem = "docket_subscribe failed: %s" % error if not error.is_empty() else \
					"docket.app no longer had this subscription; subscribed again at its head, so changes in between were not read"
			break
		if bool(page.get("expired", false)):
			problem = "docket.app could not replay from the saved cursor; resumed at %s" % [page.get("expired_projects", [])]
		var events: Array = page.get("events", []) if page.get("events") is Array else []
		for event in events:
			if event is Dictionary:
				await _take(event)
		cursor = str(page.get("next_cursor", cursor))
		_save()
		if not bool(page.get("more", false)):
			break
	_polling = false


# Registers the installation's subscription; "" or why it could not.
func _subscribe() -> String:
	var made: Dictionary = await _call("docket_subscribe", {"name": identity(), "filters": {}})
	if made.has("error"):
		return str(made.error)
	subscriber = str(made.get("subscriber", ""))
	cursor = str(made.get("cursor", ""))
	_save()
	return "" if not subscriber.is_empty() else "docket_subscribe returned no subscriber"


func _subscribe_problem(error: String) -> void:
	if not error.is_empty():
		problem = "docket_subscribe failed: %s" % error


# Hands one docket.app event to the served triggers; acks it once consumed.
func _take(event: Dictionary) -> void:
	var project: String = str(event.get("project", ""))
	var item_id: String = str(event.get("item_id", ""))
	var receipt := DocketWakeups.Receipt.new(_ack.bind({"project": project, "eid": int(event.get("eid", 0))}))
	var served: Array[TriggerDefinition] = _served(project)
	if not served.is_empty() and not item_id.is_empty():
		var read: Dictionary = await _call("docket_get", {"id": item_id, "project": project, "include": ["events"]})
		if read.has("error"):
			receipt.abandon()
			problem = "a change of %s:%s was not handled: %s" % [project, item_id, read.error]
		else:
			var raw_kind: String = str(event.get("kind", ""))
			var kind: String = str(KIND_MAP.get(raw_kind, "updated"))
			var timestamp: String = str(event.get("timestamp", ""))
			var statuses: PackedStringArray = _transition(read, raw_kind, timestamp) if kind == "transitioned" else PackedStringArray(["", ""])
			var item_type: String = str(read.get("type", "")) if kind == "created" else ""
			var key: String = DocketWakeups.change_key_of(project, item_id, kind, timestamp, statuses[0], statuses[1])
			for trig in served:
				if TriggerManager.docket_filters_pass(trig, item_id, item_type, read):
					_wakeups.take(trig, project, item_id, kind, statuses[0], statuses[1], read, key, receipt)
	receipt.release()


# [from, to] of the item's `kind` event at `timestamp`, from its note.
static func _transition(item: Dictionary, kind: String, timestamp: String) -> PackedStringArray:
	var events: Array = item.get("events", []) if item.get("events") is Array else []
	for entry in events:
		if entry is Dictionary and str(entry.get("event_type", "")) == kind and str(entry.get("timestamp", "")) == timestamp:
			var note: String = str(entry.get("note", ""))
			var arrow: int = note.find(TRANSITION_ARROW)
			if arrow >= 0:
				var to_status: String = note.substr(arrow + TRANSITION_ARROW.length()).get_slice(".", 0).strip_edges()
				return PackedStringArray([note.left(arrow).strip_edges(), to_status])
	return PackedStringArray(["", ""])


func _ack(event_ref: Dictionary) -> void:
	var acked: Dictionary = await _call("docket_ack", {"subscriber": subscriber, "event_ids": [event_ref]})
	if acked.has("error"):
		problem = "docket_ack of %s failed: %s" % [event_ref, acked.error]


# The enabled wake-mode DOCKET_POLL triggers watching `project`.
func _served(project: String) -> Array[TriggerDefinition]:
	var served: Array[TriggerDefinition] = []
	for trig: TriggerDefinition in _triggers.call():
		if trig.enabled and trig.docket_wake_sessions \
				and trig.trigger_type == TriggerDefinition.TriggerType.DOCKET_POLL \
				and (trig.docket_project.is_empty() or trig.docket_project == project):
			served.append(trig)
	return served


func _call(tool: String, arguments: Dictionary) -> Dictionary:
	if caller.is_valid():
		return await caller.call(tool, arguments)
	var manager = SingletonObject.get("mcp_manager")
	var connection = manager.servers.get(server) if manager != null else null
	if connection == null:
		return {"error": "MCP server '%s' is not connected" % server}
	var answered: Dictionary = await connection.call_tool(tool, arguments, CALL_TIMEOUT_S)
	if answered.has("error") or answered.get("success", true) == false:
		return {"error": str(answered.get("error", answered.get("text", "%s failed" % tool)))}
	return answered


func _load() -> void:
	if not FileAccess.file_exists(state_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(state_path))
	if not parsed is Dictionary:
		problem = "%s could not be read; the feed stays off" % state_path
		return
	var saved: Dictionary = parsed
	enabled = bool(saved.get("enabled", false))
	server = str(saved.get("server", DEFAULT_SERVER))
	poll_s = float(saved.get("poll_s", DEFAULT_POLL_S))
	installation_id = str(saved.get("installation_id", ""))
	subscriber = str(saved.get("subscriber", ""))
	cursor = str(saved.get("cursor", ""))


func _save() -> String:
	var file := FileAccess.open(state_path, FileAccess.WRITE)
	if file == null:
		return "could not write %s: %s" % [state_path, error_string(FileAccess.get_open_error())]
	file.store_string(JSON.stringify({"enabled": enabled, "server": server, "poll_s": poll_s,
		"installation_id": installation_id, "subscriber": subscriber, "cursor": cursor}, "\t"))
	file.close()
	return ""
