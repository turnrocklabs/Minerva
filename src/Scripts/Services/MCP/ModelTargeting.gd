class_name ModelTargeting
extends RefCounted
## Parses model-targeting expressions and filters docket items by model identity.
## Used to surface model-specific hints, insights, and prompts during skill injection.
##
## Target grammar:  {family}[:{version_spec}][@{provider}]
##   family:       "all", "sonnet", "opus", "haiku", "gpt", "gemini-flash", etc.
##   version_spec: "4.6", "<=4.6", ">=5.0", "4.5-4.6" (optional)
##   provider:     "anthropic", "openrouter", "local", etc. (optional)
## Multiple targets: comma-separated, OR logic: "sonnet:<=4.6, haiku"

# --- Family detection patterns (prefix match, checked in order) ---
const _FAMILY_PATTERNS: Array[Array] = [
	["haiku", ["claude-haiku", "haiku"]],
	["sonnet", ["claude-sonnet", "sonnet"]],
	["opus", ["claude-opus", "opus"]],
	["gpt-nano", ["gpt-5-nano", "gpt-nano"]],
	["gpt", ["gpt-5", "gpt-4", "gpt-"]],
	["gemini-flash", ["gemini-3-flash", "gemini-flash"]],
	["gemini-pro", ["gemini-3-pro", "gemini-pro"]],
	["chatgpt", ["chatgpt"]],
	["nemotron", ["nemotron"]],
	["devstral", ["devstral"]],
]

# --- Provider enum to string ---
static var _provider_map: Dictionary = {}

static func _get_provider_map() -> Dictionary:
	if _provider_map.is_empty():
		_provider_map = {
			0: "google",
			1: "openai",
			2: "anthropic",
			3: "local",
			4: "turnrock",
			5: "openrouter",
			6: "claude-code",
			7: "chatgpt",
		}
	return _provider_map


## Extract model identity from a BaseProvider.
## Returns {"family": "sonnet", "version": "4.5", "provider": "anthropic", "raw_model": "claude-sonnet-4.5"}
static func identify(provider: BaseProvider) -> Dictionary:
	var model: String = provider.model_name.to_lower().strip_edges()
	var family := ""
	for pattern in _FAMILY_PATTERNS:
		for prefix in pattern[1]:
			if model.begins_with(prefix):
				family = pattern[0]
				break
		if not family.is_empty():
			break
	if family.is_empty():
		family = model.split("-")[0] if "-" in model else model

	var version := _extract_version(model)
	var prov_str: String = _get_provider_map().get(provider.PROVIDER, "unknown")

	return {
		"family": family,
		"version": version,
		"provider": prov_str,
		"raw_model": model,
	}


## Extract model identity from a caller_chat_id.
static func identify_from_chat(caller_chat_id: String) -> Dictionary:
	if caller_chat_id.is_empty():
		return {}
	for history in SingletonObject.ChatList:
		if history.HistoryId == caller_chat_id and history.provider:
			return identify(history.provider)
	return {}


## Does a model identity match a target expression?
## Empty/null target or "all" matches everything.
static func matches(identity: Dictionary, target_str: String) -> bool:
	if identity.is_empty():
		return true
	var clean := target_str.strip_edges().to_lower() if target_str else ""
	if clean.is_empty() or clean == "all":
		return true
	# Multiple targets = OR logic
	for part in clean.split(","):
		if _matches_single(identity, part.strip_edges()):
			return true
	return false


## Filter an array of dictionaries, keeping only items whose target field matches.
static func filter_items(items: Array, identity: Dictionary, target_field: String = "target") -> Array:
	if identity.is_empty():
		return items
	var result: Array = []
	for item in items:
		var target_val = item.get(target_field, "") if item is Dictionary else ""
		if matches(identity, str(target_val)):
			result.append(item)
	return result


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

static func _matches_single(identity: Dictionary, target: String) -> bool:
	if target.is_empty() or target == "all":
		return true

	# Parse: family[:version_spec][@provider]
	var provider_part := ""
	var at_idx := target.find("@")
	if at_idx >= 0:
		provider_part = target.substr(at_idx + 1).strip_edges()
		target = target.left(at_idx).strip_edges()

	var family_part := ""
	var version_part := ""
	var colon_idx := target.find(":")
	if colon_idx >= 0:
		family_part = target.left(colon_idx).strip_edges()
		version_part = target.substr(colon_idx + 1).strip_edges()
	else:
		family_part = target.strip_edges()

	# Check family
	if family_part != "all" and family_part != identity.get("family", ""):
		return false

	# Check provider
	if not provider_part.is_empty() and provider_part != identity.get("provider", ""):
		return false

	# Check version
	if not version_part.is_empty():
		var id_version: String = identity.get("version", "")
		if id_version.is_empty():
			return false
		if not _version_matches(id_version, version_part):
			return false

	return true


static func _version_matches(actual: String, spec: String) -> bool:
	# Range: "4.5-4.6"
	if "-" in spec and not spec.begins_with("-") and not spec.begins_with("<") and not spec.begins_with(">"):
		var parts := spec.split("-", true, 2)
		if parts.size() == 2:
			return _compare_versions(actual, parts[0].strip_edges()) >= 0 and _compare_versions(actual, parts[1].strip_edges()) <= 0

	# Operators: <=, >=, <, >, =
	if spec.begins_with("<="):
		return _compare_versions(actual, spec.substr(2).strip_edges()) <= 0
	if spec.begins_with(">="):
		return _compare_versions(actual, spec.substr(2).strip_edges()) >= 0
	if spec.begins_with("<"):
		return _compare_versions(actual, spec.substr(1).strip_edges()) < 0
	if spec.begins_with(">"):
		return _compare_versions(actual, spec.substr(1).strip_edges()) > 0
	if spec.begins_with("="):
		return _compare_versions(actual, spec.substr(1).strip_edges()) == 0

	# Exact match
	return _compare_versions(actual, spec) == 0


## Compare two version strings numerically. Returns -1, 0, or 1.
static func _compare_versions(a: String, b: String) -> int:
	var a_parts := a.split(".")
	var b_parts := b.split(".")
	var max_len := maxi(a_parts.size(), b_parts.size())
	for i in range(max_len):
		var av := a_parts[i].to_int() if i < a_parts.size() else 0
		var bv := b_parts[i].to_int() if i < b_parts.size() else 0
		if av < bv:
			return -1
		if av > bv:
			return 1
	return 0


## Extract version number from a model name string.
## "claude-sonnet-4.5" → "4.5", "gpt-5.2" → "5.2"
static func _extract_version(model_name: String) -> String:
	var regex := RegEx.new()
	regex.compile("(\\d+\\.\\d+)")
	var result := regex.search(model_name)
	if result:
		return result.get_string(1)
	# Try single integer version
	regex.compile("(\\d+)")
	result = regex.search(model_name)
	if result:
		return result.get_string(1)
	return ""
