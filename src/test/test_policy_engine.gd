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
func _make_rule(overrides: Dictionary = {}) -> Dictionary:
	var base := {
		"rule_id": "test-rule-001",
		"title": "Test Rule",
		"status": "active",
		"effect": "block",
		"tool_pattern": "minerva_bash",
		"tool_regex": null,
		"arg_predicates": {},
		"arg_regexes": {},
		"context_predicates": {},
		"domain_predicates": [],
		"verb_predicates": [],
		"flag_predicates": [],
		"activate_scope": null,
		"priority": 10,
		"provenance": "user",
		"knowledge_ref": "",
		"alternatives": [],
		"cooldown": null,
	}
	base.merge(overrides, true)

	# Compile tool regex from tool_pattern if present
	var pattern: String = str(base.get("tool_pattern", ""))
	if not pattern.is_empty():
		var re := RegEx.new()
		re.compile(pattern)
		base["tool_regex"] = re

	# Compile arg regexes from arg_predicates
	var arg_regexes: Dictionary = {}
	var arg_preds: Dictionary = base.get("arg_predicates", {})
	for key in arg_preds:
		var re := RegEx.new()
		re.compile(str(arg_preds[key]))
		arg_regexes[key] = re
	base["arg_regexes"] = arg_regexes

	return base


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
	check("tool_regex compiled (non-null)", rule.get("tool_regex", null) != null)
	check("domain_predicates preserved", "git" in rule.get("domain_predicates", []))
	check("verb_predicates preserved", "force-push" in rule.get("verb_predicates", []))
	check("alternatives preserved", "git push" in rule.get("alternatives", []))


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


# ── Override safety test ───────────────────────────────────────────────────────

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
