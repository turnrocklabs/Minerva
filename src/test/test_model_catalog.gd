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

const BROKER_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"

var _pass: int = 0
var _fail: int = 0
var _completed := false


func _init() -> void:
	print("=== Model Catalog Broker Test ===\n")
	await _run()
	check("whole production catalog scenario completed", _completed)
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		printerr("FAIL: %s%s" % [label, (" — " + detail) if detail != "" else ""])


func _has(list: Array, field: String, want: Variant) -> bool:
	for e in list:
		if e is Dictionary and str(e.get(field, "")) == str(want):
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

	var resolver = load("res://Scripts/Services/Providers/ModelResolver.gd")
	var enabled_before: Dictionary = singleton._enabled_providers.duplicate()
	for model_id in [singleton.API_MODEL_PROVIDERS.HUMAN, singleton.API_MODEL_PROVIDERS.GPT_IMAGE_15, singleton.API_MODEL_PROVIDERS.NANO_BANANA_PRO]:
		var provider_id: int = singleton.MODEL_TO_PROVIDER[model_id]
		singleton._enabled_providers[provider_id] = true
		check("non-chat builtin excluded from catalog: %s" % model_id, not _has(resolver.catalog_models(singleton.provider_key(provider_id)), "id", model_id))
		check("non-chat builtin refuses plugin construction: %s" % model_id, resolver.create({"kind": "builtin", "model_id": model_id}, true).get("error_code") == "not_chat_model")
	singleton._enabled_providers = enabled_before

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
	var tools = singleton.get_mcp_manager().minerva_server
	var owners := 0
	for module in tools._modules:
		if module.can_handle("minerva_list_models"):
			owners += 1
	check("exactly one production module owns minerva_list_models", owners == 1)
	var lp: Dictionary = await tools.execute_tool_for_http("minerva_list_models", {})
	check("MCP list providers ok", lp.get("success", false) and _has(lp.get("providers", []), "key", "chatgpt"))
	var lm: Dictionary = await tools.execute_tool_for_http("minerva_list_models", {"provider": "chatgpt"})
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

	for model in lm.get("models", []):
		if model.model_name == "catalog-test-model":
			var resolved: Dictionary = resolver.create(model.model_spec)
			check("listed dynamic spec constructs the requested model", resolved.get("success", false) and resolved.provider.model_name == "catalog-test-model")
			if resolved.has("provider"):
				resolved.provider.free()
	var named: Dictionary = resolver.create_by_name("chatgpt", "Catalog test model")
	check("dynamic display name resolves without substituting identity", named.get("success", false) and named.provider.model_name == "catalog-test-model")
	if named.has("provider"):
		named.provider.free()
	manager.models.append({"id": 69998, "model_name": "different-catalog-model", "display_name": "catalog-test-model"})
	var collision: Dictionary = resolver.create_by_name("chatgpt", "catalog-test-model")
	check("canonical model name wins over another model display label", collision.get("success", false) and collision.provider.model_name == "catalog-test-model")
	if collision.has("provider"):
		collision.provider.free()
	await _core_surfaces(singleton, tools, broker)
	_completed = true

	# Restore: original models array + original enabled state (no residue).
	manager.models = saved_models
	if had_enabled:
		singleton._enabled_providers[chatgpt] = was_enabled
	else:
		singleton._enabled_providers.erase(chatgpt)


func _core_surfaces(singleton, server, broker) -> void:
	var core = root.get_node("Core")
	var resolver = load("res://Scripts/Services/Providers/ModelResolver.gd")
	var service_script = load("res://Scripts/Services/Providers/Core/scripts/service.gd")
	var history_script = load("res://Scripts/Models/ChatHistory.gd")
	var saved_services = core.services.duplicate()
	var saved_connected: bool = core.client._connected
	var saved_registered: bool = core.registered
	var turnrock: int = singleton.provider_from_key("turnrock")
	var saved_enabled: Dictionary = singleton._enabled_providers.duplicate()
	var saved_permissions: Dictionary = singleton._plugin_allowed_providers.duplicate()
	var saved_popup = singleton.errorPopup
	var saved_title = singleton.errorTitle
	var saved_text = singleton.errorText
	var saved_root_size := root.size
	root.size = Vector2i(1024, 768)
	var popup = load("res://Scripts/UI/Controls/PersistentWindow.gd").new()
	popup.visible = false
	root.add_child(popup)
	singleton.errorPopup = popup
	singleton.errorTitle = Label.new()
	singleton.errorText = Label.new()
	popup.add_child(singleton.errorTitle)
	popup.add_child(singleton.errorText)
	var saved_chats = singleton.ChatList.duplicate()
	var saved_pane = singleton.Chats
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/model_chat_registration.json"))
	var service = service_script.new(fixture.params)
	core.services.assign([service])
	core.client._connected = true
	core.registered = true
	singleton._enabled_providers[turnrock] = true
	singleton._plugin_allowed_providers[turnrock] = true

	var listed: Dictionary = await server.execute_tool_for_http("minerva_list_models", {"provider": "turnrock"})
	var host_models: Array = singleton.list_enabled_models("turnrock")
	check("production MCP and host expose the same concrete Core models", listed.get("models", []) == host_models and host_models.size() == 2)
	var spec: Dictionary = host_models[0].model_spec
	var plugin_models: Dictionary = broker._handle_host_models_list_models("tester", {"provider": "turnrock"})
	check("plugin catalog matches the same offerings", plugin_models.result.models == host_models)
	singleton._plugin_allowed_providers[turnrock] = false
	check("plugin permission filters discovery independently", broker._handle_host_models_list_models("tester", {"provider": "turnrock"}).result.models.is_empty() and singleton.list_enabled_models("turnrock").size() == 2)
	check("plugin permission also refuses explicit construction", resolver.create(spec, true).get("error_code") == "provider_disabled")
	check("plugin refusal stays structured without opening a modal", not popup.visible)
	popup.hide()
	singleton._plugin_allowed_providers[turnrock] = true

	var chooser = load("res://Scripts/UI/Controls/ProviderOptionButton.gd").new()
	chooser._setup_default_provider_set()
	chooser.switch_to_provider_set("default")
	check("GUI can select the advertised spec", chooser.select_provider_spec(spec))
	check("Core tooltip exposes exact service/action identity", chooser.get_item_tooltip(chooser.selected) == "%s / %s" % [spec.service_client_id, spec.action_name])
	var provider = chooser.get_selected_provider()
	check("GUI constructs the exact Core identity", resolver.spec_for(provider) == spec and provider.requires_chat_model)
	var history = history_script.new(provider, "core-catalog-test-chat")
	history.HistoryName = "Core catalog test"
	var serialized: Dictionary = history.Serialize()
	check("history persists the full Core tuple", serialized.CoreModelSpec == spec)

	# Real module dispatch, with an unmounted real pane so no UI/application is launched.
	var pane = load("res://Scripts/UI/Views/ChatPane.gd").new()
	pane.add_child(Control.new())
	pane._provider_option_button = chooser
	singleton.Chats = pane
	singleton.ChatList.assign([history])
	var chat_tools = load("res://Scripts/Services/MCP/Modules/MCPChatTools.gd").new(server)
	var current: Dictionary = chat_tools._resolve_chat_provider({"provider": "current"}, pane, false)
	check("current Core selection survives resolution without Node duplication", current.get("success", false) and resolver.spec_for(current.provider) == spec)
	if current.has("provider"):
		current.provider.free()
	var authoritative: Dictionary = chat_tools._resolve_chat_provider({"model_spec": spec, "provider": "unknown"}, pane, false)
	check("explicit structured identity is authoritative", authoritative.get("success", false) and authoritative.model_spec == spec)
	if authoritative.has("provider"):
		authoritative.provider.free()
	check("fractional enum is rejected before conversion", chat_tools._resolve_chat_provider({"provider_enum_id": 1.5}, pane, false).get("error_code") == "invalid_model_spec")
	check("bare TurnRock enum cannot create an unbound chat provider", resolver.create({"kind": "builtin", "model_id": singleton.API_MODEL_PROVIDERS.TURNROCK}).get("error_code") == "invalid_model_spec")
	var unknown: Dictionary = await server.execute_tool_for_http("minerva_create_chat", {"name": "Unknown explicit selection test", "provider": "not-a-real-model"})
	check("public MCP create refuses an explicit unknown model", unknown.get("error_code") == "model_not_available" and singleton.ChatList.size() == 1)

	singleton._enabled_providers[turnrock] = false
	chooser._on_provider_enabled_changed(turnrock, false)
	check("disabled GUI selection retains its tuple as an unavailable row", chooser.get_selected_provider_spec() == spec and chooser.is_item_disabled(chooser.selected))
	var pending = chooser.get_selected_provider()
	check("disabled GUI selection retains Core provider identity", resolver.spec_for(pending) == spec)
	pending.free()
	var denied: Dictionary = await server.execute_tool_for_http("minerva_set_chat_model", {"chat_id": history.HistoryId, "model_spec": spec})
	check("public MCP set retains structured refusal and requested identity", denied.get("error_code") == "provider_disabled" and denied.get("model_spec") == spec and history.provider == provider)
	check("MCP resolution does not open a modal", not popup.visible)
	popup.hide()
	var refused = await provider.generate_content([])
	check("direct Core refusal stays structured for background callers", refused.get_meta("error_code") == "provider_disabled" and not popup.visible)
	popup.hide()
	var builtin_id: int = singleton.API_MODEL_PROVIDERS.GPT_NANO
	singleton._enabled_providers[singleton.API_PROVIDER.OPENAI] = false
	var builtin_denied: Dictionary = resolver.create({"kind": "builtin", "model_id": builtin_id})
	check("builtin resolution refuses without a modal", builtin_denied.error_code == "provider_disabled" and not popup.visible)
	var retained: Dictionary = resolver.create({"kind": "builtin", "model_id": builtin_id}, false, true)
	check("disabled builtin can be retained for an empty chat", retained.success)
	retained.provider.free()
	var background_provider = resolver.restore_core(spec)
	var background = await pane.generate_content_from_provider(history, [], null, background_provider)
	background_provider.free()
	check("background generation refuses without a modal", background.get_meta("error_code") == "provider_disabled" and not popup.visible)
	var interactive = await pane.generate_content_from_provider(history, [])
	check("interactive chat refusal displays actionable dialog", interactive.get_meta("error_code") == "provider_disabled" and popup.visible and "TurnRock" in singleton.errorText.text and "Preferences" in singleton.errorText.text)
	popup.hide()
	var continued = await pane.generate_content_from_provider(history, [], null, provider)
	check("Continue with the chat provider still displays a refusal", continued.get_meta("error_code") == "provider_disabled" and popup.visible)
	popup.hide()
	chooser.switch_to_provider_set_for_service(service)
	singleton._enabled_providers[turnrock] = true
	chooser._on_provider_enabled_changed(turnrock, true)
	check("service-specific chooser repopulates when TurnRock is enabled", chooser.select_provider_spec(spec) and not chooser.is_item_disabled(chooser.selected))

	var agent = load("res://Scripts/UI/Windows/AgentManagerWindow.gd").new()
	agent.agent_provider_dropdown = OptionButton.new()
	agent.agent_model_dropdown = OptionButton.new()
	agent.agent_provider_dropdown.add_item("TurnRock")
	agent.agent_provider_dropdown.set_item_metadata(0, turnrock)
	var unavailable_agent = load("res://Scripts/Services/Agents/AgentDefinition.gd").new()
	unavailable_agent.provider_enum_id = singleton.API_MODEL_PROVIDERS.GPT_IMAGE_15
	agent._select_saved_agent_model(unavailable_agent)
	check("unavailable agent model is retained rather than selecting another model", agent._model_id_map[agent.agent_model_dropdown.selected] == unavailable_agent.provider_enum_id and agent.agent_model_dropdown.is_item_disabled(agent.agent_model_dropdown.selected))
	agent.agent_provider_dropdown.select(0)
	agent._populate_model_dropdown(turnrock)
	agent._select_core_model(spec)
	singleton._enabled_providers[turnrock] = false
	agent._refresh_core_models()
	check("agent editor retains unavailable model identity", agent._core_model_map[agent.agent_model_dropdown.selected] == spec and agent.agent_model_dropdown.is_item_disabled(agent.agent_model_dropdown.selected))

	var voice = load("res://Scripts/Services/Voice/VoiceServiceClient.gd").new()
	var summary: Dictionary = await voice.summarize_for_speech_result("question", "answer".repeat(100), spec.action_name)
	check("disabled summary uses deterministic fallback with a reason", summary.text == "answer".repeat(100).substr(0, 200) and summary.fallback_reason == "provider_disabled")
	check("voice service discovery remains independent of chat enable", voice._get_voice_service() != null)
	var preferences = load("res://Scripts/UI/Views/PreferencesPopup.gd").new()
	preferences._summary_model_option = OptionButton.new()
	var voice_config = singleton.get_voice_config()
	var saved_summary: String = voice_config.summary_model
	voice_config.summary_model = spec.action_name
	preferences._populate_summary_models()
	check("summary preferences retain unavailable selection", voice_config.summary_model == spec.action_name and preferences._summary_model_option.is_item_disabled(preferences._summary_model_option.selected))
	voice_config.summary_model = saved_summary

	core.services.clear()
	core.client._connected = false
	core.registered = false
	singleton._enabled_providers[turnrock] = true
	var restored = history_script.Deserialize(JSON.parse_string(JSON.stringify(serialized)))
	check("offline history restores the same Core tuple without substitution", resolver.spec_for(restored.provider) == spec and restored.provider.requires_chat_model)
	check("offline explicit resolution exposes the reason", resolver.create(spec).get("error_code") == "core_offline")
	core.services.assign([service])
	core.client._connected = true
	core.registered = true
	var reconnected: Dictionary = resolver.create(resolver.spec_for(restored.provider))
	check("retained identity resolves on reconnect", reconnected.get("success", false) and resolver.spec_for(reconnected.provider) == spec)
	if reconnected.has("provider"):
		reconnected.provider.free()

	singleton.errorPopup = saved_popup
	singleton.errorTitle = saved_title
	singleton.errorText = saved_text
	popup.free()
	root.size = saved_root_size
	core.services.assign(saved_services)
	core.client._connected = saved_connected
	core.registered = saved_registered
	singleton._enabled_providers = saved_enabled
	singleton._plugin_allowed_providers = saved_permissions
	singleton.ChatList.assign(saved_chats)
	singleton.Chats = saved_pane
	restored.provider.free()
	provider.free()
	chooser.free()
	pane.free()
	agent.agent_provider_dropdown.free()
	agent.agent_model_dropdown.free()
	agent.free()
	preferences._summary_model_option.free()
	preferences.free()
