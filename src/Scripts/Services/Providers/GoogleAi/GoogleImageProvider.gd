class_name GoogleImageProvider
extends BaseProvider
## Google Gemini image generation provider.
## Uses gemini-3-pro-image-preview (Nano Banana Pro) for native image generation.

## Prompt character limit
var prompt_limit: int = 32000

## Flag to identify this as a Nano Banana Pro provider (for settings UI)
var is_nano_banana_pro: bool = true


func _init():
	provider_name = "Google Imagen"
	BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
	PROVIDER = SingletonObject.API_PROVIDER.GOOGLE

	# Default model
	model_name = "gemini-3-pro-image-preview"
	short_name = "NBP"
	display_name = "Nano Banana Pro"
	token_cost = 0.04  # Fixed cost per image


func _parse_request_results(response: RequestResults) -> BotResponse:
	var bot_response := BotResponse.new()
	bot_response.provider = self

	if not response.success:
		bot_response.error = response.message
		return bot_response

	var data: Variant
	if response.http_request_result == HTTPRequest.RESULT_SUCCESS:
		var body_text := response.body.get_string_from_utf8()
		print("[NanoBananaPro] Raw response: %s" % body_text.left(500))
		data = JSON.parse_string(body_text)

		if response.response_code >= 200 and response.response_code <= 299:
			bot_response = to_bot_response(data)
		else:
			if data != null and "error" in data and data["error"] is Dictionary:
				bot_response.error = data["error"].get("message", "Unknown API error")
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

	# Build parts array - text prompt first
	var parts: Array = [
		{"text": current_prompt_text.left(prompt_limit)}
	]

	# Add any input images from the prompt array (for image editing/reference)
	var image_count := 0
	for item in prompt_array:
		if item is Dictionary:
			# Handle images array from Format() function
			if "images" in item and item["images"] is Array:
				for img_part in item["images"]:
					if img_part is Dictionary and "inline_data" in img_part:
						parts.append(img_part)
						image_count += 1
			# Handle direct inline_data (from wrap_memory)
			elif "inline_data" in item:
				parts.append(item)
				image_count += 1

	if image_count > 0:
		print("[NanoBananaPro] Including %d reference image(s) for editing" % image_count)

	# Gemini image generation uses generateContent with responseModalities
	var request_body: Dictionary = {
		"contents": [{
			"parts": parts
		}],
		"generationConfig": {
			"responseModalities": ["TEXT", "IMAGE"],
			"imageConfig": {
				"aspectRatio": SingletonObject.nbp_aspect_ratio,
				"imageSize": SingletonObject.nbp_image_size,
			}
		}
	}

	# Add Google Search grounding if enabled (for current events, weather, etc.)
	if SingletonObject.nbp_google_search_enabled:
		request_body["tools"] = [{"google_search": {}}]

	request_body.merge(additional_params, true)

	print("[NanoBananaPro] Request: %s" % JSON.stringify(request_body).left(500))

	var response: RequestResults = await make_request(
		"%s/%s:generateContent?key=%s" % [BASE_URL, model_name, API_KEY],
		HTTPClient.METHOD_POST,
		JSON.stringify(request_body),
		[
			"Content-Type: application/json",
		],
	)

	var item = _parse_request_results(response)
	SingletonObject.chat_completed.emit(item)
	return item


# Response format (Gemini generateContent with image):
# {
#   "candidates": [{
#     "content": {
#       "parts": [
#         {"text": "Here's the image..."},
#         {"inlineData": {"mimeType": "image/png", "data": "base64..."}}
#       ],
#       "role": "model"
#     },
#     "finishReason": "STOP"
#   }],
#   "usageMetadata": {...}
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()
	response.provider = self

	if data == null:
		response.error = "Failed to parse response from API."
		return response

	# Check for candidates (Gemini format)
	var candidates = data.get("candidates", [])
	if candidates.is_empty():
		response.error = "No candidates in response."
		if data.has("error"):
			response.error = "API Error: %s" % data["error"].get("message", str(data["error"]))
		return response

	var candidate = candidates[0]
	var content = candidate.get("content", {})
	var parts = content.get("parts", [])

	if parts.is_empty():
		response.error = "No parts in response content."
		return response

	# Parse parts - look for text and image data
	var found_image := false
	for part in parts:
		if not part is Dictionary:
			continue

		# Handle text part
		if "text" in part:
			response.text += part["text"] + "\n"

		# Handle image part (inlineData)
		if "inlineData" in part and not found_image:
			var inline_data: Dictionary = part["inlineData"]
			var mime_type: String = inline_data.get("mimeType", "image/png")
			var b64_data: String = inline_data.get("data", "")

			if b64_data.is_empty():
				continue

			response.image = Image.new()
			var raw_bytes = Marshalls.base64_to_raw(b64_data)

			var err: int
			if "jpeg" in mime_type or "jpg" in mime_type:
				err = response.image.load_jpg_from_buffer(raw_bytes)
			elif "webp" in mime_type:
				err = response.image.load_webp_from_buffer(raw_bytes)
			else:
				err = response.image.load_png_from_buffer(raw_bytes)

			if err != OK:
				push_error("[NanoBananaPro] Failed to load image, trying other formats...")
				# Try all formats
				if response.image.load_png_from_buffer(raw_bytes) != OK:
					if response.image.load_jpg_from_buffer(raw_bytes) != OK:
						if response.image.load_webp_from_buffer(raw_bytes) != OK:
							response.error = "Failed to decode image data"
							response.image = null
							continue

			if response.image:
				response.image.set_meta("caption", response.text.strip_edges() if not response.text.is_empty() else "Generated by %s" % display_name)
				found_image = true

	response.text = response.text.strip_edges()

	if not found_image and response.image == null:
		if response.text.is_empty():
			response.error = "No image or text in response"
		# If we got text but no image, that's still a valid response (model might explain why it can't generate)

	# Parse usage metadata
	var usage = data.get("usageMetadata", {})
	response.prompt_tokens = usage.get("promptTokenCount", 0)
	response.completion_tokens = usage.get("candidatesTokenCount", 0)

	return response


func wrap_memory(item: Note) -> Variant:
	# Support both text and image notes for image editing
	if item.type == Note.Type.TEXT:
		return (item.get_controls_container() as NoteTextControls).content
	elif item.type == Note.Type.IMAGE:
		var img = (item.get_controls_container() as NoteImageControls).image
		if img and not img.is_empty():
			return {
				"inline_data": {
					"mime_type": "image/png",
					"data": Marshalls.raw_to_base64(img.save_png_to_buffer())
				}
			}
	push_warning("[NanoBananaPro] Note type not supported for image generation")
	return ""


func Format(chat_item: ChatHistoryItem) -> Variant:
	# Collect text notes and image notes
	var text_notes := PackedStringArray()
	var image_parts: Array = []

	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			text_notes.append(note)
		elif note is Dictionary and "inline_data" in note:
			image_parts.append(note)

	# Build notes section
	var notes_section := ""
	if not text_notes.is_empty():
		notes_section = "### Reference Information ###\n"
		notes_section += "\n\n".join(text_notes)
		notes_section += "\n### End Reference Information ###\n\n"

	# Combine notes section with user message
	var full_text := "%s%s" % [notes_section, chat_item.Message]
	full_text = full_text.strip_edges()

	# Return format compatible with image generation
	var result: Dictionary = {
		"text": full_text,
	}

	# Add any reference images
	if not image_parts.is_empty():
		result["images"] = image_parts

	return result


func estimate_tokens(_input: String) -> int:
	return 0


func estimate_tokens_from_prompt(_input_prompt_array: Array[Variant]) -> float:
	return 0.0


func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null


# ============================================================================
# Model Variants
# ============================================================================

## Nano Banana Pro: Gemini 3 Pro with native image generation
class NanaBananaPro extends GoogleImageProvider:
	func _init():
		super()
		model_name = "gemini-3-pro-image-preview"
		display_name = "Nano Banana Pro"
		short_name = "NBP"
		token_cost = 0.04
