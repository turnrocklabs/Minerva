class_name GoogleVertex
extends BaseProvider



class ContentPart:
	var text: String
	
	func _init(text_value: String):
		text = text_value

class ContentResponse:
	var parts: Array[ContentPart]
	var role: String
	
	func _init(parts_array: Array, role_value: String):
		parts = []
		for part_text in parts_array:
			parts.append(ContentPart.new(part_text))
		role = role_value

# Signals
signal stream_generate_content_response(response)
signal embed_content_response(response)
signal batch_embed_contents_response(response)
signal get_model_info_response(response)
signal list_models_response(response)
signal count_tokens_response(response)


func _init():
	provider_name = "Google"
	model_name = "Vertex"
	short_name = "GV"
	BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
	PROVIDER = SingletonObject.API_PROVIDER.GOOGLE


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

	# old code
	# var response_variant: Variant
	# var response: BotResponse = BotResponse.new()
	# if result == 0:
	# 	response_variant = JSON.parse_string(body.get_string_from_utf8())
	# 	response.FromVertex(response_variant)
	# else:
	# 	push_error("Invalid result.  Response: %s", response_code)
	# if url.find("generateContent") != - 1:
	# 	chat_completed.emit(response)
	# elif url.find("streamGenerateContent") != - 1:
	# 	stream_generate_content_response.emit(response)
	# elif url.find("embedContent") != - 1:
	# 	embed_content_response.emit(response)
	# elif url.find("batchEmbedContents") != - 1:
	# 	batch_embed_contents_response.emit(response)
	# elif url.find("models/") != - 1 and url.find(":") == - 1:
	# 	get_model_info_response.emit(response)
	# elif url.find("models") != - 1 and url.find(":") == - 1:
	# 	list_models_response.emit(response)
	# elif url.find("countTokens") != - 1:
	# 	count_tokens_response.emit(response)


# Generate Content
func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):
	var request_body = {
		"contents": prompt
	}

	request_body.merge(additional_params)

	var body_stringified: String = JSON.stringify(request_body)
	
	print(body_stringified)
	#body_stringified = '{"contents": [{"role":"user", "parts":[{"text":"what is a cat?"}]}]}'
	var response = await make_request("%s/models/gemini-1.0-pro:generateContent?key=%s" % [BASE_URL, API_KEY], HTTPClient.METHOD_POST, body_stringified)
	return response

# Stream Generate Content
func stream_generate_content(prompt: Array[Variant], additional_params: Dictionary={}):
	var request_body = {
		"contents": prompt
	}
	for key in additional_params:
		request_body[key] = additional_params[key]
	var response = await make_request("%s/models/gemini-pro:streamGenerateContent?key=%s" % [BASE_URL, API_KEY], HTTPClient.METHOD_POST, JSON.stringify(request_body))
	return response

# Embed Content
func embed_content(content: String, model: String="models/embedding-001"):
	var request_body = {
		"model": model,
		"content": {"parts": [{"text": content}]}
	}
	var response = await make_request("%s/%s:embedContent?key=%s" % [BASE_URL, model, API_KEY], HTTPClient.METHOD_POST, JSON.stringify(request_body))
	return response

# Batch Embed Contents
func batch_embed_contents(contents: Array, model: String="models/embedding-001"):
	var requests = []
	for content in contents:
		requests.append({
			"model": model,
			"content": {"parts": [{"text": content}]}
		})
	var request_body = {"requests": requests}
	var response = await make_request("%s/%s:batchEmbedContents?key=%s" % [BASE_URL, model, API_KEY], HTTPClient.METHOD_POST, JSON.stringify(request_body))
	return response

# Get Model Info
func get_model_info(model: String):
	var response = await make_request("%s/%s?key=%s" % [BASE_URL, model, API_KEY], HTTPClient.METHOD_GET)
	return response

# List Models
func list_models():
	var response = await make_request("%s/models?key=%s" % [BASE_URL, API_KEY], HTTPClient.METHOD_GET)
	return response

# Count Tokens
func count_tokens(content: String):
	var request_body = {
		"contents": [{"parts": [{"text": content}]}]
	}
	var response = await make_request("%s/models/gemini-pro:countTokens?key=%s" % [BASE_URL, API_KEY], HTTPClient.METHOD_POST, JSON.stringify(request_body))
	return response




## These functions are the Provider interface duck implimentation.

# Format handles formatting a single message in the content array to Google's Vertex format.
# google's single message in a history looks like this:
# {"role" : "user|model", "parts" : [{"text": "some text"}, {"inline_data": {"mime_type" :"image/jpeg", "data" : "base64 data"}] }"
func Format(chat:ChatHistoryItem) -> Variant:
	var role: String
	var parts: Array = []
	# If we have injected a note prepend it, otherwise jsut take the message
	var text: String = chat.InjectedNote + chat.Message if chat.InjectedNote else chat.Message


	if chat.Role == ChatHistoryItem.ChatRole.USER:
		role = "user"
	else:
		role = "model"
	
	parts.append({"text":text})
	if len(chat.Base64Data) > 0:
		var mime_type: String
		var data: String
		## figure out the mimetype
		if chat.Type == ChatHistoryItem.PartType.JPEG:
			mime_type = "image/jpeg"
			data = chat.Base64Data
			var inline_data = {"mime_type":mime_type, "data": data}
			parts.append(inline_data)
	
	## Serialize the message.
	var message_object = {"role": role, "parts": parts}
	return message_object
	
## Function:
# wrap_memory takes the output of formatting and sets up the text so that the LLM understands this is background information
func wrap_memory(list_memories:String) -> String:
	var output:String = "Given this background information:\n\n"
	output += "### Reference Information ###\n"
	output += list_memories
	output += "### End Reference Information ###\n\n"
	output += "Respond to the user's message: \n\n"
	return output
		


func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()

	## dictionary["candidates"]["content"]["parts"]
	var all_parts_concatenated: String = ""
	
	if "candidates" not in data:
		response.Error  = "An error occurred."

	for candidate in data["candidates"]:
		if "content" not in candidate:
			response.Error  = "Model refused to answer. %s" % candidate
			return
		var content = candidate["content"]
		for part in content["parts"]:
			for text in part["text"]:
				all_parts_concatenated += text
	
	## I might get back a JSON string because Google Vertex APIs have a bug
	## Where the result is an "instruct" formatted JSON object (even though Google uses different role words)
	var vertex_response_extractor = RegEx.new()
	var pattern = '^\\s*\\{.*\\}\\s*$' # Basic pattern to check for something starting with { and ending with }
	vertex_response_extractor.compile(pattern)

	var result = vertex_response_extractor.search(all_parts_concatenated)

	if result:
		# turn the JSON into a dictionary, then grab the text property.
		var parsed: Variant = JSON.parse_string(all_parts_concatenated)
		response.Error = parsed["parts"]["text"]
	else:
		response.Error = all_parts_concatenated

	return response