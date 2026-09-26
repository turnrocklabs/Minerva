class_name DocketWakeups
extends RefCounted
## Wake-up pointers for registered harness sessions, from the Docket changes a
## DOCKET_POLL trigger in wake mode (TriggerDefinition.docket_wake_sessions)
## passes on. A change wakes every session its item is addressed to: the
## registered identities whose identity or role equals the item's assigned_to
## or directed_to (HarnessSessionRegistry.identities_addressed_by).
##
## Each pointer is one line naming where to look, sent through
## MCPTerminalTools.notify_retained, so the NotifyDeliveryLedger keeps it while
## the session is busy or a person is typing there.
##
## Routine changes coalesce: the first one for a session opens a window of the
## trigger's docket_poll_interval, and everything that arrives before it closes
## goes out as ONE pointer. While that pointer is still open in the ledger
## (queued, held, sending), later changes wait and go out together once it
## settles; a pointer that failed or was dropped has its changes folded back in.
##
## Control directives are never coalesced. The marker is a tag in the
## `control:` namespace (e.g. control:stop, control:scope) on an addressed
## item: a change whose item's set of control tags differs from the set this
## session last saw on that item is a directive, and goes out at once as its
## own pointer, independent of any routine one, sent as urgent. The set is
## remembered per run, so after a restart the first change to an item still
## carrying control tags is delivered as a directive again.
##
## Dedup: each change is taken at most once per session, keyed by
## "<identity>|<change key>". The change key is the plugin event's position,
## "<process generation>/<stream>/<sequence>", unique per change; without the
## plugin (embedded DocketManager) it is "<project>|<item id>|<kind>|
## <updated_at>|<from>><to>".
##
## A registered session that is not reachable (unbound, exited, another
## program in front) still gets its pointer sent: the ledger keeps it as
## awaiting_recipient and delivers it once when the session registers again,
## so no pending line is held here. Only an identity no longer registered has
## its pointers kept here, looked at again every RECHECK_S.
##
## When a role is handed over (the registry's handed_over), batches and
## directives not yet sent to a superseded identity move to the replacement;
## pointers already in the ledger are moved there (NotifyDeliveryLedger.retarget).
##
## Receipts: a caller that must know when a change was consumed (the docket.app
## subscription feed, which acks it then) passes a Receipt to take(). Each
## session the change is addressed to holds the receipt until the pointer
## carrying the change is handed_to_harness in the ledger; a change this
## session already took holds it until that earlier pointer settles. A pointer
## that ends unconfirmed (or whose record is gone) abandons the receipt, so it
## never fires. The outcome stays with the change key once the pointer settles,
## so a receipt that arrives later for a change whose pointer was not handed
## over is abandoned too, while one whose pointer was handed over holds
## nothing. A change that wakes nobody holds nothing.

const HarnessSessionRegistry := preload("res://Scripts/Services/Terminal/HarnessSessionRegistry.gd")
const NotifyDeliveryLedger := preload("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd")

const CONTROL_PREFIX := "control:"
## Change keys remembered for dedup; the oldest are forgotten first.
const WOKEN_LIMIT := 4096
## Outcome a change key keeps in _woken once its pointer settles.
const KEY_HANDED := "handed"
const KEY_ABANDONED := "abandoned"
## How often pointers kept for an absent session are looked at again.
const RECHECK_S := 10.0
const MIN_WINDOW_S := 1.0
## Items a routine pointer names before it says "+N more".
const ITEMS_NAMED := 4
const TITLE_CHARS := 40

## The MCPTerminalTools that sends; tests may swap in a scripted one.
var tools: MCPTerminalTools = TriggerDestination.terminal_tools() as MCPTerminalTools
var registry = HarnessSessionRegistry.shared()

# identity -> the routine batch not yet sent: {items: {ref: {title, kinds:
# {kind: count}}}, changes, sender, armed}.
var _routine: Dictionary = {}
# identity -> {delivery_id, batch}: the routine pointer sent last, kept until
# it settles so a failed one can be folded back. delivery_id "" while sending.
var _inflight: Dictionary = {}
# identity -> Array of {line, sender, delivery_id, sending}: directives, each
# its own pointer, kept until the ledger says the harness took it.
var _control: Dictionary = {}
# "<identity>|<change key>" -> true while its pointer is unsettled, then
# KEY_HANDED or KEY_ABANDONED; in arrival order.
var _woken: Dictionary = {}
# "<identity>|<project>|<item id>" -> the item's control tags last seen.
var _control_seen: Dictionary = {}
var _rechecking: bool = false
# "<identity>|<change key>" -> Array of Receipt: changes taken and not yet
# settled in the ledger, with the receipts waiting on them.
var _pending: Dictionary = {}


## Fires its Callable once every hold on it is released; never once abandoned.
## Its creator holds it from the start and releases that hold when it has
## handed the change to every consumer.
class Receipt extends RefCounted:
	var _holds: int = 1
	var _abandoned: bool = false
	var _on_consumed: Callable

	func _init(on_consumed: Callable) -> void:
		_on_consumed = on_consumed

	func hold() -> void:
		_holds += 1

	func release() -> void:
		_holds -= 1
		if _holds == 0 and not _abandoned:
			_on_consumed.call()

	func abandon() -> void:
		_abandoned = true


func _init() -> void:
	registry.changed.connect(_flush_all)
	registry.handed_over.connect(_on_handed_over)
	NotifyDeliveryLedger.shared().changed.connect(_on_ledger_changed)


## The change key of a change with no source position: the embedded
## DocketManager's, derived from the item's updated_at after the change.
static func change_key_of(project: String, item_id: String, kind: String, updated_at: String,
		from_status: String, to_status: String) -> String:
	return "%s|%s|%s|%s|%s>%s" % [project, item_id, kind, updated_at, from_status, to_status]


## Take one Docket change of `item_id` in `project` (kind: created,
## transitioned, updated, comment_added) that `trig` passed its filters for.
## `item` is the item as it is now; {} (deleted) wakes nobody. `receipt`,
## when given, is held until the change is delivered (see Receipts).
func take(trig: TriggerDefinition, project: String, item_id: String, kind: String,
		from_status: String, to_status: String, item: Dictionary, change_key: String,
		receipt: Receipt = null) -> void:
	if item.is_empty():
		return
	if change_key.is_empty():
		change_key = change_key_of(project, item_id, kind, str(item.get("updated_at", "")),
			from_status, to_status)
	var identities := PackedStringArray()
	for field: String in ["assigned_to", "directed_to"]:
		var principal = item.get(field)
		for identity: String in registry.identities_addressed_by(principal if principal is String else ""):
			if not identity in identities:
				identities.append(identity)
	if identities.is_empty():
		return
	var ref: String = "%s:%s" % [project, item_id.left(12)]
	var title: String = str(item.get("title", ""))
	var controls := PackedStringArray()
	var tags = item.get("tags", [])
	if tags is Array:
		for tag in tags:
			if str(tag).begins_with(CONTROL_PREFIX):
				controls.append(str(tag))
	controls.sort()
	var control_set: String = ",".join(controls)
	var sender: String = TriggerHarnessDelivery._sender(trig)
	for identity in identities:
		var key: String = identity + "|" + change_key
		if not _first_sight(key):
			if receipt != null and _pending.has(key):
				receipt.hold()
				(_pending[key] as Array).append(receipt)
			elif receipt != null and str(_woken.get(key, "")) == KEY_ABANDONED:
				receipt.abandon()
			continue
		_pending[key] = []
		if receipt != null:
			receipt.hold()
			(_pending[key] as Array).append(receipt)
		var seen_key: String = "%s|%s|%s" % [identity, project, item_id]
		var before: String = str(_control_seen.get(seen_key, ""))
		if control_set.is_empty():
			_control_seen.erase(seen_key)
		else:
			_control_seen[seen_key] = control_set
		if not control_set.is_empty() and control_set != before:
			var line: String = "Docket CONTROL %s on %s '%s' (%s): read it before you continue" % [
				control_set, ref, _short(title), kind]
			var queue: Array = _control.get_or_add(identity, [])
			queue.append({"line": line, "sender": sender, "delivery_id": "", "sending": false, "keys": [key]})
			_send_controls(identity)
		else:
			_add_routine(identity, ref, title, kind, sender, key)
			_arm(identity, maxf(trig.docket_poll_interval, MIN_WINDOW_S))


# False when this session already took this change; remembers it otherwise.
func _first_sight(key: String) -> bool:
	if _woken.has(key):
		return false
	_woken[key] = true
	while _woken.size() > WOKEN_LIMIT:
		_woken.erase(_woken.keys()[0])
	return true


func _add_routine(identity: String, ref: String, title: String, kind: String, sender: String, key: String) -> void:
	var batch: Dictionary = _routine.get_or_add(identity, _new_batch(sender))
	(batch.keys as Array).append(key)
	var entry: Dictionary = batch.items.get_or_add(ref, {"title": title, "kinds": {}})
	entry.title = title
	entry.kinds[kind] = int(entry.kinds.get(kind, 0)) + 1
	batch.changes = int(batch.changes) + 1


static func _new_batch(sender: String) -> Dictionary:
	return {"items": {}, "changes": 0, "sender": sender, "armed": false, "keys": []}


# Folds batch `from` into `into`, counts added.
static func _merge(into: Dictionary, from: Dictionary) -> void:
	for ref: String in from.items:
		var theirs: Dictionary = from.items[ref]
		var ours: Dictionary = into.items.get_or_add(ref, {"title": theirs.title, "kinds": {}})
		for kind: String in theirs.kinds:
			ours.kinds[kind] = int(ours.kinds.get(kind, 0)) + int(theirs.kinds[kind])
	into.changes = int(into.changes) + int(from.changes)
	(into.keys as Array).append_array(from.keys)


# Opens `identity`'s coalescing window unless one is open; sends when it closes.
func _arm(identity: String, window_s: float) -> void:
	var batch: Dictionary = _routine[identity]
	if batch.armed:
		return
	batch.armed = true
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.create_timer(window_s).timeout
	if _routine.has(identity):
		_routine[identity].armed = false
	_send_routine(identity)


func _send_routine(identity: String) -> void:
	if _inflight.has(identity):
		var open: Dictionary = _inflight[identity]
		if str(open.delivery_id).is_empty():
			return  # still being sent
		var state: String = str(NotifyDeliveryLedger.shared().get_record(str(open.delivery_id)).get("state", ""))
		if not state.is_empty() and not state in NotifyDeliveryLedger.SETTLED:
			return  # the last pointer is still waiting for the session
		_inflight.erase(identity)
		if state in [NotifyDeliveryLedger.FAILED, NotifyDeliveryLedger.DROPPED]:
			_merge(_routine.get_or_add(identity, _new_batch(str(open.batch.sender))), open.batch)
		else:
			_settle(open.batch.keys, state)
	if not _routine.has(identity) or _routine[identity].items.is_empty() or _routine[identity].armed:
		return
	if not _live(identity):
		_recheck_later()
		return
	var batch: Dictionary = _routine[identity]
	_routine.erase(identity)
	_inflight[identity] = {"delivery_id": "", "batch": batch}
	var delivery_id: String = await _send(identity, _routine_line(batch), str(batch.sender))
	if delivery_id.is_empty():
		_inflight.erase(identity)
		_merge(_routine.get_or_add(identity, _new_batch(str(batch.sender))), batch)
	else:
		_inflight[identity].delivery_id = delivery_id
		_on_ledger_changed(delivery_id)
	_recheck_later()


func _send_controls(identity: String) -> void:
	var queue: Array = _control.get(identity, [])
	for entry: Dictionary in queue.duplicate():
		if entry.sending:
			continue
		if not str(entry.delivery_id).is_empty():
			var state: String = str(NotifyDeliveryLedger.shared().get_record(str(entry.delivery_id)).get("state", ""))
			if state in [NotifyDeliveryLedger.HANDED, NotifyDeliveryLedger.UNCONFIRMED,
					NotifyDeliveryLedger.FAILED_UNAVAILABLE] or state.is_empty():
				queue.erase(entry)
				_settle(entry.keys, state)
				continue
			if not state in [NotifyDeliveryLedger.FAILED, NotifyDeliveryLedger.DROPPED]:
				_recheck_later()
				continue  # still held or queued in the ledger
			entry.delivery_id = ""
		if not _live(identity):
			_recheck_later()
			return
		entry.sending = true
		entry.delivery_id = await _send(identity, str(entry.line), str(entry.sender), true)
		entry.sending = false
		if not str(entry.delivery_id).is_empty():
			_on_ledger_changed(str(entry.delivery_id))
	if queue.is_empty():
		_control.erase(identity)
	else:
		_recheck_later()


# The changes `keys` left the ledger in `state`: their receipts are released
# when it is handed_to_harness, abandoned otherwise, and the key keeps that
# outcome for receipts that arrive later.
func _settle(keys: Array, state: String) -> void:
	for key: String in keys:
		var receipts: Array = _pending.get(key, [])
		_pending.erase(key)
		if _woken.has(key):
			_woken[key] = KEY_HANDED if state == NotifyDeliveryLedger.HANDED else KEY_ABANDONED
		for receipt: Receipt in receipts:
			if state == NotifyDeliveryLedger.HANDED:
				receipt.release()
			else:
				receipt.abandon()


# A pointer sent from here settled (possibly before its send returned): look
# again now rather than at the next RECHECK_S, deferred so the ledger finishes
# the change it is signalling first.
func _on_ledger_changed(delivery_id: String) -> void:
	var state: String = str(NotifyDeliveryLedger.shared().get_record(delivery_id).get("state", ""))
	if not state in NotifyDeliveryLedger.SETTLED:
		return
	var ours: bool = false
	for open: Dictionary in _inflight.values():
		ours = ours or str(open.delivery_id) == delivery_id
	for queue: Array in _control.values():
		for entry: Dictionary in queue:
			ours = ours or str(entry.delivery_id) == delivery_id
	if ours:
		_flush_all.call_deferred()


# One pointer to `identity` through the ledger: its delivery id, or "" when
# nothing was kept (refused before a target was chosen, or failed at once).
# Directives go as urgent (see NotifyDeliveryClass), routine pointers not.
func _send(identity: String, line: String, sender: String, urgent: bool = false) -> String:
	var receipt: Dictionary = await tools.notify_retained({"to": identity, "from": sender,
		"text": TriggerHarnessDelivery.one_line(line), "urgent": urgent})
	var delivery_id: String = str(receipt.get("delivery_id", ""))
	if delivery_id.is_empty():
		return ""
	var state: String = str(NotifyDeliveryLedger.shared().get_record(delivery_id).get("state", ""))
	return "" if state == NotifyDeliveryLedger.FAILED else delivery_id


# Whether a line for `identity` can be handed to notify now: it is
# registered. Notify delivers or holds it, or keeps it awaiting the session.
func _live(identity: String) -> bool:
	return registry.is_registered(identity)


# Moves what waits here for each superseded identity to `to_identity`.
func _on_handed_over(_role: String, superseded: PackedStringArray, to_identity: String) -> void:
	for old: String in superseded:
		if _routine.has(old):
			var batch: Dictionary = _routine[old]
			_routine.erase(old)
			batch.armed = false
			if _routine.has(to_identity):
				_merge(_routine[to_identity], batch)
			else:
				_routine[to_identity] = batch
		if _inflight.has(old) and not _inflight.has(to_identity):
			_inflight[to_identity] = _inflight[old]
			_inflight.erase(old)
		if _control.has(old):
			(_control.get_or_add(to_identity, []) as Array).append_array(_control[old])
			_control.erase(old)
	_flush_all()


func _flush_all() -> void:
	for identity: String in _control.keys():
		_send_controls(identity)
	var routine: Array = _routine.keys()
	for identity: String in _inflight.keys():
		if not identity in routine:
			routine.append(identity)
	for identity: String in routine:
		_send_routine(identity)


# While anything waits (a batch, a directive, or a sent routine pointer the
# ledger has not settled), look again every RECHECK_S.
func _recheck_later() -> void:
	if _rechecking:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_rechecking = true
	while not _control.is_empty() or not _routine.is_empty() or not _inflight.is_empty():
		await tree.create_timer(RECHECK_S).timeout
		_flush_all()
	_rechecking = false


static func _routine_line(batch: Dictionary) -> String:
	var parts := PackedStringArray()
	var refs: Array = batch.items.keys()
	for ref: String in refs.slice(0, ITEMS_NAMED):
		var entry: Dictionary = batch.items[ref]
		var kinds := PackedStringArray()
		for kind: String in entry.kinds:
			kinds.append("%s x%d" % [kind, int(entry.kinds[kind])] if int(entry.kinds[kind]) > 1 else kind)
		parts.append("%s '%s' (%s)" % [ref, _short(str(entry.title)), ", ".join(kinds)])
	if refs.size() > ITEMS_NAMED:
		parts.append("+%d more items" % (refs.size() - ITEMS_NAMED))
	var count: int = int(batch.changes)
	return "Docket: %d change%s on work addressed to you: %s. Read with docket_get." % [
		count, "" if count == 1 else "s", "; ".join(parts)]


static func _short(title: String) -> String:
	title = title.replace("'", "")
	return title if title.length() <= TITLE_CHARS else title.left(TITLE_CHARS - 1) + "…"
