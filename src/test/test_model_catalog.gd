extends SceneTree
## Integration test for the brokered model catalog (provider/model picker work).
##
## Run: godot --headless --path src --script test/test_model_catalog.gd
##
## Verifies the ONE catalog (SingletonObject.list_enabled_providers /
## list_enabled_models) and its two consumers — the minerva_list_models MCP tool
## and the host.models.* capability — all return the same enabled set. Temporarily
## enables a provider in-memory and injects a fake model into its manager, then
## restores both (no config writes, no real model added permanently).

const MCP_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPPreferenceTools.gd"
const BROKER_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== Model Catalog Broker Test ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _has(list: Array, field: String, want: String) -> bool:
	for e in list:
		if e is Dictionary and str(e.get(field, "")) == want:
			return true
	return false


func _run() -> void:
	await process_frame
	await process_frame
	var singleton = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload present", singleton != null)
	if singleton == null:
		return

	# Provider key round-trips through the enum mapping.
	var chatgpt: int = singleton.provider_from_key("chatgpt")
	check("provider key resolves", chatgpt != -1)
	check("provider key round-trips", singleton.provider_key(chatgpt) == "chatgpt")
	check("unknown provider key is -1", singleton.provider_from_key("nope") == -1)
	if chatgpt == -1:
		return

	# Find the chatgpt manager and snapshot state.
	var manager = null
	for id_base in singleton._dynamic_provider_map:
		var entry: Dictionary = singleton._dynamic_provider_map[id_base]
		if int(entry.get("provider", -2)) == chatgpt:
			manager = entry.get("manager", null)
			break
	check("chatgpt manager present", manager != null)
	if manager == null:
		return

	var saved_models: Array = manager.models.duplicate()
	var had_enabled: bool = singleton._enabled_providers.has(chatgpt)
	var was_enabled: bool = singleton._enabled_providers.get(chatgpt, false)

	# Enable in-memory (no config write) and inject a fake model.
	singleton._enabled_providers[chatgpt] = true
	manager.models.append({"id": 69999, "model_name": "catalog-test-model", "display_name": "Catalog Test Model"})

	# (a) the catalog itself
	check("list_enabled_providers includes chatgpt",
		_has(singleton.list_enabled_providers(), "key", "chatgpt"))
	check("list_enabled_models includes the injected model",
		_has(singleton.list_enabled_models("chatgpt"), "model_name", "catalog-test-model"))
	check("disabled provider yields no models",
		singleton.list_enabled_models("nope").is_empty())

	# (b) the MCP tool (flat success envelope: data at top level)
	var tools = load(MCP_TOOLS_PATH).new(null)
	var lp: Dictionary = tools.handle("minerva_list_models", {})
	check("MCP list providers ok", lp.get("success", false) and _has(lp.get("providers", []), "key", "chatgpt"))
	var lm: Dictionary = tools.handle("minerva_list_models", {"provider": "chatgpt"})
	check("MCP list models returns the model",
		lm.get("success", false) and _has(lm.get("models", []), "model_name", "catalog-test-model"))

	# (c) the host.models.* capability (PluginErrors envelope: data under "result")
	var broker = load(BROKER_PATH).new(null, null)
	var cp: Dictionary = broker._handle_host_models_list_providers("tester", {})
	check("capability list_providers ok",
		cp.get("success", false) and _has((cp.get("result", {}) as Dictionary).get("providers", []), "key", "chatgpt"))
	var cm: Dictionary = broker._handle_host_models_list_models("tester", {"provider": "chatgpt"})
	check("capability list_models returns the model",
		cm.get("success", false) and _has((cm.get("result", {}) as Dictionary).get("models", []), "model_name", "catalog-test-model"))
	check("capability requires a provider arg",
		not broker._handle_host_models_list_models("tester", {}).get("success", true))

	# Restore: original models array + original enabled state (no residue).
	manager.models = saved_models
	if had_enabled:
		singleton._enabled_providers[chatgpt] = was_enabled
	else:
		singleton._enabled_providers.erase(chatgpt)
