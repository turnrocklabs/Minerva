class_name ChatGPTBase
extends BaseProvider


# Change the `model_name` and `short_name` in _ready function

func _init():
	provider_name = "OpenAI"
	BASE_URL = "https://api.openai.com"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI


func _parse_request_results(response: RequestResults) -> ChatHistoryItem:
	var item:= ChatHistoryItem.new()

	var data: Variant
	if response.http_request_result == HTTPRequest.RESULT_SUCCESS:
		# since the request was completed, construct the data
		data = JSON.parse_string(response.body.get_string_from_utf8())

		# if the request was successful, parse it to bot response
		if (response.response_code >= 200 and response.response_code <= 299):
			item = to_history_item(data)
		# otherwise extract the error
		else:
			
			if "error" in data:
				item.Error = data["error"]["message"]
			else:
				item.Error = "Unexpected error occured while generating the response"

	else:
		push_error("Invalid result. Response: %s", response.response_code)
		item.Error = "Unexpected error occured with HTTP Client. Code %s" % response.http_request_result
		return
	
	return item


# https://platform.openai.com/docs/guides/text-generation/chat-completions-api
func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):

	var request_body = {
		"model": model_name,
		"messages": prompt,
		# "max_tokens": 5,
	}

	request_body.merge(additional_params)
	
	var body_stringified: String = JSON.stringify(request_body)
	
	var response: RequestResults = await make_request(
		"%s/v1/chat/completions" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		["Authorization: Bearer %s" % API_KEY]
	)

	var item = _parse_request_results(response)
	
	chat_completed.emit(item)

	return item


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
func to_history_item(data: Variant) -> ChatHistoryItem:
	var item = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.MODEL)
	
	# set the used provider so update model name
	item.provider = SingletonObject.Chats.provider

	# the id will be useful if we need to complete the response with second request
	item.Id = data["id"]

	var finish_reason = data["choices"][0]["finish_reason"]

	if finish_reason == "length":
		item.Complete = false

	item.Message = data["choices"][0]["message"]["content"]
	
	return item

