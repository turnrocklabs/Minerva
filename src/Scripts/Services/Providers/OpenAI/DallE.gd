class_name DallE
extends BaseProvider



func _init():
	provider_name = "OpenAI"
	BASE_URL = "https://api.openai.com/v1/images"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI

	model_name = "dall-e-2"
	short_name = "D2"
	token_cost = 0.018


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

func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
	# Just take the last prompt
	var request_body = {
		"model": "dall-e-3",
		"prompt": prompt.back()["text"].left(4000), # dall-e-3 has a 4000 characters prompt limit
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

func estimate_tokens_from_prompt(input: Array[Variant]):
	var latest_prompt = input.back()

	if not latest_prompt.get("text").is_empty() and (latest_prompt.get("images", []) as Array).is_empty():
		return 0.040 # https://openai.com/api/pricing/ implying we use standard quality and dalle-3

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