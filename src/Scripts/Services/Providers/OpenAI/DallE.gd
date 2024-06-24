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
			bot_response = await to_bot_response(data)
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
	}

	request_body.merge(additional_params)

	var body_stringified: String = JSON.stringify(request_body)
	
	var response: RequestResults = await make_request(
		"%s/generations" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		["Authorization: Bearer %s" % API_KEY]
	)

	var item = await _parse_request_results(response)
	
	SingletonObject.chat_completed.emit(item)

	return item

# {
#   "created": 1589478378,
#   "data": [
#     {
#       "url": "https://..."
#     },
#     {
#       "url": "https://..."
#     }
#   ]
# }

func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()
	
	# set the used provider so update model name
	response.provider = SingletonObject.Chats.provider

	response.image = await _download_image(data["data"][0]["url"])
	
	return response


func _download_image(url: String = "https://oaidalleapiprodscus.blob.core.windows.net/private/org-vsbxWIIUksxCuAv5S327SWcJ/user-qD2wsOQViEZT0rBMkt2Wm92p/img-bN5JIZhcLbGsa3RaQCMzJUjG.png?st=2024-06-23T14%3A23%3A51Z&se=2024-06-23T16%3A23%3A51Z&sp=r&sv=2023-11-03&sr=b&rscd=inline&rsct=image/png&skoid=6aaadede-4fb3-4698-a8f6-684d7786b067&sktid=a48cca56-e6da-484e-a814-9c849652bcb3&skt=2024-06-22T23%3A57%3A06Z&ske=2024-06-23T23%3A57%3A06Z&sks=b&skv=2023-11-03&sig=ir4UmOwtEuFixXH6mMVXHcn/fm4d5wUK21ZOYhJ%2B3Wk%3D") -> Image:
	
	var http_request = HTTPRequest.new()
	add_child(http_request)

	var http_error = http_request.request(url)
	if http_error != OK:
		print("An error occurred in the HTTP request.")
	
	var request_results: Array = await http_request.request_completed

	var results = RequestResults.from_request_response(request_results, http_request, url)

	var image: = Image.new()
	var err = image.load_png_from_buffer(results.body)
	if err != OK:
		push_error("Error (%s) while downloading image file from %s" % [error_string(err), url])
		return null

	return image


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

