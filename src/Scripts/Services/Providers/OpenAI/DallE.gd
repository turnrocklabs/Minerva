class_name DallE
extends BaseProvider



func _init():
	provider_name = "OpenAI"
	BASE_URL = "https://api.openai.com/v1/images"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI

	model_name = "dall-e-2"
	short_name = "D2"
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


## Creates dummy mask in lower right quarter of the image
func _dummy_mask(image: Image) -> Image:
	
	var mask = Image.new()
	mask.copy_from(image)
	
	mask.convert(Image.FORMAT_RGBA8)

	var half_width = 0#with here
	var half_height = 0#height here

	for x in range(half_width, mask.get_width()):
		for y in range(half_height, mask.get_height()):
			mask.set_pixel(x, y, Color.TRANSPARENT)

	return mask



func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
	# if we have active image this will be a edit request
	var active_image: Image
	var edit: = false # if this is a image edit for the active image, otherwise image variation

	# FIXME: this is dirry and should be handled by 'wrap_memory' somehow
	# relies on notes not being disable before calling this function
	for thread: MemoryThread in SingletonObject.ThreadList:
		for mem_item: MemoryItem in thread.MemoryItemList:
			if mem_item.Enabled and mem_item.MemoryImage:
				active_image = mem_item.MemoryImage

	for formatted_data in prompt:
		for image in formatted_data["images"]:
			if image.get_meta("active", false):
				active_image = image
				edit = true

	# Just take the last prompt
	var request_body = {
		"model": model_name,
		"prompt": prompt.back()["text"],
		"response_format": "b64_json",
	}

	request_body.merge(additional_params)
	
	var response: RequestResults

	if active_image:
		if edit:
			var boundary: = _generate_form_data_boundary()

			response = await make_request(
				"%s/edits" % BASE_URL,
				HTTPClient.METHOD_POST,
				_construct_edit_form_data(request_body, active_image.get_meta("mask"), boundary),
				[
					'Content-Type: multipart/form-data;boundary=%s' % boundary,
					"Authorization: Bearer %s" % API_KEY
				],
			)
		else: # image variation
			var boundary: = _generate_form_data_boundary()

			request_body.erase("prompt") # no prompt for variation

			response = await make_request(
				"%s/variations" % BASE_URL,
				HTTPClient.METHOD_POST,
				_construct_edit_form_data(request_body, active_image, boundary),
				[
					'Content-Type: multipart/form-data;boundary=%s' % boundary,
					"Authorization: Bearer %s" % API_KEY
				],
			)
	

	else:
		request_body["model"] = "dall-e-3" # we can use dall-e-3 for generating images
		response = await make_request(
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

func wrap_memory(item: Variant) -> Variant:
	var output: String = "Given this background information:\n\n"
	output += "### Reference Information ###\n"
	output += item.Content
	output += "### End Reference Information ###\n\n"
	output += "Respond to the user's message: \n\n"
	return output


func Format(chat_item: ChatHistoryItem) -> Variant:
	var text_notes = chat_item.InjectedNotes.filter(func(note): return note is String)

	var text: String = chat_item.Message if text_notes.is_empty() else "%s%s" % ["\n".join(text_notes), chat_item.Message]

	return {
		"text": text,
		"images": chat_item.Images
	}


func estimate_tokens(_input: String) -> int:
	return 0

func estimate_tokens_from_prompt(_input: Array[Variant]) -> int:
	return 0

func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null

#region Form Data

## Generate boundary string for form data.
## See https://developer.mozilla.org/en-US/docs/Web/HTTP/Methods/POST
func _generate_form_data_boundary() -> String:
	# Create some random bytes to generate our boundary value
	var crypto = Crypto.new()
	var random_bytes = crypto.generate_random_bytes(16)
	return '%s' % random_bytes.hex_encode()

## takes `request_data`, `image`, and form data `boundary` to construct
## form data for the request
func _construct_edit_form_data(request_data: Dictionary, image: Image, boundary: String) -> PackedByteArray:
	# Create our body
	var body: = PackedByteArray()

	for key in request_data:
		_form_data_append_line(body, "--%s" % boundary)
		_form_data_append_line(body, 'Content-Disposition: form-data; name="%s"' % key)
		_form_data_append_line(body, '')
		_form_data_append_line(body, request_data[key])

	# add the image field
	_form_data_append_line(body, "--%s" % boundary)
	_form_data_append_line(body, 'Content-Disposition: form-data; name="image"; filename="image.png"')
	_form_data_append_line(body, 'Content-Type: image/png')
	_form_data_append_line(body, 'Content-Transfer-Encoding: binary')
	_form_data_append_line(body, '')

	_form_data_append_bytes(body, image.save_png_to_buffer())
	_form_data_append_line(body, '')

	_form_data_append_line(body, "--%s--" % boundary)

	return body


func _form_data_append_line(buffer:PackedByteArray, line:String) -> void:
	buffer.append_array(line.to_ascii_buffer())
	buffer.append_array('\r\n'.to_ascii_buffer())


func _form_data_append_bytes(buffer:PackedByteArray, bytes:PackedByteArray) -> void:
	buffer.append_array(bytes)
	buffer.append_array('\r\n'.to_ascii_buffer())

# endregion
