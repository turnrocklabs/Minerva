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
##   awaiting_recipient — it is addressed to a registered identity or role
##                       whose session is not reachable (unbound, exited, no
##                       harness in front, or no live holder of the role).
##                       Minerva keeps it and tries again whenever a session
##                       registers or hands over, and on its own schedule:
##                       first after await_recheck_s, the gap doubling after
##                       each miss up to AWAIT_BACKOFF_MAX_S. It counts as
##                       pending for its address (pending_by_address).
##   failed_unavailable — it awaited its recipient for over await_max_age_s
##                       and was given up. Kept, with the last reason, for
##                       reading (unavailable_by_address).
## Handing a line to the harness is not the recipient reading it; nothing here
## infers consumption from what the screen shows.
##
## Every record also carries `class` (routine or urgent), `mechanism` (the
## path that carries or carried it) and `delivered_at` (turn_end,
## harness_queue or unknown): see NotifyDeliveryClass. A mechanism is ""
## until an attempt has chosen one (a record awaiting its recipient).
##
## Direct deliveries are retried by the attempt Callable the tool hands over
## (one look each, the same guards every time). Chat deliveries are followed
## through their queue entry, and learn the harness's answer from
## note_chat_outcome, which PluginProvider calls with its first reply; a chat
## delivery the relay held is submitted to its chat again after retry_s.
##
## Every record's target carries the address it is retried under
## (address_of): the registered identity or role it was sent to, else its
## terminal id. retarget() moves the open records of superseded sessions to
## their replacement when a role is handed over.

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
const AWAITING := "awaiting_recipient"
const FAILED_UNAVAILABLE := "failed_unavailable"

## States after which nothing more happens to a record.
const SETTLED := [HANDED, UNCONFIRMED, FAILED, DROPPED, FAILED_UNAVAILABLE]

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
## The first gap before a record awaiting its recipient is tried again
## without a registration to prompt it (a harness started again in its bound
## tab); each miss doubles the gap, up to AWAIT_BACKOFF_MAX_S.
const AWAIT_RECHECK_S := 10.0
const AWAIT_BACKOFF_MAX_S := 600.0
## A record awaiting its recipient this long becomes FAILED_UNAVAILABLE.
const AWAIT_MAX_AGE_S := 6.0 * 3600.0

const HarnessSessionRegistry := preload("res://Scripts/Services/Terminal/HarnessSessionRegistry.gd")
const NotifyDeliveryClass := preload("res://Scripts/Services/Terminal/NotifyDeliveryClass.gd")

static var _shared = null

var retry_s: float = RETRY_S
var hold_limit_s: float = HOLD_LIMIT_S
var await_recheck_s: float = AWAIT_RECHECK_S
var await_max_age_s: float = AWAIT_MAX_AGE_S

## delivery id -> record. Records are Dictionaries so a receipt can carry a
## copy as is.
var _records: Dictionary = {}
## Delivery ids, oldest first.
var _order: Array[String] = []
## Chat queue entry id -> delivery id, for every entry a delivery has had.
var _by_entry: Dictionary = {}
var _serial: int = 0
var _polling: bool = false
## delivery id -> the attempt Callable (see retain) of a record awaiting its
## recipient.
var _waiting: Dictionary = {}
var _waking: bool = false
var _wake_again: bool = false
## The pending round of _wake_waiting tries every record, not only due ones.
var _wake_all: bool = false
var _rechecking_waiting: bool = false
var _watching_registry: bool = false


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


## The address a record is retried under: target.address, else its
## registered identity, else its terminal id; "" for an unknown id.
func address_of(delivery_id: String) -> String:
	if not _records.has(delivery_id):
		return ""
	var target: Dictionary = _records[delivery_id]["target"]
	for field: String in ["address", "identity", "terminal_id"]:
		if not str(target.get(field, "")).is_empty():
			return str(target[field])
	return ""


## Open (not settled) records per address, lower case -> count: what is
## pending for each registered identity or role, and each terminal id.
func pending_by_address() -> Dictionary:
	var out: Dictionary = {}
	for id: String in _order:
		if SETTLED.has(str(_records[id]["state"])):
			continue
		var address: String = address_of(id).to_lower()
		out[address] = int(out.get(address, 0)) + 1
	return out


## Records given up as FAILED_UNAVAILABLE per address, lower case -> count.
func unavailable_by_address() -> Dictionary:
	var out: Dictionary = {}
	for id: String in _order:
		if str(_records[id]["state"]) != FAILED_UNAVAILABLE:
			continue
		var address: String = address_of(id).to_lower()
		out[address] = int(out.get(address, 0)) + 1
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
## in `state`; `fields` may set class, mechanism and delivered_at. Returns its
## delivery id.
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
		"available_ticks": Time.get_ticks_msec(),
		"entry_id": 0,
		"class": NotifyDeliveryClass.ROUTINE,
		"mechanism": "",
		"delivered_at": "",
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
	record["mechanism"] = NotifyDeliveryClass.CHAT_QUEUE
	record["delivered_at"] = NotifyDeliveryClass.delivered_at(NotifyDeliveryClass.CHAT_QUEUE)
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
		_note_terminal(delivery_id, receipt)
		# A retry that found the terminal bound to a chat was tracked into this
		# same record by the chat path; its queue decides from here.
		if bool(_records[delivery_id].get("chat_tracked", false)):
			return
		apply_receipt(delivery_id, receipt)
		if str(_records[delivery_id]["state"]) == AWAITING:
			wait_for_recipient(delivery_id, attempt)


## Keep a record awaiting its recipient (AWAITING) and try `attempt` (as in
## retain) again whenever the session registry changes and every
## AWAIT_RECHECK_S, until it leaves AWAITING; a record found held then is
## retained as usual.
func wait_for_recipient(delivery_id: String, attempt: Callable) -> void:
	if not _records.has(delivery_id):
		return
	_waiting[delivery_id] = attempt
	if not _watching_registry:
		_watching_registry = true
		HarnessSessionRegistry.shared().changed.connect(_on_registry_changed)
	_recheck_waiting()


## Move the open records addressed to any of `from_identities` (or to
## `role`) to `to_identity`, then try the waiting ones at once. A record
## already offered to a chat (path "chat") stays with that chat. Returns
## {retargeted, left_in_chat}: delivery ids.
func retarget(from_identities: PackedStringArray, role: String, to_identity: String) -> Dictionary:
	var from := PackedStringArray()
	for identity: String in from_identities:
		from.append(identity.to_lower())
	var moved: Array[String] = []
	var left: Array[String] = []
	for id: String in _order:
		var record: Dictionary = _records[id]
		if SETTLED.has(str(record["state"])):
			continue
		var target: Dictionary = record["target"]
		var address: String = address_of(id).to_lower()
		var identity: String = str(target.get("identity", "")).to_lower()
		var by_role: bool = not role.is_empty() and address == role.to_lower()
		if not (by_role or address in from or identity in from):
			continue
		if str(record["path"]) == "chat":
			left.append(id)
			continue
		if not identity.is_empty() and identity != to_identity.to_lower():
			target["retargeted_from"] = str(target["identity"])
		if not by_role:
			target["address"] = to_identity
		target["identity"] = to_identity
		moved.append(id)
		changed.emit(id)
	_wake_waiting()
	return {"retargeted": moved, "left_in_chat": left}


## Settle or re-hold a direct record from one notify receipt, taking the
## mechanism the attempt chose.
func apply_receipt(delivery_id: String, receipt: Dictionary) -> void:
	if _records.has(delivery_id) and not str(receipt.get("mechanism", "")).is_empty():
		_records[delivery_id]["mechanism"] = str(receipt["mechanism"])
		_records[delivery_id]["delivered_at"] = str(receipt.get("delivered_at", ""))
	if str(receipt.get("code", "")) in HarnessSessionRegistry.RECIPIENT_UNAVAILABLE:
		update(delivery_id, AWAITING, {"hold_reason": "", "reason": str(receipt.get("error", ""))})
		return
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
	# Time spent waiting for a recipient does not count toward hold_limit_s.
	if str(record["state"]) == AWAITING and moved:
		record["available_ticks"] = Time.get_ticks_msec()
	if state == AWAITING and moved:
		record["awaiting_ticks"] = Time.get_ticks_msec()
		record["await_gap_s"] = await_recheck_s
		record["next_try_ticks"] = Time.get_ticks_msec() + int(await_recheck_s * 1000.0)
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
	var available: int = int(_records[delivery_id]["available_ticks"])
	return Time.get_ticks_msec() - available > int(hold_limit_s * 1000.0)


## The terminal an attempt's receipt found for a record, kept in its target
## so list() by terminal finds a record that was awaiting its recipient.
func _note_terminal(delivery_id: String, receipt: Dictionary) -> void:
	var found = receipt.get("target", {})
	if not _records.has(delivery_id) or not found is Dictionary \
			or str(found.get("terminal_id", "")).is_empty():
		return
	var target: Dictionary = _records[delivery_id]["target"]
	target["terminal_id"] = str(found["terminal_id"])
	target["name"] = str(found.get("name", ""))


func _on_registry_changed() -> void:
	_wake_waiting.call_deferred()


## One attempt for every record awaiting its recipient (`due_only`: only
## those whose backoff gap has passed). A wake asked for while one runs makes
## it go round once more.
func _wake_waiting(due_only: bool = false) -> void:
	if _waking:
		_wake_again = true
		_wake_all = _wake_all or not due_only
		return
	_waking = true
	_wake_again = true
	_wake_all = not due_only
	while _wake_again:
		_wake_again = false
		var all: bool = _wake_all
		_wake_all = false
		await _wake_each(not all)
	_waking = false


func _wake_each(due_only: bool) -> void:
	for id: String in _waiting.keys():
		if not _records.has(id) or str(_records[id]["state"]) != AWAITING:
			_waiting.erase(id)
			continue
		var record: Dictionary = _records[id]
		var now: int = Time.get_ticks_msec()
		if now - int(record["awaiting_ticks"]) > int(await_max_age_s * 1000.0):
			update(id, FAILED_UNAVAILABLE, {"reason": "no recipient for over %d s: %s" % [
				int(await_max_age_s), str(record.get("reason", ""))]})
			_waiting.erase(id)
			continue
		if due_only and now < int(record["next_try_ticks"]):
			continue
		var attempt: Callable = _waiting[id]
		_records[id]["attempts"] = int(_records[id]["attempts"]) + 1
		var receipt: Dictionary = await attempt.call()
		_note_terminal(id, receipt)
		if not _records.has(id) or bool(_records[id].get("chat_tracked", false)):
			_waiting.erase(id)
			continue
		apply_receipt(id, receipt)
		var state: String = str(_records[id]["state"])
		if state == AWAITING:
			var gap: float = minf(float(_records[id]["await_gap_s"]) * 2.0, AWAIT_BACKOFF_MAX_S)
			_records[id]["await_gap_s"] = gap
			_records[id]["next_try_ticks"] = Time.get_ticks_msec() + int(gap * 1000.0)
			continue
		_waiting.erase(id)
		if state == HELD:
			retain(id, attempt)


## While any record awaits its recipient, look every await_recheck_s and try
## the ones whose backoff gap has passed (and give up the ones past
## await_max_age_s).
func _recheck_waiting() -> void:
	if _rechecking_waiting:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_rechecking_waiting = true
	while not _waiting.is_empty():
		await tree.create_timer(await_recheck_s).timeout
		await _wake_waiting(true)
	_rechecking_waiting = false


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
	var submitted: Dictionary = MCPToolUtils.submit_user_message(history, str(record["text"]), {}, true,
		str(record["class"]) == NotifyDeliveryClass.URGENT)
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
