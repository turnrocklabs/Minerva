class_name OpenAI
extends BaseProvider

const MODEL = "gpt-4o"



func _ready():
	super()
	BASE_URL = "https://api.openai.com"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI



func _on_request_completed(result, response_code, _headers, body, _http_request, _url):
	var bot_response: BotResponse
	var data: Variant
	if result == 0:
		data = JSON.parse_string(body.get_string_from_utf8())
		bot_response = to_bot_response(data)
	else:
		push_error("Invalid result. Response: %s", response_code)
		return
	
	# if data.get("object") == "chat.completion":
	chat_completed.emit(bot_response)



# https://platform.openai.com/docs/guides/text-generation/chat-completions-api
func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):

	var request_body = {
		"model": MODEL,
		"messages": prompt
	}

	request_body.merge(additional_params)
	
	var body_stringified: String = JSON.stringify(request_body)
	
	var response = await make_request(
		"%s/v1/chat/completions" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		["Authorization: Bearer %s" % API_KEY]
	)
	return response


func Format(chat_item: ChatHistoryItem) -> Variant:
	var role: String

	match chat_item.Role:
		ChatHistoryItem.ChatRole.USER:
			role = "user"
		ChatHistoryItem.ChatRole.ASSISTANT:
			role = "assistant"
		ChatHistoryItem.ChatRole.MODEL:
			role = "system"

	var text: String = chat_item.InjectedNote + chat_item.Message if chat_item.InjectedNote else chat_item.Message

	return {
		"role": role,
		"content": text
	}


func wrap_memory(list_memories: String) -> String:
	var output: String = "Given this background information:\n\n"
	output += "### Reference Information ###\n"
	output += list_memories
	output += "### End Reference Information ###\n\n"
	output += "Respond to the user's message: \n\n"
	return output

# {
#   "id": "chatcmpl-9LJ12Ijrr2MAwBtHQdO3xHMut1pAn",
#   "object": "chat.completion",
#   "created": 1714865012,
#   "model": "gpt-3.5-turbo-0125",
#   "choices": [
#     {
#       "index": 0,
#       "message": {
#         "role": "assistant",
#         "content": "Hello! How can I assist you today?"
#       },
#       "logprobs": null,
#       "finish_reason": "stop"
#     }
#   ],
#   "usage": {
#     "prompt_tokens": 8,
#     "completion_tokens": 9,
#     "total_tokens": 17
#   },
#   "system_fingerprint": "fp_3b956da36b"
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()
	
	if "error" in data:
		SingletonObject.ErrorDisplay("Error", data["error"]["message"])
		response.Error = data["error"]["message"]
		return response

	response.FullText = data["choices"][0]["message"]["content"]
	return response

