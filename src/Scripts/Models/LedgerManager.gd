class_name LedgerManager
extends RefCounted
## Manages compaction ledger entries per project.
## Entries are created when chat history is compacted, storing the original
## messages for later retrieval via MCP or the Ledger panel.

var entries: Array[LedgerEntry] = []


func add_entry(entry: LedgerEntry) -> void:
	entries.append(entry)


func get_entry(entry_id: String) -> LedgerEntry:
	for e in entries:
		if e.id == entry_id:
			return e
	return null


func get_entries_for_chat(chat_id: String) -> Array[LedgerEntry]:
	var result: Array[LedgerEntry] = []
	for e in entries:
		if e.chat_id == chat_id:
			result.append(e)
	return result


func remove_entry(entry_id: String) -> bool:
	for i in entries.size():
		if entries[i].id == entry_id:
			entries.remove_at(i)
			return true
	return false


func clear() -> void:
	entries.clear()


func serialize() -> Array:
	var result: Array = []
	for e in entries:
		result.append(e.serialize())
	return result


func deserialize(data: Array) -> void:
	entries.clear()
	for item in data:
		if item is Dictionary:
			entries.append(LedgerEntry.deserialize(item))
	print("[LedgerManager] Deserialized %d ledger entries" % entries.size())
