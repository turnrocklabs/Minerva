extends PolicyEngine
## Explicit readable policy owner for hermetic MCP tests, with no user rules.

class PolicySource extends RefCounted:
	var items: Array[Dictionary] = []
	func policy_items() -> Dictionary:
		return {"items": items}

var _source := PolicySource.new()

func set_policy_items(items: Array[Dictionary]) -> void:
	_source.items = items.duplicate(true)
	reload()

func _get_docket_host() -> Variant:
	return _source
