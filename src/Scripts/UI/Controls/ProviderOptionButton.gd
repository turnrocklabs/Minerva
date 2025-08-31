class_name ProviderOptionButton
extends OptionButton

signal provider_selected(provider: BaseProvider)

func _ready():
	# populate the options button with available model providers
	
	# duplicate the array of provider keys
	var sorted_keys: = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys().duplicate()

	# we'll add the human provider at the bottom
	sorted_keys.erase(SingletonObject.API_MODEL_PROVIDERS.HUMAN)
	sorted_keys.erase(SingletonObject.API_MODEL_PROVIDERS.TURNROCK)

	# sort the provider keys by initializing the provider class and comparing the token_cost for each one of them
	sorted_keys.sort_custom(
		func(a: SingletonObject.API_MODEL_PROVIDERS, b: SingletonObject.API_MODEL_PROVIDERS):
			return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[a].new().token_cost < SingletonObject.API_MODEL_PROVIDER_SCRIPTS[b].new().token_cost
	)

	sorted_keys.append(SingletonObject.API_MODEL_PROVIDERS.HUMAN)

	# display the sorted providers
	for key in sorted_keys:
		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance = script.new()
		add_item("%s" % instance.display_name, key)

	if SingletonObject.config_has_saved_section("Providers"):
		var provider  = SingletonObject.get_config_file_value("Providers", "DefaultProviderId")
		if provider != null:
			select(get_item_index(provider))

	Core.service_selected.connect(_on_hcp_service_selected)

func _on_provider_option_button_item_selected(index: int):
	var provider_object: = get_provider_from_id(get_item_id(index))

	provider_selected.emit(provider_object)

	# SingletonObject.Chats.set_provider(provider_object)

func get_provider_from_id(item_id: int) -> BaseProvider:
	if item_id == -1: return null

	var provider_object: BaseProvider

	if get_item_metadata(item_id) is Array:
		provider_object = CoreProvider.new.callv(get_item_metadata(item_id))
	else:
		provider_object = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id].new()

	print("The result provider is: ", provider_object.model_name)

	return provider_object

func get_selected_provider() -> BaseProvider:
	return get_provider_from_id(get_selected_id())

var _core_actions: Array[Action] = []
func _on_hcp_service_selected(service: Service, action: Action):
	if _core_actions.is_empty():
		add_separator()

	if action in _core_actions:
		print("Slected action is already present")
		return

	var idx: = item_count

	var item_name: = action.name
	item_name = "%s..." % item_name.left(20) if item_name.length() > 17 else item_name 

	add_item(item_name, idx)
	set_item_tooltip(idx, service.name)
	set_item_metadata(idx, [service, action])

	_core_actions.append(action)
	prints("added hcp item at index:", idx)

# Returns the provider object for the given tab, handling both standard and CoreProvider types
func get_provider_for_tab(tab: int) -> BaseProvider:
	if SingletonObject.ChatList.is_empty():
		return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[0].new()
	else:
		return SingletonObject.ChatList[tab].provider

# Finds the dropdown item index that matches the given provider
func get_item_index_for_provider(provider: BaseProvider) -> int:
	for i in range(get_item_count()):
		var item_id = get_item_id(i)
		var metadata = get_item_metadata(item_id)
		
		# Handle CoreProvider items (they have Array metadata)
		if metadata is Array and provider is CoreProvider:
			var core_provider = provider as CoreProvider
			# Compare the action to see if it's the same CoreProvider
			if metadata.size() >= 2 and metadata[1] == core_provider.action:
				return i
		
		# Handle standard providers (they use enum IDs)
		elif not metadata is Array and not provider is CoreProvider:
			# Check if this item ID corresponds to the provider's script
			if item_id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
				var expected_script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id]
				if expected_script == provider.get_script():
					return i
	
	return -1  # Provider not found in dropdown
