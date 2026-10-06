extends PolicyEngine
## Explicit readable policy owner for hermetic MCP tests, with no user rules.

class PolicySource extends RefCounted:
	func policy_items() -> Dictionary:
		return {"items": []}

var _source := PolicySource.new()

func _get_docket_manager() -> Variant:
	return null

func _get_docket_host() -> Variant:
	return _source
