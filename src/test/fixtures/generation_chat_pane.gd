extends "res://test/fixtures/plugin_catalog_chat_pane.gd"
## Capture scheduled MCP turns; normal provider dispatch and clone remain production code.
var submitted_options: Dictionary = {}

func execute_regular_chat(_text: String, generation_options: Dictionary = {}) -> void:
	submitted_options = generation_options.duplicate(true)

var prompt_history: ChatHistory

func create_prompt(append_item: ChatHistoryItem = null, _refresh_detached: bool = true, _provider_fallback: BaseProvider = null, _predicate: Callable = Callable(), history_override: ChatHistory = null) -> Array[Variant]:
	prompt_history = history_override
	return [{"role": "user", "content": append_item.Message}]
