class_name ProviderOptionButton
extends OptionButton

signal provider_selected(provider: BaseProvider)

func _ready():
	# populate the options button with avaivable model providers
	for key in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[key]
		var instance = script.new()
		add_item("%s" % instance.model_name, key)
	


func _on_item_selected(index: int):
	var item_id = get_item_id(index)

	var provider_object: BaseProvider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[item_id].new()

	provider_selected.emit(provider_object)

	# SingletonObject.Chats.set_provider(provider_object)
