extends RefCounted
## Where every notification minerva_terminal_notify accepted stands, from the
## moment it is accepted until the harness took it or it can never be
## delivered. One ledger per Minerva process (shared()); tests build their own.
##
## A receipt says what happened, never what probably will. The states:
##   queued            — Minerva holds the line and has not offered it yet: it
##                       waits in its chat's outgoing queue behind a turn.
##   held              — the last look found the target blocked (hold_reason:
##                       a person's draft or keystrokes, a dialog, a busy turn,
##                       an unreadable foreground). Minerva keeps the line and
##                       looks again every retry_s.
##   sending           — the line has been offered to the harness (its chat
##                       started the turn) and no reply has said yet whether
##                       the harness took it.
##   handed_to_harness — the harness took the input: the relay confirmed the
##                       submit (direct path) or the chat's relay call came back
##                       with the turn running or answered (chat path).
##   unconfirmed       — the bytes went to the terminal but nothing confirmed
##                       the harness took them. Never retried: a second write
##                       could submit the line twice.
##   failed            — it can never be delivered: the target went away, a
##                       write failed outright, or it stayed held past
##                       hold_limit_s. Kept, with the last reason, for reading.
##   dropped           — a person removed it from its chat's queue (Stop, or
##                       closing the pending bubble) before it ran.
## Handing a line to the harness is not the recipient reading it; nothing here
## infers consumption from what the screen shows.
##
## Direct deliveries are retried by the attempt Callable the tool hands over
## (one look each, the same guards every time). Chat deliveries are followed
## through their queue entry, and learn the harness's answer from
## note_chat_outcome, which PluginProvider calls with its first reply; a chat
## delivery the relay held is submitted to its chat again after retry_s.

## Emitted whenever a record changes state; views that show retained lines
## listen for it.
signal changed(delivery_id: String)

const QUEUED := "queued"
const HELD := "held"
const SENDING := "sending"
const HANDED := "handed_to_harness"
const UNCONFIRMED := "unconfirmed"
const FAILED := "failed"
const DROPPED := "dropped"

## States after which nothing more happens to a record.
const SETTLED := [HANDED, UNCONFIRMED, FAILED, DROPPED]

## Outcomes a chat's first relay reply maps to (note_chat_outcome).
const CHAT_HANDED := "handed"
const CHAT_HELD := "held"
const CHAT_UNCONFIRMED := "unconfirmed"
const CHAT_FAILED := "failed"

const RETRY_S := 1.0
## A line held this long is given up and reported failed.
const HOLD_LIMIT_S := 900.0
## Settled records kept for reading; the oldest settled go first. A record
## that is still moving is never evicted.
const RECORDS_KEPT := 128
## State changes kept per record.
const HISTORY_KEPT := 16
## How often queued chat entries are looked at.
const QUEUE_POLL_S := 0.5

static var _shared = null

var retry_s: float = RETRY_S
var hold_limit_s: float = HOLD_LIMIT_S

## delivery id -> record. Records are Dictionaries so a receipt can carry a
## copy as is.
var _records: Dictionary = {}
## Delivery ids, oldest first.
var _order: Array[String] = []
## Chat queue entry id -> delivery id, for every entry a delivery has had.
var _by_entry: Dictionary = {}
var _serial: int = 0
var _polling: bool = false


static func shared():
	if _shared == null:
		_shared = load("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd").new()
	return _shared


# ── Reading ────────────────────────────────────────────────────────────

## A copy of the record, or {} for an id this ledger does not hold.
func get_record(delivery_id: String) -> Dictionary:
	_refresh_chat(delivery_id)
	return (_records.get(delivery_id, {}) as Dictionary).duplicate(true)


## Copies of the records addressed to `terminal_id` (all when empty), oldest
## first; `open_only` leaves out the settled ones.
func list(terminal_id: String = "", open_only: bool = false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: String in _order:
		_refresh_chat(id)
		var record: Dictionary = _records[id]
		if not terminal_id.is_empty() and str(record["target"].get("terminal_id", "")) != terminal_id:
			continue
		if open_only and SETTLED.has(str(record["state"])):
			continue
		out.append(record.duplicate(true))
	return out


## The state the delivery that used this chat queue entry is in, or "" when
## no delivery used it.
func state_of_entry(entry_id: int) -> String:
	var id: String = str(_by_entry.get(entry_id, ""))
	if id.is_empty():
		return ""
	_refresh_chat(id)
	return str(_records[id]["state"]) if _records.has(id) else ""


# ── Writing ────────────────────────────────────────────────────────────

## A new record for `envelope` bound for `target` ({terminal_id, name, ...}),
## in `state`. Returns its delivery id.
func open(target: Dictionary, envelope: String, path: String, state: String, fields: Dictionary = {}) -> String:
	_serial += 1
	var id: String = "nd-%d" % _serial
	var now: String = Time.get_datetime_string_from_system(false, true)
	var record: Dictionary = {
		"delivery_id": id,
		"path": path,
		"target": target.duplicate(true),
		"text": envelope,
		"state": "",
		"hold_reason": "",
		"reason": "",
		"attempts": 0,
		"accepted_at": now,
		"accepted_ticks": Time.get_ticks_msec(),
		"entry_id": 0,
		"history": [],
	}
	_records[id] = record
	_order.append(id)
	_set_state(id, state, fields)
	_evict()
	return id


## Move a record to `state`, merging `fields` (hold_reason, reason, ...).
## A settled record does not move again.
func update(delivery_id: String, state: String, fields: Dictionary = {}) -> void:
	if not _records.has(delivery_id) or SETTLED.has(str(_records[delivery_id]["state"])):
		return
	_set_state(delivery_id, state, fields)


## Mark a record as going to chat `history_id`, BEFORE it is submitted there:
## an idle chat starts the turn inside the submit, and the relay's answer may
## come back before the submit returns.
func begin_chat(delivery_id: String, history_id: String) -> void:
	if not _records.has(delivery_id):
		return
	var record: Dictionary = _records[delivery_id]
	record["path"] = "chat"
	record["chat_tracked"] = true
	record["target"]["chat_id"] = history_id
	update(delivery_id, SENDING, {"hold_reason": ""})


## Follow a chat delivery through the queue entry its submit created (0: the
## turn started at once). A queued entry is read on from the queue's own
## record (see _refresh_chat); an outcome that already arrived stands.
func track_chat_entry(delivery_id: String, entry_id: int) -> void:
	if not _records.has(delivery_id):
		return
	_records[delivery_id]["entry_id"] = entry_id
	if entry_id <= 0:
		return
	_by_entry[entry_id] = delivery_id
	if MCPToolUtils.outgoing_queue_position(entry_id) > 0:
		update(delivery_id, QUEUED)
		_poll_queue()


## Keep retrying a held direct delivery. `attempt` is an awaitable Callable
## taking no arguments that makes ONE look and returns a notify receipt; it is
## called every retry_s until the receipt is anything but held, or until the
## line has been held past hold_limit_s.
func retain(delivery_id: String, attempt: Callable) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	while _records.has(delivery_id) and str(_records[delivery_id]["state"]) == HELD:
		if tree == null:
			_expire(delivery_id)
			return
		await tree.create_timer(retry_s).timeout
		if not _records.has(delivery_id) or str(_records[delivery_id]["state"]) != HELD:
			return
		if _held_too_long(delivery_id):
			_expire(delivery_id)
			return
		_records[delivery_id]["attempts"] = int(_records[delivery_id]["attempts"]) + 1
		var receipt: Dictionary = await attempt.call()
		# A retry that found the terminal bound to a chat was tracked into this
		# same record by the chat path; its queue decides from here.
		if bool(_records[delivery_id].get("chat_tracked", false)):
			return
		apply_receipt(delivery_id, receipt)


## Settle or re-hold a direct record from one notify receipt.
func apply_receipt(delivery_id: String, receipt: Dictionary) -> void:
	var status: String = str(receipt.get("status", ""))
	match status:
		HELD:
			update(delivery_id, HELD, {"hold_reason": str(receipt.get("hold_reason", "")),
				"reason": str(receipt.get("reason", receipt.get("error", "")))})
		HANDED, UNCONFIRMED:
			var fields: Dictionary = {"hold_reason": "", "reason": ""}
			if receipt.has("submit"):
				fields["submit"] = receipt["submit"]
			update(delivery_id, status, fields)
		_:
			update(delivery_id, FAILED, {"hold_reason": "",
				"reason": str(receipt.get("error", "the delivery ended as '%s'" % status))})


## What the relay said when a chat carried `text` to its harness: its first
## reply for that turn. Matched to the oldest chat delivery of that chat and
## text still waiting for it. A held one is submitted to its chat again after
## retry_s, unless it has been held past hold_limit_s.
func note_chat_outcome(history_id: String, text: String, outcome: String, detail: String = "",
		hold_reason: String = "") -> void:
	var id: String = _awaiting_chat_outcome(history_id, text)
	if id.is_empty():
		return
	match outcome:
		CHAT_HANDED:
			update(id, HANDED, {"hold_reason": "", "reason": ""})
		CHAT_HELD:
			update(id, HELD, {"hold_reason": hold_reason if not hold_reason.is_empty() else "screen",
				"reason": detail})
			_resubmit_later(id)
		CHAT_FAILED:
			update(id, FAILED, {"hold_reason": "", "reason": detail})
		_:
			update(id, UNCONFIRMED, {"hold_reason": "", "reason": detail})


# ── Internals ──────────────────────────────────────────────────────────

func _set_state(delivery_id: String, state: String, fields: Dictionary) -> void:
	var record: Dictionary = _records[delivery_id]
	record.merge(fields, true)
	var moved: bool = str(record["state"]) != state
	record["state"] = state
	record["updated_at"] = Time.get_datetime_string_from_system(false, true)
	var history: Array = record["history"]
	if moved or state == HELD:
		history.append({"state": state, "at": record["updated_at"],
			"hold_reason": str(record.get("hold_reason", ""))})
		while history.size() > HISTORY_KEPT:
			history.pop_front()
	changed.emit(delivery_id)


func _held_too_long(delivery_id: String) -> bool:
	var accepted: int = int(_records[delivery_id]["accepted_ticks"])
	return Time.get_ticks_msec() - accepted > int(hold_limit_s * 1000.0)


func _expire(delivery_id: String) -> void:
	var record: Dictionary = _records[delivery_id]
	update(delivery_id, FAILED, {"reason": "held for over %d s (%s): %s" % [
		int(hold_limit_s), str(record.get("hold_reason", "")), str(record.get("reason", ""))]})


## The chat delivery of `history_id` carrying `text` whose turn has been
## offered and not yet answered, oldest first. The chat may have put notes
## ahead of the message, so the text is matched at its end.
func _awaiting_chat_outcome(history_id: String, text: String) -> String:
	if text.is_empty():
		return ""
	for id: String in _order:
		var record: Dictionary = _records[id]
		if str(record["path"]) != "chat" or not text.ends_with(str(record["text"])) \
				or str(record["target"].get("chat_id", "")) != history_id:
			continue
		_refresh_chat(id)
		if str(record["state"]) == SENDING:
			return id
	return ""


## A queued chat record, re-read from its queue entry: still queued, dropped
## by a person, or promoted to a turn (sending).
func _refresh_chat(delivery_id: String) -> void:
	if not _records.has(delivery_id):
		return
	var record: Dictionary = _records[delivery_id]
	var entry_id: int = int(record.get("entry_id", 0))
	if str(record["path"]) != "chat" or str(record["state"]) != QUEUED or entry_id <= 0:
		return
	if MCPToolUtils.outgoing_queue_position(entry_id) > 0:
		return
	match MCPToolUtils.outgoing_queue_outcome(entry_id):
		ChatOutgoingQueue.Outcome.DROPPED:
			update(delivery_id, DROPPED, {"reason": "removed from the chat's queue before it ran"})
		ChatOutgoingQueue.Outcome.DISPATCHED:
			update(delivery_id, SENDING)
		_:
			update(delivery_id, UNCONFIRMED,
				{"reason": "its queue entry left the queue with no outcome on record"})


## Re-read queued chat records until none is left queued, so a view sees the
## promotion without anyone asking.
func _poll_queue() -> void:
	if _polling:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_polling = true
	while true:
		var any_queued := false
		for id: String in _order.duplicate():
			_refresh_chat(id)
			if _records.has(id) and str(_records[id]["state"]) == QUEUED:
				any_queued = true
		if not any_queued:
			break
		await tree.create_timer(QUEUE_POLL_S).timeout
	_polling = false


## Submit a held chat delivery to its chat again once retry_s has passed.
func _resubmit_later(delivery_id: String) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_expire(delivery_id)
		return
	await tree.create_timer(retry_s).timeout
	if not _records.has(delivery_id) or str(_records[delivery_id]["state"]) != HELD:
		return
	if _held_too_long(delivery_id):
		_expire(delivery_id)
		return
	var record: Dictionary = _records[delivery_id]
	var history_id: String = str(record["target"].get("chat_id", ""))
	var history = null
	var so: Node = tree.root.get_node_or_null("SingletonObject")
	if so == null:
		update(delivery_id, FAILED, {"reason": "no chats are available"})
		return
	for chat in so.ChatList:
		if str(chat.HistoryId) == history_id:
			history = chat
			break
	if history == null:
		update(delivery_id, FAILED, {"reason": "its chat is gone"})
		return
	record["attempts"] = int(record["attempts"]) + 1
	begin_chat(delivery_id, history_id)
	var submitted: Dictionary = MCPToolUtils.submit_user_message(history, str(record["text"]), {}, true)
	if not bool(submitted.get("success", false)):
		update(delivery_id, FAILED, {"reason": str(submitted.get("error", "the chat refused it"))})
		return
	track_chat_entry(delivery_id, MCPToolUtils.coerce_int(submitted.get("entry_id", 0)))


## Drop the oldest settled records past RECORDS_KEPT.
func _evict() -> void:
	var index: int = 0
	while _order.size() > RECORDS_KEPT and index < _order.size():
		var id: String = _order[index]
		if not SETTLED.has(str(_records[id]["state"])):
			index += 1
			continue
		_order.remove_at(index)
		_records.erase(id)
		for entry in _by_entry.keys():
			if str(_by_entry[entry]) == id:
				_by_entry.erase(entry)
