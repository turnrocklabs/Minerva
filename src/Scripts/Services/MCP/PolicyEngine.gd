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
## caller_id: chat ID for per-chat scope isolation. Empty string = global scope (backward compat).
func evaluate(tool_name: String, arguments: Dictionary, caller_id: String = "") -> Dictionary:
	# Get normalized action facts.
	var facts: Dictionary = _normalizer.normalize(tool_name, arguments)

	# Age all scopes.
	_scope_state.tick()

	var matched_rule_ids: Array[String] = []
	var observations: Array[Dictionary] = []
	var injections: Array[Dictionary] = []

	for rule in _rules:
		var rule_id: String = rule["rule_id"]

		# Skip overridden rules.
		if _session_overrides.has(rule_id):
			continue

		# Skip rules that do not match this call.
		if not _matches(rule, tool_name, arguments, facts, caller_id):
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
				var scope_name: String = rule["activate_scope"] if rule["activate_scope"] != null else rule_id
				var scoped_key: String = _make_scope_key(scope_name, caller_id)
				_scope_state.activate(scoped_key, rule["scope_max_actions"], rule["scope_ttl_ms"])
				_record_observation(rule, tool_name, facts, "scope")

			"inject":
				if not rule["knowledge_ref"].is_empty():
					injections.append({
						"rule_id": rule_id,
						"knowledge_ref": rule["knowledge_ref"],
						"title": rule["title"],
					})
				# Optionally activate scope to prevent re-injection
				if rule["activate_scope"] != null:
					var inject_scope: String = rule["activate_scope"]
					var inject_key: String = _make_scope_key(inject_scope, caller_id)
					_scope_state.activate(inject_key, rule["scope_max_actions"], rule["scope_ttl_ms"])
				_record_observation(rule, tool_name, facts, "inject")

			"observe":
				_record_observation(rule, tool_name, facts, rule["effect"])

	# Drain pending observations into this response.
	var pending := _observation_log.duplicate()
	_observation_log.clear()

	var result := {
		"allowed": true,
		"effect": "clear",
		"matched_rules": matched_rule_ids,
		"observations": pending,
	}
	if not injections.is_empty():
		result["injections"] = injections
		result["effect"] = "inject"
	return result


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
	# "tool_pattern" OR "triggers" must be present; "effect" and "priority" are always required.
	for required_key in ["effect", "priority"]:
		if not data.has(required_key):
			push_warning(
				"PolicyEngine: item '%s' ('%s') missing required field '%s'; skipping."
				% [rule_id, title, required_key]
			)
			return {}
	if not data.has("tool_pattern") and not data.has("triggers"):
		push_warning(
			"PolicyEngine: item '%s' ('%s') missing required field 'tool_pattern' (or 'triggers'); skipping."
			% [rule_id, title]
		)
		return {}

	# Build a normalized triggers list. Each entry has "tool_pattern" and "arg_predicates".
	# If a "triggers" array is provided use it directly; otherwise wrap the legacy fields.
	var raw_triggers: Array = []
	if data.has("triggers") and data["triggers"] is Array:
		raw_triggers = data["triggers"]
	else:
		# Legacy single-trigger format — wrap into a one-element array.
		raw_triggers = [{
			"tool_pattern": data.get("tool_pattern", ""),
			"arg_predicates": data.get("arg_predicates", {}),
		}]

	# Compile each trigger into its own tool_regex + arg_regexes.
	var compiled_triggers: Array = []
	for trigger_data in raw_triggers:
		if not trigger_data is Dictionary:
			push_warning(
				"PolicyEngine: item '%s' ('%s') has a non-dict trigger entry; skipping rule."
				% [rule_id, title]
			)
			return {}

		var tool_pattern: String = str(trigger_data.get("tool_pattern", ""))
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

		var raw_arg_predicates = trigger_data.get("arg_predicates", {})
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

		compiled_triggers.append({
			"tool_pattern": tool_pattern,
			"tool_regex": tool_regex,
			"arg_predicates": arg_predicates,
			"arg_regexes": arg_regexes,
		})

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
		"triggers": compiled_triggers,
		"context_predicates": context_preds,
		"domain_predicates": domain_predicates,
		"verb_predicates": verb_predicates,
		"flag_predicates": flag_predicates,
		"activate_scope": data.get("activate_scope", null),
		"scope_max_actions": int(data.get("scope_max_actions", 10)),
		"scope_ttl_ms": int(data.get("scope_ttl_ms", 2147483647)),
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
## Trigger matching uses OR semantics (any trigger fires the rule).
## Domain/verb/flag/context predicates are shared and use AND semantics.
func _matches(rule: Dictionary, tool_name: String, arguments: Dictionary, facts: Dictionary, caller_id: String = "") -> bool:
	# At least one trigger must match (OR semantics across triggers).
	var triggers: Array = rule.get("triggers", [])
	var any_trigger_matched := false
	for trigger in triggers:
		if _trigger_matches(trigger, tool_name, arguments):
			any_trigger_matched = true
			break
	if not any_trigger_matched:
		return false

	# Fact predicates: check normalized domains, verbs, and flags.
	# Each predicate value must be present in the corresponding facts array (AND semantics).
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
			var scoped_key: String = _make_scope_key(scope_name, caller_id)
			if not _scope_state.is_active(scoped_key):
				return false
		elif pred_key == "scope_not_active":
			var scope_name: String = str(context_preds[pred_key])
			var scoped_key: String = _make_scope_key(scope_name, caller_id)
			if _scope_state.is_active(scoped_key):
				return false

	return true


## Return true if a single compiled trigger matches the given tool call.
## tool_pattern: empty string = match everything.
## arg_predicates: each arg value (as string) must match its regex (AND semantics).
func _trigger_matches(trigger: Dictionary, tool_name: String, arguments: Dictionary) -> bool:
	var tool_pattern: String = trigger.get("tool_pattern", "")
	if not tool_pattern.is_empty():
		var tool_regex: RegEx = trigger.get("tool_regex", null)
		if tool_regex == null:
			return false
		if not tool_regex.search(tool_name):
			return false

	var arg_regexes: Dictionary = trigger.get("arg_regexes", {})
	for arg_name in arg_regexes.keys():
		var re: RegEx = arg_regexes[arg_name]
		var arg_value: String = str(arguments.get(arg_name, ""))
		if not re.search(arg_value):
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

## Build a scope key that is unique per caller (chat).
## If caller_id is empty, falls back to a global scope for backwards compat.
func _make_scope_key(scope_name: String, caller_id: String) -> String:
	if caller_id.is_empty():
		return scope_name
	return scope_name + ":" + caller_id


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
