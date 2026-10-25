extends SceneTree
## Real profile round trips: discovery cannot opt users in, and old IDs retain
## the model/effort needed by projects that have not been opened since migration.

var passed: int = 0
var failed: int = 0


func _init() -> void:
	call_deferred("run")


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: ", label)
	else:
		failed += 1
		printerr("FAIL: ", label)


func run() -> void:
	var manager_script = load("res://Scripts/Services/Providers/SelectedModelManager.gd")
	var path := "user://model-selection-%s.json" % Time.get_ticks_usec()
	var original := {"next_id": 60010, "models": [
		{"id": 60001, "model_name": "example", "display_name": "Example (Low)", "reasoning_effort": "low", "default_reasoning_level": "medium", "tool_mode": "static"},
		{"id": 60002, "model_name": "example", "display_name": "Example (High)", "reasoning_effort": "high", "default_reasoning_level": "medium", "custom_setting": 42}]}
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(original))
	file.close()
	var manager = manager_script.new(path, 60000)
	manager.load_config()
	check("one selectable entry per actual model", manager.models.size() == 1)
	check("canonical identity and custom settings preserved", manager.models[0].id == 60001 and manager.models[0].tool_mode == "static")
	check("effort is not a selectable model identity", manager.models[0].display_name == "Example" and not manager.models[0].has("reasoning_effort"))
	check("legacy variant ID and settings remain resolvable", manager.get_model(60002).model_name == "example" and manager.get_model(60002).custom_setting == 42)
	check("old chat effort retained for both IDs", manager.legacy_effort(60001) == "low" and manager.legacy_effort(60002) == "high")
	check("archived identity is not an active selection", manager.is_selected(60001) and not manager.is_selected(60002))
	check("unknown IDs do not invent a model", manager.get_model(69999).is_empty())
	check("original profile backed up byte-for-byte", FileAccess.get_file_as_string(path + ".before-selection-migration") == JSON.stringify(original))
	var saved := FileAccess.get_file_as_string(path)
	var reloaded = manager_script.new(path, 60000)
	reloaded.load_config()
	check("migration converges without rewriting", saved == FileAccess.get_file_as_string(path) and reloaded.models == manager.models)
	check("legacy effort survives restart", reloaded.legacy_effort(60002) == "high")
	check_saved_chats(reloaded)
	reloaded.refresh_selected([
		{"model_name": "example", "display_name": "Renamed upstream", "context_window": 12345},
		{"model_name": "unselected", "display_name": "New model"}])
	check("refresh updates selected metadata without registration", reloaded.models.size() == 1 and reloaded.models[0].context_window == 12345)
	check("refresh preserves ID and user fields", reloaded.models[0].id == 60001 and reloaded.models[0].tool_mode == "static" and reloaded.models[0].display_name == "Example")
	var edited: Dictionary = reloaded.get_model(60001).duplicate(true)
	edited["short_name"] = "My model"
	edited["input_token_cost"] = 17
	reloaded.update_model(60001, edited)
	reloaded.remove_model(60001)
	reloaded.refresh_selected([{"model_name": "example"}, {"model_name": "unselected"}])
	var empty = manager_script.new(path, 60000)
	empty.load_config()
	check("deleted selection stays absent after refresh and restart", empty.models.is_empty())
	check("saved chats still resolve deleted model identity", empty.get_model(60001).model_name == "example")
	check("deletion archives current custom settings and original effort", empty.get_model(60001).short_name == "My model" and empty.get_model(60001).input_token_cost == 17 and empty.legacy_effort(60001) == "low")
	var added: int = empty.add_model({"model_name": "example", "display_name": "Example"})
	check("explicit re-add creates an entry without recycling old ID", added >= 60010 and empty.models.size() == 1)
	check("repeated add is idempotent", empty.add_model({"model_name": "example"}) == added and empty.models.size() == 1)
	await check_reasoning()
	await check_controls_and_requests()
	await check_delete_buttons()
	await check_version_resolution()
	print("Results: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func check_saved_chats(manager) -> void:
	var singleton = root.get_node("SingletonObject")
	var saved = singleton._dynamic_provider_map[60000].manager
	singleton._dynamic_provider_map[60000].manager = manager
	var history_script = load("res://Scripts/Models/ServiceHistory.gd")
	var config_before: String = singleton.config_file.encode_to_text()
	for effort: String in ["", "off", "high"]:
		var legacy_chat = history_script.Deserialize({"Provider": 60002, "HistoryId": "migration-" + effort,
			"HistoryName": "Legacy", "HistoryItemList": [], "ReasoningEffort": effort})
		check("old per-chat " + effort + " is dropped without losing model identity", legacy_chat.provider.model_name == "example" and not legacy_chat.Serialize().has("ReasoningEffort"))
		var reopened = history_script.Deserialize(JSON.parse_string(JSON.stringify(legacy_chat.Serialize())))
		check("dropped chat effort stays absent after JSON save/reopen", reopened.provider.model_name == "example" and not reopened.Serialize().has("ReasoningEffort"))
		legacy_chat.provider.free()
		reopened.provider.free()
	check("old chat reasoning is not migrated into model preferences", singleton.config_file.encode_to_text() == config_before)
	var mcp = load("res://Scripts/Services/MCP/Modules/MCPModelTools.gd").new()
	check("archived model update and delete return truthful errors", not mcp._update_model({"model_id": 60002, "short_name": "wrong"}).get("success", false) and not mcp._remove_model({"model_id": 60002}).get("success", false))
	var legacy = history_script.Deserialize({"Provider": 60002, "HistoryId": "identity-check", "HistoryName": "Identity", "HistoryItemList": []})
	var pane = load("res://Scripts/UI/Views/ChatPane.gd").new()
	check("retired picker identity remains exact", pane._resolve_provider_enum_id(legacy.provider) == 60002)
	pane.free()
	var chooser = load("res://Scripts/UI/Controls/ProviderOptionButton.gd").new()
	chooser.add_item("Example", 60001)
	check("retired variant still displays canonical model without duplicate", chooser.get_item_index_for_provider(legacy.provider) == 0 and chooser.item_count == 1)
	chooser.free()
	legacy.provider.free()
	var deep = history_script.Deserialize({"Provider": singleton.API_MODEL_PROVIDERS.GPT_DEEP, "HistoryId": "deep-migration", "HistoryName": "Deep", "HistoryItemList": [], "ReasoningEffort": "high"})
	check("old OpenAI chat effort is dropped too", not deep.Serialize().has("ReasoningEffort"))
	deep.provider.free()
	singleton._dynamic_provider_map[60000].manager = saved


func check_reasoning() -> void:
	var chatgpt_script = load("res://Scripts/Services/Providers/ChatGPT/ChatGPTProvider.gd")
	var provider = chatgpt_script.create_from_config({"model_name": "example", "default_reasoning_level": "medium", "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}]})
	var request: Dictionary = {}
	provider.apply_reasoning_options(request, "high", true)
	check("ChatGPT explicit effort reaches native request options", request.get("reasoning", {}).get("effort") == "high")
	check("ChatGPT override does not mutate the default", provider._build_reasoning_options().get("effort") == "medium")
	var defaults: Dictionary = {}
	provider.apply_reasoning_options(defaults, "", true)
	check("Default after High carries no stale override", defaults.is_empty() and provider.reasoning_effort == "medium")
	var selection = load("res://Scripts/Services/Providers/ReasoningSelection.gd")
	check("unsupported effort resets, supported effort survives", selection.validate("xhigh", provider.reasoning_effort_levels()) == "" and selection.validate("high", provider.reasoning_effort_levels()) == "high")
	check("unsupported Off cannot silently become Low", selection.validate("off", provider.reasoning_effort_levels()) == "")
	provider.free()
	var openai_script = load("res://Scripts/Services/Providers/OpenAI/OpenAIProvider.gd")
	var api = openai_script.create_from_config({"model_name": "gpt-5.2"})
	request = {}
	api.apply_reasoning_options(request, "high", true)
	check("OpenAI effort uses Chat Completions parameter", request.get("reasoning_effort") == "high" and api.reasoning_effort.is_empty())
	check("OpenAI supports only its documented levels", api.reasoning_effort_levels() == ["none", "low", "medium", "high", "xhigh"])
	api.free()
	var nano = openai_script.Nano.new()
	check("Nano is reasoning-capable but cannot disable reasoning", nano.is_reasoning_model and "minimal" in nano.reasoning_effort_levels() and not "none" in nano.reasoning_effort_levels())
	nano.free()
	var unknown = openai_script.create_from_config({"model_name": "unknown-future-model"})
	check("unknown API model does not advertise guessed effort", unknown.reasoning_effort_levels().is_empty())
	unknown.set_meta("legacy_reasoning_effort", "high")
	check("unknown legacy configuration retains only its explicit effort", unknown.reasoning_effort_levels() == ["high"] and selection.validate("high", unknown.reasoning_effort_levels()) == "high")
	unknown.free()
	var previous = openai_script.create_from_config({"model_name": "gpt-5.1"})
	check("GPT-5.1 preserves supported effort through request validation", previous.reasoning_effort_levels() == ["none", "low", "medium", "high"] and selection.validate("high", previous.reasoning_effort_levels()) == "high")
	previous.free()
	await process_frame


func check_controls_and_requests() -> void:
	var singleton = root.get_node("SingletonObject")
	var original_preferences = singleton.preferences_popup
	var preferences = load("res://Scripts/UI/Views/PreferencesPopup.gd").new()
	for key: String in ["openai", "anthropic", "google", "openrouter"]:
		preferences.config_file.set_value("API KEYS", key, "fixture-key")
	singleton.preferences_popup = preferences
	var gen = load("res://Scripts/Services/Providers/GenerationOptions.gd")
	var fixtures = load("res://test/fixtures/model_request_capture.gd")
	var chatgpt_script = load("res://Scripts/Services/Providers/ChatGPT/ChatGPTProvider.gd")
	var original_auth = chatgpt_script.auth
	var auth = load("res://Scripts/Services/Providers/ChatGPT/ChatGPTAuth.gd").new()
	auth.access_token = "fixture-token"
	auth.account_id = "fixture-account"
	auth.expires_at = int(Time.get_unix_time_from_system() * 1000) + 3600000
	chatgpt_script.auth = auth
	var sonnet = fixtures.Anthropic.new()
	var api = fixtures.OpenAI.new()
	api.model_name = "gpt-5.2"
	var chatgpt = fixtures.ChatGPT.new()
	chatgpt.supported_reasoning_levels = [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}]
	var google = fixtures.Google.new()
	var router = fixtures.Router.new()
	router.is_reasoning_model = true
	for provider in [sonnet, api, chatgpt, google, router]:
		check(provider.provider_name + " saves reasoning through existing model layer", gen.save_model(provider, {"reasoning_effort": "high"}).success)
		await provider.generate_content([])
	check("Sonnet High reaches full request thinking budget", sonnet.captured.get("thinking", {}).get("budget_tokens") == 16384)
	check("OpenAI model effort reaches Chat Completions", api.captured.get("reasoning_effort") == "high")
	check("ChatGPT model effort reaches Responses", chatgpt.captured.get("reasoning", {}).get("effort") == "high")
	check("Google model effort reaches thinkingConfig", google.captured.get("generationConfig", {}).get("thinkingConfig", {}).get("thinkingBudget") == 24576)
	check("OpenRouter model effort reaches native reasoning", router.captured.get("reasoning", {}).get("effort") == "high")
	var next_sonnet = fixtures.Anthropic.new()
	var history = load("res://Scripts/Models/ChatHistory.gd").new(next_sonnet)
	await history.provider.generate_content([])
	check("Sonnet High is inherited by a new chat on the same model", next_sonnet.captured.get("thinking", {}).get("budget_tokens") == 16384)
	var other = fixtures.Anthropic.new()
	other.model_name = "claude-other-model"
	await other.generate_content([])
	check("model reasoning does not leak to another model", gen.saved_for(other).is_empty() and other.captured.get("thinking", {}).get("type") == "disabled")
	check("Anthropic offers native Off through Max stops", sonnet.reasoning_effort_levels() == ["off", "low", "medium", "high", "max"])
	gen.save_model(sonnet, {"reasoning_effort": "max"})
	await sonnet.generate_content([])
	check("Anthropic Max is largest budget below model output cap", sonnet.captured.get("thinking", {}).get("budget_tokens") == sonnet.max_tokens - 1)
	for provider in [sonnet, api, chatgpt, google, router, next_sonnet, other]:
		provider.free()
	chatgpt_script.auth = original_auth
	singleton.preferences_popup = original_preferences
	preferences.free()


func check_delete_buttons() -> void:
	var singleton = root.get_node("SingletonObject")
	var popup_script = load("res://Scripts/UI/Views/PreferencesPopup.gd")
	var selected_script = load("res://Scripts/Services/Providers/SelectedModelManager.gd")
	var router_script = load("res://Scripts/Services/Providers/OpenRouter/OpenRouterModelManager.gd")
	for router: bool in [false, true]:
		var path := "user://delete-button-%s-%s.json" % [router, Time.get_ticks_usec()]
		var manager = router_script.new() if router else selected_script.new(path, 30000)
		manager.config_path = path
		var target: int = manager.add_model({"model_name": "delete-target", "api_model_id": "delete-target", "display_name": "Delete target"})
		var neighbor: int = manager.add_model({"model_name": "keep-neighbor", "api_model_id": "keep-neighbor", "display_name": "Keep neighbor"})
		var field := "openrouter_model_manager" if router else "openai_model_manager"
		var original = singleton.get(field)
		singleton.set(field, manager)
		var popup = popup_script.new()
		var rows := VBoxContainer.new()
		if router:
			popup._or_model_list_container = rows
			popup._populate_openrouter_models()
		else:
			popup._custom_models_list_container = rows
			popup._populate_custom_models()
		var clicked := false
		for row: Node in rows.get_children():
			if row is HBoxContainer and row.get_child(0) is Label and row.get_child(0).text == "Delete target":
				for child: Node in row.get_children():
					if child is Button and child.text == "Delete":
						child.pressed.emit()
						clicked = true
		await process_frame
		var reloaded = router_script.new() if router else selected_script.new(path, 30000)
		reloaded.config_path = path
		reloaded.load_config()
		check("Delete button removes only selected row without confirmation (%s)" % router, clicked and popup.get_child_count() == 0 and reloaded.models.size() == 1 and int(reloaded.models[0].id) == neighbor and int(reloaded.models[0].id) != target)
		singleton.set(field, original)
		popup.free()
		rows.free()


var version_done: bool = false
var version_result: Dictionary = {}


func resolve_version(resolver, now: int) -> void:
	version_result = await resolver.resolve(self, "", now)
	version_done = true


func check_version_resolution() -> void:
	var resolver_script = load("res://Scripts/Services/Providers/ChatGPT/CodexClientVersion.gd")
	check("stable version parser rejects prerelease and malformed metadata", resolver_script.stable_version("0.162.1") == "0.162.1" and resolver_script.stable_version("0.163.0-alpha.1").is_empty() and resolver_script.stable_version("0.1.0\n").is_empty() and resolver_script.stable_version(123).is_empty())
	var path := "user://codex-version-test-%s.json" % Time.get_ticks_usec()
	var server := TCPServer.new()
	var listening := server.listen(0, "127.0.0.1")
	check("local registry fixture listens", listening == OK)
	if listening != OK:
		return
	var resolver = resolver_script.new(path, "http://127.0.0.1:%d/latest" % server.get_local_port())
	var override: Dictionary = await resolver.resolve(self, "9.8.7", 100000)
	check("explicit override wins without a lookup", override.version == "9.8.7" and override.source == "override" and not FileAccess.file_exists(path))
	version_done = false
	resolve_version.call_deferred(resolver, 100000)
	var peer: StreamPeerTCP
	var sent := false
	while not version_done:
		if server.is_connection_available():
			peer = server.take_connection()
		if peer != null:
			peer.poll()
			if not sent and peer.get_available_bytes() > 0:
				peer.get_data(peer.get_available_bytes())
				var body := '{"name":"@openai/codex","version":"9.8.6"}'
				peer.put_data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [body.length(), body]).to_utf8_buffer())
				sent = true
		await process_frame
	check("registry metadata resolved and saved", version_result.get("version") == "9.8.6" and version_result.get("source") == "registry" and FileAccess.file_exists(path))
	server.stop()
	if peer != null:
		peer.disconnect_from_host()
	var cached: Dictionary = await resolver.resolve(self, "", 100001)
	check("fresh cache avoids unavailable registry", cached.version == "9.8.6" and cached.source == "cache")
	var stale: Dictionary = await resolver.resolve(self, "", 200000)
	check("expired cache falls back after lookup failure", stale.version == "9.8.6" and stale.source == "stale_cache")
	var fallback = resolver_script.new(path + ".missing", "http://127.0.0.1:9/latest")
	var result: Dictionary = await fallback.resolve(self, "", 200000)
	check("no cache and failed lookup uses bundled default", result.version == resolver_script.FALLBACK and result.source == "bundled_default")
