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
	settings.hide()
	preferences.free()
	print("Results: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
