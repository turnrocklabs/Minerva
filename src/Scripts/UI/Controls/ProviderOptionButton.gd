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

	Core.service_selected.connect(_on_hcp_service_selected)

func _on_item_selected(index: int):
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
	return get_provider_from_id(get_selected_id()) if selected != -1 else null

func _on_hcp_service_selected(service: Service, action: Action):
	add_separator()

	var idx: = item_count

	var item_name = "%s..." % service.name.left(20) if service.name.length() > 17 else service.name 

	add_item(item_name, idx)
	set_item_tooltip(idx, service.name)
	set_item_metadata(idx, [service, action])
	prints("added hcp item at index:", idx)
