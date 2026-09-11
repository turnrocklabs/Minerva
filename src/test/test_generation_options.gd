extends SceneTree
## Generation contract: actual payload builder, persisted layers, editor and MCP dispatch.
var _pass := 0
var _fail := 0
var _completed := false

func _init() -> void:
	await process_frame
	await process_frame
	await _run()
	check("whole generation scenario completed", _completed)
	print("=== Results: %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail else 0)

func check(label: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("PASS: " + label)
	else:
		_fail += 1
		printerr("FAIL: " + label)

func _run() -> void:
	var gen = load("res://Scripts/Services/Providers/GenerationOptions.gd")
	var descriptor = load("res://Scripts/Services/Providers/Core/CoreModelDescriptor.gd")
	var resolver = load("res://Scripts/Services/Providers/ModelResolver.gd")
	var schema: Dictionary = descriptor.LEGACY_OPTIONS.duplicate(true)
	var lower := {"temperature": 1, "options": {"num_predict": 200, "num_ctx": 8192, "num_gpu": 0}}
	var resolved: Dictionary = gen.resolve(schema, lower, {"temperature": 0.9}, {"temperature": 1.5, "max_tokens": 10, "options": {"temperature": 0, "num_predict": 20}})
	check("logical precedence and same-layer native aliases resolve before serialization", resolved.success and resolved.values == {"temperature": 0.0, "max_tokens": 20, "num_ctx": 8192, "num_gpu": 0})
	check("payload has one representation per option", resolved.payload == {"temperature": 0.0, "max_tokens": 20, "options": {"num_ctx": 8192, "num_gpu": 0}})
	check("higher canonical request beats lower native alias", gen.resolve(schema, lower, {}, {"max_tokens": 10}).values.max_tokens == 10)
	check("native winning value replaces invalid same-layer canonical value", gen.resolve(schema, {}, {}, {"max_tokens": null, "options": {"num_predict": 10}}).success)
	var inherited: Dictionary = gen.resolve(schema, {}, {}, {"num_ctx": 0, "num_gpu": -1, "temperature": 0})
	check("inherit sentinels omitted while temperature zero survives", inherited.values.num_ctx == 40000 and inherited.values.temperature == 0 and not inherited.values.has("num_gpu"))
	var invalids := [{"temperature": null}, {"temperature": "0"}, {"temperature": false}, {"temperature": NAN}, {"temperature": INF}, {"max_tokens": 1.5}, {"max_tokens": 1e100}, {"num_gpu": -2}, {"top_p": 0.3}, {"options": {"seed": 1}}]
	var rejected := true
	for invalid in invalids:
		rejected = rejected and not gen.resolve(schema, {}, {}, invalid).success
	check("invalid, fractional, nonfinite and unsupported explicit options are rejected", rejected)
	check("unsupported advertised option refuses explicit zero", gen.resolve({}, {}, {}, {"temperature": 0}).get("error_code") == "unsupported_generation_option")

	var so = root.get_node("SingletonObject")
	var core = root.get_node("Core")
	var saved_services = core.services.duplicate()
	var saved_connected: bool = core.client._connected
	var saved_registered: bool = core.registered
	var saved_enabled: Dictionary = so._enabled_providers.duplicate()
	var saved_config: ConfigFile = so.config_file
	var saved_path: String = so._config_file_name
	var saved_chats = so.ChatList.duplicate()
	var saved_pane = so.Chats
	var saved_registry = so.plugin_chat_provider_registry
	so.config_file = ConfigFile.new()
	so._config_file_name = "/tmp/minerva-t5-options.cfg"
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/model_chat_registration.json"))
	var service = load("res://Scripts/Services/Providers/Core/scripts/service.gd").new(fixture.params)
	core.services.assign([service])
	core.client._connected = true
	core.registered = true
	so._enabled_providers[so.API_PROVIDER.TURNROCK] = true
	var spec := {"kind": "core_action", "service_client_id": "model-chat", "action_name": "qwen3:8b"}
	var key: String = load("res://Scripts/Services/Providers/Core/CoreModelCatalog.gd").settings_key(spec)
	so.config_file.set_value("Models", "Contexts", {key: 8192})
	so.config_file.set_value("Models", "NumGpu", {key: 0})
	so.config_file.set_value("Models", "CoreActionMigrations", {key: "complete"})
	so.config_file.save(so._config_file_name)
	var provider = load("res://test/fixtures/generation_capture_core_provider.gd").new(service, service.actions[0])
	provider.requires_chat_model = true
	var history = load("res://Scripts/Models/ChatHistory.gd").new(provider, "generation-test")
	history.HistoryName = "Generation test"
	check("new chat scalar default does not manufacture an override", history.Temperature == 1 and history.GenerationOverrides.is_empty())
	var prepared: Dictionary = provider.build_chat_payload([{"role": "user", "content": "hello"}], gen.chat_params(history, provider))
	check("new chat inherits descriptor temperature and stable legacy model prefs", prepared.payload.temperature == 0.7 and prepared.payload.options == {"num_ctx": 8192, "num_gpu": 0})
	history.Temperature = 0
	check("explicit agent/chat temperature records zero intent", history.GenerationOverrides.get("temperature") == 0)
	var serialized: Dictionary = history.Serialize()
	var history_script = load("res://Scripts/Models/ServiceHistory.gd")
	var restored = history_script.Deserialize(JSON.parse_string(JSON.stringify(serialized)))
	check("explicit zero survives history JSON roundtrip", restored.Temperature == 0 and restored.GenerationOverrides.temperature == 0)
	restored.provider.free()
	serialized.Temperature = 1
	serialized.GenerationOptions = {}
	restored = history_script.Deserialize(serialized)
	check("modern empty map stays inheritance despite serialized legacy scalar", restored.GenerationOverrides.is_empty())
	restored.provider.free()
	serialized.erase("GenerationOptions")
	restored = history_script.Deserialize(serialized)
	check("legacy present scalar one migrates as explicit intent", restored.GenerationOverrides.temperature == 1)
	restored.provider.free()
	gen.set_chat(history, {})

	# The scene loads effective values without writing model or chat overrides.
	var editor = load("res://Scenes/controls/CoreGenerationSettings.tscn").instantiate()
	root.add_child(editor)
	var config_before: String = so.config_file.encode_to_text()
	editor.configure(provider, history)
	editor.configure(provider, history)
	check("opening settings leaves config and explicit chat layer unchanged", so.config_file.encode_to_text() == config_before and history.GenerationOverrides.is_empty())
	editor.get_node("Scope").select(1)
	editor._load_values()
	editor.get_node("Temperature/Override").set_pressed_no_signal(true)
	editor.get_node("Temperature/Value").set_value_no_signal(0)
	editor._edit("temperature")
	check("first model edit seeds existing context/GPU preferences", gen.saved_for(provider) == {"temperature": 0.0, "num_ctx": 8192, "num_gpu": 0})
	editor._clear_layer()
	var reloaded_config := ConfigFile.new()
	reloaded_config.load(so._config_file_name)
	so.config_file = reloaded_config
	check("cleared modern map remains authoritative after reload", gen.saved_for(provider).is_empty() and gen.for_provider(provider).values.num_ctx == 40000 and not gen.for_provider(provider).values.has("num_gpu"))
	var old_schema: Dictionary = service.actions[0].model_metadata.generation_options.duplicate(true)
	service.actions[0].model_metadata.generation_options = {"temperature": schema.temperature, "max_tokens": schema.max_tokens}
	editor.configure(provider, history)
	check("temperature/output-only models show controls without context/GPU", editor.get_node("Temperature").visible and editor.get_node("MaxTokens").visible and not editor.get_node("Context").visible and not editor.get_node("Gpu").visible)
	service.actions[0].model_metadata.generation_options = old_schema
	var settings = load("res://Scripts/UI/Views/AISettings.gd").new()
	settings.current_chat_tab_ref = history
	settings._loading_values = true
	config_before = so.config_file.encode_to_text()
	settings.update_current_tab_param(settings.GPT_params.temp, 1)
	settings._on_model_chat_num_ctx_changed(2048)
	settings._on_num_gpu_changed(0)
	settings._on_timeout_changed(50)
	check("programmatic AI settings callbacks cannot create overrides", history.GenerationOverrides.is_empty() and so.config_file.encode_to_text() == config_before)
	settings.free()

	# Production MCP dispatch owns inspect/set, including write-vs-effective errors.
	var pane = load("res://test/fixtures/generation_chat_pane.gd").new()
	pane.add_child(Control.new())
	so.Chats = pane
	so.ChatList.assign([history])
	var server = so.get_mcp_manager().minerva_server
	var inspect: Dictionary = await server.execute_tool_for_http("minerva_get_generation_options", {"chat_id": history.HistoryId})
	check("MCP inspects effective defaults and schema", inspect.success and inspect.effective_options.temperature == 0.7 and inspect.schema.has("max_tokens"))
	var model_set: Dictionary = await server.execute_tool_for_http("minerva_set_generation_options", {"model_spec": spec, "options": {"max_tokens": 200}})
	check("MCP persists model layer", model_set.success and model_set.model_options.max_tokens == 200)
	var chat_set: Dictionary = await server.execute_tool_for_http("minerva_set_generation_options", {"chat_id": history.HistoryId, "options": {"temperature": 0, "num_gpu": 0}})
	check("MCP persists chat zero values", chat_set.success and chat_set.chat_options == {"temperature": 0.0, "num_gpu": 0})
	var preview: Dictionary = await server.execute_tool_for_http("minerva_get_generation_options", {"chat_id": history.HistoryId, "request_options": {"max_tokens": 10}})
	check("MCP previews highest request precedence", preview.success and preview.effective_options.max_tokens == 10 and preview.sources.max_tokens == "request")
	var private_request: Dictionary = await server.execute_tool_for_http("minerva_get_generation_options", {"chat_id": history.HistoryId, "request_options": {"_chat_generation_options": {"temperature": 1}}})
	check("public MCP cannot inject the private chat layer", private_request.get("error_code") == "unsupported_generation_option")
	var bad_send: Dictionary = await server.execute_tool_for_http("minerva_send_message", {"chat_id": history.HistoryId, "message": "bad", "generation_options": {"max_tokens": 2.5}})
	check("MCP send rejects invalid overrides before scheduling a turn", bad_send.get("error_code") == "invalid_generation_option" and history.HistoryItemList.is_empty())

	var valid_send: Dictionary = await server.execute_tool_for_http("minerva_send_message", {"chat_id": history.HistoryId, "message": "request preview", "generation_options": {"max_tokens": 10, "options": {"num_predict": 20}}})
	check("MCP send schedules normalized request overrides without changing chat preferences", valid_send.success and pane.submitted_options == {"max_tokens": 20} and not history.GenerationOverrides.has("max_tokens"))

	var item = load("res://Scripts/Models/ChatHistoryItem.gd").new()
	item.Message = "hello"
	item.provider = provider
	item.RequestMetadata = {"generation_options_request": {"max_tokens": 10, "options": {"num_ctx": 4000}}}
	history.HistoryItemList.append(item)
	var reply = await pane.generate_content_from_provider(history, [{"role": "user", "content": "hello"}])
	check("normal/agent call boundary uses explicit chat and originating request layers", reply.text == "captured" and provider.payload.temperature == 0 and provider.payload.max_tokens == 10 and provider.payload.options == {"num_ctx": 4000, "num_gpu": 0})
	check("private layer never appears on the wire", not provider.payload.has(gen.CHAT_LAYER) and not provider.payload.options.has("num_predict"))
	var metadata: Dictionary = pane._build_request_metadata(history, [], {"temperature": 0, "max_tokens": 3})
	check("request metadata exposes effective zero and requested output limit", metadata.temperature == 0 and metadata.generation_options.max_tokens == 3)
	var partial_data: Dictionary = item.Serialize().duplicate(true)
	partial_data.Role = 2
	partial_data.Message = "partial"
	var partial = load("res://Scripts/Models/ChatHistoryItem.gd").Deserialize(partial_data)
	history.HistoryItemList.append(partial)
	var later = load("res://Scripts/Models/ChatHistoryItem.gd").new()
	later.RequestMetadata = {"generation_options_request": {"max_tokens": 999}}
	history.HistoryItemList.append(later)
	var other_provider = load("res://test/fixtures/generation_capture_core_provider.gd").new(service, service.actions[1])
	var other_history = load("res://Scripts/Models/ChatHistory.gd").new(other_provider, "other-generation-chat")
	so.ChatList.append(other_history)
	pane.add_child(Control.new())
	pane.current_tab = 1
	var continued = await pane.continue_response(partial)
	check("reloaded continuation uses owning history/provider and original request", continued.Message.ends_with("captured") and pane.prompt_history == history and provider.payload.max_tokens == 10 and other_provider.payload.is_empty())
	var preserved_text: String = partial.Message
	partial.Complete = false
	var saved_overrides: Dictionary = history.GenerationOverrides.duplicate(true)
	history.GenerationOverrides = {"max_tokens": 1.5}
	history.termination_reason = "completed"
	var refused_continuation = await pane.continue_response(partial)
	check("refused continuation preserves partial text and completion state", refused_continuation.Message == preserved_text and not refused_continuation.Complete)
	check("generation refusal cannot retain successful agent status", history.termination_reason == "error" and not history.termination_message.is_empty())
	history.GenerationOverrides = saved_overrides

	so.ChatList.assign([history])
	pane.current_tab = 0
	other_provider.free()

	pane.clone_chat(0)
	var cloned = so.ChatList.back()
	check("clone retains Core selection and explicit options", resolver.spec_for(cloned.provider) == resolver.spec_for(provider) and cloned.GenerationOverrides == history.GenerationOverrides)
	cloned.GenerationOverrides["temperature"] = 1
	check("clone options are independent dictionaries", history.GenerationOverrides.temperature == 0)
	cloned.provider.free()
	so.ChatList.assign([history])

	so.plugin_chat_provider_registry = load("res://Scripts/Services/Plugins/PluginChatProviderRegistry.gd").new()
	var plugin = resolver.restore_plugin("plugin:council:absent:seat")
	var plugin_history = load("res://Scripts/Models/ChatHistory.gd").new(plugin, "plugin-clone-test")
	plugin_history.HistoryName = "Plugin clone"
	so.ChatList.assign([plugin_history])
	pane.clone_chat(0)
	var plugin_clone = so.ChatList.back()
	check("clone retains unavailable plugin identity with colon suffix", resolver.spec_for(plugin_clone.provider) == resolver.spec_for(plugin) and plugin_clone.provider.entry_id == "absent:seat" and plugin_clone.GenerationOverrides.is_empty())
	plugin_clone.provider.free()
	plugin.free()
	so.ChatList.assign([history])
	var manager = so.chatgpt_model_manager
	var saved_models: Array = manager.models.duplicate(true)
	manager.models.append({"id": 69998, "model_name": "generation-clone-test", "display_name": "Clone test"})
	so._enabled_providers[so.API_PROVIDER.CHATGPT] = true
	var dynamic = so.create_dynamic_provider(69998)
	var dynamic_copy: Dictionary = resolver.copy_selection(dynamic)
	check("copy selection reconstructs dynamic model configuration", dynamic_copy.success and dynamic_copy.provider.model_name == "generation-clone-test" and resolver.spec_for(dynamic_copy.provider) == {"kind": "dynamic", "model_id": 69998})
	if dynamic_copy.has("provider"):
		dynamic_copy.provider.free()
	dynamic.free()
	manager.models = saved_models

	var broker = load("res://Scripts/Services/Plugins/CapabilityBroker.gd").new(null, null)
	for invalid in [{"max_tokens": 2.5}, {"temperature": null}, {"options": {"seed": 1}}]:
		var args := {"model_spec": spec, "messages": [{"role": "user", "text": "must not dispatch"}]}
		args.merge(invalid)
		var refused: Dictionary = await broker._handle_host_providers_chat("tester", args)
		check("broker refuses invalid explicit options before dispatch: %s" % str(invalid), refused.get("error_code") in ["invalid_generation_option", "unsupported_generation_option"])
	service.actions[0].model_metadata.generation_options.temperature = {"type": "number", "minimum": 0, "maximum": 0.5, "default": 0.3}
	history.GenerationOverrides = {"temperature": 1}
	var written: Dictionary = await server.execute_tool_for_http("minerva_set_generation_options", {"chat_id": history.HistoryId, "scope": "model", "options": {"max_tokens": 15}})
	check("successful model writes remain explicit when another layer is invalid", written.success and written.model_options.max_tokens == 15 and written.effective_error.error_code == "invalid_generation_option")
	service.actions[0].model_metadata.generation_options = old_schema

	# Existing non-Core OpenAI sampling policy is retained by the common boundary.
	var native = so.API_MODEL_PROVIDER_SCRIPTS[so.API_MODEL_PROVIDERS.GPT_NANO].new()
	var native_history = load("res://Scripts/Models/ChatHistory.gd").new(native, "native-options-test")
	native_history.Temperature = 0
	var native_params: Dictionary = gen.chat_params(native_history, native)
	check("non-Core OpenAI sampling remains unchanged", native_params == {"temperature": 0.0, "top_p": 1.0, "presence_penalty": 0.0, "frequency_penalty": 0.0})
	native.free()

	so.config_file = saved_config
	so._config_file_name = saved_path
	so._enabled_providers = saved_enabled
	so.ChatList.assign(saved_chats)
	so.Chats = saved_pane
	so.plugin_chat_provider_registry = saved_registry
	core.services.assign(saved_services)
	core.client._connected = saved_connected
	core.registered = saved_registered
	editor.free()
	pane.free()
	provider.free()
	_completed = true
