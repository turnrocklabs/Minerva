class_name OpenAIImageProvider
extends BaseProvider
## Consolidated OpenAI image generation provider.
## Supports DALL-E 3, GPT-Image-1, and GPT-Image-1.5

## Prompt character limit varies by model
var prompt_limit: int = 4000


func _init():
	provider_name = "OpenAI Images"
	BASE_URL = "https://api.openai.com/v1/images"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI

	# Default model - subclasses override these
	model_name = "dall-e-3"
	short_name = "DE3"
	token_cost = 0.04  # Fixed cost per image


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
			if data != null and "error" in data and data["error"] is Dictionary and "message" in data["error"]:
				bot_response.error = data["error"]["message"]
			elif data != null and "message" in data:
				bot_response.error = data["message"]
			else:
				bot_response.error = "Unexpected error occurred. HTTP Code: %s" % response.response_code
	else:
		push_error("Invalid HTTP result. Response Code: %s, HTTP Client Result: %s" % [response.response_code, response.http_request_result])
		bot_response.error = "Unexpected error occurred with HTTP Client. Code %s" % response.http_request_result

	return bot_response


func generate_content(prompt_array: Array[Variant], additional_params: Dictionary = {}) -> BotResponse:
	var current_prompt_text: String = ""
	if not prompt_array.is_empty() and prompt_array.back() is Dictionary and "text" in prompt_array.back():
		current_prompt_text = str(prompt_array.back()["text"])

	if current_prompt_text.is_empty():
		var err_response := BotResponse.new()
		err_response.error = "Cannot generate image: Prompt is empty."
		SingletonObject.chat_completed.emit(err_response)
		return err_response

	var request_body: Dictionary = {
		"model": model_name,
		"prompt": current_prompt_text.left(prompt_limit),
		"response_format": "b64_json",
	}

	request_body.merge(additional_params)

	var response: RequestResults = await make_request(
		"%s/generations" % BASE_URL,
		HTTPClient.METHOD_POST,
		JSON.stringify(request_body),
		[
			"Content-Type: application/json",
			"Authorization: Bearer %s" % API_KEY
		],
	)

	var item = _parse_request_results(response)
	SingletonObject.chat_completed.emit(item)
	return item


# Response format:
# {
#   "created": 1589478378,
#   "data": [
#     {
#       "revised_prompt": "...",
#       "b64_json": "..."
#     }
#   ]
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()
	response.provider = self

	if data == null or not "data" in data or not data["data"] is Array or data["data"].is_empty():
		response.error = "Failed to parse image data from API response."
		if data != null and "error" in data and "message" in data.error:
			response.error = "API Error: " + str(data.error.message)
		elif data != null and "message" in data:
			response.error = "API Error: " + str(data.message)
		push_error("OpenAIImageProvider: Invalid data structure for image response: ", data)
		return response

	var image_data_item = data["data"][0]
	if not image_data_item is Dictionary:
		response.error = "Invalid image data item format."
		push_error("OpenAIImageProvider: Image data item is not a dictionary: ", image_data_item)
		return response

	if "b64_json" in image_data_item:
		response.image = Image.new()
		var raw_bytes = Marshalls.base64_to_raw(image_data_item["b64_json"])
		var err = response.image.load_png_from_buffer(raw_bytes)
		if err != OK:
			response.error = "Failed to load image from b64_json buffer. Error code: %s" % err
			push_error("OpenAIImageProvider: Error loading PNG from buffer: ", err)
			response.image = null
			return response
	elif "url" in image_data_item:
		response.error = "Received image URL, but b64_json was expected."
		push_warning("OpenAIImageProvider: Received URL, but b64_json expected.")
		return response
	else:
		response.error = "No 'b64_json' or 'url' found in image data."
		push_error("OpenAIImageProvider: Missing image data in response item: ", image_data_item)
		return response

	if response.image:
		response.image.set_meta("caption", image_data_item.get("revised_prompt"))

	return response


func wrap_memory(item: Note) -> Variant:
	if item.type == Note.Type.TEXT:
		return (item.get_controls_container() as NoteTextControls).content

	else:
		push_warning("Tried to wrap memory but the given note type is not implemented")
		print_stack()

	return ""


func Format(chat_item: ChatHistoryItem) -> Variant:
	# Collect text notes
	var text_notes: = PackedStringArray()

	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			text_notes.append(note)

	# Wrap all text notes together once
	var notes_section := ""
	if not text_notes.is_empty():
		notes_section = "### Reference Information ###\n"
		notes_section += "\n\n".join(text_notes)
		notes_section += "\n### End Reference Information ###\n\n"

	# Combine notes section with user message
	var full_text := "%s%s" % [notes_section, chat_item.Message]
	full_text = full_text.strip_edges()

	return {
		"text": full_text,
		"images": chat_item.Images
	}


func estimate_tokens(_input: String) -> int:
	return 0


func estimate_tokens_from_prompt(_input_prompt_array: Array[Variant]):
	# Image generation has fixed cost per image, not based on tokens
	return 0.0


func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null


#region Form Data

func _generate_form_data_boundary() -> String:
	var crypto = Crypto.new()
	var random_bytes = crypto.generate_random_bytes(16)
	return '%s' % random_bytes.hex_encode()


func _construct_multipart_form_data(request_data: Dictionary, source_images: Array[Image], boundary: String, mask_image: Image = null) -> PackedByteArray:
	var body: = PackedByteArray()

	var filtered_request_data = request_data.duplicate()
	filtered_request_data.erase("image")
	filtered_request_data.erase("image[]")
	filtered_request_data.erase("mask")

	for key in filtered_request_data:
		_form_data_append_line(body, "--%s" % boundary)
		_form_data_append_line(body, 'Content-Disposition: form-data; name="%s"' % key)
		_form_data_append_line(body, '')
		_form_data_append_line(body, str(filtered_request_data[key]))

	var image_field_name = "image"
	if request_data.get("model", "") == "gpt-image-1" and source_images.size() > 1:
		image_field_name = "image[]"

	var image_idx = 0
	for img_to_send: Image in source_images:
		if img_to_send == null:
			push_warning("OpenAIImageProvider: A null image was passed to form data. Skipping.")
			continue

		var filename = "image_%s.png" % image_idx if source_images.size() > 1 else "image.png"

		_form_data_append_line(body, "--%s" % boundary)
		_form_data_append_line(body, 'Content-Disposition: form-data; name="%s"; filename="%s"' % [image_field_name, filename])
		_form_data_append_line(body, 'Content-Type: image/png')
		_form_data_append_line(body, '')
		_form_data_append_bytes(body, img_to_send.save_png_to_buffer())
		_form_data_append_line(body, '')
		image_idx += 1

	if mask_image != null:
		_form_data_append_line(body, "--%s" % boundary)
		_form_data_append_line(body, 'Content-Disposition: form-data; name="mask"; filename="mask.png"')
		_form_data_append_line(body, 'Content-Type: image/png')
		_form_data_append_line(body, '')
		_form_data_append_bytes(body, mask_image.save_png_to_buffer())
		_form_data_append_line(body, '')

	_form_data_append_line(body, "--%s--" % boundary)
	return body


func _form_data_append_line(buffer: PackedByteArray, line: String) -> void:
	buffer.append_array(line.to_ascii_buffer())
	buffer.append_array('\r\n'.to_ascii_buffer())


func _form_data_append_bytes(buffer: PackedByteArray, bytes_to_append: PackedByteArray) -> void:
	buffer.append_array(bytes_to_append)

#endregion Form Data


# ============================================================================
# Model Variants
# ============================================================================

## DALL-E 3: Standard quality image generation
class DallE3 extends OpenAIImageProvider:
	func _init():
		super()
		model_name = "dall-e-3"
		display_name = "DALL-E 3"
		short_name = "DE3"
		prompt_limit = 4000
		token_cost = 0.04  # Fixed cost per image


## GPT-Image-1: Advanced image generation with longer prompts
class GPTImage1 extends OpenAIImageProvider:
	func _init():
		super()
		model_name = "gpt-image-1"
		display_name = "GPT Image 1"
		short_name = "GI1"
		prompt_limit = 32000
		token_cost = 0.02


## GPT-Image-1.5: Latest image generation capabilities
class GPTImage15 extends OpenAIImageProvider:
	func _init():
		super()
		model_name = "gpt-image-1.5"
		display_name = "GPT Image 1.5"
		short_name = "GI15"
		prompt_limit = 32000
		token_cost = 0.03
