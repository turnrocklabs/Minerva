class_name TriggerHarnessDelivery
extends RefCounted
## Delivers trigger messages to harness sessions (TriggerDestination) through
## the terminal notification path, MCPTerminalTools.notify: one line in the
## host-written "[MINERVA NOTIFY from trigger <name>]" envelope, held while a
## person types there or a dialog is open, queued behind a busy passthrough
## chat. At most one delivery per trigger is outstanding, so a busy session
## is never flooded and nothing arrives twice. The destination's identity
## (its chat, or its harness process) is checked by notify where the write
## happens, so a changed or replaced session is refused, not written to. Each
## trigger's latest outcome is kept as its receipt, written only by the
## attempt that owns it.

const TerminalInputArbiter := preload("res://Scripts/Services/Terminal/TerminalInputArbiter.gd")
const NotifyDeliveryLedger := preload("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd")
const RETRY_S := 2.0
## A delivery still held after this long is given up and reported failed.
const HOLD_LIMIT_S := 600.0

## HOLD_LIMIT_S, as this instance applies it (tests shorten it).
var hold_limit_s: float = HOLD_LIMIT_S

## The MCPTerminalTools that resolves and delivers; tests swap in one whose
## terminal listing and relay are scripted.
var tools: MCPTerminalTools = TriggerDestination.terminal_tools() as MCPTerminalTools
## trigger id -> {attempt, entry_id, ticket}: the delivery in progress.
## entry_id is its chat queue entry once it is queued, else 0 (being sent or
## held); ticket is its host write ticket (TerminalInputArbiter).
var _outstanding: Dictionary = {}
var _receipts: Dictionary = {}
var _attempts: int = 0
## trigger id -> the attempt that owns its receipt: the latest fire that
## wrote one, including one that failed at once. Only that attempt may still
## write the receipt once it has awaited.
var _latest: Dictionary = {}


## Start delivering `message` for `trig`. False when nothing was started: the
## destination does not resolve now, the message is empty, or a delivery is
## still outstanding. A fire while one is held or queued is folded into it:
## its own line (a later docket item, say) is not sent, the receipt counts it
## as coalesced (a scheduled time retried meanwhile counts once per minute
## check), and a scheduled-time trigger tries again at its next minute check,
## as it does for an agent still busy.
func deliver(trig: TriggerDefinition, message: String) -> bool:
	if _is_outstanding(trig.id):
		_receipts[trig.id]["coalesced"] = int(_receipts[trig.id].get("coalesced", 0)) + 1
		return false
	_attempts += 1
	_latest[trig.id] = _attempts
	var line: String = one_line(message)
	if line.is_empty():
		_record(trig, {"status": "failed", "reason": "the message is empty"}, true)
		return false
	var resolved: Dictionary = trig.destination.resolve()
	if resolved.has("error"):
		_record(trig, {"status": "failed", "reason": "unresolved: " + str(resolved.error)}, true)
		return false
	_outstanding[trig.id] = {"attempt": _attempts, "entry_id": 0,
		"ticket": TerminalInputArbiter.issue_ticket()}
	_record(trig, {"status": "sending", "line": line, "truncated": line != _collapse(message)}, true)
	_send(trig, line, _attempts)
	return true


## Stop `trigger_id`'s outstanding delivery: its write ticket is revoked, so
## a send still being resolved or relayed writes and queues nothing; a held
## one is abandoned; a queued one is taken back out of its chat's queue if it
## has not started yet. A write the host already admitted stands.
func cancel(trigger_id: String) -> void:
	if not _outstanding.has(trigger_id):
		return
	TerminalInputArbiter.revoke_ticket(_outstanding[trigger_id].ticket)
	var entry_id: int = _outstanding[trigger_id].entry_id
	_outstanding.erase(trigger_id)
	var delivery_receipt: Dictionary = _receipts.get(trigger_id, {})
	if entry_id <= 0:
		delivery_receipt["status"] = "cancelled"
	elif MCPToolUtils.withdraw_outgoing(entry_id):
		delivery_receipt["status"] = "withdrawn"
	else:
		delivery_receipt["status"] = MCPTerminalTools.notify_status(entry_id, 0)


## The latest outcome for `trigger_id`, or {} when it has never delivered:
## status is sending, held, queued, handed_to_harness, unconfirmed, dropped,
## unknown, failed, cancelled or withdrawn (see NotifyDeliveryLedger), with
## the reason, target and time. A chat delivery is read on from its ledger
## record, which follows it past its queue to the relay's answer, except a
## withdrawn one: cancel took it out of the queue before it ran, and the
## ledger records that only as dropped. A direct write also carries
## pane_mode_check (see TerminalInputArbiter).
func receipt(trigger_id: String) -> Dictionary:
	_is_outstanding(trigger_id)
	var delivery_receipt: Dictionary = _receipts.get(trigger_id, {})
	var delivery_id: String = str(delivery_receipt.get("delivery_id", ""))
	if not delivery_id.is_empty() and not _outstanding.has(trigger_id) \
			and delivery_receipt.get("status") != "withdrawn":
		var state: String = str(NotifyDeliveryLedger.shared().get_record(delivery_id).get("state", ""))
		if not state.is_empty():
			delivery_receipt["status"] = state
	return delivery_receipt.duplicate()


## `message` as one deliverable line: control characters and line breaks
## become spaces, runs of spaces collapse, and anything past the notification
## cap is cut with an ellipsis.
static func one_line(message: String) -> String:
	var line: String = _collapse(message)
	var cap: int = MCPTerminalTools.NOTIFY_MAX_TEXT_LENGTH
	return line if line.length() <= cap else line.left(cap - 1) + "…"


static func _collapse(message: String) -> String:
	var spaced := ""
	for i in message.length():
		var code: int = message.unicode_at(i)
		spaced += " " if code < 0x20 or code == 0x7F else message[i]
	var words := PackedStringArray()
	for word in spaced.split(" ", false):
		words.append(word)
	return " ".join(words)


## Send, and while the target holds, look again every RETRY_S until it takes
## the line, refuses it, or the hold limit has passed (checked before each
## look, so a hold that clears late sends nothing). The attempt's ticket goes
## with every send and is revoked when the attempt ends.
func _send(trig: TriggerDefinition, line: String, attempt: int) -> void:
	var ticket: String = _outstanding[trig.id].ticket
	await _send_until_settled(trig, line, attempt, ticket)
	TerminalInputArbiter.revoke_ticket(ticket)


func _send_until_settled(trig: TriggerDefinition, line: String, attempt: int, ticket: String) -> void:
	var started: int = Time.get_ticks_msec()
	var last_hold: String = ""
	while _current(trig.id, attempt):
		if Time.get_ticks_msec() - started > hold_limit_s * 1000.0:
			_finish(trig, {"status": "failed", "reason": "held for over %d s: %s" % [int(hold_limit_s), last_hold]})
			return
		var resolved: Dictionary = trig.destination.resolve()
		if resolved.has("error"):
			_finish(trig, {"status": "failed", "reason": "unresolved: " + str(resolved.error)})
			return
		var expect: Dictionary = trig.destination.expectation()
		expect["ticket"] = ticket
		var sent: Dictionary = await tools.notify({"to": resolved.terminal_id,
			"from": _sender(trig), "text": line}, expect)
		var status: String = str(sent.get("status", "failed"))
		var target: Dictionary = sent.get("target", {})
		if status == "queued":
			if not _current(trig.id, attempt):
				MCPToolUtils.withdraw_outgoing(int(sent.get("entry_id", 0)))
				return
			_outstanding[trig.id].entry_id = int(sent.get("entry_id", 0))
			_record(trig, {"status": "queued", "target": target,
				"delivery_id": str(sent.get("delivery_id", ""))})
			return
		if status != "held":
			# A write that happened is recorded even if a cancel landed
			# mid-send, unless a newer attempt has started since (the receipt
			# is its); a cancelled send that wrote nothing leaves "cancelled".
			var cancelled: bool = not _current(trig.id, attempt)
			if not cancelled:
				_outstanding.erase(trig.id)
			if _latest.get(trig.id) != attempt or (cancelled and not sent.get("success", false)):
				return
			var reason: String = "" if sent.get("success", false) else str(sent.get("error", ""))
			var outcome: Dictionary = {"status": "failed" if status == "error" else status,
				"reason": reason, "target": target}
			if sent.has("pane_mode_check"):
				outcome["pane_mode_check"] = sent["pane_mode_check"]
			if sent.has("delivery_id"):
				outcome["delivery_id"] = str(sent["delivery_id"])
			_record(trig, outcome)
			return
		if not _current(trig.id, attempt):
			return
		last_hold = str(sent.get("error", ""))
		_record(trig, {"status": "held", "hold_reason": str(sent.get("hold_reason", "")),
			"reason": last_hold, "target": target})
		await Engine.get_main_loop().create_timer(RETRY_S).timeout


func _current(trigger_id: String, attempt: int) -> bool:
	return _outstanding.has(trigger_id) and _outstanding[trigger_id].attempt == attempt


## Whether a delivery is outstanding; a queued one that has left its chat's
## queue is settled into its receipt first.
func _is_outstanding(trigger_id: String) -> bool:
	if not _outstanding.has(trigger_id):
		return false
	var entry_id: int = _outstanding[trigger_id].entry_id
	if entry_id <= 0 or MCPToolUtils.outgoing_queue_position(entry_id) > 0:
		return true
	_outstanding.erase(trigger_id)
	_receipts[trigger_id]["status"] = MCPTerminalTools.notify_status(entry_id, 0)
	return false


func _finish(trig: TriggerDefinition, fields: Dictionary) -> void:
	_outstanding.erase(trig.id)
	_record(trig, fields)


## Replace the receipt's outcome fields, keeping what the attempt started with;
## `fresh` starts a new attempt's receipt, carrying nothing from the last one.
func _record(trig: TriggerDefinition, fields: Dictionary, fresh: bool = false) -> void:
	var delivery_receipt: Dictionary = {} if fresh or not _receipts.has(trig.id) else _receipts[trig.id]
	for key in ["reason", "hold_reason", "pane_mode_check", "delivery_id"]:
		delivery_receipt.erase(key)
	delivery_receipt.merge(fields, true)
	delivery_receipt["destination"] = trig.destination.label
	delivery_receipt["at"] = Time.get_datetime_string_from_system(false, true)
	_receipts[trig.id] = delivery_receipt


## The envelope's sender: "trigger <name>", made safe for it (no brackets, no
## forged reply address, within the sender cap).
static func _sender(trig: TriggerDefinition) -> String:
	var name: String = _collapse(trig.name).replace("]", "").replace("[", "").replace("(reply to:", "")
	return ("trigger " + name).strip_edges().left(MCPTerminalTools.NOTIFY_MAX_FROM_LENGTH)
