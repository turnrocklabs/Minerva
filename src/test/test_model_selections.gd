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
	await check_version_resolution()
	print("Results: %d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func check_saved_chats(manager) -> void:
	var singleton = root.get_node("SingletonObject")
	var saved = singleton._dynamic_provider_map[60000].manager
	singleton._dynamic_provider_map[60000].manager = manager
	var history_script = load("res://Scripts/Models/ServiceHistory.gd")
	var legacy = history_script.Deserialize({"Provider": 60002, "HistoryId": "migration-check", "HistoryName": "Legacy", "HistoryItemList": [], "ReasoningEffort": ""})
	check("real saved chat restores original model and effort", legacy.provider.model_name == "example" and legacy.ReasoningEffort == "high")
	var pane_script = load("res://Scripts/UI/Views/ChatPane.gd")
	var pane = pane_script.new()
	check("retired picker identity is exact", pane._resolve_provider_enum_id(legacy.provider) == 60002)
	pane.free()
	var chooser_script = load("res://Scripts/UI/Controls/ProviderOptionButton.gd")
	var chooser = chooser_script.new()
	chooser.add_item("Example", 60001)
	check("retired variant displays canonical choice without duplicate", chooser.get_item_index_for_provider(legacy.provider) == 0 and chooser.item_count == 1 and legacy.provider.get_meta("dynamic_model_id") == 60002)
	chooser.free()
	var serialized: Dictionary = legacy.Serialize()
	var reopened = history_script.Deserialize(JSON.parse_string(JSON.stringify(serialized)))
	check("migrated chat survives JSON save/reopen", reopened.provider.model_name == "example" and reopened.ReasoningEffort == "high")
	serialized.ReasoningEffort = ""
	var defaults = history_script.Deserialize(serialized)
	check("new Default is not remigrated to legacy effort", defaults.ReasoningEffort.is_empty())
	var deep = history_script.Deserialize({"Provider": singleton.API_MODEL_PROVIDERS.GPT_DEEP, "HistoryId": "deep-migration", "HistoryName": "Deep", "HistoryItemList": [], "ReasoningEffort": "high"})
	check("old OpenAI preserves effective effort over stale chat override", deep.ReasoningEffort == "xhigh")
	deep.provider.free()
	var settings_script = load("res://Scripts/UI/Views/AISettings.gd")
	var settings = settings_script.new()
	var picker := OptionButton.new()
	picker.add_item("Default", 0)
	picker.add_item("Off", 1)
	settings._select_reasoning_value(picker, "none")
	check("native none displays as Off", picker.get_selected_id() == 1)
	picker.free()
	settings.free()
	legacy.provider.free()
	reopened.provider.free()
	defaults.provider.free()
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
	unknown.free()
	await process_frame


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
