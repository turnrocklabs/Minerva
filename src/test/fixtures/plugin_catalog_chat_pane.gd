extends ChatPane
## Keep rendering outside this fixture; the production MCP modules own history mutation.

func render_history(_history: ChatHistory) -> void:
	pass

func sync_provider_picker_to_chat(_tab_or_chat_id: Variant = -1) -> void:
	pass
