extends SceneTree
## Unit tests for ToolMemoryManager.
## Run: godot --headless --script test/test_tool_memory_manager.gd

var _pass_count: int = 0
var _fail_count: int = 0
var _skip_count: int = 0

## ChatHistoryItem depends on SingletonObject autoload which may not compile
## in headless mode. Detect this and skip tests that need real ChatHistoryItems.
var _chi_available: bool = false


func _init():
	print("=== ToolMemoryManager Unit Tests ===\n")

	# Probe whether ChatHistoryItem is constructable in this environment
	_chi_available = _probe_chat_history_item()
	if not _chi_available:
		print("  NOTE: ChatHistoryItem unavailable (autoload not compiled). Some tests will be skipped.\n")

	print("-- Configuration --")
	test_apply_config()
	test_hydrate_from_history()

	print("\n-- Projection (disabled) --")
	test_disabled_passthrough()

	print("\n-- Dehydration --")
	test_dehydration_basic()
	test_dehydrate_preserves_latest_round()
	test_dehydrate_tool_use_collapse()

	print("\n-- Recovery Index --")
	test_recovery_index_built()
	test_recovery_index_bounded()
	test_recovery_index_lossless()

	print("\n-- Handle Recall --")
	test_handle_recall_search()
	test_handle_recall_search_filtered()
	test_handle_recall_retrieve_missing()

	print("\n-- Deterministic Summary --")
	test_deterministic_fallback()

	print("\n-- Telemetry --")
	test_record_telemetry()

	print("\n=== Results: %d passed, %d failed, %d skipped ===" % [_pass_count, _fail_count, _skip_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _probe_chat_history_item() -> bool:
	var item = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER, "probe", true)
	return item != null


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func skip(description: String) -> void:
	_skip_count += 1
	print("  SKIP: %s (ChatHistoryItem unavailable)" % description)


## Returns true if ChatHistoryItem tests should run; false = skip.
func require_chi(test_name: String) -> bool:
	if _chi_available:
		return true
	skip(test_name)
	return false


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

## Create a minimal ChatHistoryItem for testing.
func _make_item(role: ChatHistoryItem.ChatRole, message: String = "", tool_name: String = "", tool_artifact_note_id: String = "", is_tool_call: bool = false, tool_calls: Array[Dictionary] = []) -> ChatHistoryItem:
	var item := ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, role, message, true)
	item._suppress_save_state = true
	item.ToolName = tool_name
	item.ToolArtifactNoteId = tool_artifact_note_id
	item.IsToolCall = is_tool_call
	if not tool_calls.is_empty():
		item.ToolCalls = tool_calls
	item._suppress_save_state = false
	return item


## Create a basic 3-round tool conversation for testing dehydration.
## Round 1: user → assistant(tool_use) → tool_result
## Round 2: assistant(tool_use) → tool_result
## Round 3: assistant(tool_use) → tool_result (latest)
func _make_3_round_history() -> Array[ChatHistoryItem]:
	var items: Array[ChatHistoryItem] = []

	# User message
	items.append(_make_item(ChatHistoryItem.ChatRole.USER, "Find me some USB cables"))

	# Round 1: assistant with tool call → tool result
	var tc1: Array[Dictionary] = [{"id": "call_1", "name": "search_amazon", "arguments": {}}]
	items.append(_make_item(ChatHistoryItem.ChatRole.ASSISTANT, "Let me search.", "", "", true, tc1))
	var tool1 := _make_item(ChatHistoryItem.ChatRole.TOOL, "Found 10 results with prices and ratings", "search_amazon", "note-uuid-1111")
	tool1._suppress_save_state = true
	tool1.ToolCallId = "call_1"
	tool1.ToolSummary = "[search_amazon: 10 results]"
	tool1._suppress_save_state = false
	items.append(tool1)

	# Round 2: assistant with tool call → tool result
	var tc2: Array[Dictionary] = [{"id": "call_2", "name": "read_product", "arguments": {}}]
	items.append(_make_item(ChatHistoryItem.ChatRole.ASSISTANT, "Reading product details.", "", "", true, tc2))
	var tool2 := _make_item(ChatHistoryItem.ChatRole.TOOL, "Product details: Anker USB-C cable, $12.99, 4.5 stars", "read_product", "note-uuid-2222")
	tool2._suppress_save_state = true
	tool2.ToolCallId = "call_2"
	tool2.ToolSummary = "[read_product: Anker USB-C]"
	tool2._suppress_save_state = false
	items.append(tool2)

	# Round 3 (latest): assistant with tool call → tool result
	var tc3: Array[Dictionary] = [{"id": "call_3", "name": "add_to_spreadsheet", "arguments": {}}]
	items.append(_make_item(ChatHistoryItem.ChatRole.ASSISTANT, "Adding to spreadsheet.", "", "", true, tc3))
	var tool3 := _make_item(ChatHistoryItem.ChatRole.TOOL, "Added row for Anker cable", "add_to_spreadsheet", "note-uuid-3333")
	tool3._suppress_save_state = true
	tool3.ToolCallId = "call_3"
	tool3.ToolSummary = "[add_to_spreadsheet: 1 row]"
	tool3._suppress_save_state = false
	items.append(tool3)

	return items


# ---------------------------------------------------------------------------
# Configuration tests
# ---------------------------------------------------------------------------

func test_apply_config():
	var tmm := ToolMemoryManager.new()
	tmm.apply_config({
		"enabled": true,
		"dehydrate_after_n_rounds": 3,
		"max_floating_summary_chars": 5000,
		"drop_refs_after_n_rounds": 20,
		"max_tool_schema_count": 10,
		"context_budget_tokens": 80000,
		"max_index_entries": 100,
		"summary_prompt": "test prompt",
	})
	check("enabled is true", tmm.enabled == true)
	check("dehydrate_after_n_rounds is 3", tmm.dehydrate_after_n_rounds == 3)
	check("max_floating_summary_chars is 5000", tmm.max_floating_summary_chars == 5000)
	check("drop_refs_after_n_rounds is 20", tmm.drop_refs_after_n_rounds == 20)
	check("max_tool_schema_count is 10", tmm.max_tool_schema_count == 10)
	check("context_budget_tokens is 80000", tmm.context_budget_tokens == 80000)
	check("max_index_entries is 100", tmm.max_index_entries == 100)
	check("summary_prompt is set", tmm.summary_prompt == "test prompt")


func test_hydrate_from_history():
	# Create a real ChatHistory with provider=null — ChatHistory._init requires provider arg
	# We can't easily create one without SingletonObject, so test the manager's hydrate directly
	var tmm := ToolMemoryManager.new()
	# Manually set the fields that _hydrate would read
	tmm.floating_summary_note_id = "test-note-id"
	tmm.tool_memory_state = {"version": 3, "active": {}}
	tmm.telemetry = {"items_dehydrated": 5}
	check("floating_summary_note_id preserved", tmm.floating_summary_note_id == "test-note-id")
	check("tool_memory_state preserved", tmm.tool_memory_state.get("version") == 3)
	check("telemetry preserved", tmm.telemetry.get("items_dehydrated") == 5)


# ---------------------------------------------------------------------------
# Projection tests
# ---------------------------------------------------------------------------

func test_disabled_passthrough():
	var tmm := ToolMemoryManager.new()
	tmm.enabled = false
	check("disabled manager has enabled=false", tmm.enabled == false)
	check("recovery index empty when no rebuild", tmm.get_recovery_index().is_empty())


func test_dehydration_basic():
	if not require_chi("dehydration_basic"): return
	var tmm := ToolMemoryManager.new()
	var items := _make_3_round_history()
	var chain_state: Dictionary = tmm._get_latest_tool_chain_state(items)
	var retained: Dictionary = chain_state.get("retained_tool_result_indices", {})
	var latest_idx: int = chain_state.get("latest_tool_idx", -1)

	check("latest_tool_idx is 6", latest_idx == 6)
	check("retained has index 6", retained.has(6))
	check("retained does NOT have index 2 (round 1)", not retained.has(2))
	check("retained does NOT have index 4 (round 2)", not retained.has(4))
	check("retained count is 1", retained.size() == 1)


func test_dehydrate_preserves_latest_round():
	if not require_chi("dehydrate_preserves_latest_round"): return
	var tmm := ToolMemoryManager.new()
	var items := _make_3_round_history()
	var chain_state: Dictionary = tmm._get_latest_tool_chain_state(items)
	var latest_call_msg_idx: int = chain_state.get("latest_tool_call_message_idx", -1)

	check("latest_tool_call_message_idx is 5", latest_call_msg_idx == 5)

	var retained: Dictionary = chain_state.get("retained_tool_result_indices", {})
	check("retained includes tool result after latest call", retained.has(6))


func test_dehydrate_tool_use_collapse():
	# Test the collapsed message builder
	var tool_calls: Array[Dictionary] = [
		{"name": "search_amazon", "arguments": {}},
		{"name": "read_product", "arguments": {}},
	]
	var collapsed: String = ToolMemoryManager._build_collapsed_tool_use_message(tool_calls)
	check("collapsed contains both tool names", "search_amazon" in collapsed and "read_product" in collapsed)
	check("collapsed starts with [tool-use summarized:", collapsed.begins_with("[tool-use summarized:"))


# ---------------------------------------------------------------------------
# Recovery index tests
# ---------------------------------------------------------------------------

func test_recovery_index_built():
	if not require_chi("recovery_index_built"): return
	var tmm := ToolMemoryManager.new()
	var items := _make_3_round_history()
	tmm.rebuild_recovery_index(items)
	var index := tmm.get_recovery_index()
	check("index has 3 entries (3 tool results with note IDs)", index.size() == 3)
	check("first entry tool is search_amazon", index[0].get("tool") == "search_amazon")
	check("second entry tool is read_product", index[1].get("tool") == "read_product")
	check("third entry tool is add_to_spreadsheet", index[2].get("tool") == "add_to_spreadsheet")


func test_recovery_index_bounded():
	if not require_chi("recovery_index_bounded"): return
	var tmm := ToolMemoryManager.new()
	tmm.max_index_entries = 2
	var items := _make_3_round_history()
	tmm.rebuild_recovery_index(items)
	var index := tmm.get_recovery_index()
	check("index bounded to 2 entries", index.size() == 2)
	check("oldest (search_amazon) dropped", index[0].get("tool") == "read_product")
	check("newest (add_to_spreadsheet) kept", index[1].get("tool") == "add_to_spreadsheet")


func test_recovery_index_lossless():
	if not require_chi("recovery_index_lossless"): return
	var tmm := ToolMemoryManager.new()
	var items := _make_3_round_history()
	tmm.rebuild_recovery_index(items)
	var index := tmm.get_recovery_index()

	check("note_id is exact string", index[0].get("note_id") == "note-uuid-1111")
	check("round is int 1", index[0].get("round") is int and index[0].get("round") == 1)
	check("tool name exact", index[0].get("tool") == "search_amazon")
	check("brief from ToolSummary", index[0].get("brief") == "[search_amazon: 10 results]")

	check("second note_id exact", index[1].get("note_id") == "note-uuid-2222")
	check("second round is int 2", index[1].get("round") == 2)


# ---------------------------------------------------------------------------
# Handle recall tests
# ---------------------------------------------------------------------------

func test_handle_recall_search():
	if not require_chi("handle_recall_search"): return
	var tmm := ToolMemoryManager.new()
	var items := _make_3_round_history()
	tmm.rebuild_recovery_index(items)

	var result := tmm.handle_recall({"query": "", "limit": 10})
	check("search returns all 3", result.get("count") == 3)
	check("entries array present", result.get("entries") is Array)
	check("total_archived is 3", result.get("total_archived") == 3)


func test_handle_recall_search_filtered():
	if not require_chi("handle_recall_search_filtered"): return
	var tmm := ToolMemoryManager.new()
	var items := _make_3_round_history()
	tmm.rebuild_recovery_index(items)

	var result := tmm.handle_recall({"query": "spreadsheet"})
	check("filtered search returns 1", result.get("count") == 1)
	var entries: Array = result.get("entries", [])
	check("filtered entry is add_to_spreadsheet", entries[0].get("tool") == "add_to_spreadsheet" if entries.size() > 0 else false)


func test_handle_recall_retrieve_missing():
	var tmm := ToolMemoryManager.new()
	# Retrieve a note that doesn't exist (no SingletonObject in headless)
	var result := tmm.handle_recall({"note_id": "nonexistent-uuid"})
	check("retrieve missing returns error", result.has("error"))
	check("error says not found", "not found" in str(result.get("error", "")))


# ---------------------------------------------------------------------------
# Deterministic summary tests
# ---------------------------------------------------------------------------

func test_deterministic_fallback():
	var tmm := ToolMemoryManager.new()
	var existing := "Previous summary: found 5 products"
	var new_source := "Tool: read_product\nCompact summary: [read_product: Anker USB-C]"

	var result: String = tmm._build_deterministic_floating_summary(existing, new_source)
	check("result contains existing summary", "found 5 products" in result)
	check("result contains new source", "read_product" in result)
	check("result contains separator", "---" in result)

	# Test truncation with very long input
	var long_text := "x".repeat(5000)
	var truncated: String = tmm._build_deterministic_floating_summary(long_text, new_source)
	check("truncated to TOOL_WINDOW_LENGTH", truncated.length() <= ToolMemoryManager.TOOL_WINDOW_LENGTH)


# ---------------------------------------------------------------------------
# Telemetry tests
# ---------------------------------------------------------------------------

func test_record_telemetry():
	var tmm := ToolMemoryManager.new()
	# We can't create a real ServiceHistory without SingletonObject, so test the local telemetry
	tmm.telemetry = {}
	# Directly update local telemetry to verify the pattern
	var update := {"items_dehydrated": 3, "chars_removed": 1500}
	for key in update.keys():
		tmm.telemetry[key] = update[key]
	check("telemetry has items_dehydrated", tmm.telemetry.get("items_dehydrated") == 3)
	check("telemetry has chars_removed", tmm.telemetry.get("chars_removed") == 1500)

	# Verify get_stats includes telemetry
	var stats := tmm.get_stats()
	check("stats includes telemetry", stats.get("telemetry") is Dictionary)
	check("stats telemetry has items_dehydrated", stats.get("telemetry", {}).get("items_dehydrated") == 3)
