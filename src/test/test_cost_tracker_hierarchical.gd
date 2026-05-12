extends SceneTree
## Unit tests for CostTracker hierarchical budget helpers.
##
## Run: godot --headless --script test/test_cost_tracker_hierarchical.gd
##
## CostTracker.gd cannot be loaded in headless --script mode because
## singleton_object.gd fails to parse without the full set of C++ extension
## types (Service, CoreClient, etc.). Instead, this test inlines the two new
## methods under test into a local _Tracker inner-class that replicates only
## the data structures and logic being tested. This is the same pattern used
## for ToolBudgetManager tests which use class_name directly (available because
## GDScript class names are registered before --script runs, unlike autoload-
## dependent scripts that need --path + full project context).
##
## Covers:
##   - get_spend_for_key: exact match + prefix match
##   - check_hierarchical_budget: no budgets → ok=true
##   - check_hierarchical_budget: most-specific key exceeded → ok=false + which_budget
##   - check_hierarchical_budget: infinity at leaf does NOT bypass exceeded parent
##   - All BUDGET_PERIODS smoke-tested

var _pass_count: int = 0
var _fail_count: int = 0


# ---------------------------------------------------------------------------
# Inline replica of the two new CostTracker methods
# ---------------------------------------------------------------------------
# This class contains only the fields and methods relevant to the new
# hierarchical budget feature, copied verbatim from CostTracker.gd.
# It does NOT subclass CostTracker (can't load it) — it is a standalone RefCounted
# that mirrors the same logic.

class _Tracker extends RefCounted:
	const BUDGET_PERIODS := ["hour", "day", "week", "month"]

	var _ledger: Array[Dictionary] = []
	var _budgets: Dictionary = {}

	func _get_period_cutoff(period: String) -> String:
		var seconds: int
		match period:
			"hour":
				seconds = 3600
			"day":
				seconds = 86400
			"week":
				seconds = 7 * 86400
			"month":
				seconds = 30 * 86400
			_:
				seconds = 86400
		var cutoff_unix := Time.get_unix_time_from_system() - seconds
		return Time.get_datetime_string_from_unix_time(int(cutoff_unix), true)

	## Verbatim copy of CostTracker.get_spend_for_key
	func get_spend_for_key(key: String, period: String) -> float:
		var cutoff := _get_period_cutoff(period)
		var prefix := key + "/"
		var total := 0.0
		for entry in _ledger:
			if entry["ts"] < cutoff:
				continue
			var cid: String = entry.get("chat_id", "")
			if cid == key or cid.begins_with(prefix):
				total += entry["cost_usd"]
		return total

	## Verbatim copy of CostTracker.check_hierarchical_budget
	func check_hierarchical_budget(plugin_id: String, provider: String, model: String) -> Dictionary:
		var keys: Array[String] = [
			"plugin/%s/%s/%s" % [plugin_id, provider, model],
			"plugin/%s/%s" % [plugin_id, provider],
			"plugin/%s" % plugin_id,
		]
		for key in keys:
			if not _budgets.has(key):
				continue
			var budget_info: Dictionary = _budgets[key]
			var budget_usd: float = float(budget_info.get("budget_usd", 0.0))
			if budget_usd == -1.0:
				continue
			if budget_usd <= 0.0:
				continue
			var period: String = str(budget_info.get("period", "day"))
			var spent: float = get_spend_for_key(key, period)
			if spent >= budget_usd:
				return {
					"ok": false,
					"which_budget": key,
					"budget": budget_usd,
					"spent": spent,
					"period": period,
				}
		return {"ok": true}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

func _init() -> void:
	print("=== CostTracker Hierarchical Budget Tests ===\n")
	_run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	_test_get_spend_for_key()
	_test_check_hierarchical_no_budgets()
	_test_check_hierarchical_leaf_exceeded()
	_test_infinity_does_not_bypass_parent()
	_test_budget_periods_smoke()


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

func _make_tracker() -> _Tracker:
	return _Tracker.new()


func _inject_entry(t: _Tracker, chat_id: String, cost: float) -> void:
	var now: String = Time.get_datetime_string_from_system(true)
	t._ledger.append({
		"ts": now,
		"provider": "test",
		"model": "test-model",
		"input_tokens": 0,
		"output_tokens": 0,
		"cost_usd": cost,
		"chat_id": chat_id,
	})


# ---------------------------------------------------------------------------
# Test: get_spend_for_key prefix matching
# ---------------------------------------------------------------------------

func _test_get_spend_for_key() -> void:
	print("--- get_spend_for_key ---")
	var t := _make_tracker()

	_inject_entry(t, "plugin/scansort", 1.0)
	_inject_entry(t, "plugin/scansort/anthropic", 2.0)
	_inject_entry(t, "plugin/scansort/anthropic/sonnet", 4.0)
	# Unrelated entry must NOT appear in any scansort sum
	_inject_entry(t, "plugin/other", 100.0)

	# Root key matches all three scansort entries (exact + prefix)
	var root_sum: float = t.get_spend_for_key("plugin/scansort", "day")
	check("root key sums exact + both children (7.0)", absf(root_sum - 7.0) < 0.0001)

	# Middle key matches anthropic-exact + sonnet (prefix of anthropic), not root-only
	var mid_sum: float = t.get_spend_for_key("plugin/scansort/anthropic", "day")
	check("mid key sums anthropic exact + sonnet child (6.0)", absf(mid_sum - 6.0) < 0.0001)

	# Leaf key matches only the sonnet entry (exact only)
	var leaf_sum: float = t.get_spend_for_key("plugin/scansort/anthropic/sonnet", "day")
	check("leaf key sums only exact match (4.0)", absf(leaf_sum - 4.0) < 0.0001)

	# Unrelated key gets zero
	var none_sum: float = t.get_spend_for_key("plugin/unknown", "day")
	check("unknown key returns 0.0", absf(none_sum) < 0.0001)

	# "other" key does NOT bleed into "scansort" prefix check
	var other_sum: float = t.get_spend_for_key("plugin/other", "day")
	check("other key returns only its own entry (100.0)", absf(other_sum - 100.0) < 0.0001)


# ---------------------------------------------------------------------------
# Test: no budgets set → ok=true
# ---------------------------------------------------------------------------

func _test_check_hierarchical_no_budgets() -> void:
	print("--- check_hierarchical_budget: no budgets ---")
	var t := _make_tracker()
	_inject_entry(t, "plugin/scansort/anthropic/sonnet", 999.0)

	var r: Dictionary = t.check_hierarchical_budget("scansort", "anthropic", "sonnet")
	check("no budgets → ok=true", r.get("ok", false) == true)


# ---------------------------------------------------------------------------
# Test: most-specific (leaf) budget exceeded
# ---------------------------------------------------------------------------

func _test_check_hierarchical_leaf_exceeded() -> void:
	print("--- check_hierarchical_budget: leaf budget exceeded ---")
	var t := _make_tracker()

	t._budgets["plugin/scansort/anthropic/sonnet"] = {
		"budget_usd": 0.01,
		"warn_pct": 0.8,
		"period": "day",
	}
	_inject_entry(t, "plugin/scansort/anthropic/sonnet", 0.05)

	var r: Dictionary = t.check_hierarchical_budget("scansort", "anthropic", "sonnet")
	check("leaf exceeded → ok=false", r.get("ok", true) == false)
	check("which_budget is leaf key",
		r.get("which_budget", "") == "plugin/scansort/anthropic/sonnet")
	check("budget field present", r.has("budget"))
	check("spent field present", r.has("spent"))
	check("period field present", r.has("period"))

	# Also verify: a second call after spend drops below budget returns ok=true
	var t2 := _make_tracker()
	t2._budgets["plugin/scansort/anthropic/sonnet"] = {
		"budget_usd": 1.0,
		"warn_pct": 0.8,
		"period": "day",
	}
	_inject_entry(t2, "plugin/scansort/anthropic/sonnet", 0.001)
	var r2: Dictionary = t2.check_hierarchical_budget("scansort", "anthropic", "sonnet")
	check("under budget → ok=true", r2.get("ok", false) == true)


# ---------------------------------------------------------------------------
# Test: infinity (-1.0) at leaf does NOT bypass an exceeded parent budget
# ---------------------------------------------------------------------------

func _test_infinity_does_not_bypass_parent() -> void:
	print("--- check_hierarchical_budget: infinity leaf + exceeded parent ---")
	var t := _make_tracker()

	# Leaf has infinity → passes at this level, continues to parent
	t._budgets["plugin/scansort/anthropic/sonnet"] = {
		"budget_usd": -1.0,
		"warn_pct": 0.8,
		"period": "day",
	}
	# Middle level has no budget → skipped
	# Root/plugin level has a tight budget
	t._budgets["plugin/scansort"] = {
		"budget_usd": 0.01,
		"warn_pct": 0.8,
		"period": "day",
	}

	# Inject spend at the leaf chat_id path so the parent prefix-sum aggregates it
	_inject_entry(t, "plugin/scansort/anthropic/sonnet", 0.05)

	var r: Dictionary = t.check_hierarchical_budget("scansort", "anthropic", "sonnet")
	check("infinity at leaf does not bypass parent → ok=false",
		r.get("ok", true) == false)
	check("which_budget is root plugin key",
		r.get("which_budget", "") == "plugin/scansort")

	# Sanity: with no spend the parent budget is fine
	var t2 := _make_tracker()
	t2._budgets["plugin/scansort/anthropic/sonnet"] = {"budget_usd": -1.0, "period": "day", "warn_pct": 0.8}
	t2._budgets["plugin/scansort"] = {"budget_usd": 1.0, "period": "day", "warn_pct": 0.8}
	_inject_entry(t2, "plugin/scansort/anthropic/sonnet", 0.001)
	var r2: Dictionary = t2.check_hierarchical_budget("scansort", "anthropic", "sonnet")
	check("infinity leaf + parent under budget → ok=true", r2.get("ok", false) == true)


# ---------------------------------------------------------------------------
# Test: smoke all BUDGET_PERIODS
# ---------------------------------------------------------------------------

func _test_budget_periods_smoke() -> void:
	print("--- check_hierarchical_budget: all periods smoke ---")
	for period in _Tracker.BUDGET_PERIODS:
		# Over budget
		var t := _make_tracker()
		t._budgets["plugin/smoketest"] = {
			"budget_usd": 0.01,
			"warn_pct": 0.8,
			"period": period,
		}
		_inject_entry(t, "plugin/smoketest", 0.05)
		var r: Dictionary = t.check_hierarchical_budget("smoketest", "any", "any")
		check("period '%s': exceeded → ok=false" % period, r.get("ok", true) == false)

		# Under budget
		var t2 := _make_tracker()
		t2._budgets["plugin/smoketest2"] = {
			"budget_usd": 1.0,
			"warn_pct": 0.8,
			"period": period,
		}
		_inject_entry(t2, "plugin/smoketest2", 0.001)
		var r2: Dictionary = t2.check_hierarchical_budget("smoketest2", "any", "any")
		check("period '%s': under budget → ok=true" % period, r2.get("ok", false) == true)


# ---------------------------------------------------------------------------
# check helper
# ---------------------------------------------------------------------------

func check(label: String, condition: bool) -> void:
	if condition:
		print("  PASS: %s" % label)
		_pass_count += 1
	else:
		printerr("  FAIL: %s" % label)
		_fail_count += 1
