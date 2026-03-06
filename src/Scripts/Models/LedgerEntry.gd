class_name LedgerEntry
extends RefCounted
## A single compaction archive entry. Stores the original messages that were
## compacted into a summary, allowing retrieval via MCP or the Ledger panel.

var id: String = ""
var chat_id: String = ""
var chat_name: String = ""
var timestamp: String = ""
var message_range: String = ""  # e.g. "messages 1-24"
var summary_text: String = ""
var original_messages: Array[Dictionary] = []  # Serialized ChatHistoryItems


func _init(p_id: String = ""):
	if p_id.is_empty():
		id = _generate_id()
	else:
		id = p_id


static func _generate_id() -> String:
	return "%08x%04x" % [
		Time.get_unix_time_from_system(),
		randi() % 0xFFFF
	]


func serialize() -> Dictionary:
	return {
		"id": id,
		"chat_id": chat_id,
		"chat_name": chat_name,
		"timestamp": timestamp,
		"message_range": message_range,
		"summary_text": summary_text,
		"original_messages": original_messages,
	}


static func deserialize(data: Dictionary) -> LedgerEntry:
	var entry = LedgerEntry.new(data.get("id", ""))
	entry.chat_id = data.get("chat_id", "")
	entry.chat_name = data.get("chat_name", "")
	entry.timestamp = data.get("timestamp", "")
	entry.message_range = data.get("message_range", "")
	entry.summary_text = data.get("summary_text", "")
	var msgs = data.get("original_messages", [])
	for m in msgs:
		if m is Dictionary:
			entry.original_messages.append(m)
	return entry
