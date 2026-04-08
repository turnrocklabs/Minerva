extends SceneTree
## Regression tests for MCPChatTools chat history metadata + selective hydration.
## Run: godot --headless --path <minerva/src> --main-loop res://test/test_mcp_chat_history_tools.gd

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("\n===== MCP Chat History Tool Tests =====\n")

	test_get_chat_history_returns_metadata_only()
	test_get_chat_messages_hydrates_requested_indices()
	test_get_chat_messages_validates_indices()

	print("\n===== Results: %d passed, %d failed =====" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _assert(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % label)
	else:
		_fail += 1
		printerr("  FAIL: %s" % label)


func _assert_eq(actual, expected, label: String) -> void:
	if typeof(actual) == typeof(expected) and actual == expected:
		_pass += 1
		print("  PASS: %s" % label)
	else:
		_fail += 1
		printerr("  FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])


func _build_test_history() -> ChatHistory:
	var history := ChatHistory.new(null, "chat-under-test")
	history.HistoryName = "Chat Under Test"

	var user_item := ChatHistoryItem.new()
	user_item.Role = ChatHistoryItem.ChatRole.USER
	user_item.Message = "Plan the work"

	var model_item := ChatHistoryItem.new()
	model_item.Role = ChatHistoryItem.ChatRole.MODEL
	model_item.Message = "Calling tools"
	model_item.IsToolCall = true
	model_item.ToolCalls = [
		{
			"id": "call_1",
			"name": "minerva_list_chats",
			"arguments": {}
		}
	]

	var tool_item := ChatHistoryItem.new()
	tool_item.Role = ChatHistoryItem.ChatRole.TOOL
	tool_item.Message = "{\"count\":1}"
	tool_item.ToolCallId = "call_1"
	tool_item.ToolName = "minerva_list_chats"

	history.HistoryItemList = [user_item, model_item, tool_item]
	return history


func _build_tools_with_history() -> MCPChatTools:
	var singleton = get_root().get_node("/root/SingletonObject")
	singleton.ChatList = [_build_test_history()]
	return MCPChatTools.new(null)


func test_get_chat_history_returns_metadata_only() -> void:
	print("test_get_chat_history_returns_metadata_only:")
	var tools := _build_tools_with_history()
	var result := tools._get_chat_history({"chat_id": "chat-under-test"})

	_assert(result.get("success", false), "metadata call succeeds")
	_assert_eq(result.get("count", -1), 3, "metadata count")

	var messages: Array = result.get("messages", [])
	_assert_eq(messages[0].get("index", -1), 0, "user index included")
	_assert_eq(messages[0].get("role", ""), "user", "user role mapped")
	_assert_eq(messages[0].get("chars", -1), "Plan the work".length(), "user char count")
	_assert(not messages[0].has("content"), "metadata omits content")

	_assert_eq(messages[1].get("role", ""), "assistant", "model role maps to assistant")
	_assert_eq(messages[1].get("tool_calls", -1), 1, "tool call count included")
	_assert_eq(messages[1].get("tool_names", [])[0], "minerva_list_chats", "tool names included")

	_assert_eq(messages[2].get("role", ""), "tool", "tool role mapped")
	_assert_eq(messages[2].get("tool_name", ""), "minerva_list_chats", "tool result name included")


func test_get_chat_messages_hydrates_requested_indices() -> void:
	print("test_get_chat_messages_hydrates_requested_indices:")
	var tools := _build_tools_with_history()
	var result := tools._get_chat_messages({
		"chat_id": "chat-under-test",
		"indices": [1, 2]
	})

	_assert(result.get("success", false), "hydrate call succeeds")
	_assert_eq(result.get("count", -1), 2, "hydrate count")

	var messages: Array = result.get("messages", [])
	_assert_eq(messages[0].get("index", -1), 1, "first hydrated index preserved")
	_assert_eq(messages[0].get("content", ""), "Calling tools", "assistant content hydrated")
	_assert_eq(messages[0].get("tool_calls", [])[0].get("name", ""), "minerva_list_chats", "assistant tool call payload hydrated")

	_assert_eq(messages[1].get("index", -1), 2, "second hydrated index preserved")
	_assert_eq(messages[1].get("tool_call_id", ""), "call_1", "tool result call id hydrated")
	_assert_eq(messages[1].get("tool_name", ""), "minerva_list_chats", "tool result name hydrated")


func test_get_chat_messages_validates_indices() -> void:
	print("test_get_chat_messages_validates_indices:")
	var tools := _build_tools_with_history()

	var missing := tools._get_chat_messages({"chat_id": "chat-under-test", "indices": []})
	_assert_eq(missing.get("error", ""), "indices is required", "empty indices rejected")

	var out_of_range := tools._get_chat_messages({
		"chat_id": "chat-under-test",
		"indices": [99]
	})
	_assert(out_of_range.get("error", "").contains("out of range"), "out of range index rejected")
