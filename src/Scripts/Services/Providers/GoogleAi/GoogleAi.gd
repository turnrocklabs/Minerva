### Title: GoogleAi
class_name GoogleAi
extends BaseProvider

var system_prompt: String

const API_ENDPOINT = "us-central1-aiplatform.googleapis.com"
const PROJECT_ID = "utility-braid-124209"
const LOCATION_ID = "us-central1"
const MODEL_ID = "gemini-1.5-pro-001"

func _init():
	provider_name = "Google"
	BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
	PROVIDER = SingletonObject.API_PROVIDER.GOOGLE

	model_name = "gemini-1.5-flash"
	short_name = "GV"
	token_cost = 1.5 / 1_000_000 # https://claude101.com/claude-3-5-sonnet/

func _parse_request_results(response: RequestResults) -> BotResponse:
	var bot_response := BotResponse.new()

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

func imga() -> String:
	var img = Image.new()
	var load_result = img.load("res://fffffffff.png")
	
	if load_result != OK:
		push_error("Failed to load image")
		return ""
	
	# Resize image if necessary
	if img.get_width() > 1024 or img.get_height() > 1024:
		img.resize(1024, 1024)
	
	var img_data = img.save_png_to_buffer()
	# Ensure the image data is not empty before proceeding
	if img_data.is_empty():
		push_error("Image data is empty after encoding")
		return ""
	
	var encoded_data = Marshalls.variant_to_base64(img_data)
	
	return encoded_data

func generate_content(prompt: Array[Variant], additional_params: Dictionary = {}):
	var image_data = imga()
	if image_data == "":
		push_error("Failed to encode image")
		return

	var request_body = {
		"contents": [
			{
				"parts": [
					{"text": system_prompt},
					{
						"inline_data": {
							"mime_type": "image/png",
							"data": image_data
						}
					}
				]
			}
		]
	}

	request_body.merge(additional_params)
	
	var body_stringified: String = JSON.stringify(request_body)
	
	# Print full request body for debugging
	print("Request Body: ", body_stringified)
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

func wrap_memory(list_memories: String) -> String:
	var output: String = "Given this background information:\n\n"
	output += "### Reference Information ###\n"
	output += list_memories
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
	
	var image_captions_array = chat_item.Images.map(func(img: Image): return img.get_meta("caption", "No caption."))
	var image_captions: String

	if not image_captions_array.is_empty():
		image_captions = "Image Caption: %s" % "\n".join(image_captions_array)

	var text = """
		%s
		%s
		%s
	""" % [image_captions, chat_item.InjectedNote, chat_item.Message]

	text = text.strip_edges()

	return {
		"role": role,
		"parts": [
			{
				"text": text
			}
		]
	}

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
