class_name ChatOutgoingQueue
extends RefCounted
## Per-chat FIFO of messages submitted while that chat already had a request in
## flight. Every entry point that starts a turn (send button, minerva_send_message,
## worker-completion injection, trigger MESSAGE_EXISTING) reaches ChatPane through
## execute_regular_chat / _on_send_message_button_item_selected, and those gate on
## ChatHistory.is_request_active: busy chats enqueue here instead of starting a
## second, overlapping request. The queue drains one entry when the active request
## ends (completion, error or cancel-with-empty-queue).
##
## CANCEL RULE: cancelling the active request DISCARDS every pending entry of that
## chat. Stop means stop — the user who pressed stop must not then watch a queued
## message fire on its own. Entries removed this way are returned to the caller so
## it can free their bubbles.
##
## The queue owns no UI. `Entry.bubble` is a view-only back-reference to the
## pending bubble in the chat's VBox; it can be freed out from under the queue
## (e.g. a chat tab re-renders and builds a fresh VBox), so every reader must
## check is_instance_valid before touching it.

## Mirrors the SendMessageButton indices, so a queued entry replays through the
## same executor that would have run it.
enum Mode { REGULAR = 0, PARALLEL = 1, SEQUENTIAL = 2 }


class Entry extends RefCounted:
	## Identity of this queued message, unique for the life of the queue. Two
	## identical texts are two entries: a receipt that named the TEXT could not
	## tell them apart, and could not tell "it ran" from "it was removed".
	var id: int = 0
	var history_id: String = ""
	var text: String = ""
	var mode: ChatOutgoingQueue.Mode = ChatOutgoingQueue.Mode.REGULAR
	var generation_options: Dictionary = {}
	var bubble: Node = null
	## A background message (a notify envelope) rather than something a human
	## typed. Deferred entries are skipped by the drain while the chat is
	## waiting for the answer to a question card: the agent behind the chat is
	## blocked on that answer, so the answer's turn must come first. Once a turn
	## ends without a question, deferred entries are eligible again, in order.
	var deferred: bool = false
	## A background message marked urgent (stop or scope steering): placed
	## ahead of routine background entries by promote_urgent.
	var urgent: bool = false


## What became of an entry that left the queue.
enum Outcome { UNKNOWN = 0, DISPATCHED = 1, DROPPED = 2 }

## How many departed entries keep their outcome. A receipt asks within its own
## wait, so a short history is enough and the map cannot grow without bound.
const OUTCOME_HISTORY: int = 128

## HistoryId -> Array[Entry], oldest first. A chat with nothing pending has no key.
var _pending: Dictionary = {}

## Entry id -> Outcome, for entries that have left the queue, newest last.
var _outcomes: Dictionary = {}
var _outcome_order: Array[int] = []
var _next_id: int = 1


## Append a message to the chat's queue and return the created entry so the caller
## can attach its pending bubble.
func enqueue(history_id: String, text: String, mode: Mode = Mode.REGULAR,
		generation_options: Dictionary = {}, deferred: bool = false) -> Entry:
	var entry: = Entry.new()
	entry.deferred = deferred
	entry.id = _next_id
	_next_id += 1
	entry.history_id = history_id
	entry.text = text
	entry.mode = mode
	entry.generation_options = generation_options.duplicate(true)
	if not _pending.has(history_id):
		_pending[history_id] = []
	var queue: Array = _pending[history_id]
	queue.append(entry)
	return entry


func has_pending(history_id: String) -> bool:
	return pending_count(history_id) > 0


func pending_count(history_id: String) -> int:
	if not _pending.has(history_id):
		return 0
	var queue: Array = _pending[history_id]
	return queue.size()


## Oldest pending entry without removing it, or null.
func peek(history_id: String) -> Entry:
	if not has_pending(history_id):
		return null
	var queue: Array = _pending[history_id]
	return queue[0]


## Remove and return the oldest ELIGIBLE pending entry, or null when the chat
## has nothing eligible queued. With `include_deferred` false, background
## entries are passed over (they keep their place) and the oldest ordinary
## entry is taken instead — that is how a human's answer to a question card
## starts before a notification that arrived first.
func pop_next(history_id: String, include_deferred: bool = true) -> Entry:
	if not has_pending(history_id):
		return null
	var queue: Array = _pending[history_id]
	var index: int = -1
	for i in range(queue.size()):
		var candidate: Entry = queue[i]
		if include_deferred or not candidate.deferred:
			index = i
			break
	if index == -1:
		return null
	var entry: Entry = queue[index]
	queue.remove_at(index)
	if queue.is_empty():
		_pending.erase(entry.history_id)
	_record_outcome(entry, Outcome.DISPATCHED)
	return entry


## Mark a queued background entry urgent and move it ahead of the routine
## background entries (deferred, not urgent) directly in front of it. A
## message a person queued, and an earlier urgent entry, stop the move: those
## keep their place ahead of it. Returns the entry it now stands in front of,
## or null when it did not move.
func promote_urgent(entry: Entry) -> Entry:
	entry.urgent = true
	if not _pending.has(entry.history_id):
		return null
	var queue: Array = _pending[entry.history_id]
	var index: int = queue.find(entry)
	var to: int = index
	while to > 0:
		var ahead: Entry = queue[to - 1]
		if not ahead.deferred or ahead.urgent:
			break
		to -= 1
	if index == -1 or to == index:
		return null
	queue.remove_at(index)
	queue.insert(to, entry)
	return queue[to + 1]


## Drop one entry (the user removed its bubble). Returns true if it was queued.
func remove(entry: Entry) -> bool:
	if entry == null or not _pending.has(entry.history_id):
		return false
	var queue: Array = _pending[entry.history_id]
	var index: = queue.find(entry)
	if index == -1:
		return false
	queue.remove_at(index)
	if queue.is_empty():
		_pending.erase(entry.history_id)
	_record_outcome(entry, Outcome.DROPPED)
	return true


## Discard the chat's whole queue (the cancel rule) and hand the dropped entries
## back so their bubbles can be freed.
func clear(history_id: String) -> Array:
	if not _pending.has(history_id):
		return []
	var dropped: Array = _pending[history_id]
	_pending.erase(history_id)
	for entry: Entry in dropped:
		_record_outcome(entry, Outcome.DROPPED)
	return dropped


## Queued texts, oldest first — for tests and diagnostics.
func pending_texts(history_id: String) -> PackedStringArray:
	var texts: = PackedStringArray()
	if not _pending.has(history_id):
		return texts
	var queue: Array = _pending[history_id]
	for entry: Entry in queue:
		texts.append(entry.text)
	return texts


## The queued entry with this id, or null when it is not queued.
func find(entry_id: int) -> Entry:
	for history_id: String in _pending:
		for entry: Entry in _pending[history_id]:
			if entry.id == entry_id:
				return entry
	return null


## Where `entry_id` sits in its chat's queue, 1-based, or 0 when it is not
## queued (never was, or has already left).
func position_of(entry_id: int) -> int:
	for history_id: String in _pending:
		var queue: Array = _pending[history_id]
		for i in range(queue.size()):
			var entry: Entry = queue[i]
			if entry.id == entry_id:
				return i + 1
	return 0


## What became of an entry that is no longer queued: DISPATCHED when it was
## promoted to a turn, DROPPED when it was removed or discarded, UNKNOWN when
## the queue has no record of it (still queued, never queued, or long gone).
func outcome_of(entry_id: int) -> Outcome:
	return _outcomes.get(entry_id, Outcome.UNKNOWN)


## Id of the chat's newest queued entry, or 0 when it has nothing pending.
func newest_id(history_id: String) -> int:
	if not has_pending(history_id):
		return 0
	var queue: Array = _pending[history_id]
	var entry: Entry = queue[queue.size() - 1]
	return entry.id


## A popped entry that could not be started after all (its chat is gone). It
## left the queue as DISPATCHED; correct the record so its receipt says what
## really happened.
func note_dropped(entry: Entry) -> void:
	if entry != null:
		_record_outcome(entry, Outcome.DROPPED)


func _record_outcome(entry: Entry, outcome: Outcome) -> void:
	_outcomes[entry.id] = outcome
	_outcome_order.append(entry.id)
	while _outcome_order.size() > OUTCOME_HISTORY:
		_outcomes.erase(_outcome_order.pop_front())
