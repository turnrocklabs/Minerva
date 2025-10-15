### Title: GoogleAi
class_name GoogleAi_PRO
extends BaseProvider

var system_prompt: String

func _init():
	provider_name = "Google"
	BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
	PROVIDER = SingletonObject.API_PROVIDER.GOOGLE

	model_name = "gemini-2.5-pro"
	short_name = "GP"
	token_cost = 1.25 / 1_000_000 # https://claude101.com/claude-3-5-sonnet/

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

func wrap_memory(item: Note) -> Variant:

	# Return either string for text notes or dictionary for image/audio/video notes

	if item.type == Note.Type.IMAGE:
		return {
			"inline_data": {
				"mime_type": "image/png",
				"data": Marshalls.raw_to_base64((item.get_controls_container() as NoteImageControls).image.save_png_to_buffer())
			}
		}
	elif item.type == Note.Type.VIDEO:

		if item.file.is_empty():
			push_error("Tried to get note video when there is no file attached to it")
			print_stack()
			return ""
		if not SingletonObject.google_supported_video_formats.has(item.file.get_extension()):
			push_error("wrap_memory: Video format (%s) not supported, returning empty string" % [item.file])
			return ""

		var file_content: = FileAccess.get_file_as_bytes(item.file)
		var video_mime: String = SingletonObject.google_supported_video_formats.get(item.Content.get_extension())
		return {
			"inline_data": {
				"mime_type": video_mime,
				"data": Marshalls.raw_to_base64(file_content)
			}
		}
	
	elif item.type == Note.Type.AUDIO:

		# TODO: support in memory recordings, not just audio files

		var controls_container: = item.get_controls_container() as NoteAudioControls
		
		var file_content: PackedByteArray

		if item.file.is_empty():
			# NOTICE: in this case the audio is recorded in app, which is always AudioStreamWAV

			file_content = (controls_container.audio as AudioStreamWAV).data
		
		else:
			if not SingletonObject.google_supported_audio_formats.has(item.file.get_extension()):
				push_error("wrap_memory: Audio format (%s) not supported, returning empty string" % [item.file])
				return ""
			
			else:
				file_content = FileAccess.get_file_as_bytes(item.file)

		var audio_mime: String = SingletonObject.google_supported_audio_formats.get(item.file.get_extension())
		return {
			"inline_data": {
				"data": Marshalls.raw_to_base64(file_content),
				"mime_type": audio_mime
			}
	}
	elif item.type == Note.Type.TEXT:
		return (item.get_controls_container() as NoteTextControls).content

	else:
		push_warning("Tried to wrap memory but the given note type is not implemented")
		print_stack()
	
	return ""

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
	
	# Collect text notes and media notes separately
	var text_notes: = PackedStringArray()
	var media_notes: Array[Dictionary] = []

	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			text_notes.append(note)
		elif note is Dictionary:
			media_notes.append(note)

	# Wrap all text notes together once
	var notes_section := ""
	if not text_notes.is_empty():
		notes_section = "### Reference Information ###\n"
		notes_section += "\n\n".join(text_notes)
		notes_section += "\n### End Reference Information ###\n\n"

	var image_captions_array = chat_item.Images.map(func(img: Image): return img.get_meta("caption", "No caption."))
	var image_captions: String

	if not image_captions_array.is_empty():
		image_captions = "Image Caption: %s" % "\n".join(image_captions_array)

	# Combine everything
	var text := "%s\n%s\n%s" % [image_captions, notes_section, chat_item.Message]
	text = text.strip_edges()

	var output = {
		"role": role,
		"parts": [
			{ "text": text }
		]
	}

	# Add media notes (images, audio, video) to parts array
	output["parts"].append_array(media_notes)
	return output

func estimate_tokens(input) -> int:
	return roundi(input.get_slice_count(" ") * 1.335)

func estimate_tokens_from_prompt(input: Array[Variant]):
	var all_text: = PackedStringArray()
	
	for msg: Variant in input:
		if not msg is Dictionary:
			continue
		
		var parts = msg.get("parts", [])
		if not parts is Array:
			continue
		
		for part in parts:
			if not part is Dictionary:
				continue
			
			if "text" in part:
				all_text.append(part["text"])
	
	return estimate_tokens("\n".join(all_text))

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
