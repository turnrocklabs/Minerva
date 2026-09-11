class_name ProviderOptionButton
extends OptionButton

## Emitted when a provider is selected from the dropdown
signal provider_selected(provider: BaseProvider)

## Stores data for a single dropdown item
class ProviderItem:
	var display_name: String
	var id: int
	var tooltip: String
	var provider_script: Script  ## Script reference for standard providers
	var metadata: Variant  ## Core model_spec (legacy arrays accepted), plugin key, or null for standard
	
	func _init(name: String, item_id: int, script: Script = null, meta: Variant = null, tip: String = ""):
		display_name = name
		id = item_id
		provider_script = script
		metadata = meta
		tooltip = tip
	
	## Returns true if this represents a CoreProvider (service action wrapper)
	func is_core_provider() -> bool:
		return (metadata is Array and metadata.size() == 2) or (metadata is Dictionary and metadata.get("kind") == "core_action")

	## Returns true if this represents a plugin chat-provider entry
	## (chat-passthrough W1). Plugin items carry the registry key as a String
	## metadata and an id >= PLUGIN_PROVIDER_ID_BASE.
	func is_plugin_provider() -> bool:
		return metadata is String and id >= SingletonObject.PLUGIN_PROVIDER_ID_BASE

## Dictionary mapping set keys to provider item arrays
## Key: "default" (String) for standard providers, or Service object for service-specific sets
var _provider_sets: Dictionary = {}
var _current_set_key: Variant = "default"
## Services used to build the current combined set (for rebuilding after provider changes)
var _current_combined_services: Array = []

## Lock state (chat-passthrough W2): a locked chooser is disabled and pinned to
## one plugin entry — the chat's provider binding is contractual. When the bound
## registry entry vanishes the chooser keeps displaying the bound name with an
## " (offline)" suffix and NEVER auto-falls-back; W3's relaunch affordance owns
## recovery. Repopulation-driven selection changes are ignored while locked.
var _locked := false
var _locked_entry_key := ""
var _locked_display_name := ""

## Suffix shown on the locked entry when its registry entry is gone.
const OFFLINE_SUFFIX := " (offline)"


func _ready():
	_setup_default_provider_set()
	switch_to_provider_set("default")

	if Core:
		Core.service_selected.connect(_on_service_selected)

	# Rebuild dropdown when providers are enabled/disabled
	SingletonObject.provider_enabled_changed.connect(_on_provider_enabled_changed)
	ModelResolver.watch_core_changes(_on_core_catalog_changed)

	# Rebuild dropdown when plugin chat-provider entries change (chat-passthrough W1)
	var cpr = _get_chat_provider_registry()
	if cpr != null and cpr.has_signal("chat_providers_changed"):
		cpr.chat_providers_changed.connect(_on_chat_providers_changed)

	_load_saved_provider()


## Resolve the PluginChatProviderRegistry (may be null pre-init / headless).
func _get_chat_provider_registry():
	if "plugin_chat_provider_registry" in SingletonObject:
		return SingletonObject.plugin_chat_provider_registry
	return null


## Rebuild the default set + dropdown when plugin chat-provider entries change.
## Preserve a vanished selection by its stable key until it registers again.
func _on_chat_providers_changed() -> void:
	clear_combined_provider_sets()
	_on_core_catalog_changed()
	# Locked chooser (chat-passthrough W2): the binding is contractual. Re-pin the
	# locked entry (or its offline placeholder) and NEVER fall back to a default.
	if _locked:
		_ensure_locked_entry_displayed()
		return


#region Lock mechanism (chat-passthrough W2)

## Lock/unlock the chooser. Locking captures the currently-selected plugin entry
## as the contractual binding (use lock_to_entry when the entry key/name are
## known explicitly, e.g. on tab switch into a passthrough chat).
func set_locked(locked: bool, reason_tooltip: String = "") -> void:
	_locked = locked
	disabled = locked
	tooltip_text = reason_tooltip if locked else ""
	if locked:
		var idx := selected
		if idx >= 0 and idx < get_item_count() \
				and get_item_id(idx) >= SingletonObject.PLUGIN_PROVIDER_ID_BASE:
			var meta = get_item_metadata(idx)
			if meta is String:
				_locked_entry_key = meta
				_locked_display_name = get_item_text(idx).trim_suffix(OFFLINE_SUFFIX)
	else:
		_locked_entry_key = ""
		_locked_display_name = ""


func is_locked() -> bool:
	return _locked


## Lock the chooser onto an explicit plugin entry. Selects the live item when
## the entry is registered; otherwise shows an offline placeholder. Used by
## ChatPane when the active tab is a passthrough chat (the entry may already be
## gone — the bound name still must display).
func lock_to_entry(entry_key: String, display_name: String, reason_tooltip: String = "") -> void:
	_locked = true
	disabled = true
	tooltip_text = reason_tooltip
	_locked_entry_key = entry_key
	_locked_display_name = display_name
	_ensure_locked_entry_displayed()


## Pin the dropdown's visible selection to the locked entry. If the entry is no
## longer in the dropdown (registry entry vanished), append a display-only
## placeholder "<name> (offline)" and select it. select() does not emit
## item_selected, so no provider change is propagated.
func _ensure_locked_entry_displayed() -> void:
	if not _locked:
		return
	if not _locked_entry_key.is_empty():
		var idx := _find_item_index_by_key(_locked_entry_key)
		if idx != -1:
			select(idx)
			return
	# Entry gone (or key unknown) → offline placeholder, never a fallback.
	var placeholder_text := _locked_display_name + OFFLINE_SUFFIX
	var placeholder_idx := -1
	for i in range(get_item_count()):
		if get_item_text(i) == placeholder_text:
			placeholder_idx = i
			break
	if placeholder_idx == -1:
		var placeholder_id := SingletonObject.PLUGIN_PROVIDER_ID_BASE
		while get_item_index(placeholder_id) != -1:
			placeholder_id += 1
		add_item(placeholder_text, placeholder_id)
		placeholder_idx = get_item_count() - 1
		set_item_metadata(placeholder_idx, _locked_entry_key)
	select(placeholder_idx)

#endregion


## Handle provider enable/disable changes
func _on_provider_enabled_changed(_provider: SingletonObject.API_PROVIDER, _enabled: bool) -> void:
	_on_core_catalog_changed()


## Switches to the appropriate provider set for a single service
func switch_to_provider_set_for_service(service: Service):
	if service.client_id == Service.INTERNAL_CHAT_SERVICE_ID:
		switch_to_provider_set("default")
	else:
		switch_to_provider_set(service)


## Switches to provider set for multiple services (combines their providers)
func switch_to_provider_set_for_services(services: Array):
	if services.is_empty():
		switch_to_provider_set("default")
		_current_combined_services = []
		return

	var combined_key := _create_combined_key(services)

	# ALWAYS recreate - don't reuse cached combined sets
	var has_internal_chat := _contains_internal_chat_service(services)
	_create_combined_set(services, combined_key, has_internal_chat)

	_current_set_key = combined_key
	_current_combined_services = services
	_rebuild_dropdown()


## Switches to a specific provider set by key
func switch_to_provider_set(key: Variant):
	if not _provider_sets.has(key):
		if key is Service:
			_create_service_set(key)
		else:
			push_warning("Provider set '%s' does not exist" % str(key))
			return
	
	_current_set_key = key
	_rebuild_dropdown()


## Returns the currently selected provider instance
func get_selected_provider() -> BaseProvider:
	return _get_provider_from_id(get_selected_id())


## Returns a serializable spec for the currently selected provider/model entry.
func get_selected_provider_spec() -> Dictionary:
	if selected < 0 or selected >= get_item_count():
		return {}
	return get_item_provider_spec(selected)


## Returns a serializable spec for a given dropdown index.
func get_item_provider_spec(index: int) -> Dictionary:
	if index < 0 or index >= get_item_count():
		return {}

	var item_id := get_item_id(index)
	var metadata = get_item_metadata(index)
	if metadata is Dictionary:
		return metadata.duplicate(true)
	if metadata is Array and metadata.size() == 2:
		# Core action: the spec shape belongs to the one Core-action enumerator,
		# so the chooser, the MCP resolver and host.models.list_models all hand
		# out the same dictionary for the same action.
		var spec: Dictionary = CoreActionCatalog.spec_for(metadata[0], metadata[1])
		if not spec.is_empty():
			return spec

	# Plugin chat-provider entry (chat-passthrough W1): key-addressed so it
	# survives across rebuilds where the ordinal id changes.
	if item_id >= SingletonObject.PLUGIN_PROVIDER_ID_BASE and metadata is String:
		return {
			"kind": "plugin_provider",
			"entry_key": metadata,
		}

	if item_id >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
		return {
			"kind": "dynamic",
			"model_id": item_id,
		}

	if item_id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		return {
			"kind": "builtin",
			"model_id": item_id,
		}

	return {}


## Selects a provider/model entry matching the given serialized provider spec.
func select_provider_spec(spec: Dictionary) -> bool:
	for i in range(get_item_count()):
		if _provider_spec_matches(get_item_provider_spec(i), spec):
			select(i)
			return true
	return false


## Returns the dropdown index for a given provider (for programmatic selection)
func get_item_index_for_provider(provider: BaseProvider) -> int:
	var spec := ModelResolver.spec_for(provider)
	if not spec.is_empty():
		for index in range(get_item_count()):
			if _provider_spec_matches(get_item_provider_spec(index), spec):
				return index
		return -1
	for i in range(get_item_count()):
		var item_id := get_item_id(i)
		var metadata = get_item_metadata(get_item_index(item_id))

		if provider is CoreProvider and metadata is Array:
			var core_provider := provider as CoreProvider
			if metadata.size() >= 2 and metadata[1] == core_provider.action:
				return i

		# Dynamic models: match by model_name since they share a provider script
		elif item_id >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
			if provider.has_meta("dynamic_model_id") and int(provider.get_meta("dynamic_model_id")) == item_id:
				return i
			var dynamic_instance = SingletonObject.create_dynamic_provider(item_id)
			if dynamic_instance and dynamic_instance.model_name == provider.model_name:
				return i

		elif not provider is CoreProvider and item_id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
			var expected_script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id]
			if expected_script == provider.get_script():
				return i

	return -1


## Clears all combined provider sets (forces rebuild on next switch)
func clear_combined_provider_sets():
	var keys_to_remove := []
	for key in _provider_sets.keys():
		if key is String and key.begins_with("combined_"):
			keys_to_remove.append(key)
	
	for key in keys_to_remove:
		_provider_sets.erase(key)


## Clears a specific service's provider set
func clear_service_provider_set(service: Service):
	_provider_sets.erase(service)


#region Private Methods

## Creates the default provider set with all standard AI providers (filtered by enabled state)
func _setup_default_provider_set():
	var items: Array[ProviderItem] = []

	var sorted_keys: Array = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys().duplicate()
	# Remove HUMAN and TURNROCK from sorting - they'll be added at the end if enabled
	sorted_keys.erase(SingletonObject.API_MODEL_PROVIDERS.HUMAN)
	sorted_keys.erase(SingletonObject.API_MODEL_PROVIDERS.TURNROCK)

	sorted_keys.sort_custom(
		func(a, b):
			return _get_token_cost_for_key(a) < _get_token_cost_for_key(b)
	)

	# Add TURNROCK and HUMAN at the end (they're special/local providers)
	if SingletonObject.is_model_enabled(SingletonObject.API_MODEL_PROVIDERS.HUMAN):
		sorted_keys.append(SingletonObject.API_MODEL_PROVIDERS.HUMAN)

	for key in sorted_keys:
		# Skip models whose provider is disabled
		if not SingletonObject.is_model_enabled(key):
			continue

		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance: BaseProvider
		# Dynamic models need config applied via factory
		if key >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
			var dynamic_instance = SingletonObject.create_dynamic_provider(key)
			if dynamic_instance:
				instance = dynamic_instance
			else:
				instance = script.new()
		else:
			instance = script.new()
		var item := ProviderItem.new(instance.display_name, key, script, null, "")
		items.append(item)

	# Append plugin chat-provider entries (chat-passthrough W1). Each entry gets
	# a stable-within-rebuild id of PLUGIN_PROVIDER_ID_BASE + ordinal; the entry
	# key string is the metadata, used by _get_provider_from_id to build a
	# PluginProvider from the registry.
	var cpr = _get_chat_provider_registry()
	if cpr != null and cpr.has_method("list_entries"):
		var plugin_id_counter := SingletonObject.PLUGIN_PROVIDER_ID_BASE
		for entry in cpr.list_entries():
			var disp: String = str(entry.get("display_name", "Plugin"))
			var key_str: String = str(entry.get("key", ""))
			if key_str.is_empty():
				continue
			var pitem := ProviderItem.new(disp, plugin_id_counter, null, key_str, key_str)
			items.append(pitem)
			plugin_id_counter += 1

	for entry in CoreModelCatalog.list_models():
		items.append(ProviderItem.new(entry.display, 1000 + items.size(), null, entry.model_spec, "%s / %s" % [entry.model_spec.service_client_id, entry.model_spec.action_name]))
	_provider_sets["default"] = items


## Creates a provider set for a specific service (all its actions as CoreProviders)
func _create_service_set(service: Service):
	var items: Array[ProviderItem] = []
	for entry in CoreModelCatalog.list_models():
		if entry.model_spec.service_client_id == service.client_id:
			items.append(ProviderItem.new(entry.display, 1000 + items.size(), null, entry.model_spec, "%s / %s" % [entry.model_spec.service_client_id, entry.model_spec.action_name]))
	_provider_sets[service] = items


func _create_combined_set(services: Array, key: String, include_standard: bool):
	var items: Array[ProviderItem] = []
	if include_standard:
		for item: ProviderItem in _provider_sets.get("default", []):
			if not item.is_core_provider():
				items.append(item)
	var service_ids: Array[String] = []
	for service: Service in services:
		service_ids.append(service.client_id)
	for entry in CoreModelCatalog.list_models():
		if entry.model_spec.service_client_id in service_ids:
			items.append(ProviderItem.new(entry.display, 1000 + items.size(), null, entry.model_spec, "%s / %s" % [entry.model_spec.service_client_id, entry.model_spec.action_name]))
	_provider_sets[key] = items


func _on_core_catalog_changed() -> void:
	_setup_default_provider_set()
	if _current_set_key is Service:
		_create_service_set(_current_set_key)
	elif not _current_combined_services.is_empty():
		_create_combined_set(_current_combined_services, _current_set_key, _contains_internal_chat_service(_current_combined_services))
	_rebuild_dropdown()


func _rebuild_dropdown():
	# Store current selection before rebuilding
	var current_spec := get_selected_provider_spec()
	var previous_label := get_item_text(selected) if selected >= 0 else "TurnRock"

	clear()

	var items: Array = _provider_sets.get(_current_set_key, [])
	var separator_added := false

	for item: ProviderItem in items:
		if item.is_core_provider():
			var spec: Dictionary = item.metadata if item.metadata is Dictionary else CoreActionCatalog.spec_for(item.metadata[0], item.metadata[1])
			if not CoreModelCatalog.resolve(spec).success:
				continue
		# Skip disabled providers (filter at display time for all set types).
		# Plugin chat-provider entries are always shown — their lifecycle is the
		# registry, not the model-enabled config (chat-passthrough W1).
		if not item.is_core_provider() and not item.is_plugin_provider() \
				and not SingletonObject.is_model_enabled(item.id):
			continue

		# Add visual separator before first CoreProvider
		if item.is_core_provider() and not separator_added and get_item_count() > 0:
			add_separator()
			separator_added = true

		add_item(item.display_name, item.id)
		var item_index := get_item_count() - 1
		
		if item.metadata != null:
			set_item_metadata(item_index, item.metadata)
		
		if item.tooltip != "":
			set_item_tooltip(item_index, item.tooltip)
	
	if not current_spec.is_empty() and not select_provider_spec(current_spec):
		if current_spec.get("kind") == "core_action":
			_show_unavailable_core(current_spec, previous_label)
		elif current_spec.get("kind") == "plugin_provider":
			_show_plugin_selection(current_spec.entry_key, previous_label)


func _show_plugin_selection(key: String, label: String) -> void:
	var entry := ModelResolver.plugin_entry(key)
	var unavailable := entry.is_empty()
	var id := SingletonObject.PLUGIN_PROVIDER_ID_BASE
	while get_item_index(id) != -1:
		id += 1
	add_item(label.trim_suffix(" (unavailable)") + (" (unavailable)" if unavailable else ""), id)
	var index := item_count - 1
	set_item_metadata(index, key)
	set_item_disabled(index, unavailable)
	set_item_tooltip(index, "Plugin chat entry is not registered: %s" % key if unavailable else key)
	select(index)


func _show_unavailable_core(spec: Dictionary, label: String) -> void:
	var result := CoreModelCatalog.resolve(spec)
	add_item(label.trim_suffix(" (unavailable)") + " (unavailable)", 999)
	var index := item_count - 1
	set_item_metadata(index, spec.duplicate(true))
	set_item_disabled(index, true)
	set_item_tooltip(index, result.get("error_message", "Model unavailable"))
	select(index)


## Converts dropdown item ID back to actual provider instance
func _get_provider_from_id(item_id: int) -> BaseProvider:
	if item_id == -1:
		return null

	var metadata = get_item_metadata(get_item_index(item_id))
	var provider: BaseProvider

	# Plugin chat-provider entry (chat-passthrough W1): metadata is the registry
	# key string. Must be checked BEFORE the dynamic-model branch because plugin
	# ids are >= DYNAMIC_MODEL_ID_BASE too.
	if item_id >= SingletonObject.PLUGIN_PROVIDER_ID_BASE and metadata is String:
		provider = _build_plugin_provider(metadata as String)
	# CoreProvider: metadata is [Service, Action]
	elif (metadata is Array and metadata.size() == 2) or (metadata is Dictionary and metadata.get("kind") == "core_action"):
		var spec: Dictionary = metadata if metadata is Dictionary else CoreActionCatalog.spec_for(metadata[0], metadata[1])
		provider = ModelResolver.create(spec).get("provider")
		if provider == null:
			provider = ModelResolver.restore_core(spec)
	# Dynamic model: use centralized factory
	elif item_id >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
		provider = SingletonObject.create_dynamic_provider(item_id)
	# Standard provider: use script from dictionary
	elif item_id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		provider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id].new()
	
	if provider:
		print("Selected provider: ", provider.model_name)
	
	return provider

## Build a PluginProvider from a registry entry key (chat-passthrough W1).
## A vanished entry remains an unavailable provider carrying the exact key.
func _build_plugin_provider(entry_key: String) -> BaseProvider:
	var result := ModelResolver.create({"kind": "plugin_provider", "entry_key": entry_key})
	return result.provider if result.success else ModelResolver.restore_plugin(entry_key)


## Returns the provider for a specific tab index
func get_provider_for_tab(tab: int) -> BaseProvider:
	if SingletonObject.ChatList.is_empty():
		return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[0].new()
	else:
		return SingletonObject.ChatList[tab].provider

## Old OpenRouter enum IDs (14-17) mapped to their api_model_id for migration
const _LEGACY_OR_IDS := {
	14: "z-ai/glm-4.7",
	15: "minimax/minimax-m2.1",
	16: "moonshotai/kimi-k2.5",
	17: "x-ai/grok-4.1-fast",
}

## Loads previously saved provider selection from config
func _load_saved_provider():
	var saved_spec: Variant = SingletonObject.get_config_file_value("Providers", "DefaultModelSpec")
	if saved_spec is Dictionary and saved_spec.get("kind") == "plugin_provider":
		if not select_provider_spec(saved_spec):
			_show_plugin_selection(str(saved_spec.get("entry_key", "")), str(saved_spec.get("entry_key", "Plugin")))
		return
	if saved_spec is Dictionary and saved_spec.get("kind") == "core_action":
		if not select_provider_spec(saved_spec):
			_show_unavailable_core(saved_spec, str(saved_spec.get("action_name", "TurnRock")))
		return
	if not SingletonObject.config_has_saved_section("Providers"):
		return

	var provider_id = SingletonObject.get_config_file_value("Providers", "DefaultProviderId")
	if provider_id == null:
		return

	# Migrate old OpenRouter enum IDs (14-17) to dynamic model IDs
	if provider_id in _LEGACY_OR_IDS:
		var api_model_id: String = _LEGACY_OR_IDS[provider_id]
		var config: Dictionary = SingletonObject.openrouter_model_manager.get_model_by_api_id(api_model_id)
		if not config.is_empty():
			provider_id = config["id"]
			SingletonObject.save_to_config_file("Providers", "DefaultProviderId", provider_id)

	# Plugin chat-provider selections persist a stable KEY string alongside the
	# ordinal int, because the ordinal (PLUGIN_PROVIDER_ID_BASE + registration
	# order) is unstable across boots and can silently restore the WRONG entry.
	# When a key is present, resolve it to the CURRENT ordinal; absent key →
	# fall through to the int path (old configs / non-plugin selections).
	if int(provider_id) >= SingletonObject.PLUGIN_PROVIDER_ID_BASE:
		var saved_key = SingletonObject.get_config_file_value("Providers", "DefaultProviderKey")
		if saved_key != null and str(saved_key) != "":
			var key_index := _find_item_index_by_key(str(saved_key))
			if key_index != -1:
				select(key_index)
				return
			_show_plugin_selection(str(saved_key), str(saved_key))
			return

	var index := _find_item_index_by_id(provider_id)
	if index != -1:
		select(index)


## Finds the dropdown index whose plugin entry-key metadata matches (chat-
## passthrough W1). Returns -1 when no plugin item carries that key.
func _find_item_index_by_key(key: String) -> int:
	for i in range(get_item_count()):
		if get_item_id(i) >= SingletonObject.PLUGIN_PROVIDER_ID_BASE:
			var meta = get_item_metadata(i)
			if meta is String and meta == key:
				return i
	return -1


## Finds dropdown index by item ID
func _find_item_index_by_id(id: int) -> int:
	for i in range(get_item_count()):
		if get_item_id(i) == id:
			return i
	return -1


func _provider_spec_matches(left: Dictionary, right: Dictionary) -> bool:
	if left.is_empty() or right.is_empty():
		return false
	if str(left.get("kind", "")) != str(right.get("kind", "")):
		return false

	match str(left.get("kind", "")):
		"builtin", "dynamic":
			return int(left.get("model_id", -1)) == int(right.get("model_id", -1))
		"plugin_provider":
			return str(left.get("entry_key", "")) == str(right.get("entry_key", ""))
		"core_action":
			return str(left.get("service_client_id", "")) == str(right.get("service_client_id", "")) \
				and str(left.get("action_name", "")) == str(right.get("action_name", ""))

	return false


## Creates unique key for combination of services
func _create_combined_key(services: Array) -> String:
	var service_ids: Array[String] = []
	for service in services:
		service_ids.append(service.client_id)
	service_ids.sort()
	return "combined_" + "_".join(service_ids)


## Checks if internal chat service is in services array
func _contains_internal_chat_service(services: Array) -> bool:
	for service in services:
		if service.client_id == Service.INTERNAL_CHAT_SERVICE_ID:
			return true
	return false


## Gets the token cost for a model key (handles dynamic models from any provider)
func _get_token_cost_for_key(key: int) -> float:
	if key >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
		var manager = SingletonObject.get_model_manager_for_id(key)
		if manager:
			var config: Dictionary = manager.get_model(key)
			if not config.is_empty():
				return config.get("input_token_cost", 0.0) + config.get("output_token_cost", 0.0)
		return 0.0
	return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key].new().token_cost


## Truncates long action names for display
func _truncate_name(name_: String) -> String:
	if name_.length() > 17:
		return "%s..." % name_.left(20)
	return name_


## Handles dynamic service selection (adds CoreProviders)
func _on_service_selected(service: Service):
	if service.client_id == Service.INTERNAL_CHAT_SERVICE_ID:
		_add_service_to_default(service)
		if _current_set_key == "default":
			_rebuild_dropdown()
	else:
		_create_service_set(service)
		if _current_set_key is Service and _current_set_key == service:
			_rebuild_dropdown()


## Adds service actions to default set (for internal chat service)
func _add_service_to_default(_service: Service):
	_setup_default_provider_set()


## Signal handler for dropdown item selection
func _on_provider_option_button_item_selected(index: int):
	var item_id := get_item_id(index)
	SingletonObject.save_to_config_file("Providers", "DefaultModelSpec", get_item_provider_spec(index))
	# Persist a stable entry-KEY for plugin chat-provider selections so the
	# correct entry is restored next boot regardless of registration order. Clear
	# it otherwise so a later builtin/dynamic selection doesn't resurrect a stale
	# plugin key (chat-passthrough W1, key-based restore).
	if item_id >= SingletonObject.PLUGIN_PROVIDER_ID_BASE:
		var meta = get_item_metadata(index)
		if meta is String:
			SingletonObject.save_to_config_file("Providers", "DefaultProviderKey", meta)
	else:
		SingletonObject.save_to_config_file("Providers", "DefaultProviderKey", "")

	var provider := _get_provider_from_id(item_id)
	if provider:
		provider_selected.emit(provider)

#endregion
