class_name MCPExportCatalog
extends RefCounted
## Deterministic snapshots of host-owned tools eligible for public export.

var _dirty := true
var _tools: Array[Dictionary] = []


func invalidate() -> void:
	_dirty = true


func snapshot(registry: Dictionary, enabled_sets: Array = []) -> Dictionary:
	if not _dirty:
		return {"ok": true, "tools": _tools.duplicate(true)}
	var names: Array[String] = []
	for key: Variant in registry:
		if not key is String:
			return _failure("Tool registry contains a non-string name")
		var definition = registry[key]
		if definition == null or str(definition.get("server_name")) != "minerva":
			continue
		if not enabled_sets.is_empty():
			var tool_set := str(definition.get("tool_set"))
			if tool_set != "meta" and tool_set not in enabled_sets:
				continue
		names.append(key)
	names.sort()
	var candidate: Array[Dictionary] = []
	for name: String in names:
		var definition = registry[name]
		if not definition.has_method("to_mcp_format"):
			return _failure("Tool '%s' cannot produce an MCP definition" % name)
		var wire: Variant = definition.to_mcp_format()
		if not wire is Dictionary or not wire.get("name") is String \
				or wire.get("name") != name:
			return _failure("Tool '%s' has a mismatched wire name" % name)
		candidate.append(wire.duplicate(true))
	_tools = candidate
	_dirty = false
	return {"ok": true, "tools": _tools.duplicate(true)}


func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
