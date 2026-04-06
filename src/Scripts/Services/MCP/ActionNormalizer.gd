class_name ActionNormalizer
extends RefCounted
## Extracts deterministic action facts from MCP tool calls.
## All regex patterns are pre-compiled in _init() for performance.
## Returns a consistent Dictionary shape regardless of tool type.

# ── Pre-compiled domain patterns ──────────────────────────────────────────────

var _re_domain_git: RegEx
var _re_domain_docker: RegEx
var _re_domain_npm: RegEx
var _re_domain_deploy: RegEx
var _re_domain_python: RegEx

# ── Pre-compiled verb patterns ─────────────────────────────────────────────────

var _re_verb_push: RegEx
var _re_verb_force_push: RegEx
var _re_verb_delete: RegEx
var _re_verb_delete_recursive: RegEx
var _re_verb_reset_hard: RegEx
var _re_verb_checkout_force: RegEx
var _re_verb_drop: RegEx

# ── Pre-compiled flag patterns ─────────────────────────────────────────────────

var _re_flag_force: RegEx
var _re_flag_no_verify: RegEx
var _re_flag_hard: RegEx
var _re_flag_recursive: RegEx


func _init() -> void:
	# Domains
	_re_domain_git = _compile(r"\bgit\b")
	_re_domain_docker = _compile(r"\b(docker|docker-compose|podman)\b")
	_re_domain_npm = _compile(r"\b(npm|yarn|pnpm|bun)\b")
	_re_domain_deploy = _compile(r"\b(deploy|kubectl|terraform|helm)\b")
	_re_domain_python = _compile(r"\b(python|pip|python3|pip3)\b")

	# Verbs
	_re_verb_push = _compile(r"\bgit\s+push\b")
	_re_verb_force_push = _compile(r"\bgit\s+push\s+.*--force")
	_re_verb_delete = _compile(r"\b(rm|del|rmdir)\b")
	_re_verb_delete_recursive = _compile(r"\brm\s+.*-r")
	_re_verb_reset_hard = _compile(r"\bgit\s+reset\s+--hard\b")
	_re_verb_checkout_force = _compile(r"\bgit\s+checkout\s+.*--force")
	_re_verb_drop = _compile(r"(?i)\bDROP\s+(TABLE|DATABASE)\b")

	# Flags
	_re_flag_force = _compile(r"--force\b")
	_re_flag_no_verify = _compile(r"--no-verify\b")
	_re_flag_hard = _compile(r"--hard\b")
	_re_flag_recursive = _compile(r"\s-r\b|\s-rf\b|--recursive\b")


## Normalize a tool call into a deterministic facts dictionary.
## Returns: {"tool": String, "domains": Array[String], "verbs": Array[String],
##           "flags": Array[String], "paths": Array[String]}
func normalize(tool_name: String, arguments: Dictionary) -> Dictionary:
	var facts: Dictionary = _empty_facts(tool_name)

	if tool_name == "minerva_bash":
		_normalize_bash(arguments.get("command", ""), facts)
	elif tool_name.begins_with("minerva_file_"):
		_normalize_file(arguments, facts)
	elif tool_name == "docket_transition" \
			or tool_name.begins_with("minerva_docket_") \
			or tool_name.begins_with("docket_"):
		_add_domain(facts, "docket")

	return facts


# ── Private helpers ────────────────────────────────────────────────────────────

func _normalize_bash(command: String, facts: Dictionary) -> void:
	# Domains
	if _re_domain_git.search(command):
		_add_domain(facts, "git")
	if _re_domain_docker.search(command):
		_add_domain(facts, "docker")
	if _re_domain_npm.search(command):
		_add_domain(facts, "npm")
	if _re_domain_deploy.search(command):
		_add_domain(facts, "deploy")
	if _re_domain_python.search(command):
		_add_domain(facts, "python")

	# Verbs — order matters: check more-specific patterns before less-specific
	if _re_verb_force_push.search(command):
		_add_verb(facts, "force-push")
	elif _re_verb_push.search(command):
		_add_verb(facts, "push")
	if _re_verb_delete_recursive.search(command):
		_add_verb(facts, "delete-recursive")
	elif _re_verb_delete.search(command):
		_add_verb(facts, "delete")
	if _re_verb_reset_hard.search(command):
		_add_verb(facts, "reset-hard")
	if _re_verb_checkout_force.search(command):
		_add_verb(facts, "checkout-force")
	if _re_verb_drop.search(command):
		_add_verb(facts, "drop")

	# Flags
	if _re_flag_force.search(command):
		_add_flag(facts, "force")
	if _re_flag_no_verify.search(command):
		_add_flag(facts, "no-verify")
	if _re_flag_hard.search(command):
		_add_flag(facts, "hard")
	if _re_flag_recursive.search(command):
		_add_flag(facts, "recursive")


func _normalize_file(arguments: Dictionary, facts: Dictionary) -> void:
	_add_domain(facts, "filesystem")
	var path: String = arguments.get("path", "")
	if not path.is_empty():
		facts["paths"].append(path)


func _empty_facts(tool_name: String) -> Dictionary:
	return {
		"tool": tool_name,
		"domains": [] as Array[String],
		"verbs": [] as Array[String],
		"flags": [] as Array[String],
		"paths": [] as Array[String],
	}


func _add_domain(facts: Dictionary, domain: String) -> void:
	var arr: Array[String] = facts["domains"]
	if domain not in arr:
		arr.append(domain)


func _add_verb(facts: Dictionary, verb: String) -> void:
	var arr: Array[String] = facts["verbs"]
	if verb not in arr:
		arr.append(verb)


func _add_flag(facts: Dictionary, flag: String) -> void:
	var arr: Array[String] = facts["flags"]
	if flag not in arr:
		arr.append(flag)


func _compile(pattern: String) -> RegEx:
	var re := RegEx.new()
	re.compile(pattern)
	return re
