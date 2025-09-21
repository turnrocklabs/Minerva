class_name ProviderOptionButton
extends OptionButton

signal provider_selected(provider: BaseProvider)

# Dictionary to store different provider sets
# Key: Service object or "default" string
# Value: Array of provider data
var provider_sets: Dictionary = {}
var current_set_key: Variant = "default"

# Structure to hold provider item data
class ProviderItemData:
	var display_name: String
	var id: int
	var metadata: Variant
	var tooltip: String
	var provider_script: Script
	var is_core_provider: bool = false
	
	func _init(name: String, item_id: int, meta: Variant = null, tip: String = "", script: Script = null, core: bool = false):
		display_name = name
		id = item_id
		metadata = meta
		tooltip = tip
		provider_script = script
		is_core_provider = core

func _ready():
	# Initialize default provider set
	_setup_default_provider_set()
	
	# Set to show default providers
	switch_to_provider_set("default")
	
	# Connect to service selection for dynamic CoreProvider additions
	if Core:
		Core.service_selected.connect(_on_hcp_service_selected)
	
	# Load saved provider if exists
	if SingletonObject.config_has_saved_section("Providers"):
		var provider = SingletonObject.get_config_file_value("Providers", "DefaultProviderId")
		if provider != null:
			var index = _find_item_index_by_id(provider)
			if index != -1:
				select(index)

func _setup_default_provider_set():
	# Create default provider set with standard providers
	var default_providers: Array[ProviderItemData] = []
	
	# Get sorted provider keys (same logic as before)
	var sorted_keys: Array = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys().duplicate()
	sorted_keys.erase(SingletonObject.API_MODEL_PROVIDERS.HUMAN)
	sorted_keys.erase(SingletonObject.API_MODEL_PROVIDERS.TURNROCK)
	
	# Sort by token cost
	sorted_keys.sort_custom(
		func(a: SingletonObject.API_MODEL_PROVIDERS, b: SingletonObject.API_MODEL_PROVIDERS):
			return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[a].new().token_cost < SingletonObject.API_MODEL_PROVIDER_SCRIPTS[b].new().token_cost
	)
	
	sorted_keys.append(SingletonObject.API_MODEL_PROVIDERS.HUMAN)
	
	# Add standard providers to default set
	for key in sorted_keys:
		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance = script.new()
		var item_data = ProviderItemData.new(
			instance.display_name,
			key,
			null,
			"",
			script,
			false
		)
		default_providers.append(item_data)
	
	# Store the default provider set
	provider_sets["default"] = default_providers

func switch_to_provider_set_for_service(service: Service):
	"""Switch provider set based on a service - main method you'll use"""
	if service.client_id == Service.INTERNAL_CHAT_SERVICE_ID:
		switch_to_provider_set("default")
	else:
		switch_to_provider_set(service)

func switch_to_provider_set(key: Variant):
	"""Switch to a different provider set by key"""
	if not provider_sets.has(key):
		# If it's a service that doesn't have a set yet, create one
		if key is Service:
			_create_service_provider_set(key)
		else:
			push_warning("Provider set with key '%s' does not exist" % str(key))
			return
	
	current_set_key = key
	_rebuild_dropdown()

func _create_service_provider_set(service: Service):
	"""Create a provider set for a specific service with its actions"""
	var service_providers: Array[ProviderItemData] = []
	
	# Add core providers from this service's actions
	for action in service.actions:
		var item_name = action.name
		item_name = "%s..." % item_name.left(20) if item_name.length() > 17 else item_name 
		
		var provider_data = ProviderItemData.new(
			item_name,
			service_providers.size(),  # Use array index as ID
			[service, action],
			service.name,
			null,
			true
		)
		
		service_providers.append(provider_data)
	
	# Store the service provider set
	provider_sets[service] = service_providers

func get_current_provider_set() -> Array[ProviderItemData]:
	"""Get the currently active provider set"""
	if current_set_key and provider_sets.has(current_set_key):
		return provider_sets[current_set_key]
	return []

func _rebuild_dropdown():
	"""Rebuild the dropdown with the current provider set"""
	clear()
	
	var current_providers = get_current_provider_set()
	var separator_added = false
	
	for provider_data in current_providers:
		# Add separator before core providers if we have standard providers
		if provider_data.is_core_provider and not separator_added and get_item_count() > 0:
			add_separator()
			separator_added = true
		
		add_item(provider_data.display_name, provider_data.id)
		var item_index = get_item_count() - 1
		
		if provider_data.metadata != null:
			set_item_metadata(provider_data.id, provider_data.metadata)
		
		if provider_data.tooltip != "":
			set_item_tooltip(item_index, provider_data.tooltip)

func _on_hcp_service_selected(service: Service):
	"""Handle dynamic CoreProvider additions"""
	# If this is the internal chat service, add to default set
	if service.client_id == Service.INTERNAL_CHAT_SERVICE_ID:
		_add_service_actions_to_default(service)
	else:
		# Create or update service-specific provider set
		_create_service_provider_set(service)
	
	# Rebuild if we're currently showing this service's set
	if (service.client_id == Service.INTERNAL_CHAT_SERVICE_ID and current_set_key == "default") or (current_set_key is Service and current_set_key == service):
		_rebuild_dropdown()

func _add_service_actions_to_default(service: Service):
	"""Add service actions to the default provider set"""
	var default_providers = provider_sets["default"]
	
	for action in service.actions:
		# Check if action already exists
		if _action_exists_in_set(action, default_providers):
			continue
		
		var item_name = action.name
		item_name = "%s..." % item_name.left(20) if item_name.length() > 17 else item_name 
		
		var provider_data = ProviderItemData.new(
			item_name,
			default_providers.size(),
			[service, action],
			service.name,
			null,
			true
		)
		
		default_providers.append(provider_data)

func _action_exists_in_set(action, provider_set: Array[ProviderItemData]) -> bool:
	"""Check if an action already exists in a provider set"""
	for provider_data in provider_set:
		if provider_data.is_core_provider and provider_data.metadata is Array:
			if provider_data.metadata.size() >= 2 and provider_data.metadata[1] == action:
				return true
	return false

func _find_item_index_by_id(id: int) -> int:
	"""Find dropdown item index by ID"""
	for i in range(get_item_count()):
		if get_item_id(i) == id:
			return i
	return -1

func _on_provider_option_button_item_selected(index: int):
	var provider_object: BaseProvider = get_provider_from_id(get_item_id(index))
	if provider_object:
		provider_selected.emit(provider_object)

func get_provider_from_id(item_id: int) -> BaseProvider:
	if item_id == -1: 
		return null

	var provider_object: BaseProvider
	
	# Check if this is a core provider by looking at metadata
	var metadata = get_item_metadata(item_id)
	if metadata is Array:
		provider_object = CoreProvider.new.callv(metadata)
	else:
		# Standard provider from scripts
		if item_id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
			provider_object = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id].new()

	if provider_object:
		print("The result provider is: ", provider_object.model_name)

	return provider_object

func get_selected_provider() -> BaseProvider:
	return get_provider_from_id(get_selected_id())

func get_provider_for_tab(tab: int) -> BaseProvider:
	if SingletonObject.ChatList.is_empty():
		return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[0].new()
	else:
		return SingletonObject.ChatList[tab].provider

func get_item_index_for_provider(provider: BaseProvider) -> int:
	for i in range(get_item_count()):
		var item_id = get_item_id(i)
		var metadata = get_item_metadata(item_id)
		
		# Handle CoreProvider items (they have Array metadata)
		if metadata is Array and provider is CoreProvider:
			var core_provider = provider as CoreProvider
			if metadata.size() >= 2 and metadata[1] == core_provider.action:
				return i
		
		# Handle standard providers (they use enum IDs)
		elif not metadata is Array and not provider is CoreProvider:
			if item_id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
				var expected_script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id]
				if expected_script == provider.get_script():
					return i
	
	return -1
