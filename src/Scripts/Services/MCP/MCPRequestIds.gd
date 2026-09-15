class_name MCPRequestIds
extends RefCounted
## Typed request identity ownership shared by transports. String "1" and
## integer 1 are distinct JSON-RPC identities and cannot replace each other.

const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")

var _counter := 0
var _outstanding: Dictionary = {}


func next_string() -> String:
	_counter += 1
	return str(_counter)


func admit(value: Variant) -> bool:
	var key := Protocol.request_id_key(value)
	if key.is_empty() or _outstanding.has(key):
		return false
	_outstanding[key] = value
	return true


func contains(value: Variant) -> bool:
	return _outstanding.has(Protocol.request_id_key(value))


func release(value: Variant) -> bool:
	return _outstanding.erase(Protocol.request_id_key(value))


func clear() -> void:
	_outstanding.clear()


func size() -> int:
	return _outstanding.size()
