class_name CoreProvider
extends BaseProvider

var service: Service
var action: Action

func _init(service_: Service = null, action_: Action = null):
	service = service_
	action = action_

	provider_name = "TurnRock"
	PROVIDER = SingletonObject.API_PROVIDER.TURNROCK

	if action:
		model_name = "%s (%s)" % [service.name if service else "Core", action.name]
	
	short_name = service.name[0] if service else "C"
	
	token_cost = 0.000015


func _parse_request_results(response: Dictionary) -> BotResponse:
	var bot_response:= BotResponse.new()

	# { "cmd": "error", "entity_type": "core", "params": 
		# { "client_id": "1745160706.99", "error": "Request messages must include a \'data\' field in params", "request_id": "1745160715.808_2592814796" }, 
	# "topic": "etsu_service/chat" }

	var cmd: String = response.get("cmd")
	var params: Dictionary = response.get("params")


	if cmd == "error":
		bot_response.error = params.get("error", "Unknown Error")
		return bot_response

	if not params.has("result"):
		bot_response.error = params.get("error", "No 'data' field found in received data")
		push_error("%s has no 'data' field." % params)
		return bot_response

	bot_response.hcp_data = params["result"]

	return bot_response


func generate_content(prompt: Array[Variant], _additional_params: Dictionary={}):
	
	if not SingletonObject.preferences_popup.selected_action:
		var bot_response:= BotResponse.new()
		bot_response.error = "No service selected in preferences"
		return bot_response

	var msg = await Core.send_message(service, action, prompt.back()).receive()
	
	if not msg:
		var bot_response:= BotResponse.new()
		bot_response.error = "No response received"
		return bot_response

	print("\n\nRESPONSE:")
	print(msg)

	var item = _parse_request_results(msg)
	
	SingletonObject.chat_completed.emit(item)

	return item


# TODO: make other chat messages somehow be sent to the hcp request
# maybe a special field definition to mark it as "notes" or previous messages content...
func Format(chat_item: ChatHistoryItem) -> Variant:
	return chat_item.HcpData


func wrap_memory(item: MemoryItem) -> Variant:
	var output: String = "Given this background information:\n\n"
	output += "### Reference Information ###\n"
	output += item.Content
	output += "### End Reference Information ###\n\n"
	output += "Respond to the user's message: \n\n"
	return output

func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()
	
	# set the used provider so update model name
	response.provider = self

	# the id will be useful if we need to complete the response with second request
	response.id = data["id"]

	var finish_reason = data["choices"][0]["finish_reason"]

	if finish_reason == "length":
		response.complete = false
	
	response.prompt_tokens = data["usage"]["prompt_tokens"]
	response.completion_tokens = data["usage"]["completion_tokens"]

	response.text = data["choices"][0]["message"]["content"]
	
	return response


func estimate_tokens(_input) -> int:
	return 0


func estimate_tokens_from_prompt(_input: Array[Variant]):
	
	return estimate_tokens("")

	# var all_messages: Array[String] = []

	# get all user messages
	# for msg: Dictionary in input:
	# 	var content = msg.get("content")

	# 	if content is String:
	# 		all_messages.append(msg["content"])
		
	# 	elif content is Array:
	# 		for part: Dictionary in content:
	# 			if part.get("type") == "text":
	# 				all_messages.append(part.get("text"))
	

	# return estimate_tokens("".join(all_messages))


func continue_partial_response(_partial_chi: ChatHistoryItem):
	var chi = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	chi.Message = "finish"

	return chi
