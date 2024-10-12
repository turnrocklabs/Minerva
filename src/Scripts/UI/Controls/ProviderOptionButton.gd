class_name ProviderOptionButton
extends OptionButton

signal provider_selected(provider: BaseProvider)

func _ready():
	# populate the options button with avaivable model providers
	
	# duplicate the array of provider keys
	var sorted_keys: = SingletonObject.API_MODEL_PROVIDER_SCRIPTS.keys().duplicate()

	# sort the provider keys by initializing the provider class and comparing the token_cost for each one of them
	sorted_keys.sort_custom(
		func(a: SingletonObject.API_MODEL_PROVIDERS, b: SingletonObject.API_MODEL_PROVIDERS):
			return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[a].new().token_cost < SingletonObject.API_MODEL_PROVIDER_SCRIPTS[b].new().token_cost
	)

	# display the sorted providers
	for key in sorted_keys:
		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance = script.new()
		add_item("%s" % instance.model_name, key)

func _on_item_selected(index: int):
	var item_id = get_item_id(index)

	var provider_object: BaseProvider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id].new()

	provider_selected.emit(provider_object)

	# SingletonObject.Chats.set_provider(provider_object)
