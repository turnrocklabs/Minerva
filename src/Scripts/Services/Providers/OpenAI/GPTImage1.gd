class_name GPTImage1 extends BaseProvider

func _init():
	provider_name = "OpenAI"
	BASE_URL = "https://api.openai.com/v1/images"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI

	model_name = "gpt-image-1" # This class is specifically for gpt-image-1
	short_name = "I1"
	token_cost = 0.000005 # output 0.00004 40$ per 1 million


func _parse_request_results(response: RequestResults) -> BotResponse:
	var bot_response:= BotResponse.new()

	if not response.success:
		bot_response.error = response.message
		return bot_response

	var data: Variant
	if response.http_request_result == HTTPRequest.RESULT_SUCCESS:
		data = JSON.parse_string(response.body.get_string_from_utf8())

		if (response.response_code >= 200 and response.response_code <= 299):
			bot_response = to_bot_response(data)
		else:
			if data != null and "error" in data and data["error"] is Dictionary and "message" in data["error"]:
				bot_response.error = data["error"]["message"]
			elif data != null and "message" in data:
				bot_response.error = data["message"]
			else:
				bot_response.error = "Unexpected error occurred. HTTP Code: %s. Body: %s" % [response.response_code, response.body.get_string_from_utf8()]
	else:
		push_error("Invalid HTTP result. Response Code: %s, HTTP Client Result: %s" % [response.response_code, response.http_request_result])
		bot_response.error = "Unexpected error occurred with HTTP Client. Code %s" % response.http_request_result
		
	return bot_response


func generate_content(prompt_array: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
	# --- Prepare common request elements ---
	var current_prompt_text: String = ""
	if not prompt_array.is_empty() and prompt_array.back() is Dictionary and "text" in prompt_array.back():
		current_prompt_text = str(prompt_array.back()["text"])

	var request_body_params: Dictionary = { "model": model_name } # Default model for this provider
	if not current_prompt_text.is_empty():
		request_body_params["prompt"] = current_prompt_text
	
	request_body_params.merge(additional_params)

	current_prompt_text = str(request_body_params.get("prompt", ""))
	var model_to_use: String = str(request_body_params.get("model", model_name))

	# SCENARIO: New Generation from prompt
	if current_prompt_text.is_empty():
		var err_response:= BotResponse.new()
		err_response.error = "Cannot generate image: Prompt is empty."
		SingletonObject.chat_completed.emit(err_response)
		return err_response

	var generation_request_body: Dictionary = request_body_params.duplicate(true)
	generation_request_body["model"] = model_to_use
	
	if model_to_use == "gpt-image-1":
		generation_request_body["prompt"] = current_prompt_text.left(32000)
	elif model_to_use == "dall-e-3":
		generation_request_body["prompt"] = current_prompt_text.left(4000)
	elif model_to_use == "dall-e-2":
		generation_request_body["prompt"] = current_prompt_text.left(1000)
	
	var response: RequestResults = await make_request(
		"%s/generations" % BASE_URL,
		HTTPClient.METHOD_POST,
		JSON.stringify(generation_request_body),
		[
			"Content-Type: application/json",
			"Authorization: Bearer %s" % API_KEY
		],
	)

	var item = _parse_request_results(response)
	SingletonObject.chat_completed.emit(item)
	return item


func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()
	response.provider = self

	if data == null or not "data" in data or not data["data"] is Array or data["data"].is_empty():
		response.error = "Failed to parse image data from API response."
		if data != null and "error" in data and "message" in data.error:
			response.error = "API Error: " + str(data.error.message)
		elif data != null and "message" in data:
			response.error = "API Error: " + str(data.message)
		push_error("GPTImage1: Invalid data structure for image response: ", data)
		return response

	var image_data_item = data["data"][0]
	if not image_data_item is Dictionary:
		response.error = "Invalid image data item format."
		push_error("GPTImage1: Image data item is not a dictionary: ", image_data_item)
		return response

	if "b64_json" in image_data_item:
		response.image = Image.new()
		var raw_bytes = Marshalls.base64_to_raw(image_data_item["b64_json"])
		var err = response.image.load_png_from_buffer(raw_bytes)
		if err != OK:
			response.error = "Failed to load image from b64_json buffer. Error code: %s" % err
			push_error("GPTImage1: Error loading PNG from buffer: ", err)
			response.image = null
			return response
	elif "url" in image_data_item:
		response.error = "Received image URL, but b64_json was expected for gpt-image-1."
		push_warning("GPTImage1: Received URL, but b64_json expected. Image will not be loaded.")
		return response
	else:
		response.error = "No 'b64_json' or 'url' found in image data."
		push_error("GPTImage1: Missing image data in response item: ", image_data_item)
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


func estimate_tokens_from_prompt(input_prompt_array: Array[Variant]):
	input_prompt_array = input_prompt_array
	# Placeholder - Proper gpt-image-1 cost estimation needed based on operation, size, quality etc.
	return 0.0


func estimate_tokens(_input: String) -> int:
	return 0 


func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null
	
#region Form Data

func _generate_form_data_boundary() -> String:
	var crypto = Crypto.new()
	var random_bytes = crypto.generate_random_bytes(16)
	return '%s' % random_bytes.hex_encode()

# Modified to handle an array of source_images and an optional mask_image.
func _construct_multipart_form_data(request_data: Dictionary, source_images: Array[Image], boundary: String, mask_image: Image = null) -> PackedByteArray:
	var body: = PackedByteArray()

	var filtered_request_data = request_data.duplicate()
	filtered_request_data.erase("image") # Field name for single image, we use "image[]" for array
	filtered_request_data.erase("image[]")# Field name for image array, handled below
	filtered_request_data.erase("mask")   # Handled by mask_image param

	for key in filtered_request_data:
		_form_data_append_line(body, "--%s" % boundary)
		_form_data_append_line(body, 'Content-Disposition: form-data; name="%s"' % key)
		_form_data_append_line(body, '')
		_form_data_append_line(body, str(filtered_request_data[key]))

	# Add the source image(s)
	# For /edits, the API expects "image[]" if multiple, or "image" if single.
	# For /variations, it expects "image" (single).
	# The new docs for /images/edits example with gpt-image-1 uses image[] for multiple files.
	# Let's use "image[]" for /edits if multiple, "image" if single.
	# For /variations (which is DALL-E 2), it's always "image".

	var image_field_name = "image" # Default for single image / variations
	if request_data.get("model", "") == model_name and source_images.size() > 1 : # Using gpt-image-1 (our default) for /edits with multiple images
		image_field_name = "image[]"
	
	var image_idx = 0
	for img_to_send: Image in source_images:
		if img_to_send == null: 
			push_warning("GPTImage1: A null image was passed to _construct_multipart_form_data. Skipping.")
			continue
		
		var current_image_field_name = image_field_name
		# If image_field_name is "image[]", it's already correct for multiple.
		# If it's "image", it implies only one image is expected by the endpoint or for this call.
		# This logic assumes the calling function (`generate_content`) has set up `source_images` correctly
		# (e.g., only one image for /variations).
		
		var filename = "image_%s.png" % image_idx if source_images.size() > 1 else "image.png"
		
		_form_data_append_line(body, "--%s" % boundary)
		_form_data_append_line(body, 'Content-Disposition: form-data; name="%s"; filename="%s"' % [current_image_field_name, filename])
		_form_data_append_line(body, 'Content-Type: image/png')
		_form_data_append_line(body, '')
		_form_data_append_bytes(body, img_to_send.save_png_to_buffer())
		_form_data_append_line(body, '') # Extra CRLF
		image_idx += 1

	if mask_image != null:
		_form_data_append_line(body, "--%s" % boundary)
		_form_data_append_line(body, 'Content-Disposition: form-data; name="mask"; filename="mask.png"')
		_form_data_append_line(body, 'Content-Type: image/png')
		_form_data_append_line(body, '')
		_form_data_append_bytes(body, mask_image.save_png_to_buffer())
		_form_data_append_line(body, '') # Extra CRLF

	_form_data_append_line(body, "--%s--" % boundary)
	return body


func _form_data_append_line(buffer:PackedByteArray, line:String) -> void:
	buffer.append_array(line.to_ascii_buffer())
	buffer.append_array('\r\n'.to_ascii_buffer())


func _form_data_append_bytes(buffer:PackedByteArray, bytes_to_append:PackedByteArray) -> void:
	buffer.append_array(bytes_to_append)
	# The subsequent _form_data_append_line will add the CRLF

#endregion