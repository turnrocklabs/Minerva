extends SceneTree
## Unit tests for PolicyEngine, ActionNormalizer, and RiskScopeState.
## Run: godot --headless --script test/test_policy_engine.gd

var _pass_count: int = 0
var _fail_count: int = 0


func _init():
	print("=== PolicyEngine Unit Tests ===\n")

	# ActionNormalizer tests
	print("-- ActionNormalizer --")
	test_normalize_bash_git_push()
	test_normalize_bash_rm_rf()
	test_normalize_bash_docker()
	test_normalize_file_tool()
	test_normalize_docket_tool()
	test_normalize_terminal_write_ignored()
	test_normalize_unknown_tool()
	test_normalize_cobrowser_navigate()
	test_normalize_cobrowser_click()
	test_normalize_cobrowser_read()
	test_normalize_nudge_tool()

	# RiskScopeState tests
	print("\n-- RiskScopeState --")
	test_scope_activate_and_check()
	test_scope_expires_by_count()
	test_scope_refresh()
	test_scope_clear()
	test_get_active_scopes()

	# PolicyEngine rule compilation tests
	print("\n-- PolicyEngine: Rule Compilation --")
	test_compile_missing_fence()
	test_compile_invalid_json()
	test_compile_missing_required_field()
	test_compile_valid_rule()
	test_compile_triggers_array()
	test_compile_single_element_triggers_array()

	# PolicyEngine evaluation tests
	print("\n-- PolicyEngine: Evaluation --")
	test_evaluate_no_rules_allows()
	test_evaluate_block_rule_blocks()
	test_evaluate_observe_rule_allows_with_observations()
	test_evaluate_scope_rule_activates_scope()
	test_evaluate_proposed_rule_always_observes()
	test_evaluate_session_override_skips_rule()
	test_evaluate_priority_ordering()
	test_evaluate_domain_predicate_matching()
	test_evaluate_verb_predicate_matching()
	test_evaluate_multi_trigger_first_trigger_matches()
	test_evaluate_multi_trigger_second_trigger_matches()
	test_evaluate_multi_trigger_neither_matches()
	test_evaluate_legacy_format_backward_compat()

	# Scope duration tests
	print("\n-- Scope Duration --")
	test_scope_custom_duration()

	# Per-chat scope isolation tests
	print("\n-- Per-Chat Scope Isolation --")
	test_scope_per_chat()

	# Inject effect tests
	print("\n-- Inject Effect --")
	test_inject_effect_allowed_with_injections()
	test_inject_with_scope_prevents_reinjection()
	test_inject_proposed_downgrades_to_observe()
	test_inject_multiple_rules_collect_all()
	test_inject_plus_block_block_wins()

	# Override safety note
	print("\n-- Override Safety (manual validation note) --")
	test_agent_cannot_self_override_note()

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


# ── Helpers ───────────────────────────────────────────────────────────────────

## Build a fully-compiled rule Dictionary that can be injected directly into
## PolicyEngine._rules, bypassing the Docket/reload path.
##
## Accepts either a "triggers" array (new format) or "tool_pattern"/"arg_predicates"
## at the top level (legacy format, auto-wrapped into a single-element triggers list).
func _make_rule(overrides: Dictionary = {}) -> Dictionary:
	var base := {
		"rule_id": "test-rule-001",
		"title": "Test Rule",
		"status": "active",
		"effect": "block",
		"tool_pattern": "minerva_bash",
		"arg_predicates": {},
		"context_predicates": {},
		"domain_predicates": [],
		"verb_predicates": [],
		"flag_predicates": [],
		"activate_scope": null,
		"scope_max_actions": 10,
		"scope_ttl_ms": 300000,
		"priority": 10,
		"provenance": "user",
		"knowledge_ref": "",
		"alternatives": [],
		"cooldown": null,
	}
	base.merge(overrides, true)

	# Build the compiled triggers list.
	# If the caller supplied a pre-compiled "triggers" array, use it directly.
	# Otherwise wrap the legacy tool_pattern / arg_predicates into one trigger.
	if not base.has("triggers"):
		var trigger := _compile_trigger(
			str(base.get("tool_pattern", "")),
			base.get("arg_predicates", {})
		)
		base["triggers"] = [trigger]

	# Remove legacy top-level keys so tests don't accidentally rely on them.
	base.erase("tool_pattern")
	base.erase("arg_predicates")

	return base


## Compile a single trigger dict (tool_pattern + arg_predicates → regexes).
func _compile_trigger(tool_pattern: String, arg_predicates: Dictionary) -> Dictionary:
	var tool_regex: RegEx = null
	if not tool_pattern.is_empty():
		var re := RegEx.new()
		re.compile(tool_pattern)
		tool_regex = re

	var arg_regexes: Dictionary = {}
	for key in arg_predicates:
		var re := RegEx.new()
		re.compile(str(arg_predicates[key]))
		arg_regexes[key] = re

	return {
		"tool_pattern": tool_pattern,
		"tool_regex": tool_regex,
		"arg_predicates": arg_predicates,
		"arg_regexes": arg_regexes,
	}


# ── ActionNormalizer tests ─────────────────────────────────────────────────────

func test_normalize_bash_git_push():
	print("test_normalize_bash_git_push:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("minerva_bash", {"command": "git push --force origin main"})
	check("git push --force: domains contains 'git'", "git" in facts["domains"])
	check("git push --force: verbs contains 'force-push'", "force-push" in facts["verbs"])
	check("git push --force: flags contains 'force'", "force" in facts["flags"])
	check("git push --force: verbs does not contain plain 'push'", "push" not in facts["verbs"])


func test_normalize_bash_rm_rf():
	print("test_normalize_bash_rm_rf:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("minerva_bash", {"command": "rm -rf /tmp/test"})
	check("rm -rf: domains is empty", facts["domains"].is_empty())
	check("rm -rf: verbs contains 'delete-recursive'", "delete-recursive" in facts["verbs"])
	check("rm -rf: flags contains 'recursive'", "recursive" in facts["flags"])
	check("rm -rf: verbs does not contain plain 'delete'", "delete" not in facts["verbs"])


func test_normalize_bash_docker():
	print("test_normalize_bash_docker:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("minerva_bash", {"command": "docker build ."})
	check("docker build: domains contains 'docker'", "docker" in facts["domains"])


func test_normalize_file_tool():
	print("test_normalize_file_tool:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("minerva_file_read", {"path": "/foo/bar.gd"})
	check("file_read: domains contains 'filesystem'", "filesystem" in facts["domains"])
	check("file_read: paths contains '/foo/bar.gd'", "/foo/bar.gd" in facts["paths"])


func test_normalize_docket_tool():
	print("test_normalize_docket_tool:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("docket_transition", {"id": "abc", "to": "active"})
	check("docket_transition: domains contains 'docket'", "docket" in facts["domains"])


func test_normalize_terminal_write_ignored():
	print("test_normalize_terminal_write_ignored:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("minerva_terminal_write", {"text": "git push --force\r"})
	check("terminal_write: domains is empty", facts["domains"].is_empty())
	check("terminal_write: verbs is empty", facts["verbs"].is_empty())
	check("terminal_write: flags is empty", facts["flags"].is_empty())
	check("terminal_write: paths is empty", facts["paths"].is_empty())


func test_normalize_unknown_tool():
	print("test_normalize_unknown_tool:")
	var n := ActionNormalizer.new()
	# Unknown external tools get their prefix as domain (fallback behavior)
	var facts := n.normalize("some_random_tool_xyz", {"foo": "bar"})
	check("unknown tool: gets prefix domain", "some" in facts["domains"])
	check("unknown tool: flags is empty", facts["flags"].is_empty())
	check("unknown tool: paths is empty", facts["paths"].is_empty())
	check("unknown tool: tool name preserved", facts["tool"] == "some_random_tool_xyz")


func test_normalize_cobrowser_navigate():
	print("test_normalize_cobrowser_navigate:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("cobrowser_navigate", {"url": "https://example.com"})
	check("cobrowser_navigate: domain is browser", "browser" in facts["domains"])
	check("cobrowser_navigate: verb is navigate", "navigate" in facts["verbs"])
	check("cobrowser_navigate: url in paths", "https://example.com" in facts["paths"])


func test_normalize_cobrowser_click():
	print("test_normalize_cobrowser_click:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("cobrowser_click", {"selector": "#btn"})
	check("cobrowser_click: domain is browser", "browser" in facts["domains"])
	check("cobrowser_click: verb is interact", "interact" in facts["verbs"])
	check("cobrowser_click: paths is empty (no url)", facts["paths"].is_empty())


func test_normalize_cobrowser_read():
	print("test_normalize_cobrowser_read:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("cobrowser_read", {"selector": "body"})
	check("cobrowser_read: domain is browser", "browser" in facts["domains"])
	check("cobrowser_read: verb is read", "read" in facts["verbs"])


func test_normalize_nudge_tool():
	print("test_normalize_nudge_tool:")
	var n := ActionNormalizer.new()
	var facts := n.normalize("nudge_set_hint", {"component": "build", "key": "cmd", "value": "make"})
	check("nudge_set_hint: domain is nudge", "nudge" in facts["domains"])


# ── RiskScopeState tests ───────────────────────────────────────────────────────

func test_scope_activate_and_check():
	print("test_scope_activate_and_check:")
	var s := RiskScopeState.new()
	check("scope not active before activation", not s.is_active("my-scope"))
	s.activate("my-scope", 5, 300000)
	check("scope active after activation", s.is_active("my-scope"))


func test_scope_expires_by_count():
	print("test_scope_expires_by_count:")
	var s := RiskScopeState.new()
	s.activate("count-scope", 2, 300000)
	check("scope active before ticking", s.is_active("count-scope"))
	s.tick()
	check("scope active after 1 tick (max_actions=2)", s.is_active("count-scope"))
	s.tick()
	# After second tick, actions_remaining hits 0 and scope is pruned during tick()
	check("scope expired after 2 ticks", not s.is_active("count-scope"))


func test_scope_refresh():
	print("test_scope_refresh:")
	var s := RiskScopeState.new()
	s.activate("refresh-scope", 3, 300000)
	s.tick()
	check("scope active after 1 tick", s.is_active("refresh-scope"))
	# Re-activate resets the counter
	s.activate("refresh-scope", 3, 300000)
	s.tick()
	s.tick()
	check("scope still active after re-activate + 2 ticks (fresh count=3)", s.is_active("refresh-scope"))


func test_scope_clear():
	print("test_scope_clear:")
	var s := RiskScopeState.new()
	s.activate("clear-scope", 10, 300000)
	check("scope active before clear", s.is_active("clear-scope"))
	s.clear()
	check("scope not active after clear", not s.is_active("clear-scope"))


func test_get_active_scopes():
	print("test_get_active_scopes:")
	var s := RiskScopeState.new()
	s.activate("scope-alpha", 5, 300000)
	s.activate("scope-beta", 5, 300000)
	var active := s.get_active_scopes()
	check("get_active_scopes returns 2 entries", active.size() == 2)
	check("scope-alpha in active list", "scope-alpha" in active)
	check("scope-beta in active list", "scope-beta" in active)


# ── PolicyEngine rule compilation tests ───────────────────────────────────────
# _compile_rule is tested via its internal helpers using the _extract_fenced_json
# method and the full compile path invoked directly on a PolicyEngine instance.

func test_compile_missing_fence():
	print("test_compile_missing_fence:")
	var engine := PolicyEngine.new()
	var item := {
		"id": "rule-miss-fence",
		"title": "No Fence",
		"status": "active",
		"description": "This description has no fenced JSON block at all."
	}
	var rule: Dictionary = engine._compile_rule(item)
	check("missing fence returns empty dict", rule.is_empty())


func test_compile_invalid_json():
	print("test_compile_invalid_json:")
	var engine := PolicyEngine.new()
	var item := {
		"id": "rule-bad-json",
		"title": "Bad JSON",
		"status": "active",
		"description": "---policy-rule---\n{ not valid json !!!!\n---end-rule---"
	}
	var rule: Dictionary = engine._compile_rule(item)
	check("invalid JSON returns empty dict", rule.is_empty())


func test_compile_missing_required_field():
	print("test_compile_missing_required_field:")
	var engine := PolicyEngine.new()
	# Valid JSON but missing "effect"
	var item := {
		"id": "rule-no-effect",
		"title": "Missing Effect",
		"status": "active",
		"description": "---policy-rule---\n{\"tool_pattern\": \"minerva_bash\", \"priority\": 10}\n---end-rule---"
	}
	var rule: Dictionary = engine._compile_rule(item)
	check("missing 'effect' field returns empty dict", rule.is_empty())


func test_compile_valid_rule():
	print("test_compile_valid_rule:")
	var engine := PolicyEngine.new()
	var json_block := JSON.stringify({
		"tool_pattern": "minerva_bash",
		"effect": "block",
		"priority": 20,
		"knowledge_ref": "kb://git-force-push",
		"alternatives": ["git push"],
		"domain_predicates": ["git"],
		"verb_predicates": ["force-push"],
	})
	var item := {
		"id": "rule-valid-001",
		"title": "Block Force Push",
		"status": "active",
		"description": "---policy-rule---\n%s\n---end-rule---" % json_block
	}
	var rule: Dictionary = engine._compile_rule(item)
	check("valid rule compiles to non-empty dict", not rule.is_empty())
	check("rule_id matches item id", rule.get("rule_id", "") == "rule-valid-001")
	check("title matches", rule.get("title", "") == "Block Force Push")
	check("effect is 'block'", rule.get("effect", "") == "block")
	check("priority is 20", rule.get("priority", 0) == 20)
	var triggers: Array = rule.get("triggers", [])
	check("triggers array has one entry (legacy wrap)", triggers.size() == 1)
	check("trigger tool_regex compiled (non-null)", triggers.size() > 0 and triggers[0].get("tool_regex", null) != null)
	check("domain_predicates preserved", "git" in rule.get("domain_predicates", []))
	check("verb_predicates preserved", "force-push" in rule.get("verb_predicates", []))
	check("alternatives preserved", "git push" in rule.get("alternatives", []))


func test_compile_triggers_array():
	print("test_compile_triggers_array:")
	var engine := PolicyEngine.new()
	var json_block := JSON.stringify({
		"triggers": [
			{"tool_pattern": "cobrowser_navigate", "arg_predicates": {"url": "amazon"}},
			{"tool_pattern": "cobrowser_tab_new", "arg_predicates": {"url": "amazon"}},
		],
		"effect": "block",
		"priority": 100,
	})
	var item := {
		"id": "rule-multi-001",
		"title": "Multi-Trigger Block",
		"status": "active",
		"description": "---policy-rule---\n%s\n---end-rule---" % json_block,
	}
	var rule: Dictionary = engine._compile_rule(item)
	check("multi-trigger rule compiles", not rule.is_empty())
	var triggers: Array = rule.get("triggers", [])
	check("triggers array has 2 entries", triggers.size() == 2)
	check("first trigger has tool_regex", triggers[0].get("tool_regex", null) != null)
	check("second trigger has tool_regex", triggers[1].get("tool_regex", null) != null)
	check("first trigger has arg_regexes", triggers[0].get("arg_regexes", {}).has("url"))
	check("second trigger has arg_regexes", triggers[1].get("arg_regexes", {}).has("url"))


func test_compile_single_element_triggers_array():
	print("test_compile_single_element_triggers_array:")
	var engine := PolicyEngine.new()
	var json_block := JSON.stringify({
		"triggers": [
			{"tool_pattern": "minerva_bash", "arg_predicates": {"command": "git push"}},
		],
		"effect": "block",
		"priority": 10,
	})
	var item := {
		"id": "rule-single-trig-001",
		"title": "Single Element Triggers",
		"status": "active",
		"description": "---policy-rule---\n%s\n---end-rule---" % json_block,
	}
	var rule: Dictionary = engine._compile_rule(item)
	check("single-element triggers compiles", not rule.is_empty())
	var triggers: Array = rule.get("triggers", [])
	check("triggers array has 1 entry", triggers.size() == 1)
	check("trigger tool_pattern is minerva_bash", triggers[0].get("tool_pattern", "") == "minerva_bash")


# ── PolicyEngine evaluation tests ─────────────────────────────────────────────

func test_evaluate_no_rules_allows():
	print("test_evaluate_no_rules_allows:")
	var engine := PolicyEngine.new()
	# No rules loaded — reload() not called (no DocketManager in test env)
	var result := engine.evaluate("minerva_bash", {"command": "git push --force origin main"})
	check("no rules: allowed is true", result.get("allowed", false) == true)
	check("no rules: effect is 'clear'", result.get("effect", "") == "clear")


func test_evaluate_block_rule_blocks():
	print("test_evaluate_block_rule_blocks:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "block-bash-001",
		"title": "Block All Bash",
		"effect": "block",
		"tool_pattern": "minerva_bash",
	}))
	var result := engine.evaluate("minerva_bash", {"command": "echo hello"})
	check("block rule: allowed is false", result.get("allowed", true) == false)
	check("block rule: effect is 'block'", result.get("effect", "") == "block")
	check("block rule: blocked_by_rule matches", result.get("blocked_by_rule", "") == "block-bash-001")
	check("block rule: error message present", not result.get("error", "").is_empty())


func test_evaluate_observe_rule_allows_with_observations():
	print("test_evaluate_observe_rule_allows_with_observations:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "observe-bash-001",
		"title": "Observe All Bash",
		"effect": "observe",
		"tool_pattern": "minerva_bash",
	}))
	var result := engine.evaluate("minerva_bash", {"command": "echo hello"})
	check("observe rule: allowed is true", result.get("allowed", false) == true)
	var observations: Array = result.get("observations", [])
	check("observe rule: at least one observation", observations.size() >= 1)
	check("observe rule: observation has rule_id", str(observations[0].get("rule_id", "")) == "observe-bash-001")


func test_evaluate_scope_rule_activates_scope():
	print("test_evaluate_scope_rule_activates_scope:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "scope-git-001",
		"title": "Activate Git Scope",
		"effect": "scope",
		"tool_pattern": "minerva_bash",
		"activate_scope": "git-elevated",
	}))
	var result := engine.evaluate("minerva_bash", {"command": "git status"})
	check("scope rule: allowed is true", result.get("allowed", false) == true)
	# The scope_state is accessible for verification
	check("scope rule: git-elevated scope is now active", engine._scope_state.is_active("git-elevated"))


func test_evaluate_proposed_rule_always_observes():
	print("test_evaluate_proposed_rule_always_observes:")
	var engine := PolicyEngine.new()
	# A "proposed" status rule with effect=block should ONLY observe, never block
	engine._rules.append(_make_rule({
		"rule_id": "proposed-block-001",
		"title": "Proposed Block Rule",
		"status": "proposed",
		"effect": "block",
		"tool_pattern": "minerva_bash",
	}))
	var result := engine.evaluate("minerva_bash", {"command": "rm -rf /"})
	check("proposed rule: allowed is true (not blocked)", result.get("allowed", false) == true)
	var observations: Array = result.get("observations", [])
	check("proposed rule: produces an observation", observations.size() >= 1)
	check("proposed rule: observation effect is 'block' (what would have happened)", \
		str(observations[0].get("would_have_effect", "")) == "block")


func test_evaluate_session_override_skips_rule():
	print("test_evaluate_session_override_skips_rule:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "override-target-001",
		"title": "Override Target",
		"effect": "block",
		"tool_pattern": "minerva_bash",
	}))
	engine.add_session_override("override-target-001")
	var result := engine.evaluate("minerva_bash", {"command": "echo hello"})
	check("session override: allowed is true (rule skipped)", result.get("allowed", false) == true)
	# Remove override and verify block resumes
	engine.remove_session_override("override-target-001")
	var result2 := engine.evaluate("minerva_bash", {"command": "echo hello"})
	check("after removing override: allowed is false again", result2.get("allowed", true) == false)


func test_evaluate_priority_ordering():
	print("test_evaluate_priority_ordering:")
	var engine := PolicyEngine.new()
	# Higher priority rule (20) should block before lower priority observe rule (5)
	engine._rules.append(_make_rule({
		"rule_id": "low-priority-observe",
		"title": "Low Priority Observe",
		"status": "active",
		"effect": "observe",
		"tool_pattern": "minerva_bash",
		"priority": 5,
	}))
	engine._rules.append(_make_rule({
		"rule_id": "high-priority-block",
		"title": "High Priority Block",
		"status": "active",
		"effect": "block",
		"tool_pattern": "minerva_bash",
		"priority": 20,
	}))
	# Sort by priority descending (as reload() would do)
	engine._rules.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["priority"] > b["priority"]
	)
	var result := engine.evaluate("minerva_bash", {"command": "echo hello"})
	check("priority: higher priority block fires first", result.get("allowed", true) == false)
	check("priority: blocked_by_rule is the high-priority rule", \
		result.get("blocked_by_rule", "") == "high-priority-block")


func test_evaluate_domain_predicate_matching():
	print("test_evaluate_domain_predicate_matching:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "git-domain-block",
		"title": "Block Git Domain",
		"effect": "block",
		"tool_pattern": "minerva_bash",
		"domain_predicates": ["git"],
	}))
	# Git command → should be blocked
	var blocked := engine.evaluate("minerva_bash", {"command": "git status"})
	check("domain predicate: git command is blocked", blocked.get("allowed", true) == false)

	# Non-git command → should be allowed
	var allowed := engine.evaluate("minerva_bash", {"command": "echo hello"})
	check("domain predicate: non-git command is allowed", allowed.get("allowed", false) == true)


func test_evaluate_verb_predicate_matching():
	print("test_evaluate_verb_predicate_matching:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "force-push-block",
		"title": "Block Force Push Verb",
		"effect": "block",
		"tool_pattern": "minerva_bash",
		"verb_predicates": ["force-push"],
	}))
	# Force-push command → should be blocked
	var blocked := engine.evaluate("minerva_bash", {"command": "git push --force origin main"})
	check("verb predicate: force-push is blocked", blocked.get("allowed", true) == false)

	# Regular push → should be allowed (verb 'push' != 'force-push')
	var allowed := engine.evaluate("minerva_bash", {"command": "git push origin main"})
	check("verb predicate: regular git push is allowed", allowed.get("allowed", false) == true)


func test_evaluate_multi_trigger_first_trigger_matches():
	print("test_evaluate_multi_trigger_first_trigger_matches:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "multi-trig-001",
		"effect": "block",
		"triggers": [
			_compile_trigger("cobrowser_navigate", {"url": "amazon"}),
			_compile_trigger("cobrowser_tab_new", {"url": "amazon"}),
		],
	}))
	var result := engine.evaluate("cobrowser_navigate", {"url": "https://www.amazon.com"})
	check("first trigger matches: blocked", result.get("allowed", true) == false)


func test_evaluate_multi_trigger_second_trigger_matches():
	print("test_evaluate_multi_trigger_second_trigger_matches:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "multi-trig-002",
		"effect": "block",
		"triggers": [
			_compile_trigger("cobrowser_navigate", {"url": "amazon"}),
			_compile_trigger("cobrowser_tab_new", {"url": "amazon"}),
		],
	}))
	var result := engine.evaluate("cobrowser_tab_new", {"url": "https://www.amazon.com"})
	check("second trigger matches: blocked", result.get("allowed", true) == false)


func test_evaluate_multi_trigger_neither_matches():
	print("test_evaluate_multi_trigger_neither_matches:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "multi-trig-003",
		"effect": "block",
		"triggers": [
			_compile_trigger("cobrowser_navigate", {"url": "amazon"}),
			_compile_trigger("cobrowser_tab_new", {"url": "amazon"}),
		],
	}))
	var result := engine.evaluate("cobrowser_navigate", {"url": "https://www.bestbuy.com"})
	check("neither trigger matches: allowed", result.get("allowed", false) == true)


func test_evaluate_legacy_format_backward_compat():
	print("test_evaluate_legacy_format_backward_compat:")
	var engine := PolicyEngine.new()
	# Use legacy format (tool_pattern + arg_predicates at top level, no triggers array)
	engine._rules.append(_make_rule({
		"rule_id": "legacy-001",
		"effect": "block",
		"tool_pattern": "minerva_bash",
		"arg_predicates": {"command": "rm -rf"},
	}))
	var blocked := engine.evaluate("minerva_bash", {"command": "rm -rf /"})
	check("legacy format: matching call is blocked", blocked.get("allowed", true) == false)
	var allowed := engine.evaluate("minerva_bash", {"command": "ls -la"})
	check("legacy format: non-matching call is allowed", allowed.get("allowed", false) == true)


# ── Override safety test ───────────────────────────────────────────────────────

func test_scope_custom_duration():
	print("test_scope_custom_duration:")
	var engine := PolicyEngine.new()
	# Scope rule with custom max_actions=3 (expires after 3 tool calls)
	engine._rules.append(_make_rule({
		"rule_id": "scope-custom-001",
		"title": "Short-lived scope",
		"effect": "scope",
		"tool_pattern": "minerva_docket_get",
		"activate_scope": "short-scope",
		"scope_max_actions": 3,
		"scope_ttl_ms": 600000,
	}))
	# Block rule gated on scope_not_active
	engine._rules.append(_make_rule({
		"rule_id": "block-gated-001",
		"title": "Gated block",
		"effect": "block",
		"tool_pattern": "cobrowser_navigate",
		"context_predicates": {"scope_not_active": "short-scope"},
		"priority": 100,
	}))

	# Before scope: navigate should be blocked
	var r1 := engine.evaluate("cobrowser_navigate", {"url": "https://example.com"})
	check("custom scope: blocked before scope activation", r1.get("allowed", true) == false)

	# Activate scope by triggering the scope rule
	var r2 := engine.evaluate("minerva_docket_get", {"id": "some-article"})
	check("custom scope: docket_get allowed", r2.get("allowed", false) == true)
	check("custom scope: scope is now active", engine._scope_state.is_active("short-scope"))

	# Navigate should now pass (scope active, 2 actions remaining after tick+is_active)
	var r3 := engine.evaluate("cobrowser_navigate", {"url": "https://example.com"})
	check("custom scope: navigate allowed while scope active", r3.get("allowed", false) == true)

	# Consume remaining actions (scope started at 3, tick has been called 3 times now)
	engine.evaluate("cobrowser_navigate", {"url": "https://example.com"})

	# Scope should be expired — next navigate is blocked again
	var r5 := engine.evaluate("cobrowser_navigate", {"url": "https://example.com"})
	check("custom scope: blocked after scope expires (3 actions consumed)", r5.get("allowed", true) == false)


func test_scope_per_chat():
	print("test_scope_per_chat:")
	var engine := PolicyEngine.new()

	# Scope rule: reading an Amazon KB article activates "amazon-kb-read" scope.
	engine._rules.append(_make_rule({
		"rule_id": "amazon-kb-scope-001",
		"title": "Activate Amazon KB Scope",
		"effect": "scope",
		"triggers": [
			_compile_trigger("cobrowser_read", {"selector": ".*"}),
		],
		"activate_scope": "amazon-kb-read",
		"scope_max_actions": 10,
		"scope_ttl_ms": 300000,
		"priority": 50,
	}))

	# Block rule: navigating Amazon requires the scope to be active.
	engine._rules.append(_make_rule({
		"rule_id": "amazon-nav-block-001",
		"title": "Block Amazon Navigate Without KB Scope",
		"effect": "block",
		"triggers": [
			_compile_trigger("cobrowser_navigate", {"url": "amazon"}),
		],
		"context_predicates": {"scope_not_active": "amazon-kb-read"},
		"priority": 100,
	}))

	# Sort by priority descending (as reload() would do)
	engine._rules.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["priority"] > b["priority"]
	)

	# Chat A reads the KB article → activates scope for chat A only.
	var r_a_read := engine.evaluate("cobrowser_read", {"selector": "body"}, "chat-A")
	check("per-chat scope: chat A read is allowed", r_a_read.get("allowed", false) == true)
	check("per-chat scope: scope active for chat A after read", \
		engine._scope_state.is_active("amazon-kb-read:chat-A"))

	# Chat B should NOT have the scope — scope for chat A must not bleed into chat B.
	check("per-chat scope: scope NOT active for chat B", \
		not engine._scope_state.is_active("amazon-kb-read:chat-B"))

	# Chat B tries to navigate Amazon → must be BLOCKED (no scope for chat B).
	var r_b_nav := engine.evaluate("cobrowser_navigate", {"url": "https://www.amazon.com"}, "chat-B")
	check("per-chat scope: chat B navigate is blocked (scope not active for B)", \
		r_b_nav.get("allowed", true) == false)

	# Chat A tries to navigate Amazon → must be ALLOWED (scope is active for chat A).
	var r_a_nav := engine.evaluate("cobrowser_navigate", {"url": "https://www.amazon.com"}, "chat-A")
	check("per-chat scope: chat A navigate is allowed (scope active for A)", \
		r_a_nav.get("allowed", false) == true)


func test_inject_effect_allowed_with_injections():
	print("test_inject_effect_allowed_with_injections:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "inject-nav-001",
		"title": "Inject Amazon Hints",
		"effect": "inject",
		"tool_pattern": "cobrowser_navigate",
		"knowledge_ref": "kb-article-001",
		"activate_scope": null,
	}))
	var result := engine.evaluate("cobrowser_navigate", {"url": "https://www.amazon.com"})
	check("inject: allowed is true", result.get("allowed", false) == true)
	check("inject: effect is 'inject'", result.get("effect", "") == "inject")
	var injections: Array = result.get("injections", [])
	check("inject: injections array has 1 entry", injections.size() == 1)
	check("inject: injection has correct rule_id", str(injections[0].get("rule_id", "")) == "inject-nav-001")
	check("inject: injection has knowledge_ref", str(injections[0].get("knowledge_ref", "")) == "kb-article-001")


func test_inject_with_scope_prevents_reinjection():
	print("test_inject_with_scope_prevents_reinjection:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "inject-scope-001",
		"title": "Inject With Scope",
		"effect": "inject",
		"tool_pattern": "cobrowser_navigate",
		"knowledge_ref": "kb-article-002",
		"activate_scope": "amazon-injected",
		"scope_max_actions": 50,
		"scope_ttl_ms": 300000,
		"context_predicates": {"scope_not_active": "amazon-injected"},
	}))
	# First call: inject fires, scope activates
	var r1 := engine.evaluate("cobrowser_navigate", {"url": "https://www.amazon.com"})
	check("inject+scope: first call has injections", r1.get("injections", []).size() == 1)
	check("inject+scope: scope activated", engine._scope_state.is_active("amazon-injected"))
	# Second call: scope active, inject rule skipped via context_predicate
	var r2 := engine.evaluate("cobrowser_navigate", {"url": "https://www.amazon.com/dp/123"})
	check("inject+scope: second call has no injections", r2.get("injections", []).size() == 0)
	check("inject+scope: second call still allowed", r2.get("allowed", false) == true)


func test_inject_proposed_downgrades_to_observe():
	print("test_inject_proposed_downgrades_to_observe:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "inject-proposed-001",
		"title": "Proposed Inject Rule",
		"status": "proposed",
		"effect": "inject",
		"tool_pattern": "cobrowser_navigate",
		"knowledge_ref": "kb-article-003",
	}))
	var result := engine.evaluate("cobrowser_navigate", {"url": "https://www.amazon.com"})
	check("proposed inject: allowed is true", result.get("allowed", false) == true)
	check("proposed inject: no injections (downgraded to observe)", result.get("injections", []).size() == 0)
	var observations: Array = result.get("observations", [])
	check("proposed inject: has observation", observations.size() >= 1)
	check("proposed inject: observation records inject as would_have_effect", \
		str(observations[0].get("would_have_effect", "")) == "inject")


func test_inject_multiple_rules_collect_all():
	print("test_inject_multiple_rules_collect_all:")
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "inject-multi-001",
		"title": "Inject Rule A",
		"effect": "inject",
		"tool_pattern": "cobrowser_navigate",
		"knowledge_ref": "kb-a",
		"priority": 10,
	}))
	engine._rules.append(_make_rule({
		"rule_id": "inject-multi-002",
		"title": "Inject Rule B",
		"effect": "inject",
		"tool_pattern": "cobrowser_navigate",
		"knowledge_ref": "kb-b",
		"priority": 5,
	}))
	engine._rules.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["priority"] > b["priority"]
	)
	var result := engine.evaluate("cobrowser_navigate", {"url": "https://example.com"})
	check("multi inject: allowed is true", result.get("allowed", false) == true)
	var injections: Array = result.get("injections", [])
	check("multi inject: 2 injections collected", injections.size() == 2)
	check("multi inject: first is higher priority rule", str(injections[0].get("rule_id", "")) == "inject-multi-001")
	check("multi inject: second is lower priority rule", str(injections[1].get("rule_id", "")) == "inject-multi-002")


func test_inject_plus_block_block_wins():
	print("test_inject_plus_block_block_wins:")
	var engine := PolicyEngine.new()
	# Block rule at higher priority
	engine._rules.append(_make_rule({
		"rule_id": "block-nav-001",
		"title": "Block Navigate",
		"effect": "block",
		"tool_pattern": "cobrowser_navigate",
		"priority": 100,
	}))
	# Inject rule at lower priority
	engine._rules.append(_make_rule({
		"rule_id": "inject-nav-002",
		"title": "Inject Hints",
		"effect": "inject",
		"tool_pattern": "cobrowser_navigate",
		"knowledge_ref": "kb-hints",
		"priority": 50,
	}))
	engine._rules.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["priority"] > b["priority"]
	)
	var result := engine.evaluate("cobrowser_navigate", {"url": "https://example.com"})
	check("block+inject: block wins (allowed is false)", result.get("allowed", true) == false)
	check("block+inject: no injections in blocked response", result.get("injections", []).size() == 0)


func test_agent_cannot_self_override_note():
	print("test_agent_cannot_self_override_note:")
	# This is a validation step that requires MinervaMCPServer integration.
	# The check: MinervaMCPServer.handle_tool_call() must gate add_session_override
	# behind a provenance check so that an agent-originated call to a hypothetical
	# "policy_override" tool (provenance="agent") is rejected before reaching
	# engine.add_session_override().
	#
	# In unit isolation we verify the engine's override mechanism works correctly
	# by confirming that calling add_session_override() does bypass the rule (as
	# intended for legitimate human overrides), which confirms the mechanism is
	# present and gating must be enforced at the MCP dispatch layer.
	var engine := PolicyEngine.new()
	engine._rules.append(_make_rule({
		"rule_id": "sensitive-rule-001",
		"effect": "block",
		"tool_pattern": "minerva_bash",
	}))
	# Without override: blocked
	var blocked := engine.evaluate("minerva_bash", {"command": "echo hello"})
	check("self-override safety: rule blocks without override", blocked.get("allowed", true) == false)
	# With override: bypassed — this is the privileged path that must be human-gated
	engine.add_session_override("sensitive-rule-001")
	var bypassed := engine.evaluate("minerva_bash", {"command": "echo hello"})
	check("self-override safety: override mechanism works (must be human-gated at MCP layer)", \
		bypassed.get("allowed", false) == true)
	print("  NOTE: Full self-override protection requires MinervaMCPServer to reject")
	print("        agent-originated policy_override calls (provenance check at dispatch).")
