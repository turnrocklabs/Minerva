class_name ProviderOptionButton
extends OptionButton

signal provider_selected(provider: BaseProvider)

func _ready():
	# populate the options button with available model providers
	
	# duplicate the array of provider keys
	var sorted_keys: = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys().duplicate()

	# we'll add the human provider at the bottom
	var human: = SingletonObject.API_MODEL_PROVIDERS.HUMAN
	sorted_keys.erase(human)

	# sort the provider keys by initializing the provider class and comparing the token_cost for each one of them
	sorted_keys.sort_custom(
		func(a: SingletonObject.API_MODEL_PROVIDERS, b: SingletonObject.API_MODEL_PROVIDERS):
			return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[a].new().token_cost < SingletonObject.API_MODEL_PROVIDER_SCRIPTS[b].new().token_cost
	)

	sorted_keys.append(human)

	# display the sorted providers
	for key in sorted_keys:
		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance = script.new()
		add_item("%s" % instance.display_name, key)

	# add special button for core services
	# add_item("Core", 999)

func _on_item_selected(index: int):
	var item_id = get_item_id(index)

	# if item_id == 999:
		
	# 	# SingletonObject.preferences_popup

	# 	return

	var provider_object: BaseProvider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id].new()

	provider_selected.emit(provider_object)

	# SingletonObject.Chats.set_provider(provider_object)
