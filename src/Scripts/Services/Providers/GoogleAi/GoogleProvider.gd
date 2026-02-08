class_name GoogleProvider
extends BaseProvider
## Consolidated Google/Gemini provider with tool support.
## Supports multimodal content (text, images, audio, video).

var system_prompt: String

## Available tools for agentic mode (set by ChatPane when agent mode is enabled)
var available_tools: Array[Dictionary] = []

## Whether tool use is enabled for this provider
var tools_enabled: bool = false

## Counter for generating unique tool call IDs
var _tool_call_counter: int = 0


func _init():
	provider_name = "Google"
	BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"
	PROVIDER = SingletonObject.API_PROVIDER.GOOGLE

	# Default model - subclasses override these
	model_name = "gemini-3-flash-preview"
	short_name = "G3F"
	input_token_cost = 0.50   # $0.50 per million input tokens
	output_token_cost = 3.00   # $3 per million output tokens

	# Request timeout - Gemini is generally fast
	default_timeout = 90.0

	# Gemini 3 supports temperature/top_p but works best at default
	supports_temperature = true
	supports_top_p = true
	temperature_warning = "Gemini 3 works best with temperature=1.0"


## Set available tools for agentic mode
func set_tools(tools: Array[Dictionary]) -> void:
	available_tools = tools
	tools_enabled = not tools.is_empty()


## Format tools for Gemini API
## Gemini uses: tools: [{function_declarations: [{name, description, parameters}]}]
func format_tools_for_request() -> Array:
	var function_declarations: Array = []
	for tool in available_tools:
		var schema = tool.get("input_schema", {"type": "object", "properties": {}}).duplicate(true)
		_strip_unsupported_schema_fields(schema)
		function_declarations.append({
			"name": tool.get("name", ""),
			"description": tool.get("description", ""),
			"parameters": schema
		})
	return [{"function_declarations": function_declarations}]


## Recursively remove JSON Schema fields that Google's Gemini API doesn't support
static func _strip_unsupported_schema_fields(schema: Variant) -> void:
	if schema is Dictionary:
		schema.erase("additionalProperties")
		schema.erase("$schema")
		for value in schema.values():
			_strip_unsupported_schema_fields(value)
	elif schema is Array:
		for item in schema:
			_strip_unsupported_schema_fields(item)


func _parse_request_results(response: RequestResults) -> BotResponse:
	var bot_response := BotResponse.new()
	bot_response.provider = self  # Always set provider, even for errors

	if not response.success:
		bot_response.error = response.message
		return bot_response

	var data: Variant
	if response.http_request_result == HTTPRequest.RESULT_SUCCESS:
		var body_text := response.body.get_string_from_utf8()
		print("[Gemini] Raw response body: %s" % body_text.left(2000))
		data = JSON.parse_string(body_text)
		print("[Gemini] Parsed data: %s" % str(data).left(1000))
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
		return bot_response

	return bot_response


func generate_content(prompt: Array[Variant], additional_params: Dictionary = {}):
	var request_body = {
		"contents": prompt
	}

	# Add tools if enabled
	print("[Gemini] generate_content: tools_enabled=%s, available_tools.size=%d" % [tools_enabled, available_tools.size()])
	if tools_enabled and not available_tools.is_empty():
		request_body["tools"] = format_tools_for_request()
		print("[Gemini] Added %d tools to request" % available_tools.size())

	request_body.merge(additional_params)

	var body_stringified: String = JSON.stringify(request_body)

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
		var controls_container: = item.get_controls_container() as NoteAudioControls
		var file_content: PackedByteArray

		if item.file.is_empty():
			# Audio is recorded in app (always AudioStreamWAV)
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
	# Handle SYSTEM role first (sets system_prompt and returns null)
	if chat_item.Role == ChatHistoryItem.ChatRole.SYSTEM:
		system_prompt = chat_item.Message
		return null

	# Handle TOOL role (tool results)
	if chat_item.Role == ChatHistoryItem.ChatRole.TOOL:
		# Tool results are sent as user role with functionResponse
		# Gemini expects: {role: "user", parts: [{functionResponse: {name, response}}]}
		var response_content: Variant
		var parsed = JSON.parse_string(chat_item.Message)
		if parsed != null:
			response_content = parsed
		else:
			response_content = {"content": chat_item.Message}

		return {
			"role": "user",
			"parts": [{
				"functionResponse": {
					"name": chat_item.ToolName,
					"response": response_content
				}
			}]
		}

	var role: String

	match chat_item.Role:
		ChatHistoryItem.ChatRole.USER:
			role = "user"
		ChatHistoryItem.ChatRole.ASSISTANT:
			role = "model"
		ChatHistoryItem.ChatRole.MODEL:
			role = "model"
		_:
			push_warning("[Gemini] Unknown chat role: %s, defaulting to user" % chat_item.Role)
			role = "user"

	# Handle model messages with function calls (MODEL role is used for bot responses)
	var is_model_role = chat_item.Role == ChatHistoryItem.ChatRole.ASSISTANT or chat_item.Role == ChatHistoryItem.ChatRole.MODEL
	if is_model_role and chat_item.IsToolCall and not chat_item.ToolCalls.is_empty():
		var parts: Array = []
		# Add text part first if any
		if not chat_item.Message.is_empty():
			parts.append({"text": chat_item.Message})
		# Add functionCall parts
		for tool_call in chat_item.ToolCalls:
			var func_call_part: Dictionary = {
				"functionCall": {
					"name": tool_call.get("name", ""),
					"args": tool_call.get("arguments", {})
				}
			}
			# Include thoughtSignature if present (required for Gemini 3 models)
			if tool_call.has("thoughtSignature"):
				func_call_part["thoughtSignature"] = tool_call["thoughtSignature"]
			parts.append(func_call_part)
		return {
			"role": "model",
			"parts": parts
		}

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


# Response format:
# {
#   "candidates": [{
#     "content": {
#       "role": "model",
#       "parts": [{"text": "..."}, {"functionCall": {...}}]
#     },
#     "finishReason": "STOP"
#   }],
#   "usageMetadata": {...}
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()

	response.provider = self

	var candidate = (data["candidates"] as Array).pop_front()
	print("[Gemini] candidate: %s" % str(candidate).left(500))

	if not candidate:
		response.error = "No candidates"
		return response

	# Handle error finish reasons
	var finish_reason: String = candidate.get("finishReason", "")
	if finish_reason == "UNEXPECTED_TOOL_CALL":
		response.error = "Gemini error: Tool result without matching tool call in history. This can happen when editing chats with tool interactions. Try starting a fresh chat."
		return response
	elif finish_reason == "SAFETY":
		response.error = "Gemini blocked this response due to safety filters."
		return response
	elif finish_reason == "RECITATION":
		response.error = "Gemini blocked this response due to recitation concerns."
		return response

	if not "finishReason" in candidate:
		response.complete = false

	var content = candidate.get("content", {})
	print("[Gemini] content: %s" % str(content).left(500))

	# Handle empty content
	if content.is_empty():
		response.error = "Gemini returned empty content (finishReason: %s)" % finish_reason
		return response

	# Parse parts - can be text and/or functionCall
	if content.has("parts"):
		print("[Gemini] parts count: %d" % content["parts"].size())
		for part in content["parts"]:
			print("[Gemini] part keys: %s" % str(part.keys()))
			if "text" in part:
				print("[Gemini] Found text part, length: %d" % part["text"].length())
				response.text += "\n%s" % part["text"]
			elif "functionCall" in part:
				# Parse function call
				var func_call: Dictionary = part["functionCall"]
				# Gemini doesn't provide an ID for function calls, so we generate one
				# Use a counter to ensure uniqueness when multiple calls are in the same response
				_tool_call_counter += 1
				var call_id: String = "gemini_call_%s_%d_%d" % [func_call.get("name", "unknown"), Time.get_ticks_msec(), _tool_call_counter]
				response.add_tool_call(
					call_id,
					func_call.get("name", ""),
					func_call.get("args", {})
				)
				# Store thoughtSignature if present (required for Gemini 3 models)
				if "thoughtSignature" in part:
					response.tool_calls[-1]["thoughtSignature"] = part["thoughtSignature"]

	response.text = response.text.strip_edges()

	response.prompt_tokens = data["usageMetadata"]["promptTokenCount"]
	response.completion_tokens = data["usageMetadata"].get("candidatesTokenCount", 0)

	return response


# ============================================================================
# Model Variants
# ============================================================================

## Gemini 3 Flash: Fast, capable multimodal model (preview)
class Flash extends GoogleProvider:
	func _init():
		super()
		model_name = "gemini-3-flash-preview"
		display_name = "Gemini 3 Flash"
		short_name = "G3F"
		input_token_cost = 0.50   # $0.50 per million input tokens
		output_token_cost = 3.00   # $3 per million output tokens


## Gemini 3 Pro: Most capable model (preview)
class Pro extends GoogleProvider:
	func _init():
		super()
		model_name = "gemini-3-pro-preview"
		display_name = "Gemini 3 Pro"
		short_name = "G3P"
		input_token_cost = 2.00   # $2 per million input tokens
		output_token_cost = 12.00  # $12 per million output tokens
