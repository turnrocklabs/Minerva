extends PolicyEngine
## Deterministic public-server policy denial without Docket or owner config.

func evaluate(_tool_name: String, _arguments: Dictionary,
		_caller_id: String = "") -> Dictionary:
	return {
		"allowed": false,
		"success": false,
		"error": "Blocked by focused public MCP fixture",
		"error_message": "Blocked by focused public MCP fixture",
		"allowed_next_actions": [],
	}
