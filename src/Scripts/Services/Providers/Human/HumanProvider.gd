class_name HumanProvider
extends BaseProvider

func _init():
	provider_name = "Human"

	model_name = "human"
	short_name = "HU"
	token_cost = 0 # so it ends up at the bottom of the list


func _parse_request_results(_response: RequestResults) -> BotResponse:
	var bot_response:= BotResponse.new()
	return bot_response


func generate_content(_prompt: Array[Variant], _additional_params: Dictionary={}):
	var item = _parse_request_results(null)
	
	SingletonObject.chat_completed.emit(item)

	return item


func wrap_memory(item: MemoryItem) -> Variant:
	if item.MemoryImage:
		return item.MemoryImage
	
	else:
		var output = "Given this background information:\n\n"
		output += "### Reference Information ###\n"
		output += item.Content
		output += "### End Reference Information ###\n\n"
		output += "Respond to the user's message: \n\n"
		return output


func Format(_chat_item: ChatHistoryItem) -> Variant:
	return {}

func estimate_tokens(_input) -> int:
	return 0


func estimate_tokens_from_prompt(_input: Array[Variant]):
	return 0


func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null
