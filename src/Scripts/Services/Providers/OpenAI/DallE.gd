class_name DallE
extends BaseProvider



func _init():
	provider_name = "OpenAI"
	BASE_URL = "https://api.openai.com/v1/images"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI

	model_name = "dall-e-3"
	short_name = "D3"
	token_cost = 0


func _parse_request_results(response: RequestResults) -> BotResponse:
	var bot_response:= BotResponse.new()

	var data: Variant
	if response.http_request_result == HTTPRequest.RESULT_SUCCESS:
		# since the request was completed, construct the data
		data = JSON.parse_string(response.body.get_string_from_utf8())

		# if the request was successful, parse it to bot response
		if (response.response_code >= 200 and response.response_code <= 299):
			bot_response = to_bot_response(data)
		# otherwise extract the error
		else:
			
			if "error" in data:
				bot_response.error = data["error"]["message"]
			else:
				bot_response.error = "Unexpected error occured while generating the response"

	else:
		push_error("Invalid result. Response: %s", response.response_code)
		bot_response.error = "Unexpected error occured with HTTP Client. Code %s" % response.http_request_result
		return

	return bot_response


func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:

	# Just take the last prompt
	var request_body = {
		"model": model_name,
		"prompt": prompt.back(),
		"response_format": "b64_json",
	}

	request_body.merge(additional_params)

	var body_stringified: String = JSON.stringify(request_body)
	
	var response: RequestResults = await make_request(
		"%s/generations" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		["Authorization: Bearer %s" % API_KEY]
	)

	var item = _parse_request_results(response)
	
	SingletonObject.chat_completed.emit(item)

	return item

# {
#   "created": 1589478378,
#   "data": [
#     {
#       "revised_prompt": "...",
#       "url": "https://..."
#     },
#     {
#       "revised_prompt": "...",
#       "url": "https://..."
#     }
#   ]
# }

func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()

	# set the used provider so update model name
	response.provider = self

	response.image = Image.new()
	response.image.load_png_from_buffer(
		Marshalls.base64_to_raw(data["data"][0]["b64_json"])
	)

	response.image.set_meta("caption", data["data"][0].get("revised_prompt"))
	
	return response

func wrap_memory(list_memories: String) -> String:
	var output: String = "Given this background information:\n\n"
	output += "### Reference Information ###\n"
	output += list_memories
	output += "### End Reference Information ###\n\n"
	output += "Respond to the user's message: \n\n"
	return output


# When fomatting the message for the DALLE, just create a array of text prompts
# and we will use the last one
func Format(chat_item: ChatHistoryItem) -> Variant:
	var text: String = chat_item.InjectedNote + chat_item.Message if chat_item.InjectedNote else chat_item.Message

	return text


func estimate_tokens(_input: String) -> int:
	return 0

func estimate_tokens_from_prompt(_input: Array[Variant]) -> int:
	return 0
