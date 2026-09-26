extends RefCounted
## The delivery half of minerva_terminal_notify: target resolution, the holds,
## the chat and direct (relay) paths, the ledger glue that keeps a held or
## unaddressable line, and the receipts. MCPTerminalTools owns the tools and
## the terminal facts; it builds one of these per call (MCPTerminalTools
## ._delivery) and every notify entry point there forwards here.
##
## Every environment fact is read back through `tools`, the MCPTerminalTools
## that built this: its listing (_terminal_list), session lookup
## (_resolve_session), chat binding (_find_passthrough_chat) and the two
## injectable seams (relay_send_source, watch_profile_source). A test that
## overrides those on the module steers this code too. The limits the relay
## shares by convention (NOTIFY_ENVELOPE_PREFIX, NOTIFY_HUMAN_TYPING_MS) and
## the tool-schema limits stay on MCPTerminalTools and are read from there.

## Preloaded (not class_name) so this parses in isolated --script harnesses.
const TerminalInputArbiter := preload("res://Scripts/Services/Terminal/TerminalInputArbiter.gd")
const NotifyDeliveryLedger := preload("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd")
const HarnessSessionRegistry := preload("res://Scripts/Services/Terminal/HarnessSessionRegistry.gd")
const NotifyDeliveryClass := preload("res://Scripts/Services/Terminal/NotifyDeliveryClass.gd")

## Pause between looks while a direct delivery waits out a hold.
const NOTIFY_RETRY_INTERVAL_S := 0.25
## How long a line typed into a harness's own queue is looked for there.
const NATIVE_QUEUE_CONFIRM_MS := 2000

const AGENT_RELAY_WATCH_STATUS_TOOL := "minerva_agent_relay_watch_status"
const AGENT_RELAY_SEND_TOOL := "minerva_agent_relay_send"
const AGENT_RELAY_PLUGIN_ID := "agent_relay"

## The hint each harness shows while a turn runs: the host-side twin of the
## relay's spinner_glyphs (agent-relay profiles.rs). Change one and change the
## other. Both harnesses draw it on their status row while working.
const BUSY_MARKERS := {
	"claude": ["esc to interrupt"],
	"codex": ["esc to interrupt"],
}

## How far up from the last drawn row the busy hint is looked for.
const BUSY_WINDOW_ROWS := 12

## What a kept notification's receipt tells its sender.
const RETAINED_NOTE := "Minerva keeps this notification and delivers it when that clears; do not send it again. minerva_terminal_notify_status with this delivery_id shows where it stands."
const AWAITING_NOTE := "No session that can take it holds this address now. Minerva keeps this notification and delivers it once one does (it registers, or the role is handed over); do not send it again. minerva_terminal_notify_status with this delivery_id shows where it stands."

## The MCPTerminalTools this delivery reads its terminals through.
var tools = null


func _init(owner_tools = null) -> void:
	tools = owner_tools


## The one terminal `to` names, as minerva_terminal_notify resolves it, plus
## "chat_id" when a passthrough chat is bound to it; {success:false, error}
## when none or several match.
func resolve_address(to: String) -> Dictionary:
	var target: Dictionary = await resolve_target(to, tools.list_terminals())
	if target.get("success", false):
		var history = tools._find_passthrough_chat(str(target["terminal_id"]))
		if history != null:
			target["chat_id"] = str(history.HistoryId)
	return target


## The MCP tool: one delivery, and when it is held the line is KEPT. The first
## look (or looks, within wait_ms) is made here; a held line is then recorded
## in the ledger and retried there, one look each time, addressed by session
## identity (or the role it was sent to) when the target has one, else by
## terminal id, so a renamed tab keeps its line. A line for a registered
## identity or role no reachable session holds is recorded as
## awaiting_recipient and tried again by the ledger when one does. Chat
## deliveries are tracked by the chat path itself. A request refused before
## any target was chosen (bad arguments, no such terminal, no harness) is not
## a delivery and gets no record.
func notify_tool(arguments: Dictionary) -> Dictionary:
	var receipt: Dictionary = await terminal_notify(arguments, {}, {"hold_busy": true})
	var target: Dictionary = receipt.get("target", {})
	var ledger = NotifyDeliveryLedger.shared()
	var to: String = str(arguments.get("to", "")).strip_edges()
	var sessions = HarnessSessionRegistry.shared()
	if str(receipt.get("code", "")) in HarnessSessionRegistry.RECIPIENT_UNAVAILABLE:
		var awaiting: Dictionary = {"address": to, "terminal_id": "", "name": ""}
		if sessions.is_registered(to):
			awaiting["identity"] = sessions.current_identity(to)
			awaiting["address"] = awaiting["identity"]
		var klass: String = NotifyDeliveryClass.class_of(_urgent(arguments))
		var waiting_id: String = ledger.open(awaiting, _envelope(arguments), "relay",
			NotifyDeliveryLedger.AWAITING, {"reason": str(receipt.get("error", "")), "class": klass})
		ledger.wait_for_recipient(waiting_id, _retry_attempt(arguments, waiting_id))
		return {"success": true, "retained": true, "status": NotifyDeliveryLedger.AWAITING,
			"code": str(receipt["code"]), "reason": str(receipt.get("error", "")),
			"target": awaiting, "delivery_id": waiting_id, "note": AWAITING_NOTE,
			"class": klass, "mechanism": "", "delivered_at": ""}
	if receipt.has("delivery_id") or target.is_empty():
		return receipt
	if not str(target.get("identity", "")).is_empty():
		target["address"] = to if sessions.is_role(to) else str(target["identity"])
	var envelope: String = _envelope(arguments)
	var status: String = str(receipt.get("status", ""))
	var classed: Dictionary = {}
	for field: String in ["class", "mechanism", "delivered_at"]:
		classed[field] = str(receipt.get(field, ""))
	if str(classed["class"]).is_empty():
		classed["class"] = NotifyDeliveryClass.class_of(_urgent(arguments))
	if status == NotifyDeliveryLedger.HANDED or status == NotifyDeliveryLedger.UNCONFIRMED:
		receipt["delivery_id"] = ledger.open(target, envelope, "relay", status,
			classed.merged({"submit": receipt.get("submit", ""), "reason": str(receipt.get("reason", ""))}))
		return receipt
	if status != NotifyDeliveryLedger.HELD:
		receipt["delivery_id"] = ledger.open(target, envelope, "relay", NotifyDeliveryLedger.FAILED,
			classed.merged({"reason": str(receipt.get("error", status))}))
		return receipt
	# A registered session is looked for by identity (or the role it was
	# addressed by) on every retry, so a line kept for it follows it to the
	# tab it registers from next.
	var id: String = ledger.open(target, envelope, "relay", NotifyDeliveryLedger.HELD, classed.merged({
		"hold_reason": str(receipt.get("hold_reason", "")),
		"reason": str(receipt.get("reason", ""))}))
	ledger.retain(id, _retry_attempt(arguments, id))
	var kept: Dictionary = receipt.duplicate()
	kept.erase("error")
	kept["success"] = true
	kept["retained"] = true
	kept["delivery_id"] = id
	kept["note"] = RETAINED_NOTE
	return kept


## One more look for kept delivery `delivery_id`, made by the address its
## record carries at the time, which a handover may move
## (NotifyDeliveryLedger.retarget). A Callable for the ledger's retries.
func _retry_attempt(arguments: Dictionary, delivery_id: String) -> Callable:
	var retry: Dictionary = arguments.duplicate()
	retry["wait_ms"] = 0
	var ledger = NotifyDeliveryLedger.shared()
	return func() -> Dictionary:
		var again: Dictionary = retry.duplicate()
		again["to"] = ledger.address_of(delivery_id)
		return await terminal_notify(again, {}, {"hold_busy": true, "delivery_id": delivery_id})


## One record, or the records for a terminal, from the ledger.
func status_tool(arguments: Dictionary) -> Dictionary:
	var ledger = NotifyDeliveryLedger.shared()
	var id: String = str(arguments.get("delivery_id", "")).strip_edges()
	if not id.is_empty():
		var record: Dictionary = ledger.get_record(id)
		if record.is_empty():
			return MCPToolUtils.error("No notification '%s' is on record (ids are per Minerva run; the oldest settled ones are dropped past %d)" % [
				id, NotifyDeliveryLedger.RECORDS_KEPT])
		return {"success": true, "delivery": record}
	var records: Array[Dictionary] = ledger.list(str(arguments.get("terminal_id", "")).strip_edges(),
		bool(arguments.get("open_only", false)))
	return {"success": true, "deliveries": records, "count": records.size()}


## The envelope every notification is delivered inside, built from the tool's
## arguments. The envelope, not the name inside it, is what recipients are told
## to trust: only the host writes this prefix. The reply address rides inside
## it so the recipient answers this instance and not a look-alike.
func _envelope(arguments: Dictionary) -> String:
	var from: String = str(arguments.get("from", "")).strip_edges()
	var reply_to: String = str(arguments.get("reply_to", "")).strip_edges()
	var text: String = str(arguments.get("text", "")).strip_edges()
	var reply_suffix: String = "" if reply_to.is_empty() else " (reply to: %s)" % reply_to
	return "%s%s%s] %s" % [tools.NOTIFY_ENVELOPE_PREFIX, from, reply_suffix, text]


## Whether the caller marked this notification urgent.
static func _urgent(arguments: Dictionary) -> bool:
	var urgent = arguments.get("urgent", false)
	if urgent is bool:
		return urgent
	return str(urgent).to_lower() == "true"


## One line from one harness to another. The host resolves the target, holds
## while a person is typing there, then hands the envelope to whichever
## delivery path the target has: its passthrough chat (queue + bubble) or the
## relay's gated send straight into the harness. `options`:
##   hold_busy   — on the direct path, hold while the harness shows a turn
##                 running (BUSY_MARKERS) instead of typing into it
##   delivery_id — the ledger record a chat delivery is tracked into; without
##                 it the chat path opens one of its own
func terminal_notify(arguments: Dictionary, expect: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	var to: String = str(arguments.get("to", "")).strip_edges()
	var text: String = str(arguments.get("text", "")).strip_edges()
	var from: String = str(arguments.get("from", "")).strip_edges()
	var reply_to: String = str(arguments.get("reply_to", "")).strip_edges()

	if to.is_empty():
		return MCPToolUtils.error("to is required: a terminal id, a tab name, harness@tab name, or a harness (claude/codex)")
	if from.is_empty():
		return MCPToolUtils.error("from is required: the name this notification is delivered under")
	var invalid: String = _validate_notify_line(text, from)
	if not invalid.is_empty():
		return MCPToolUtils.error(invalid)

	var listing: Array = tools._terminal_list({}).get("terminals", [])
	var target: Dictionary = await resolve_target(to, listing)
	if not target.get("success", false):
		return target
	# A reply address must be a terminal that exists or a registered session:
	# a typo here would send every answer to nobody.
	var sessions = HarnessSessionRegistry.shared()
	if not reply_to.is_empty() and tools._listing_entry(listing, reply_to).is_empty() \
			and not sessions.is_registered(reply_to):
		return MCPToolUtils.error("reply_to '%s' is neither a terminal here nor a registered session; pass your session identity or your own $MINERVA_TERMINAL_ID" % reply_to)
	# The permission rule (see the file header): everything but the caller's
	# own terminal.
	var own_terminal: String = reply_to if not tools._listing_entry(listing, reply_to).is_empty() \
		else sessions.terminal_of(reply_to)
	if not own_terminal.is_empty() and own_terminal == str(target["terminal_id"]):
		var own: Dictionary = MCPToolUtils.error("'%s' is your own terminal (reply_to %s); a session does not notify itself" % [
			str(target["name"]), reply_to])
		own["code"] = "notify_self"
		return own

	var envelope: String = _envelope(arguments)
	var urgent: bool = _urgent(arguments)

	var wait_ms: int = clampi(
		MCPToolUtils.coerce_int(arguments.get("wait_ms", 0)), 0, tools.NOTIFY_MAX_WAIT_MS)
	var receipt_target: Dictionary = {
		"terminal_id": str(target["terminal_id"]),
		"name": str(target["name"]),
	}
	if not str(target.get("identity", "")).is_empty():
		receipt_target["identity"] = str(target["identity"])

	var history = tools._find_passthrough_chat(str(target["terminal_id"]))
	var expect_chat: String = str(expect.get("chat_id", ""))
	if not expect_chat.is_empty() and (history == null or str(history.HistoryId) != expect_chat):
		return _changed(receipt_target, "'%s' is no longer the terminal of the chat this was meant for" % str(target["name"]))
	if expect.has("process") and history != null:
		return _changed(receipt_target, "'%s' now has a passthrough chat; its session is not the one this was meant for" % str(target["name"]))
	if history == null:
		# The direct path paces its own holds within wait_ms.
		return await _notify_direct(target, receipt_target, envelope, wait_ms, expect,
			bool(options.get("hold_busy", false)), urgent)

	# The chat path queues, so its holds are decided once, now. A person
	# mid-sentence in the target outranks any agent: the write would submit
	# their half-typed line with the envelope stapled to it.
	var typed_ago: int = _ms_since_human_input(target, str(target["terminal_id"]))
	if typed_ago >= 0 and typed_ago < tools.NOTIFY_HUMAN_TYPING_MS:
		return _held(receipt_target, "human_typing",
			"a person typed in '%s' %d ms ago; nothing was written" % [str(target["name"]), typed_ago])
	# The chat's relay types into the foreground process: without a harness
	# there the line would run as a shell command. A foreground the platform
	# can report but could not read just now is a hold, not a shell.
	if str(target.get("harness", "")).is_empty():
		if target.has("foreground_process") and str(target["foreground_process"]).is_empty():
			return _held(receipt_target, "foreground_unknown",
				"the foreground process of '%s' could not be read; nothing was written" % str(target["name"]))
		return _no_harness(target)
	if _withdrawn(expect):
		return _withdrawn_receipt(receipt_target)

	receipt_target["chat_id"] = str(history.HistoryId)
	# No notification, urgent included, takes a turn the chat's agent is
	# blocked on: while a question card is unanswered this queues (deferred)
	# rather than starting a generate, so the human's answer goes first. An
	# urgent one only moves ahead of routine notifications in that queue.
	# The ledger follows the line past the chat's queue to the relay's answer:
	# leaving the queue is not the harness taking it. The record goes to the
	# chat before the submit, because an idle chat starts the turn inside it.
	var ledger = NotifyDeliveryLedger.shared()
	var delivery_id: String = str(options.get("delivery_id", ""))
	if delivery_id.is_empty():
		delivery_id = ledger.open(receipt_target, envelope, "chat", NotifyDeliveryLedger.SENDING,
			{"class": NotifyDeliveryClass.class_of(urgent)})
	ledger.begin_chat(delivery_id, str(history.HistoryId))
	var submitted: Dictionary = MCPToolUtils.submit_user_message(history, envelope, {}, true, urgent)
	if not submitted.get("success", false):
		ledger.update(delivery_id, NotifyDeliveryLedger.FAILED,
			{"reason": str(submitted.get("error", "the chat refused it"))})
		submitted["delivery_id"] = delivery_id
		submitted["status"] = NotifyDeliveryLedger.FAILED
		submitted["target"] = receipt_target
		return submitted

	# The receipt follows the QUEUE ENTRY, not the text: two identical
	# notifications are two entries, and an entry that vanishes from the queue
	# may have been cancelled rather than run.
	var entry_id: int = MCPToolUtils.coerce_int(submitted.get("entry_id", 0))
	ledger.track_chat_entry(delivery_id, entry_id)
	if wait_ms > 0:
		await _await_notify_taken(delivery_id, wait_ms)
	var record: Dictionary = ledger.get_record(delivery_id)
	var receipt: Dictionary = {
		"success": true,
		"target": receipt_target,
		"status": str(record.get("state", "")),
		"queue_position": MCPToolUtils.outgoing_queue_position(entry_id),
		"entry_id": entry_id,
		"delivery_id": delivery_id,
		"class": str(record.get("class", "")),
		"mechanism": str(record.get("mechanism", "")),
		"delivered_at": str(record.get("delivered_at", "")),
	}
	if not str(record.get("hold_reason", "")).is_empty():
		receipt["hold_reason"] = str(record["hold_reason"])
		receipt["retained"] = true
		receipt["note"] = RETAINED_NOTE
	return receipt


## Delivery to a terminal with no passthrough chat: the relay types the
## envelope, classifying the screen with the harness it can see in the
## foreground, and starts no watch (a watch would register a passthrough
## provider nobody asked for). A bare shell is refused outright — the line
## would run as a command.
##
## The relay is asked for ONE look at a time and the human-typing rule is
## re-read from the live session before each look: a relay left to wait out
## a dialog would write the instant a person's keystroke cleared it, which is
## exactly when that person is at the keyboard.
##
## An urgent line for a harness whose own input queue was measured on this
## platform is not held for a running turn: it is typed into that queue, and
## taken as handed only when the harness's queued marker shows it
## (NotifyDeliveryClass.harness_queued). Every other line waits for the turn
## to end. Each receipt carries class, mechanism and delivered_at.
func _notify_direct(target: Dictionary, receipt_target: Dictionary,
		envelope: String, wait_ms: int, expect: Dictionary = {}, hold_busy: bool = false,
		urgent: bool = false) -> Dictionary:
	var klass: String = NotifyDeliveryClass.class_of(urgent)
	var harness: String = str(target.get("harness", ""))
	var pid: int = int(target.get("foreground_pid", 0))
	var tid: String = str(target["terminal_id"])
	var session = tools._resolve_session(tid)
	var deadline: int = Time.get_ticks_msec() + wait_ms
	var tree: SceneTree = SingletonObject.get_tree()
	while true:
		# Every hold is decided per look, so a wait can outlast a person's
		# last keystroke or a momentarily unreadable foreground. The
		# foreground can change while a delivery waits (the harness exits,
		# the shell is back): the live process decides each look, and a
		# terminal whose foreground can no longer be read is not written to.
		var typed_ago: int = _ms_since_human_input(target, tid)
		var hold: Dictionary = {}
		if session == null and target.has("foreground_process") \
				and str(target["foreground_process"]).is_empty():
			# No live session to re-read (a listing-only caller): the snapshot
			# stands.
			hold = _held(receipt_target, "foreground_unknown",
				"the foreground process of '%s' could not be read; nothing was written" % str(target["name"]))
		elif harness.is_empty() and session == null:
			return _no_harness(target)
		elif session != null and target.has("foreground_process"):
			if not session.is_alive():
				var gone: Dictionary = MCPToolUtils.error("Terminal '%s' (id %s) exited; nothing was written" % [
					str(target["name"]), tid])
				gone["status"] = "error"
				gone["target"] = receipt_target
				return gone
			var foreground: Dictionary = session.get_foreground_process()
			if foreground.is_empty() or str(foreground.get("name", "")).is_empty():
				hold = _held(receipt_target, "foreground_unknown",
					"the foreground process of '%s' could not be read; nothing was written" % str(target["name"]))
			else:
				harness = session.harness_of(foreground)
				pid = int(foreground.get("pid", 0))
				if harness.is_empty():
					target["foreground_process"] = session.program_of(foreground)
					return _no_harness(target)
		# The harness in front decides the mechanism on every look.
		var mechanism: String = NotifyDeliveryClass.planned(klass, harness, false)
		var native: bool = mechanism == NotifyDeliveryClass.NATIVE_QUEUE
		if hold.is_empty() and typed_ago >= 0 and typed_ago < tools.NOTIFY_HUMAN_TYPING_MS:
			hold = _held(receipt_target, "human_typing",
				"a person typed in '%s' %d ms ago; nothing was written" % [str(target["name"]), typed_ago])
		elif hold.is_empty() and _withdrawn(expect):
			return _withdrawn_receipt(receipt_target)
		elif hold.is_empty() and int(expect.get("process", 0)) > 0 and pid <= 0:
			hold = _held(receipt_target, "process_unknown",
				"the foreground process of '%s' cannot be identified just now, so it cannot be confirmed as the expected session; nothing was written" % str(target["name"]))
		elif hold.is_empty() and hold_busy and not native and _busy_turn_shown(session, harness):
			hold = _held(receipt_target, "busy_turn",
				"%s in '%s' is in the middle of a turn; nothing was written" % [harness, str(target["name"])])
		elif hold.is_empty():
			var changed: String = _expectation_broken(expect, harness, pid, str(target["name"]))
			if not changed.is_empty():
				return _changed(receipt_target, changed)
			# The host decides these again when it admits the relay's write, so
			# a restart or a withdrawal during the relay's round trip still
			# stops it.
			var expected_harness: String = str(expect.get("harness", ""))
			# A write made while a turn shows lands in the harness's own input
			# queue; the screen before it is what the queued marker is judged
			# against.
			var into_turn: bool = _busy_turn_shown(session, harness)
			var before: String = _screen_text(session) if into_turn else ""
			var raw = await _relay_send({
				"terminal_id": tid, "text": envelope, "arm": false,
				"profile": harness, "gate_budget_ms": 0,
				"human_guard_ms": tools.NOTIFY_HUMAN_TYPING_MS,
				"expect_harness": expected_harness if not expected_harness.is_empty() else harness,
				"expect_process": int(expect.get("process", 0)),
				"write_ticket": str(expect.get("ticket", "")),
			})
			var classified: Dictionary = PassthroughLaunchDialog._classify_watch_result(
				raw if raw is Dictionary else {"error": "relay send returned nothing"})
			if classified.get("ok", false):
				var sent: Dictionary = classified.get("result", {})
				var submit = sent.get("submit", null)
				var submit_state: String = str(submit.get("state", "")) if submit is Dictionary else ""
				var evidence: String = str(submit.get("evidence", "")) if submit is Dictionary else ""
				# The relay's own confirmation is the only evidence the harness
				# took the line; any other outcome typed it and proved nothing.
				var status: String = NotifyDeliveryLedger.HANDED if submit_state == "submitted" \
					else NotifyDeliveryLedger.UNCONFIRMED
				var why: String = ""
				var used: String = mechanism
				if into_turn and evidence == "echo":
					# An echo is only confirmed once no turn shows: the line ran
					# as a submit of its own.
					used = NotifyDeliveryClass.RELAY_WHEN_IDLE
				elif into_turn:
					used = NotifyDeliveryClass.NATIVE_QUEUE \
						if NotifyDeliveryClass.native_queue_measured(harness, NotifyDeliveryClass.platform()) \
						else NotifyDeliveryClass.RELAY_INTO_TURN
					# The relay's "busy" evidence was on screen before this write,
					# so only the harness's queued marker confirms it.
					var queued: bool = false
					if status == NotifyDeliveryLedger.HANDED and used == NotifyDeliveryClass.NATIVE_QUEUE:
						queued = await _harness_queued(session, harness, envelope, before)
					if status == NotifyDeliveryLedger.HANDED and not queued:
						status = NotifyDeliveryLedger.UNCONFIRMED
						why = "typed while %s was in a turn; its queued marker did not show the line" % harness
				elif used == NotifyDeliveryClass.NATIVE_QUEUE:
					used = NotifyDeliveryClass.RELAY_WHEN_IDLE
				var written: Dictionary = _stamped({
					"success": true, "target": receipt_target,
					"status": status,
					"harness": harness,
					"submit": submit_state,
				}, klass, used)
				if not why.is_empty():
					written["reason"] = why
				# The host's pane-mode verdict ("unknown": the container does not
				# report it, so nothing could hold this for it); absent from an
				# older relay or host.
				if sent.get("pane_mode_check") is String:
					written["pane_mode_check"] = sent["pane_mode_check"]
				return written
			var reason: String = str(classified.get("error", ""))
			if not _relay_reply_is_hold(raw):
				var failed: Dictionary = MCPToolUtils.error(reason)
				failed["status"] = "error"
				failed["target"] = receipt_target
				return failed
			hold = _held(receipt_target, _relay_hold_reason(raw, reason), reason)
		# The budget is checked before sleeping and again on waking, so no
		# look is taken once the caller's wait has lapsed.
		var remaining_ms: int = deadline - Time.get_ticks_msec()
		if tree == null or remaining_ms <= 0:
			return _stamped(hold, klass, mechanism)
		await tree.create_timer(minf(NOTIFY_RETRY_INTERVAL_S, remaining_ms / 1000.0)).timeout
		if Time.get_ticks_msec() >= deadline:
			return _stamped(hold, klass, mechanism)
	# Unreachable: the loop only leaves through the returns above, but the
	# parser wants every path to yield a value.
	return {}


## `receipt` with its class, the mechanism that carries it and when the
## harness gets it (NotifyDeliveryClass).
static func _stamped(receipt: Dictionary, klass: String, mechanism: String) -> Dictionary:
	receipt["class"] = klass
	receipt["mechanism"] = mechanism
	receipt["delivered_at"] = NotifyDeliveryClass.delivered_at(mechanism)
	return receipt


## Whether the harness shows `envelope` in its own input queue, looked for
## until NATIVE_QUEUE_CONFIRM_MS has passed: the queued state was first seen
## within a second of the Enter in the measurements.
func _harness_queued(session, harness: String, envelope: String, before: String) -> bool:
	var tree: SceneTree = SingletonObject.get_tree()
	var deadline: int = Time.get_ticks_msec() + NATIVE_QUEUE_CONFIRM_MS
	while true:
		if NotifyDeliveryClass.harness_queued(harness, envelope, before, _screen_text(session)):
			return true
		if tree == null or Time.get_ticks_msec() >= deadline:
			return false
		await tree.create_timer(NOTIFY_RETRY_INTERVAL_S).timeout
	return false


func _screen_text(session) -> String:
	if session == null or not session.has_method("read_viewport_text"):
		return ""
	return str(session.read_viewport_text())


## The refusal for a terminal whose foreground is not an agent harness.
func _no_harness(target: Dictionary) -> Dictionary:
	return MCPToolUtils.error("Terminal '%s' (id %s) has no agent harness in the foreground (%s); a notification typed into a shell would run as a command" % [
		str(target["name"]), str(target["terminal_id"]),
		str(target.get("foreground_process", "unknown process"))])


## Why the session in the terminal is not the one `expect` names ("" when it
## is, or when nothing is expected): another harness, or the same kind of
## harness started again (a different process group). An unreadable process
## group is not judged here; callers hold or refuse on it themselves.
static func _expectation_broken(expect: Dictionary, harness: String, pid: int, name: String) -> String:
	var want_harness: String = str(expect.get("harness", ""))
	if not want_harness.is_empty() and harness != want_harness:
		return "'%s' now runs %s, not %s" % [name, harness if not harness.is_empty() else "no harness", want_harness]
	var want_pid: int = int(expect.get("process", 0))
	if want_pid > 0 and pid > 0 and pid != want_pid:
		return "the %s in '%s' was replaced by another one" % [want_harness, name]
	return ""


## Whether the caller has withdrawn this delivery (revoked its ticket).
static func _withdrawn(expect: Dictionary) -> bool:
	var ticket: String = str(expect.get("ticket", ""))
	return not ticket.is_empty() and not TerminalInputArbiter.ticket_valid(ticket)


func _withdrawn_receipt(receipt_target: Dictionary) -> Dictionary:
	var withdrawn: Dictionary = MCPToolUtils.error("the sender withdrew this notification; nothing was written")
	withdrawn["status"] = "withdrawn"
	withdrawn["target"] = receipt_target
	return withdrawn


## A refusal because the terminal now holds a different session than the one
## the caller meant.
func _changed(receipt_target: Dictionary, why: String) -> Dictionary:
	var changed: Dictionary = MCPToolUtils.error("%s; nothing was written" % why)
	changed["status"] = "error"
	changed["target"] = receipt_target
	return changed


## A hold receipt: not delivered, retry later, and why.
func _held(receipt_target: Dictionary, hold_reason: String, why: String) -> Dictionary:
	var held: Dictionary = MCPToolUtils.error("%s. Send again in a moment." % why)
	held["status"] = "held"
	held["hold_reason"] = hold_reason
	held["reason"] = why
	held["target"] = receipt_target
	return held


## The relay marks a gate refusal with held:true inside its error payload.
func _relay_reply_is_hold(raw) -> bool:
	return bool(_relay_error_payload(raw).get("held", false))


## The relay's error payload: the reply itself when the refusal keys are
## already at the top level, else the JSON inside its MCP content block.
func _relay_error_payload(raw) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	for key in ["held", "outcome", "hold_reason"]:
		if raw.has(key):
			return raw
	var content = raw.get("content", null)
	if content is Array and content.size() > 0 and content[0] is Dictionary:
		var parsed = JSON.parse_string(str(content[0].get("text", "{}")))
		if parsed is Dictionary:
			return parsed
	return raw


## Why the relay held this delivery. The refusal's own structured keys decide
## it — hold_reason as sent, else the host outcome it carries, which the
## terminal arbiter names "refused_<reason>". Prose is the fallback for a relay
## build that sends only a message: the composer hold is then told from a
## screen hold by the phrase the arbiter writes into it.
func _relay_hold_reason(raw, reason: String) -> String:
	var payload: Dictionary = _relay_error_payload(raw)
	var stated: String = str(payload.get("hold_reason", ""))
	if not stated.is_empty():
		return stated
	var outcome: String = str(payload.get("outcome", ""))
	if not outcome.is_empty():
		return outcome.trim_prefix("refused_")
	if reason.contains(TerminalInputArbiter.COMPOSER_HOLD_PHRASE):
		return "composer_not_empty"
	# The relay's own slot: its previous prompt's turn has not ended.
	if reason.contains("still in flight"):
		return "busy_turn"
	return "screen"


## Milliseconds since a person last typed in this terminal, or -1 when never.
## Read from the live session when there is one — the listing is a snapshot
## and a keystroke can land while a delivery waits — else from the listing.
func _ms_since_human_input(target: Dictionary, terminal_id: String = "") -> int:
	var last: int = MCPToolUtils.coerce_int(target.get("last_input_ms", 0))
	if not terminal_id.is_empty():
		var session = tools._resolve_session(terminal_id)
		if session != null and "last_input_ms" in session:
			last = int(session.last_input_ms)
	if last <= 0:
		return -1
	return maxi(0, int(Time.get_unix_time_from_system() * 1000.0) - last)




func _relay_send(args: Dictionary):
	if tools.relay_send_source.is_valid():
		return await tools.relay_send_source.call(args)
	return await call_relay_tool(AGENT_RELAY_SEND_TOOL, args)


## One relay tool call from inside the host: through PluginToolRegistry when
## it has synced the plugin's manifest tools, else straight down the plugin's
## connection (the registry learns manifest tools on a state change that a
## just-started plugin may not have had yet). Errors come back as {"error"}.
func call_relay_tool(tool_name: String, args: Dictionary):
	var registry = SingletonObject.plugin_tool_registry if "plugin_tool_registry" in SingletonObject else null
	if registry != null and registry.has_method("is_plugin_tool") and registry.is_plugin_tool(tool_name):
		return await registry.handle_tool_call(tool_name, args)
	var manager = SingletonObject.plugin_manager if "plugin_manager" in SingletonObject else null
	var conn = manager.get_connection(AGENT_RELAY_PLUGIN_ID) if manager != null and manager.has_method("get_connection") else null
	if conn == null:
		var relay = manager.get_db().get_by_id(AGENT_RELAY_PLUGIN_ID) if manager != null and manager.has_method("get_db") else null
		var issue := RequiredPlugins.runtime_issue(relay) if relay != null else ""
		if manager != null and (relay == null or not issue.is_empty()):
			return {"error": "%s Nothing was typed into that terminal." % RequiredPlugins.missing_message(AGENT_RELAY_PLUGIN_ID, issue)}
		return {"error": "the agent-relay plugin is not running, so nothing can type into that terminal"}
	return await conn.call_tool(tool_name, args)


## Empty string when the line is deliverable, else why it is not.
func _validate_notify_line(text: String, from: String) -> String:
	if text.is_empty():
		return "text is required"
	if text.contains("\n") or text.contains("\r"):
		return "text must be ONE line — a notification is a pointer, not a payload. Put the detail where the line points."
	if _first_control_char(text) >= 0:
		return "text contains a control character (0x%02X) — the envelope is typed into a terminal, where control bytes are keystrokes, not text" % _first_control_char(text)
	if text.length() > tools.NOTIFY_MAX_TEXT_LENGTH:
		return "text is %d characters; the cap is %d. A notification is a pointer, not a payload." % [
			text.length(), tools.NOTIFY_MAX_TEXT_LENGTH]
	if from.contains("\n") or from.contains("\r") or from.contains("]"):
		return "from must be a single line and must not contain ']' — it goes inside the notify envelope"
	if from.contains("(reply to:"):
		return "from must not contain '(reply to:' — the reply address is written by the host from reply_to, never self-declared"
	if _first_control_char(from) >= 0:
		return "from contains a control character (0x%02X) — the envelope is typed into a terminal, where control bytes are keystrokes, not text" % _first_control_char(from)
	if from.length() > tools.NOTIFY_MAX_FROM_LENGTH:
		return "from is %d characters; the cap is %d" % [from.length(), tools.NOTIFY_MAX_FROM_LENGTH]
	return ""


## Code point of the first C0 control character or DEL in `line`, or -1 when
## the line is all printable. The envelope ends up as keystrokes in someone's
## terminal, so ESC and its neighbours would be read as an escape sequence
## rather than shown. Tabs are in the rejected set too: they have no use in a
## one-line pointer, so admitting them would only widen what can be injected.
func _first_control_char(line: String) -> int:
	for i: int in range(line.length()):
		var code: int = line.unicode_at(i)
		if code < 0x20 or code == 0x7F:
			return code
	return -1


## Which terminal `to` names — EXACTLY one, by terminal id, tab name
## (case-insensitive), harness@tab name or bare harness; no match or more
## than one is an error listing the candidates, never a guess. The match
## carries the listing facts delivery needs (harness, foreground process,
## last human keystroke). The harness is what the PTY shows in the
## foreground; only a terminal whose foreground cannot be read at all
## (ConPTY) falls back to its watch profile. A terminal holding a registered
## session carries its identity and role (from the listing).
func resolve_target(to: String, listing: Array) -> Dictionary:
	if listing.is_empty():
		return MCPToolUtils.error("No terminals exist, so '%s' cannot be delivered to" % to)
	# A registered identity or role pins the terminal; every other form is
	# matched below. The pinned terminal still goes through the same loop so
	# it gets the same harness facts.
	var named: Dictionary = HarnessSessionRegistry.shared().resolve(to, listing)
	if named.has("error"):
		var unavailable: Dictionary = MCPToolUtils.error(str(named["error"]))
		unavailable["code"] = str(named.get("code", ""))
		return unavailable
	var pinned: String = str(named.get("terminal_id", ""))

	# The watch profile is asked for only where the foreground is unreadable;
	# it is one plugin round-trip per terminal.
	var ids: PackedStringArray = PackedStringArray()
	for entry: Dictionary in listing:
		if not entry.has("foreground_process"):
			ids.append(str(entry.get("id", "")))
	var profiles: Dictionary = await _watch_profiles(ids) if not ids.is_empty() else {}

	var needle: String = to.to_lower()
	var matches: Array[Dictionary] = []
	var described: PackedStringArray = PackedStringArray()
	for entry: Dictionary in listing:
		var tid: String = str(entry.get("id", ""))
		var tname: String = str(entry.get("name", ""))
		# The watch profile stands in only when the foreground could not be
		# read at all: a readable shell prompt is a shell, whatever was watched
		# there before.
		var harness: String = str(entry.get("harness", ""))
		if harness.is_empty() and not entry.has("foreground_process"):
			harness = str(profiles.get(tid, ""))
		# A renamed tab answers to BOTH names: the tab bar shows the new one,
		# but the running child still reads the spawn-time name out of its own
		# MINERVA_TERMINAL_NAME, and that is the name it quotes when it asks to
		# be addressed. No rename can update the child's environment.
		var lname: String = str(entry.get("launch_name", ""))
		var addresses: PackedStringArray = PackedStringArray([tname.to_lower()])
		if not lname.is_empty() and not addresses.has(lname.to_lower()):
			addresses.append(lname.to_lower())
		described.append("%s (id %s%s%s)" % [
			tname, tid,
			(", was %s" % lname) if not lname.is_empty() and lname != tname else "",
			(", %s" % harness) if not harness.is_empty() else ""])
		var by_name: bool = addresses.has(needle)
		var by_harness: bool = false
		if not harness.is_empty():
			by_harness = harness.to_lower() == needle
			for address: String in addresses:
				by_harness = by_harness or needle == "%s@%s" % [harness.to_lower(), address]
		var hit_here: bool = tid == pinned if not pinned.is_empty() \
			else (tid == to or by_name or by_harness)
		if hit_here:
			var hit: Dictionary = entry.duplicate()
			hit["terminal_id"] = tid
			hit["harness"] = harness
			matches.append(hit)

	if matches.is_empty():
		return MCPToolUtils.error("No terminal matches '%s'. Terminals: %s" % [
			to, ", ".join(described)])
	if matches.size() > 1:
		var ambiguous: PackedStringArray = PackedStringArray()
		for m: Dictionary in matches:
			ambiguous.append("%s (id %s)" % [str(m["name"]), str(m["terminal_id"])])
		return MCPToolUtils.error("'%s' matches %d terminals: %s. Name one by its terminal id." % [
			to, matches.size(), ", ".join(ambiguous)])

	var target: Dictionary = matches[0]
	target["success"] = true
	return target



## terminal_id -> watch profile id, as the agent-relay plugin knows it.
## Default implementation dispatches the plugin's watch_status tool through
## PluginToolRegistry — the same internal path MCP dispatch uses. This is the
## fallback harness identity for a terminal whose foreground process the
## listing cannot name; an unwatched one simply has no profile.
func _watch_profiles(terminal_ids: PackedStringArray) -> Dictionary:
	if tools.watch_profile_source.is_valid():
		var injected = await tools.watch_profile_source.call(terminal_ids)
		return injected if injected is Dictionary else {}
	var profiles: Dictionary = {}
	for terminal_id in terminal_ids:
		var raw = await call_relay_tool(
			AGENT_RELAY_WATCH_STATUS_TOOL, {"terminal_id": terminal_id})
		if not (raw is Dictionary):
			continue
		# Same unwrap/classify the passthrough launch dialog uses for this
		# plugin's replies (envelope stripping + isError/success handling).
		var classified: Dictionary = PassthroughLaunchDialog._classify_watch_result(raw)
		if not classified.get("ok", false):
			continue
		var status = (classified.get("result", {}) as Dictionary).get("status", null)
		if status is Dictionary:
			var profile_id: String = str(status.get("profile_id", ""))
			if not profile_id.is_empty():
				profiles[terminal_id] = profile_id
	return profiles


## What became of the chat delivery that used queue entry `entry_id`, for a
## caller that holds only the entry (TriggerHarnessDelivery):
##   queued      — still waiting, `position` says where
##   the ledger's state for the delivery, when one used this entry (see
##               NotifyDeliveryLedger: sending, held, handed_to_harness, ...)
##   sending     — promoted to a turn (or started straight away: no entry)
##               with no ledger record to say whether the harness took it
##   dropped     — removed or discarded before it ran (a cancel, a closed bubble)
##   unknown     — the entry left the queue but its outcome is no longer on
##               record: the outcome ring is finite.
## Leaving the queue is never reported as the harness taking the line; only
## the ledger, told by the relay's reply, says handed_to_harness.
static func notify_status(entry_id: int, position: int) -> String:
	if position > 0:
		return NotifyDeliveryLedger.QUEUED
	var recorded: String = NotifyDeliveryLedger.shared().state_of_entry(entry_id)
	if not recorded.is_empty():
		return recorded
	# No entry at all means no queue was involved: the turn started on the spot.
	if entry_id <= 0:
		return NotifyDeliveryLedger.SENDING
	match MCPToolUtils.outgoing_queue_outcome(entry_id):
		ChatOutgoingQueue.Outcome.DROPPED:
			return NotifyDeliveryLedger.DROPPED
		ChatOutgoingQueue.Outcome.DISPATCHED:
			return NotifyDeliveryLedger.SENDING
		_:
			return "unknown"


## Wait until the harness takes this chat delivery, it is held, or it settles
## otherwise — or until the budget lapses. The receipt then reports the
## ledger's state either way.
func _await_notify_taken(delivery_id: String, wait_ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + wait_ms
	var tree: SceneTree = SingletonObject.get_tree()
	if tree == null:
		return
	var ledger = NotifyDeliveryLedger.shared()
	while Time.get_ticks_msec() < deadline:
		var state: String = str(ledger.get_record(delivery_id).get("state", ""))
		if state != NotifyDeliveryLedger.QUEUED and state != NotifyDeliveryLedger.SENDING:
			return
		await tree.process_frame


## Whether the harness in this session shows a turn running: its busy hint
## (BUSY_MARKERS) on one of the last BUSY_WINDOW_ROWS rows of the visible
## screen, blank rows at the foot left out. Both harnesses draw the hint just
## above their input box; a hint further up is an old screen scrolling away
## (a dialog drawn after it, say). A session that cannot be read is not judged
## busy here; the relay's own gate still classifies it.
func _busy_turn_shown(session, harness: String) -> bool:
	if session == null or not session.has_method("read_viewport_text"):
		return false
	var markers: Array = Array(BUSY_MARKERS.get(harness, []))
	if markers.is_empty():
		return false
	var rows: PackedStringArray = str(session.read_viewport_text()).split("\n")
	var last: int = rows.size() - 1
	while last >= 0 and rows[last].strip_edges().is_empty():
		last -= 1
	for row in range(maxi(0, last - BUSY_WINDOW_ROWS + 1), last + 1):
		for marker: String in markers:
			if rows[row].contains(marker):
				return true
	return false