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
	var source_images_for_api: Array[Image] = []
	var image_mask_for_inpainting: Image = null # Will store the actual mask Image if found from the first relevant note

	# --- Determine active source images and if a mask is explicitly provided ---
	# Prioritize DetachedNotes (explicitly selected/added by user for this turn)
	var detached_notes_used: Array[MemoryItem] = []
	for item: MemoryItem in SingletonObject.DetachedNotes:
		if item.Type == SingletonObject.note_type.IMAGE and item.Enabled and item.MemoryImage:
			source_images_for_api.append(item.MemoryImage)
			detached_notes_used.append(item) # Keep track to disable them later
			# If this is the first image note and it has a mask, use it
			if image_mask_for_inpainting == null and item.MemoryImage.has_meta("mask"):
				var potential_mask = item.MemoryImage.get_meta("mask")
				if potential_mask is Image:
					image_mask_for_inpainting = potential_mask
				else:
					push_warning("GPTImage1: Note image has 'mask' meta, but it's not a valid Image object.")
	
	# Disable the detached notes that were collected
	for item_to_disable: MemoryItem in detached_notes_used:
		item_to_disable.Enabled = false

	# Fallback: If no images from DetachedNotes, check ThreadList for a single "active" image
	# This maintains some of the old behavior for single-image edits/variations from chat history.
	if source_images_for_api.is_empty():
		var single_active_image_from_history: Image = null
		# This loop structure is from original code, may need refinement for picking the "right" image from history
		for thread: MemoryThread in SingletonObject.ThreadList:
			for mem_item: MemoryItem in thread.MemoryItemList:
				if mem_item.Enabled and mem_item.MemoryImage:
					single_active_image_from_history = mem_item.MemoryImage
					# For history images, we are not currently assuming a mask is implicitly active for this operation
					# unless specifically handled elsewhere.
					break 
			if single_active_image_from_history:
				break
		if single_active_image_from_history:
			source_images_for_api.append(single_active_image_from_history)


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

	var response: RequestResults

	if not source_images_for_api.is_empty():
		# --- We have one or more source images ---
		var boundary: String = _generate_form_data_boundary()
		
		if not current_prompt_text.is_empty():
			# SCENARIO: Image(s) + Prompt => USE /EDITS
			var edit_request_body: Dictionary = request_body_params.duplicate(true)
			edit_request_body["model"] = model_to_use
			
			if model_to_use == "gpt-image-1":
				edit_request_body["prompt"] = current_prompt_text.left(32000)
			elif model_to_use == "dall-e-2":
				edit_request_body["prompt"] = current_prompt_text.left(1000)
			# else, unknown model, don't truncate

			var form_payload = _construct_multipart_form_data(
				edit_request_body, 
				source_images_for_api, # Pass array of images
				boundary, 
				image_mask_for_inpainting # Pass the mask if found (applies to first image)
			)

			response = await make_request(
				"%s/edits" % BASE_URL,
				HTTPClient.METHOD_POST,
				form_payload,
				[
					'Content-Type: multipart/form-data;boundary=%s' % boundary,
					"Authorization: Bearer %s" % API_KEY
				],
			)
		else:
			# SCENARIO: Image(s) + NO Prompt => True Variation
			# API docs: /variations is DALL-E 2 only, takes ONE image, no prompt.
			if source_images_for_api.size() > 1:
				push_warning("GPTImage1: Multiple source images provided for variation, but API expects one. Using the first image.")
			
			var single_image_for_variation = source_images_for_api[0]
			
			var variation_specific_params: Dictionary = {}
			variation_specific_params["model"] = "dall-e-2" # Hardcode DALL-E 2 for /variations
			if "n" in request_body_params: variation_specific_params["n"] = request_body_params["n"]
			if "size" in request_body_params: variation_specific_params["size"] = request_body_params["size"]
			
			var form_payload = _construct_multipart_form_data(
				variation_specific_params, 
				[single_image_for_variation], # Send as array with one element
				boundary, 
				null # No mask for variations
			)
			
			response = await make_request(
				"%s/variations" % BASE_URL,
				HTTPClient.METHOD_POST,
				form_payload,
				[
					'Content-Type: multipart/form-data;boundary=%s' % boundary,
					"Authorization: Bearer %s" % API_KEY
				],
			)
	else:
		# SCENARIO: NO Source Images => New Generation from prompt
		if current_prompt_text.is_empty():
			var err_response:= BotResponse.new()
			err_response.error = "Cannot generate image: Prompt is empty and no source images are provided."
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
		
		response = await make_request(
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


func wrap_memory(item: Variant) -> Variant:
	# This function seems unrelated to image generation, keeping as is.
	var output: String = "Given this background information:\n\n"
	output += "### Reference Information ###\n"
	output += item.Content
	output += "### End Reference Information ###\n\n"
	output += "Respond to the user's message: \n\n"
	return output


func Format(chat_item: ChatHistoryItem) -> Variant:
	# This function formats input for the provider. The `generate_content` uses `prompt_array.back()["text"]`.
	# The collection of images for API happens from DetachedNotes/ThreadList directly in `generate_content`.
	var text_notes = chat_item.InjectedNotes.filter(func(note): return note is String)
	var text: String = chat_item.Message if text_notes.is_empty() else "%s%s" % ["\n".join(text_notes), chat_item.Message]

	return {
		"text": text,
		"images": chat_item.Images 
	}


func estimate_tokens_from_prompt(input_prompt_array: Array[Variant]):
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
