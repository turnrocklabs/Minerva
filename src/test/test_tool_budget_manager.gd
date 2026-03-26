extends SceneTree
## Test: ToolBudgetManager LRU eviction and token budget enforcement.
## Run: godot --headless --script test/test_tool_budget_manager.gd

var _pass_count: int = 0
var _fail_count: int = 0


func _init():
	print("=== ToolBudgetManager Tests ===\n")

	test_initial_state()
	test_activate_tool()
	test_activate_existing_refreshes()
	test_mark_used()
	test_is_active()
	test_try_call_active()
	test_try_call_pruned()
	test_budget_enforcement()
	test_lru_prunes_oldest()
	test_protected_tool_never_pruned()
	test_reset()
	test_advance_turn()
	test_set_budget()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func _make_schema(name: String, size: int = 100) -> Dictionary:
	return {"name": name, "description": "x".repeat(size * 4), "inputSchema": {}}


# ── Tests ─────────────────────────────────────────────────────────────

func test_initial_state():
	print("test_initial_state:")
	var mgr := ToolBudgetManager.new()
	check("new manager has 0 active tools", mgr.get_active_count() == 0)
	check("new manager has 0 token usage", mgr.get_token_usage() == 0)
	check("default budget is 3000", mgr.get_budget() == 3000)
	check("initial turn is 0", mgr.get_current_turn() == 0)


func test_activate_tool():
	print("test_activate_tool:")
	var mgr := ToolBudgetManager.new()
	mgr.activate_tool("tool_a", _make_schema("tool_a"))
	check("activating a tool adds it to active set", mgr.get_active_count() == 1)
	check("token usage > 0 after activation", mgr.get_token_usage() > 0)
	check("schemas list has 1 entry", mgr.get_active_schemas().size() == 1)


func test_activate_existing_refreshes():
	print("test_activate_existing_refreshes:")
	var mgr := ToolBudgetManager.new()
	mgr.activate_tool("tool_a", _make_schema("tool_a"))
	var usage_before: int = mgr.get_token_usage()
	mgr.advance_turn()
	mgr.activate_tool("tool_a", _make_schema("tool_a"))
	check("activating same tool twice does not duplicate", mgr.get_active_count() == 1)
	check("token usage unchanged after re-activation", mgr.get_token_usage() == usage_before)


func test_mark_used():
	print("test_mark_used:")
	var mgr := ToolBudgetManager.new()
	mgr.activate_tool("tool_a", _make_schema("tool_a"))
	mgr.advance_turn()
	mgr.advance_turn()
	mgr.mark_used("tool_a")
	# Activate another tool that forces pruning — tool_a should survive because it was just used
	# Use a tiny budget so adding tool_b forces pruning
	var mgr2 := ToolBudgetManager.new(200)
	mgr2.activate_tool("tool_a", _make_schema("tool_a", 10))  # ~40 tokens
	mgr2.advance_turn()
	mgr2.mark_used("tool_a")
	mgr2.advance_turn()
	mgr2.activate_tool("tool_b", _make_schema("tool_b", 10))  # ~40 tokens, fits
	check("mark_used keeps tool active after use", mgr2.is_active("tool_a"))
	check("mark_used: tool_a still active alongside tool_b", mgr2.is_active("tool_b"))


func test_is_active():
	print("test_is_active:")
	var mgr := ToolBudgetManager.new()
	mgr.activate_tool("tool_a", _make_schema("tool_a"))
	check("is_active returns true for active tool", mgr.is_active("tool_a"))
	check("is_active returns false for inactive tool", not mgr.is_active("tool_z"))


func test_try_call_active():
	print("test_try_call_active:")
	var mgr := ToolBudgetManager.new()
	var schema := _make_schema("tool_a")
	mgr.activate_tool("tool_a", schema)
	var result := mgr.try_call("tool_a")
	check("try_call returns active=true for active tool", result.get("active") == true)
	check("try_call returns schema for active tool", result.has("schema"))
	check("returned schema name matches", result["schema"].get("name") == "tool_a")


func test_try_call_pruned():
	print("test_try_call_pruned:")
	var mgr := ToolBudgetManager.new()
	var result := mgr.try_call("tool_missing")
	check("try_call returns active=false for missing tool", result.get("active") == false)
	check("try_call returns error key for missing tool", result.has("error"))
	check("error message contains tool name", ("tool_missing" in result.get("error", "")))
	check("error message mentions minerva_tool_search", ("minerva_tool_search" in result.get("error", "")))


func test_budget_enforcement():
	print("test_budget_enforcement:")
	# Budget of 500 tokens, each schema ~100 tokens → fits ~5 tools
	var mgr := ToolBudgetManager.new(500)
	for i in range(20):
		mgr.activate_tool("tool_%d" % i, _make_schema("tool_%d" % i, 25))
	check("usage never exceeds budget", mgr.get_token_usage() <= 500)
	check("some tools were pruned (not all 20 active)", mgr.get_active_count() < 20)


func test_lru_prunes_oldest():
	print("test_lru_prunes_oldest:")
	# Budget fits exactly 3 tools of size 10 (~40 tokens each → ~120 total), set budget to 130
	var mgr := ToolBudgetManager.new(130)
	# Turn 0: activate tool_1
	mgr.activate_tool("tool_1", _make_schema("tool_1", 10))
	mgr.advance_turn()
	# Turn 1: activate tool_2
	mgr.activate_tool("tool_2", _make_schema("tool_2", 10))
	mgr.advance_turn()
	# Turn 2: activate tool_3
	mgr.activate_tool("tool_3", _make_schema("tool_3", 10))
	check("all 3 tools active before adding 4th", mgr.get_active_count() == 3)
	# Mark tool_1 and tool_3 as used, making tool_2 the oldest unused
	mgr.mark_used("tool_1")
	mgr.mark_used("tool_3")
	mgr.advance_turn()
	# Turn 3: activate tool_4 — should evict tool_2 (LRU)
	mgr.activate_tool("tool_4", _make_schema("tool_4", 10))
	check("tool_2 was pruned (LRU)", not mgr.is_active("tool_2"))
	check("tool_1 survives (was used)", mgr.is_active("tool_1"))
	check("tool_3 survives (was used)", mgr.is_active("tool_3"))
	check("tool_4 is now active", mgr.is_active("tool_4"))


func test_protected_tool_never_pruned():
	print("test_protected_tool_never_pruned:")
	# Very tight budget: only fits 1 small tool
	var mgr := ToolBudgetManager.new(60)
	var search_schema := _make_schema(ToolBudgetManager.PROTECTED_TOOL, 5)
	mgr.activate_tool(ToolBudgetManager.PROTECTED_TOOL, search_schema)
	# Activate another tool that would require pruning tool_search to fit — it cannot
	mgr.activate_tool("tool_a", _make_schema("tool_a", 5))
	check("protected tool is never pruned", mgr.is_active(ToolBudgetManager.PROTECTED_TOOL))


func test_reset():
	print("test_reset:")
	var mgr := ToolBudgetManager.new()
	# Activate tool_search and several others
	mgr.activate_tool(ToolBudgetManager.PROTECTED_TOOL, _make_schema(ToolBudgetManager.PROTECTED_TOOL))
	for i in range(4):
		mgr.activate_tool("tool_%d" % i, _make_schema("tool_%d" % i))
	mgr.advance_turn()
	mgr.advance_turn()
	check("5 tools active before reset", mgr.get_active_count() == 5)
	mgr.reset()
	check("only 1 tool remains after reset (tool_search)", mgr.get_active_count() == 1)
	check("tool_search survives reset", mgr.is_active(ToolBudgetManager.PROTECTED_TOOL))
	check("turn resets to 0", mgr.get_current_turn() == 0)

	# Test reset without tool_search active
	var mgr2 := ToolBudgetManager.new()
	for i in range(3):
		mgr2.activate_tool("tool_%d" % i, _make_schema("tool_%d" % i))
	mgr2.reset()
	check("reset with no tool_search leaves 0 tools", mgr2.get_active_count() == 0)


func test_advance_turn():
	print("test_advance_turn:")
	var mgr := ToolBudgetManager.new()
	check("initial turn is 0", mgr.get_current_turn() == 0)
	mgr.advance_turn()
	check("turn is 1 after one advance", mgr.get_current_turn() == 1)
	mgr.advance_turn()
	mgr.advance_turn()
	check("turn is 3 after three advances", mgr.get_current_turn() == 3)


func test_set_budget():
	print("test_set_budget:")
	var mgr := ToolBudgetManager.new(3000)
	check("initial budget is 3000", mgr.get_budget() == 3000)
	mgr.set_budget(500)
	check("budget updated to 500", mgr.get_budget() == 500)

	# Verify tighter budget causes pruning on next activation
	var mgr2 := ToolBudgetManager.new(10000)
	for i in range(10):
		mgr2.activate_tool("tool_%d" % i, _make_schema("tool_%d" % i, 50))
	var count_before: int = mgr2.get_active_count()
	mgr2.set_budget(100)
	# Adding one more tool at the new tight budget should trigger pruning
	mgr2.activate_tool("tool_new", _make_schema("tool_new", 5))
	check("new tool activated under tight budget", mgr2.is_active("tool_new"))
	check("usage respects new tighter budget", mgr2.get_token_usage() <= 100)
	check("fewer tools active than before budget change", mgr2.get_active_count() < count_before)
