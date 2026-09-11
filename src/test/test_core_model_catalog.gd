extends SceneTree
## Shared registration fixture, chat classification, availability and durable preferences.

var _failures := 0
var _passes := 0
var _completed := false

class ClientState extends RefCounted:
	var _connected := true

class CoreState extends Node:
	var services: Array[Service] = []
	var client := ClientState.new()
	var connecting := false
	var registered := true


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await process_frame
	await _scenario()
	_check(_completed, "whole model catalog scenario completed")
	print("Core model catalog: %d passed, %d failed" % [_passes, _failures])
	quit(1 if _failures else 0)


func _scenario() -> void:
	var catalog = load("res://Scripts/Services/Providers/Core/CoreModelCatalog.gd")
	var raw = load("res://Scripts/Services/Providers/Core/CoreActionCatalog.gd")
	var descriptor = load("res://Scripts/Services/Providers/Core/CoreModelDescriptor.gd")
	var preferences = load("res://Scripts/Services/Providers/Core/CoreModelPreferences.gd")
	var singleton := root.get_node("SingletonObject")
	var turnrock: int = singleton.provider_from_key("turnrock")
	var was_enabled: bool = singleton.is_provider_enabled(turnrock)
	singleton._enabled_providers[turnrock] = true
	var core := CoreState.new()
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://test/fixtures/model_chat_registration.json"))
	var service := Service.new(fixture.params)
	core.services = [service]
	var action := service.actions[0]
	_check(action.model_metadata.chat_model == true, "actual Service/Action parser retains public flag")
	_check(action.model_metadata.generation_options == fixture.params.actions[0].generation_options,
		"actual Service/Action parser retains complete generation schema")
	var parsed_options: Dictionary = descriptor.describe(service, action).generation_options
	_check(parsed_options.temperature.default == 0.7 and parsed_options.num_ctx.default == 40000,
		"backend defaults remain unchanged through parsing")
	_check(not parsed_options.num_gpu.has("default"), "GPU omission stays distinct from explicit CPU zero")
	var spec: Dictionary = raw.spec_for(service, action)
	var key: String = catalog.settings_key(spec)
	_check(JSON.parse_string(Marshalls.base64_to_utf8(key.trim_prefix("core_action:"))) == ["model-chat", "qwen3:8b"],
		"preference key decodes to exact ordered identity tuple")
	_check(catalog.settings_key({"kind": "core_action", "service_client_id": "a:b", "action_name": "c"}) !=
		catalog.settings_key({"kind": "core_action", "service_client_id": "a", "action_name": "b:c"}), "tuple encoding avoids separator collisions")
	var renamed := spec.duplicate(true)
	renamed.service_name = "Renamed display"
	_check(catalog.settings_key(renamed) == key, "display name is not persistence identity")
	_check(catalog.settings_key({"kind": "core_action", "service_client_id": "", "action_name": "x"}).is_empty(), "empty identity refused")
	_check(catalog.list_models(core, singleton).size() == 2, "only concrete advertised models initially listed")
	_check(catalog.resolve(spec, core, singleton).success, "exact model spec resolves")
	var created: Dictionary = catalog.create_provider(spec, core, singleton)
	var provider = created.provider
	_check(provider.get_model_settings_key() == key, "provider preference reads use stable tuple key")
	var refused = await provider.generate_content([])
	_check(refused.get_meta("error_code", "") == "core_offline", "chat provider rechecks actual connection before invocation")
	provider.free()

	var generic := _service("gpu-node", "GPU", [{"name": "qwen3:8b", "topic": "gpu/chat",
		"output_parameters": {"choices": {}, "model": {}, "usage": {}}}])
	var other := _service("other-chat", service.name, [fixture.params.actions[0].duplicate(true)])
	core.services.append(generic)
	core.services.append(other)
	_check(raw.list_actions(core).size() == 4, "generic action catalog preserves every service operation")
	_check(catalog.list_models(core, singleton).size() == 3, "chat filter excludes chat-shaped generic GPU RPC")
	_check(catalog.resolve(raw.spec_for(generic, generic.actions[0]), core, singleton).error_code == "not_chat_model", "generic action refused by chat resolver")
	var generic_provider = raw.create_provider(generic.client_id, generic.actions[0].name, core)
	_check(generic_provider != null and not generic_provider._is_openai_compatible_service(), "generic provider remains usable without output-shape guessing")
	generic_provider.free()
	var entries: Array[Dictionary] = catalog.list_models(core, singleton, true)
	_check(entries[0].display == entries[2].display and entries[0].settings_key != entries[2].settings_key,
		"identical display labels retain distinct public identities")

	var legacy := _service("model-chat", "Legacy", [{"name": "legacy", "topic": "chat/legacy"}])
	_check(descriptor.describe(legacy, legacy.actions[0]).eligible, "only absent model-chat metadata gets legacy fallback")
	for flag in [false, null, 1, "true"]:
		legacy.actions[0] = Action.new({"name": "legacy", "topic": "chat/legacy", "chat_model": flag})
		_check(legacy.actions[0].model_metadata.has("chat_model") and not descriptor.describe(legacy, legacy.actions[0]).eligible,
			"present false/malformed flag suppresses legacy fallback: %s" % str(flag))
	var invalid: Dictionary = fixture.params.actions[0].duplicate(true)
	invalid.generation_options.temperature.default = NAN
	var invalid_action := Action.new(invalid)
	_check(not descriptor.describe(service, invalid_action).valid, "non-finite descriptor default refused")
	invalid.generation_options.temperature.default = 0
	invalid.generation_options.num_ctx.default = 4.5
	_check(not descriptor.describe(service, Action.new(invalid)).valid, "fractional integer descriptor default refused")
	invalid.generation_options.num_ctx.default = 4
	invalid.generation_options.num_gpu.default = 0
	_check(descriptor.describe(service, Action.new(invalid)).valid, "explicit temperature and GPU zero are valid")
	invalid.generation_options.extra_option = {"type": "number"}
	_check(not descriptor.describe(service, Action.new(invalid)).valid, "unknown option produces invalid-descriptor diagnostics")
	_check(descriptor.validate_options({"temperature": {"type": "number"}}).diagnostics.is_empty(), "optional bounds use canonical limits")
	_check(descriptor.validate_options({"temperature": {"type": "number"}}).options.temperature.maximum == 2, "normalized descriptor exposes effective bound")
	invalid.generation_options = null
	var malformed := _service("malformed", "Malformed", [invalid])
	core.services.append(malformed)
	var bad_spec: Dictionary = raw.spec_for(malformed, malformed.actions[0])
	_check(catalog.resolve(bad_spec, core, singleton).error_code == "invalid_model_descriptor", "malformed public model cannot resolve")

	# Raw true+false duplicate identity must not become unique after filtering.
	var duplicate_action: Dictionary = fixture.params.actions[0].duplicate(true)
	duplicate_action.chat_model = false
	var duplicate := _service(service.client_id, "Duplicate", [duplicate_action])
	core.services.append(duplicate)
	_check(catalog.resolve(spec, core, singleton).error_code == "model_ambiguous", "duplicate exact tuple refuses even when duplicate is ineligible")
	_check(raw.find_action(service.client_id, action.name, core).is_empty(), "generic resolver also never chooses first duplicate")
	core.services.erase(other)
	var duplicate_config := ConfigFile.new()
	duplicate_config.set_value("Models", "Contexts", {raw.display_for(service, action): 4096})
	var duplicate_path := "user://core-model-duplicate-test.cfg"
	var duplicate_migration: Dictionary = preferences.migrate(duplicate_config, duplicate_path, spec, catalog.list_models(core, singleton, true))
	_check(duplicate_migration.status == "blocked_ambiguous" and not duplicate_config.get_value("Models", "Contexts").has(key),
		"ineligible raw duplicate also blocks preference migration")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(duplicate_path))
	core.services.append(other)
	core.services.erase(duplicate)

	core.connecting = true
	_check(catalog.resolve(spec, core, singleton).error_code == "core_offline", "authentication in progress is not chat readiness")
	core.connecting = false
	core.registered = false
	_check(catalog.resolve(spec, core, singleton).error_code == "core_offline", "socket without registration is not ready")
	core.registered = true
	core.client._connected = false
	var unavailable: Dictionary = catalog.resolve(spec, core, singleton)
	_check(unavailable.error_code == "core_offline" and unavailable.model_spec == spec, "offline refusal preserves requested identity")
	_check(catalog.list_models(core, singleton).is_empty() and not catalog.list_models(core, singleton, true).is_empty(), "cached unavailable models remain discoverable separately")
	core.client._connected = true
	singleton._enabled_providers[turnrock] = false
	_check(catalog.resolve(spec, core, singleton).error_code == "provider_disabled", "chat toggle refuses selected model consistently")
	_check(raw.list_actions(core).size() == 5, "chat toggle leaves raw services available")
	singleton._enabled_providers[turnrock] = true
	_check(catalog.resolve(spec, core, singleton).success, "reconnection recovers exact selection")

	# Use a real temp config and reload it to prove markers and copied settings persist.
	var config := ConfigFile.new()
	var path := "user://core-model-migration-test.cfg"
	var display: String = raw.display_for(service, action)
	config.set_value("Models", "Timeouts", {display: 180.0})
	config.set_value("Models", "Contexts", {display: 8192})
	config.set_value("Models", "NumGpu", {display: 0})
	entries = catalog.list_models(core, singleton, true)
	var migrated: Dictionary = preferences.migrate(config, path, spec, entries)
	_check(migrated.status == "blocked_ambiguous", "ambiguous old display preferences never apply")
	var other_key: String = catalog.settings_key(raw.spec_for(other, other.actions[0]))
	_check(config.get_value("Models", "CoreActionMigrations").get(other_key) == "blocked_ambiguous",
		"ambiguity marker protects the other encountered identity before it is selected")
	_check(not config.get_value("Models", "Timeouts").has(key), "ambiguous migration leaves stable settings absent")
	core.services.erase(service)
	var other_migration: Dictionary = preferences.migrate(config, path, raw.spec_for(other, other.actions[0]), catalog.list_models(core, singleton, true))
	_check(other_migration.status == "blocked_ambiguous" and not config.get_value("Models", "Timeouts").has(other_key),
		"initially unselected identity stays blocked after its same-label peer vanishes")
	core.services.append(service)
	core.services.erase(other)
	migrated = preferences.migrate(config, path, spec, catalog.list_models(core, singleton, true))
	_check(migrated.status == "blocked_ambiguous", "later service disappearance cannot reactivate ambiguous legacy settings")
	config.clear()
	config.set_value("Models", "Timeouts", {display: 180.0, key: 300.0})
	config.set_value("Models", "Contexts", {display: 8192})
	config.set_value("Models", "NumGpu", {display: 0})
	migrated = preferences.migrate(config, path, spec, catalog.list_models(core, singleton, true))
	_check(migrated.status == "complete", "unambiguous legacy preferences migrate")
	var restored := ConfigFile.new()
	_check(restored.load(path) == OK, "migration persisted to disk")
	_check(restored.get_value("Models", "Timeouts")[key] == 300.0, "present stable preference never overwritten")
	_check(restored.get_value("Models", "Contexts")[key] == 8192 and restored.get_value("Models", "NumGpu")[key] == 0,
		"context and CPU-only GPU zero migrate")
	var contexts: Dictionary = restored.get_value("Models", "Contexts")
	contexts.erase(key)
	restored.set_value("Models", "Contexts", contexts)
	restored.save(path)
	preferences.migrate(restored, path, spec, catalog.list_models(core, singleton, true))
	_check(not restored.get_value("Models", "Contexts").has(key), "clearing new settings never reapplies legacy preferences")
	_check(restored.get_value("Models", "Contexts").has(display), "legacy entries retained for explicit reselection")
	config.clear()
	config.set_value("Models", "Timeouts", {display: 0})
	config.set_value("Models", "Contexts", {display: 0})
	config.set_value("Models", "NumGpu", {display: -1})
	preferences.migrate(config, path, spec, catalog.list_models(core, singleton, true))
	_check(not config.get_value("Models", "Timeouts").has(key) and not config.get_value("Models", "Contexts").has(key)
		and not config.get_value("Models", "NumGpu").has(key), "legacy omission sentinels remain omitted")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	singleton._enabled_providers[turnrock] = was_enabled
	core.free()
	_completed = true


func _service(id: String, label: String, actions: Array) -> Service:
	return Service.new({"client_id": id, "name": label, "description": label, "actions": actions})


func _check(ok: bool, label: String) -> void:
	if ok:
		_passes += 1
	else:
		_failures += 1
	print("%s: %s" % ["PASS" if ok else "FAIL", label])
