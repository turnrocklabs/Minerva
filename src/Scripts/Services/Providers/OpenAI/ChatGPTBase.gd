class_name ChatGPTBase
extends BaseProvider


# Change the `model_name` and `short_name` in _ready function

func _init():
	provider_name = "OpenAI"
	BASE_URL = "https://api.openai.com"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI


func _on_request_completed(result, response_code, _headers, body, _http_request, _url):
	var bot_response:= BotResponse.new()

	var data: Variant
	if result == HTTPRequest.RESULT_SUCCESS:
		# since the request was completed, construct the data
		data = JSON.parse_string(body.get_string_from_utf8())

		# if the request was successful, parse it to bot response
		if (response_code >= 200 and response_code <= 299):
			bot_response = to_bot_response(data)
		# otherwise extract the error
		else:
			
			if "error" in data:
				bot_response.Error = data["error"]["message"]
			else:
				bot_response.Error = "Unexpected error occured while generating the response"

	else:
		push_error("Invalid result. Response: %s", response_code)
		bot_response.Error = "Unexpected error occured with HTTP Client. Code %s" % result
		return
	
	chat_completed.emit(bot_response)


# https://platform.openai.com/docs/guides/text-generation/chat-completions-api
func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):

	var request_body = {
		"model": model_name,
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
	var response = BotResponse.new(self)

	response.FullText = data["choices"][0]["message"]["content"]
	return response
