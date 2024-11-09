class_name ClaudeSonnet
extends BaseProvider

var system_prompt: String

func _init():
	provider_name = "Anthropic"
	BASE_URL = "https://api.anthropic.com/v1"
	PROVIDER = SingletonObject.API_PROVIDER.ANTHROPIC

	model_name = "claude-3.5-sonnet"
	short_name = "CS"
	token_cost = 1.5 / 1_000_000 # https://claude101.com/claude-3-5-sonnet/


func _parse_request_results(response: RequestResults) -> BotResponse:
	var bot_response:= BotResponse.new()

	if not response.success:
		bot_response.error = response.message
		return bot_response

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
				bot_response.error = "Unexpected error occurred while generating the response"

	else:
		push_error("Invalid result. Response: %s", response.response_code)
		bot_response.error = "Unexpected error occurred with HTTP Client. Code %s" % response.http_request_result
		return

	return bot_response


# https://docs.anthropic.com/en/api/messages
func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):
	var request_body = {
		"model": "claude-3-5-sonnet-20240620",
		"messages": prompt,
		"max_tokens": 4096,
		"system": system_prompt
	}

	request_body.merge(additional_params)
	
	var body_stringified: String = JSON.stringify(request_body)
	
	var response: RequestResults = await make_request(
		"%s/messages" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		[
			"Content-Type: application/json",
			"x-api-key: %s" % API_KEY,
			"anthropic-version: 2023-06-01",
		],
	)

	var item = _parse_request_results(response)
	
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


func Format(chat_item: ChatHistoryItem) -> Variant:

	var role: String

	match chat_item.Role:
		ChatHistoryItem.ChatRole.USER:
			role = "user"
		ChatHistoryItem.ChatRole.ASSISTANT:
			role = "assistant"
		ChatHistoryItem.ChatRole.SYSTEM:
			role = "system"
		ChatHistoryItem.ChatRole.MODEL:
			role = "assistant"

	# content can be a string, but also an array of dictionaries, to handle different media types
	# message and each note will be it's own dictionary
	var content: = [
		{
			"type": "text",
			"text": chat_item.Message
		},
	]

	# handle text and image notes
	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			content.append({
				"type": "text",
				"text": note
			})
		
		# if we have a image, encode it to base64 and send it as a b64 encoded image
		elif note is Image:
			content.append({
				"type": "image",
				"source": {
					"type": "base64",
					"media_type": "image/png",
					"data": Marshalls.raw_to_base64(note.save_png_to_buffer()),
				}
			})

	return {
		"role": role,
		"content": content
	}




func estimate_tokens(input) -> int:
	return roundi(input.get_slice_count(" ") * 1.335)


func estimate_tokens_from_prompt(input: Array[Variant]):
	var all_messages: Array[String] = []
	# get all user messages
	for msg: Dictionary in input:
		var content = msg.get("content")

		if content is String:
			all_messages.append(msg["content"])
		
		elif content is Array:
			for part: Dictionary in content:
				if part.get("type") == "text":
					all_messages.append(part.get("text"))
	
	return estimate_tokens("".join(all_messages))


func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null


# {
#   "content": [
#     {
#       "text": "Hi! My name is Claude.",
#       "type": "text"
#     }
#   ],
#   "id": "msg_013Zva2CMHLNnXjNJJKqJ2EF",
#   "model": "claude-3-5-sonnet-20240620",
#   "role": "assistant",
#   "stop_reason": "end_turn",
#   "stop_sequence": null,
#   "type": "message",
#   "usage": {
#     "input_tokens": 10,
#     "output_tokens": 25
#   }
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()
	
	# set the used provider so update model name
	response.provider = self

	# the id will be useful if we need to complete the response with second request
	response.id = data["id"]

	var finish_reason = data["stop_reason"]

	if finish_reason == "max_tokens":
		response.complete = false
	
	response.prompt_tokens = data["usage"]["input_tokens"]
	response.completion_tokens = data["usage"]["output_tokens"]

	# TODO: this could also be used tool, but since we don't use that yet, it should always be text
	response.text = data["content"][0]["text"]
	
	return response
