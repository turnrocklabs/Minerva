extends SceneTree
## One real gear-dialog scenario; fixture discovery replaces network access only.
var passed: int = 0
var failed: int = 0


func _init() -> void:
	_run.call_deferred()


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		printerr("FAIL: " + label)


func _run() -> void:
	await process_frame
	# Autoload-dependent classes are loaded at runtime for the --script runner.
	var singleton = root.get_node("SingletonObject")
	var core = root.get_node("Core")
	# The normal project entry binds preferences before deferred auth loading;
	# a standalone SceneTree must supply that owner before instantiating MainScene.
	var preferences = load("res://Scripts/UI/Views/PreferencesPopup.gd").new()
	singleton.preferences_popup = preferences
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/model_chat_registration.json"))
	var service = load("res://Scripts/Services/Providers/Core/scripts/service.gd").new(fixture.params)
	core.services.assign([service])
	core.client._connected = true
	core.registered = true
	singleton._enabled_providers[singleton.API_PROVIDER.TURNROCK] = true
	var main: Node = load("res://Scenes/MainScene.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	await process_frame
	# Discovery is fixture-owned: a closed real socket must not clear this
	# advertised connection while the real scene advances through frames.
	core.client.set_process(false)
	core.services.assign([service])
	core.client._connected = true
	core.registered = true
	var pane = singleton.Chats
	var picker = pane._provider_option_button
	picker._on_core_catalog_changed()
	var spec := {"kind": "core_action", "service_client_id": "model-chat", "service_name": "Model Chat Service", "action_name": "qwen3:8b"}
	check("Core fixture is selectable", picker.select_provider_spec(spec))
	picker.item_selected.emit(picker.selected)
	check("chat dropdown persists default ID", singleton.get_config_file_value("Providers", "DefaultProviderId") == picker.get_selected_id())
	check("chat dropdown retains stable Core default", singleton.get_config_file_value("Providers", "DefaultModelSpec") == spec)
	var settings: Window = pane.get_node("%AISettings")
	settings.load_current_chat_settings()
	var label: Label = settings.find_child("SelectedModelLabel", true, false)
	check("gear without a chat names selected Core model", label != null and "qwen3:8b" in label.text)
	settings.popup_centered()
	var fallback_spec: Dictionary = spec.duplicate()
	fallback_spec.action_name = "library/model:latest"
	picker.switch_to_provider_set_for_service(service)
	picker.select_provider_spec(fallback_spec)
	picker.item_selected.emit(picker.selected)
	check("open gear follows the selected model before the first chat", "library/model:latest" in label.text)
	picker.select_provider_spec(spec)
	picker.item_selected.emit(picker.selected)
	settings.hide()
	pane._on_new_chat()
	await process_frame
	var history = singleton.ChatList.back()
	var resolver = load("res://Scripts/Services/Providers/ModelResolver.gd")
	check("new chat starts on selected Core model", resolver.spec_for(history.provider) == spec)
	history.AgenticSystemPrompt = "Fixture prompt"
	# A programmatic picker change must not relabel the bound chat's settings.
	var other_spec: Dictionary = spec.duplicate()
	other_spec.action_name = "library/model:latest"
	picker.select_provider_spec(other_spec)
	pane._on_btn_chat_settings_pressed()
	await process_frame
	check("gear names bound chat model rather than stale picker text", label != null and label.text == "Settings for %s (%s)" % [history.provider.display_name, history.provider.provider_name])
	var model_editor: Control = settings.find_child("ModelGenerationSettings", true, false)
	check("context and GPU live in model section", model_editor != null and model_editor.get_parent().name == "ModelSettings")
	if model_editor != null:
		model_editor.get_node("Context/Override").button_pressed = true
		model_editor.get_node("Context/Value").value = 8192
		model_editor.get_node("Gpu/Override").button_pressed = true
		model_editor.get_node("Gpu/Value").value = 0
		var gen = load("res://Scripts/Services/Providers/GenerationOptions.gd")
		var saved: Dictionary = gen.saved_for(history.provider)
		check("model fields persist under bound model settings key", saved.get("num_ctx") == 8192 and saved.get("num_gpu") == 0)
		check("model fields create no chat overrides", history.GenerationOverrides.is_empty())
	check("separate default-provider control removed", settings.find_child("ProviderOptionButton", true, false) == null)
	var unsupported = settings.find_child("ModelReasoningSettings", true, false)
	check("unsupported model hides slider and explains why", unsupported != null and not unsupported.get_node("Effort").visible and "does not offer" in unsupported.get_node("Message").text)
	settings.hide()
	await _check_native_slider(singleton, core, pane, settings)
	preferences.free()
	print("Results: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)


func _check_native_slider(singleton: Node, core: Node, pane: Node, settings: Window) -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/native_model_chat_registration.json"))
	var service = load("res://Scripts/Services/Providers/Core/scripts/service.gd").new(fixture.params)
	core.services.assign([service])
	var picker = pane._provider_option_button
	# The earlier chat scenario selects the internal chat service. Select the
	# advertised model service through the same public chooser path as the UI.
	picker.switch_to_provider_set_for_service(service)
	var spec := {"kind": "core_action", "service_client_id": "model-chat", "service_name": "Model Chat Service", "action_name": "GLM-5.3-Flash"}
	check("native GLM fixture is selectable", picker.select_provider_spec(spec))
	picker.item_selected.emit(picker.selected)
	var history = singleton.ChatList[pane.current_tab]
	history.AgenticSystemPrompt = "Fixture prompt"
	pane._on_btn_chat_settings_pressed()
	await process_frame
	var label: Label = settings.find_child("SelectedModelLabel", true, false)
	check("native gear label names GLM", label != null and "GLM-5.3-Flash" in label.text)
	var control = settings.find_child("ModelReasoningSettings", true, false)
	check("model reasoning scene control exists", control != null)
	if control == null:
		return
	var gen = load("res://Scripts/Services/Providers/GenerationOptions.gd")
	var slider: HSlider = control.get_node("Effort")
	if OS.get_environment("MINERVA_MODEL_REASONING_FALSIFIER") == "1":
		var body: Dictionary = history.provider.build_chat_payload([])
		check("FALSIFIER: reverted ingestion hides slider", not slider.visible and control.levels.is_empty())
		check("FALSIFIER: reverted ingestion omits reasoning field", body.success and not body.payload.has("reasoning_effort"))
		settings.hide()
		return
	check("GLM slider stops are native low/high/max with high default", control.levels == ["low", "high", "max"] and control.default_effort == "high" and slider.visible and slider.value == 1)
	check("native default is marked", "high (default)" in control.get_node("Levels").text)
	slider.value = 2
	check("moving slider to non-default Max persists the model choice", gen.saved_for(history.provider).get("reasoning_effort") == "max")
	var classic: Dictionary = history.provider.build_chat_payload([{"role": "user", "content": "fixture"}])
	check("gear choice reaches classic native request", classic.success and classic.payload.get("reasoning_effort") == "max")
	if classic.success:
		var input: Dictionary = history.provider._job_input(classic.payload, history.provider.model_name)
		check("gear choice reaches chat/v1 input", input.get("reasoning_effort") == "max" and input.get("model") == "GLM-5.3-Flash")
	settings.hide()
	pane._on_new_chat()
	await process_frame
	var next_history = singleton.ChatList.back()
	check("new chat starts on GLM with model effort inherited", next_history.provider.model_name == "GLM-5.3-Flash" and gen.for_provider(next_history.provider).values.get("reasoning_effort") == "max")
	next_history.AgenticSystemPrompt = "Fixture prompt"
	# Simulate a preference saved before the advertised effort levels changed.
	var stored: Dictionary = singleton.config_file.get_value("Models", "GenerationOptions", {}).duplicate(true)
	stored[next_history.provider.get_model_settings_key()] = {"reasoning_effort": "retired-level"}
	singleton.config_file.set_value("Models", "GenerationOptions", stored)
	singleton.config_file.save(singleton._config_file_name)
	pane._on_btn_chat_settings_pressed()
	check("stale effort resets to model default with a visible notice", gen.for_provider(next_history.provider).values.get("reasoning_effort") == "high" and "unavailable" in control.get_node("Message").text and slider.value == 1)
	check("reset clears Core editor validation error", settings.find_child("ModelGenerationSettings", true, false).get_node("Error").text.is_empty())
	slider.value = 2
	var model_editor: Control = settings.find_child("ModelGenerationSettings", true, false)
	model_editor.get_node("Clear").pressed.emit()
	check("clearing model overrides refreshes reasoning to its default", gen.for_provider(next_history.provider).values.get("reasoning_effort") == "high" and slider.value == 1)
	var glm_key: String = next_history.provider.get_model_settings_key()
	var qwen_spec: Dictionary = spec.duplicate()
	qwen_spec.action_name = "Qwen3.8-Flash-Next"
	picker.switch_to_provider_set_for_service(service)
	check("Qwen can be selected while gear is open", picker.select_provider_spec(qwen_spec))
	picker.item_selected.emit(picker.selected)
	var qwen = next_history.provider
	check("open gear rebinds label and model editor to Qwen", "Qwen3.8" in label.text and settings.current_chat_tab_ref == next_history and control.levels == ["low", "medium", "xhigh"])
	check("Qwen slider orders native levels and marks its real default", control.levels == ["low", "medium", "xhigh"] and control.default_effort == "xhigh" and slider.value == 3)
	slider.value = 0
	var off: Dictionary = qwen.build_chat_payload([])
	check("Qwen Off disables thinking without an inactive effort", off.success and off.payload.get("enable_thinking") == false and not off.payload.has("reasoning_effort"))
	slider.value = 1
	var low: Dictionary = qwen.build_chat_payload([])
	check("Qwen effort re-enables thinking with the native value", low.success and low.payload.get("enable_thinking") == true and low.payload.get("reasoning_effort") == "low")
	check("open gear saves only the rebound Qwen key", gen.saved_for(qwen).get("reasoning_effort") == "low" and not singleton.config_file.get_value("Models", "GenerationOptions", {}).get(glm_key, {}).has("reasoning_effort"))
	next_history.Temperature = 0.3
	history.Temperature = 0.8
	pane.current_tab = singleton.ChatList.find(history)
	check("open gear tab change rebinds chat and model sections", settings.current_chat_tab_ref == history and "GLM" in label.text and control.levels == ["low", "high", "max"] and is_equal_approx(settings.get_node("%TempHSlider").value, 0.8))
	var plugin = load("res://Scripts/Services/Providers/PluginProvider.gd").new()
	plugin.display_name = "Fixture terminal"
	var previous = history.provider
	history.provider = plugin
	history.PassthroughMode = true
	check("open gear follows passthrough binding and hides reasoning", "Fixture terminal" in label.text and not slider.visible and settings.current_chat_tab_ref == history)
	history.provider = previous
	history.PassthroughMode = false
	plugin.free()
	settings.hide()
	var api = load("res://Scripts/Services/Providers/OpenAI/OpenAIProvider.gd").create_from_config({"model_name": "gpt-5.2"})
	control.configure(api)
	slider.value = 1
	check("native none is labelled None and sends native none", control.get_node("Selection").text == "None" and api.model_reasoning_params({}).values.get("reasoning_effort") == "none")
	api.free()
	var google = load("res://Scripts/Services/Providers/GoogleAi/GoogleProvider.gd").new()
	# The full runner shares preferences across suites; this case owns an
	# unchosen model preference and restores the preceding suite's choice.
	var prior_google: Dictionary = gen.saved_for(google)
	var inherited: Dictionary = gen.save_model(google, {})
	control.configure(google)
	check("unknown provider default is an initial inheritance stop", inherited.success and control.default_effort.is_empty() and slider.value == 0 and control.get_node("Selection").text == "Provider default" and google.model_reasoning_params({}).values.is_empty())
	check("provider-default fixture restores the preceding model preference", gen.save_model(google, prior_google).success and gen.saved_for(google) == prior_google)
	google.free()
