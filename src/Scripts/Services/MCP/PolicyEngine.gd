class_name PolicyEngine
extends RefCounted
## Loads, compiles, and evaluates policy rules from the Docket.
##
## Usage:
##   var engine := PolicyEngine.new()
##   engine.reload()                         # fetch rules from Docket
##   var result := engine.evaluate("minerva_bash", {"command": "git push --force"})
##   if not result["allowed"]:
##       print(result["error"])

# ── Dependencies ───────────────────────────────────────────────────────────────

var _normalizer: ActionNormalizer
var _scope_state: RiskScopeState

# ── State ──────────────────────────────────────────────────────────────────────

## Compiled rules sorted by priority descending.
var _rules: Array[Dictionary] = []

## Rule IDs bypassed for the current session.
var _session_overrides: Dictionary = {}   # rule_id -> true

## In-memory observation buffer drained by the telemetry layer.
var _observation_log: Array[Dictionary] = []


func _init() -> void:
	_normalizer = ActionNormalizer.new()
	_scope_state = RiskScopeState.new()


# ── Public API ─────────────────────────────────────────────────────────────────

## Clear and recompile all rules from Docket.
## Silently results in zero rules if docket_manager is null.
func reload() -> void:
	_rules.clear()

	var dm = _get_docket_manager()
	if dm == null:
		return

	# Query proposed and active policy items separately
	# (flat dict filter doesn't support __in suffix)
	var compiled: Array[Dictionary] = []
	for status in ["proposed", "active"]:
		var result: Dictionary = dm.call_tool(
			"docket_query",
			{"filter": {"type": "policy", "status": status}}
		)
		var items = result.get("items", [])
		if not items is Array:
			continue
		for item in items:
			if not item is Dictionary:
				continue
			var rule: Dictionary = _compile_rule(item)
			if not rule.is_empty():
				compiled.append(rule)

	# Sort by priority descending (higher priority = evaluated first).
	compiled.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["priority"] > b["priority"]
	)
	_rules = compiled


## Evaluate a tool call against all loaded rules.
## Returns an allowed or blocked response Dictionary.
func evaluate(tool_name: String, arguments: Dictionary) -> Dictionary:
	# Get normalized action facts.
	var facts: Dictionary = _normalizer.normalize(tool_name, arguments)

	# Age all scopes.
	_scope_state.tick()

	var matched_rule_ids: Array[String] = []
	var observations: Array[Dictionary] = []

	for rule in _rules:
		var rule_id: String = rule["rule_id"]

		# Skip overridden rules.
		if _session_overrides.has(rule_id):
			continue

		# Skip rules that do not match this call.
		if not _matches(rule, tool_name, arguments, facts):
			continue

		# Proposed items are observation-only regardless of their effect field.
		var effective_effect: String = rule["effect"]
		if rule["status"] == "proposed":
			effective_effect = "observe"

		matched_rule_ids.append(rule_id)

		match effective_effect:
			"block":
				return {
					"allowed": false,
					"effect": "block",
					"blocked_by_rule": rule_id,
					"reason": rule["title"],
					"knowledge_ref": rule["knowledge_ref"],
					"allowed_next_actions": rule["alternatives"].duplicate(),
					"success": false,
					"error": "Blocked by policy: %s" % rule["title"],
				}

			"scope":
				_scope_state.activate(rule["activate_scope"] if rule["activate_scope"] != null else rule_id)
				_record_observation(rule, tool_name, facts, "scope")

			"observe":
				_record_observation(rule, tool_name, facts, rule["effect"])

	# Drain pending observations into this response.
	var pending := _observation_log.duplicate()
	_observation_log.clear()

	return {
		"allowed": true,
		"effect": "clear",
		"matched_rules": matched_rule_ids,
		"observations": pending,
	}


## Return the number of currently compiled rules.
func rule_count() -> int:
	return _rules.size()


## Bypass a rule for the lifetime of this session.
func add_session_override(rule_id: String) -> void:
	_session_overrides[rule_id] = true


## Remove a previously added session override.
func remove_session_override(rule_id: String) -> void:
	_session_overrides.erase(rule_id)


## Return a copy of currently active session override rule IDs.
func get_session_overrides() -> Array[String]:
	var out: Array[String] = []
	for key in _session_overrides.keys():
		out.append(key as String)
	return out


## Return and clear the pending observation log.
## The telemetry layer calls this to drain buffered observations.
func get_observation_log() -> Array[Dictionary]:
	var copy := _observation_log.duplicate()
	_observation_log.clear()
	return copy


# ── Private: Rule compilation ──────────────────────────────────────────────────

## Parse one Docket item into a compiled rule Dictionary.
## Returns an empty Dictionary on failure (rule is skipped).
func _compile_rule(item: Dictionary) -> Dictionary:
	var rule_id: String = str(item.get("id", ""))
	var title: String = str(item.get("title", ""))
	var status: String = str(item.get("status", ""))
	var description: String = str(item.get("description", ""))

	# Extract fenced JSON block.
	var json_text: String = _extract_fenced_json(description)
	if json_text.is_empty():
		push_warning("PolicyEngine: item '%s' ('%s') has no ---policy-rule--- block; skipping." % [rule_id, title])
		return {}

	var parsed = JSON.parse_string(json_text)
	if parsed == null or not parsed is Dictionary:
		push_warning("PolicyEngine: item '%s' ('%s') has invalid JSON in rule block; skipping." % [rule_id, title])
		return {}

	var data: Dictionary = parsed

	# Validate required fields.
	for required_key in ["tool_pattern", "effect", "priority"]:
		if not data.has(required_key):
			push_warning(
				"PolicyEngine: item '%s' ('%s') missing required field '%s'; skipping."
				% [rule_id, title, required_key]
			)
			return {}

	# Compile tool pattern regex.
	var tool_pattern: String = str(data.get("tool_pattern", ""))
	var tool_regex: RegEx = null
	if not tool_pattern.is_empty():
		var re := RegEx.new()
		var err := re.compile(tool_pattern)
		if err != OK:
			push_warning(
				"PolicyEngine: item '%s' ('%s') has invalid tool_pattern regex '%s'; skipping."
				% [rule_id, title, tool_pattern]
			)
			return {}
		tool_regex = re

	# Compile argument predicate regexes.
	var raw_arg_predicates = data.get("arg_predicates", {})
	var arg_predicates: Dictionary = {}
	var arg_regexes: Dictionary = {}
	if raw_arg_predicates is Dictionary:
		for arg_name in raw_arg_predicates.keys():
			var pattern: String = str(raw_arg_predicates[arg_name])
			arg_predicates[arg_name] = pattern
			var re := RegEx.new()
			var err := re.compile(pattern)
			if err != OK:
				push_warning(
					"PolicyEngine: item '%s' ('%s') has invalid arg_predicate regex for '%s'; skipping."
					% [rule_id, title, arg_name]
				)
				return {}
			arg_regexes[arg_name] = re

	var context_preds = data.get("context_predicates", {})
	if not context_preds is Dictionary:
		context_preds = {}

	# Fact predicates: match against normalized action facts (domains, verbs, flags).
	# Each is an Array[String] of values that must ALL be present in the normalized facts.
	var domain_predicates: Array = _coerce_array(data.get("domain_predicates", []))
	var verb_predicates: Array = _coerce_array(data.get("verb_predicates", []))
	var flag_predicates: Array = _coerce_array(data.get("flag_predicates", []))

	return {
		"rule_id": rule_id,
		"title": title,
		"status": status,
		"effect": str(data.get("effect", "observe")),
		"tool_pattern": tool_pattern,
		"tool_regex": tool_regex,
		"arg_predicates": arg_predicates,
		"arg_regexes": arg_regexes,
		"context_predicates": context_preds,
		"domain_predicates": domain_predicates,
		"verb_predicates": verb_predicates,
		"flag_predicates": flag_predicates,
		"activate_scope": data.get("activate_scope", null),
		"priority": int(data.get("priority", 0)),
		"provenance": str(data.get("provenance", "user")),
		"knowledge_ref": str(data.get("knowledge_ref", "")),
		"alternatives": _coerce_array(data.get("alternatives", [])),
		"cooldown": data.get("cooldown", null),
	}


## Extract the text between ---policy-rule--- and ---end-rule--- markers.
## Returns an empty string if the markers are not found.
func _extract_fenced_json(description: String) -> String:
	var start_marker := "---policy-rule---"
	var end_marker := "---end-rule---"

	var start_idx := description.find(start_marker)
	if start_idx == -1:
		return ""

	var content_start := start_idx + start_marker.length()
	var end_idx := description.find(end_marker, content_start)
	if end_idx == -1:
		return ""

	return description.substr(content_start, end_idx - content_start).strip_edges()


# ── Private: Matching ──────────────────────────────────────────────────────────

## Return true if the rule matches the given tool call.
## All sub-checks must pass (AND semantics).
func _matches(rule: Dictionary, tool_name: String, arguments: Dictionary, facts: Dictionary) -> bool:
	# Tool pattern: empty string = match everything.
	var tool_pattern: String = rule["tool_pattern"]
	if not tool_pattern.is_empty():
		var tool_regex: RegEx = rule["tool_regex"]
		if tool_regex == null:
			return false
		if not tool_regex.search(tool_name):
			return false

	# Argument predicates: each arg value (as string) must match its regex.
	var arg_regexes: Dictionary = rule["arg_regexes"]
	for arg_name in arg_regexes.keys():
		var re: RegEx = arg_regexes[arg_name]
		var arg_value: String = str(arguments.get(arg_name, ""))
		if not re.search(arg_value):
			return false

	# Fact predicates: check normalized domains, verbs, and flags.
	# Each predicate value must be present in the corresponding facts array.
	var fact_domains: Array = facts.get("domains", [])
	for required_domain in rule["domain_predicates"]:
		if str(required_domain) not in fact_domains:
			return false

	var fact_verbs: Array = facts.get("verbs", [])
	for required_verb in rule["verb_predicates"]:
		if str(required_verb) not in fact_verbs:
			return false

	var fact_flags: Array = facts.get("flags", [])
	for required_flag in rule["flag_predicates"]:
		if str(required_flag) not in fact_flags:
			return false

	# Context predicates.
	var context_preds: Dictionary = rule["context_predicates"]
	for pred_key in context_preds.keys():
		if pred_key == "scope_active":
			var scope_name: String = str(context_preds[pred_key])
			if not _scope_state.is_active(scope_name):
				return false
		elif pred_key == "scope_not_active":
			var scope_name: String = str(context_preds[pred_key])
			if _scope_state.is_active(scope_name):
				return false

	return true


# ── Private: Observation recording ────────────────────────────────────────────

func _record_observation(
	rule: Dictionary,
	tool_name: String,
	facts: Dictionary,
	would_have_effect: String
) -> void:
	_observation_log.append({
		"rule_id": rule["rule_id"],
		"tool_name": tool_name,
		"facts": facts.duplicate(true),
		"timestamp": Time.get_ticks_msec(),
		"would_have_effect": would_have_effect,
	})


# ── Private: Helpers ───────────────────────────────────────────────────────────

func _get_docket_manager() -> Variant:
	var root := Engine.get_main_loop()
	if root == null or not root is SceneTree:
		return null
	var singleton_node = (root as SceneTree).root.get_node_or_null("/root/SingletonObject")
	if singleton_node == null:
		return null
	var dm = singleton_node.get("docket_manager")
	if dm == null:
		return null
	return dm


## Coerce a value to a plain Array, returning an empty Array on failure.
func _coerce_array(value: Variant) -> Array:
	if value is Array:
		return value
	return []
