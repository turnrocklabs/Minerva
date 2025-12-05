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
	var metadata: Variant  ## [Service, Action] array for CoreProviders, null for standard
	
	func _init(name: String, item_id: int, script: Script = null, meta: Variant = null, tip: String = ""):
		display_name = name
		id = item_id
		provider_script = script
		metadata = meta
		tooltip = tip
	
	## Returns true if this represents a CoreProvider (service action wrapper)
	func is_core_provider() -> bool:
		return metadata is Array and metadata.size() == 2

## Dictionary mapping set keys to provider item arrays
## Key: "default" (String) for standard providers, or Service object for service-specific sets
var _provider_sets: Dictionary = {}
var _current_set_key: Variant = "default"


func _ready():
	_setup_default_provider_set()
	switch_to_provider_set("default")
	
	if Core:
		Core.service_selected.connect(_on_service_selected)
	
	_load_saved_provider()


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
		return
	
	var combined_key := _create_combined_key(services)
	
	# ALWAYS recreate - don't reuse cached combined sets
	var has_internal_chat := _contains_internal_chat_service(services)
	_create_combined_set(services, combined_key, has_internal_chat)
	
	_current_set_key = combined_key
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


## Returns the dropdown index for a given provider (for programmatic selection)
func get_item_index_for_provider(provider: BaseProvider) -> int:
	for i in range(get_item_count()):
		var item_id := get_item_id(i)
		var metadata = get_item_metadata(get_item_index(item_id))
		
		if provider is CoreProvider and metadata is Array:
			var core_provider := provider as CoreProvider
			if metadata.size() >= 2 and metadata[1] == core_provider.action:
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

## Creates the default provider set with all standard AI providers
func _setup_default_provider_set():
	var items: Array[ProviderItem] = []
	
	var sorted_keys: Array = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys().duplicate()
	sorted_keys.erase(SingletonObject.API_MODEL_PROVIDERS.HUMAN)
	sorted_keys.erase(SingletonObject.API_MODEL_PROVIDERS.TURNROCK)
	
	sorted_keys.sort_custom(
		func(a, b):
			return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[a].new().token_cost < \
				   SingletonObject.API_MODEL_PROVIDER_SCRIPTS[b].new().token_cost
	)
	
	sorted_keys.append(SingletonObject.API_MODEL_PROVIDERS.HUMAN)
	
	for key in sorted_keys:
		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance = script.new()
		var item := ProviderItem.new(instance.display_name, key, script, null, "")
		items.append(item)
	
	_provider_sets["default"] = items


## Creates a provider set for a specific service (all its actions as CoreProviders)
func _create_service_set(service: Service):
	var items: Array[ProviderItem] = []
	
	var item_id := 1000
	for action in service.actions:
		var item_name := _truncate_name(action.name)
		var item := ProviderItem.new(item_name, item_id, null, [service, action], service.name)
		items.append(item)
		item_id += 1
	
	_provider_sets[service] = items


## Creates a combined set from multiple services
func _create_combined_set(services: Array, key: String, include_standard: bool):
	var items: Array[ProviderItem] = []
	
	# Include standard providers if internal chat service is present
	if include_standard:
		var default_items: Array = _provider_sets.get("default", [])
		for item in default_items:
			if not item.is_core_provider():
				var copy := ProviderItem.new(item.display_name, item.id, item.provider_script, null, item.tooltip)
				items.append(copy)
	
	# Add all service actions as CoreProviders
	var next_id := 1000
	for service in services:
		for action in service.actions:
			if _action_exists(action, items):
				continue
			
			var item_name := _truncate_name(action.name)
			var item := ProviderItem.new(item_name, next_id, null, [service, action], service.name)
			items.append(item)
			next_id += 1
	
	_provider_sets[key] = items


func _rebuild_dropdown():
	# Store current selection before rebuilding
	var current_provider = get_selected_provider()
	
	clear()
	
	var items: Array = _provider_sets.get(_current_set_key, [])
	var separator_added := false
	
	for item: ProviderItem in items:
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
	
	# Restore previous selection if it still exists
	if current_provider:
		var provider_index = get_item_index_for_provider(current_provider)
		if provider_index != -1:
			select(provider_index)
		


## Converts dropdown item ID back to actual provider instance
func _get_provider_from_id(item_id: int) -> BaseProvider:
	if item_id == -1:
		return null

	var metadata = get_item_metadata(get_item_index(item_id))
	var provider: BaseProvider

	# CoreProvider: metadata is [Service, Action]
	if metadata is Array and metadata.size() == 2:
		provider = CoreProvider.new.callv(metadata)
	# Standard provider: use script from dictionary
	elif item_id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		provider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id].new()
	
	if provider:
		print("Selected provider: ", provider.model_name)
	
	return provider

## Returns the provider for a specific tab index
func get_provider_for_tab(tab: int) -> BaseProvider:
	if SingletonObject.ChatList.is_empty():
		return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[0].new()
	else:
		return SingletonObject.ChatList[tab].provider

## Loads previously saved provider selection from config
func _load_saved_provider():
	if not SingletonObject.config_has_saved_section("Providers"):
		return
	
	var provider_id = SingletonObject.get_config_file_value("Providers", "DefaultProviderId")
	if provider_id == null:
		return

	var index := _find_item_index_by_id(provider_id)
	if index != -1:
		select(index)


## Finds dropdown index by item ID
func _find_item_index_by_id(id: int) -> int:
	for i in range(get_item_count()):
		if get_item_id(i) == id:
			return i
	return -1


## Creates unique key for combination of services
func _create_combined_key(services: Array) -> String:
	var service_ids: Array[String] = []
	for service in services:
		service_ids.append(service.client_id)
	service_ids.sort()
	return "combined_" + "_".join(service_ids)


## Checks if action already exists in items array
func _action_exists(action: Action, items: Array) -> bool:
	for item: ProviderItem in items:
		if item.is_core_provider() and item.metadata[1] == action:
			return true
	return false


## Checks if internal chat service is in services array
func _contains_internal_chat_service(services: Array) -> bool:
	for service in services:
		if service.client_id == Service.INTERNAL_CHAT_SERVICE_ID:
			return true
	return false


## Truncates long action names for display
func _truncate_name(name: String) -> String:
	if name.length() > 17:
		return "%s..." % name.left(20)
	return name


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
func _add_service_to_default(service: Service):
	var default_items: Array = _provider_sets["default"]
	
	var next_id := 1000
	# Find the highest CoreProvider ID already in default
	for item in default_items:
		if item.is_core_provider() and item.id >= next_id:
			next_id = item.id + 1

	for action in service.actions:
		if _action_exists(action, default_items):
			continue
		
		var item_name := _truncate_name(action.name)
		var item := ProviderItem.new(item_name, next_id, null, [service, action], service.name)
		default_items.append(item)
		next_id += 1


## Signal handler for dropdown item selection
func _on_provider_option_button_item_selected(index: int):
	var provider := _get_provider_from_id(get_item_id(index))
	if provider:
		provider_selected.emit(provider)

#endregion
