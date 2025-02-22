### Title: GoogleAi
class_name GoogleAi
extends BaseProvider

var system_prompt: String

func _init():
	provider_name = "Google"
	BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
	PROVIDER = SingletonObject.API_PROVIDER.GOOGLE

	model_name = "gemini-2.0-flash-exp"
	short_name = "GV"
	token_cost = 0

func _parse_request_results(response: RequestResults) -> BotResponse:
	var bot_response := BotResponse.new()

	if not response.success:
		bot_response.error = response.message
		return bot_response

	var data: Variant
	if response.http_request_result == HTTPRequest.RESULT_SUCCESS:
		data = JSON.parse_string(response.body.get_string_from_utf8())
		if response.response_code >= 200 and response.response_code <= 299:
			bot_response = to_bot_response(data)
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


func generate_content(prompt: Array[Variant], additional_params: Dictionary = {}):

	var request_body = {
		"contents": prompt
	}

	request_body.merge(additional_params)
	
	var body_stringified: String = JSON.stringify(request_body)
	
	# Print full request body for debugging
	#print("Request Body: ", body_stringified)
	print("Sending request to: %s" % "%s/%s:generateContent?key=%s" % [BASE_URL, model_name, API_KEY])
	
	var response: RequestResults = await make_request(
		"https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s" % [model_name, API_KEY], 
		HTTPClient.METHOD_POST,
		body_stringified,
		[
			"Content-Type: application/json",
		],
	)

	var item = _parse_request_results(response)
	
	SingletonObject.chat_completed.emit(item)

	return item

func wrap_memory(item: MemoryItem) -> Variant:

	# Return either string for text notes or dictionary for image notes

	if item.Type == SingletonObject.note_type.IMAGE:
		return {
			"inline_data": {
				"mime_type": "image/png",
				"data": Marshalls.raw_to_base64(item.MemoryImage.save_png_to_buffer())
			}
		}
	elif item.Type == SingletonObject.note_type.VIDEO and SingletonObject.google_supported_video_formats.has(item.File.get_extension()):
		# item.Content only contains the file path for the video
		var file_content: = FileAccess.get_file_as_bytes(item.File)
		var video_mime: String = SingletonObject.google_supported_video_formats.get(item.File.get_extension())
		return {
			"inline_data": {
				"mime_type": video_mime,
				"data": Marshalls.raw_to_base64(file_content)
			}
		}
	elif item.Type == SingletonObject.note_type.AUDIO and SingletonObject.google_supported_audio_formats.has(item.File.get_extension()):
		var file_content = FileAccess.get_file_as_bytes(item.File)
		var audio_mime: String = SingletonObject.google_supported_audio_formats.get(item.File.get_extension())
		return {
			"inline_data": {
				"data": Marshalls.raw_to_base64(file_content),
				"mime_type": audio_mime
			}
		}
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
		ChatHistoryItem.ChatRole.SYSTEM:
			system_prompt = chat_item.Message
			return null
		ChatHistoryItem.ChatRole.ASSISTANT:
			role = "model"
		ChatHistoryItem.ChatRole.MODEL:
			role = "model"
	
	# text_notes will be added straight to the text that's passed as the prompt message
	var text_notes: = PackedStringArray()

	# image_notes should be formatted properly inside the wrap_memory method
	var image_notes: Array[Dictionary] = []

	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			text_notes.append(note)
		
		elif note is Dictionary:
			image_notes.append(note)


	var image_captions_array = chat_item.Images.map(func(img: Image): return img.get_meta("caption", "No caption."))
	var image_captions: String

	if not image_captions_array.is_empty():
		image_captions = "Image Caption: %s" % "\n".join(image_captions_array)


	var text = """
		%s
		%s
		%s
	""" % [image_captions, "\n".join(text_notes), chat_item.Message]

	text = text.strip_edges()

	var output = {
		"role": role,
		"parts": [
			{ "text": text }
		]
	}

	output["parts"].append_array(image_notes)
	return output

func estimate_tokens(input) -> int:
	return roundi(input.get_slice_count(" ") * 1.335)

func estimate_tokens_from_prompt(input: Array[Variant]):
	var all_messages: Array[String] = []

	for msg: Dictionary in input:
		for part in msg["parts"]:
			if "text" in part: all_messages.append(part["text"])
	
	return estimate_tokens("".join(all_messages))

func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null

func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()
	
	response.provider = self

	var candidate = (data["candidates"] as Array).pop_front()

	if not candidate:
		response.error = "No candidates"
		return

	if not "finishReason" in candidate:
		response.complete = false
	
	var content = candidate["content"]

	for part in content["parts"]:
		if "text" in part:
			response.text += "\n%s" % part["text"]

	response.prompt_tokens = data["usageMetadata"]["promptTokenCount"]
	response.completion_tokens = data["usageMetadata"]["candidatesTokenCount"]
	
	return response
