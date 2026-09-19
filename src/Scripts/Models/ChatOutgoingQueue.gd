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
	var history_id: String = ""
	var text: String = ""
	var mode: ChatOutgoingQueue.Mode = ChatOutgoingQueue.Mode.REGULAR
	var generation_options: Dictionary = {}
	var bubble: Node = null


## HistoryId -> Array[Entry], oldest first. A chat with nothing pending has no key.
var _pending: Dictionary = {}


## Append a message to the chat's queue and return the created entry so the caller
## can attach its pending bubble.
func enqueue(history_id: String, text: String, mode: Mode = Mode.REGULAR,
		generation_options: Dictionary = {}) -> Entry:
	var entry: = Entry.new()
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


## Remove and return the oldest pending entry, or null when nothing is queued.
func pop_next(history_id: String) -> Entry:
	if not has_pending(history_id):
		return null
	var queue: Array = _pending[history_id]
	var entry: Entry = queue.pop_front()
	if queue.is_empty():
		_pending.erase(entry.history_id)
	return entry


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
	return true


## Discard the chat's whole queue (the cancel rule) and hand the dropped entries
## back so their bubbles can be freed.
func clear(history_id: String) -> Array:
	if not _pending.has(history_id):
		return []
	var dropped: Array = _pending[history_id]
	_pending.erase(history_id)
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
