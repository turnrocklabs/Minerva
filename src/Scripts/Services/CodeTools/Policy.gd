## Policy enforcement for CodeTools.
##
## Policy is loaded from ~/.codetools/policy.json and is immutable after load.
## This prevents LLMs from modifying policy during operation.
##
## Usage:
##   var policy := CodeToolsPolicy.get_instance()
##   var err := policy.check_bash_command("rm -rf /")
##   if err != "":
##       print("Denied: ", err)
class_name CodeToolsPolicy extends RefCounted

# ---------------------------------------------------------------------------
# Singleton
# ---------------------------------------------------------------------------

static var _instance: RefCounted = null

## Returns the global singleton, loading from disk on first call.
## The returned object is a CodeToolsPolicy instance.
static func get_instance() -> RefCounted:
	if _instance == null:
		# Instantiate via load() so this works regardless of whether
		# the class_name is globally registered.
		var script: GDScript = load("res://Scripts/Services/CodeTools/Policy.gd")
		_instance = script.new()
		_instance._load_policy()
	return _instance

## Reset the singleton. Used for testing.
static func reset_instance() -> void:
	_instance = null

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const POLICY_FILE_PATH: String = "~/.codetools/policy.json"

## Hardcoded baseline patterns that are ALWAYS denied.
## These protect the policy system itself from LLM modification.
const BASELINE_DENY_PATTERNS: Array[String] = [
	r"\.codetools/policy\.json",
	r"\.codetools/policy",
]

# ---------------------------------------------------------------------------
# State (frozen after _load_policy)
# ---------------------------------------------------------------------------

## User-configured deny patterns loaded from policy.json.
var bash_deny_patterns: Array[String] = []

# Compiled baseline regexes — built once at load time.
var _baseline_regexes: Array[RegEx] = []
# Compiled user deny regexes — built once at load time; invalid ones skipped.
var _deny_regexes: Array[RegEx] = []

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

## Load policy from the default location. Called exactly once by get_instance().
func _load_policy(policy_path: String = "") -> void:
	if policy_path.is_empty():
		policy_path = POLICY_FILE_PATH

	# Compile baseline patterns (always present, never fail on init).
	for raw in BASELINE_DENY_PATTERNS:
		var rx := RegEx.new()
		if rx.compile(raw) == OK:
			_baseline_regexes.append(rx)

	# Resolve ~ to the real home directory.
	var expanded_path: String = policy_path
	if expanded_path.begins_with("~"):
		expanded_path = OS.get_environment("HOME") + expanded_path.substr(1)

	if not FileAccess.file_exists(expanded_path):
		# Missing file → empty policy (allow all).
		return

	var file := FileAccess.open(expanded_path, FileAccess.READ)
	if file == null:
		# Unreadable file → empty policy.
		return

	var raw_text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(raw_text)
	if parsed == null or not parsed is Dictionary:
		# Invalid JSON → empty policy.
		return

	var data: Dictionary = parsed
	var bash_config: Variant = data.get("bash", {})
	if not bash_config is Dictionary:
		return

	var deny_list: Variant = (bash_config as Dictionary).get("deny", [])
	if not deny_list is Array:
		return

	for entry in deny_list:
		if not entry is String:
			continue
		bash_deny_patterns.append(entry)
		var rx := RegEx.new()
		if rx.compile(entry) == OK:
			_deny_regexes.append(rx)
		# Invalid regex → silently skipped (mirrors Python behaviour).

# ---------------------------------------------------------------------------
# Policy check
# ---------------------------------------------------------------------------

## Check whether a bash command is allowed by policy.
##
## Returns an empty String if the command is allowed.
## Returns a non-empty error message if the command is denied.
func check_bash_command(command: String) -> String:
	# Baseline patterns are checked first and are always enforced.
	for rx in _baseline_regexes:
		if rx.search(command) != null:
			return (
				"Command not allowed by policy. Ask user to perform the action. "
				+ "(Protected system path)"
			)

	# User-configured deny patterns.
	for i in range(_deny_regexes.size()):
		var rx: RegEx = _deny_regexes[i]
		if rx.search(command) != null:
			var pattern: String = bash_deny_patterns[i] if i < bash_deny_patterns.size() else "?"
			return (
				"Command not allowed by policy. Ask user to perform the action. "
				+ "(Pattern matched: %s)" % pattern
			)

	return ""
