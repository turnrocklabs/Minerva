class_name OpenRouterProvider
extends BaseProvider
## OpenRouter provider - unified API for multiple AI models.
## Uses OpenAI-compatible format for requests and responses.

# Provider-specific params
var temperature: float = 1
var topP: float = 1
var FrequencyPenalty: float = 0
var presencePenalty: float = 0

## The OpenRouter model ID (e.g., "moonshotai/kimi-k2")
var api_model_id: String = ""

## Available tools for agentic mode (set by ChatPane when agent mode is enabled)
var available_tools: Array[Dictionary] = []

## Whether tool use is enabled for this provider
var tools_enabled: bool = false


func _init():
	provider_name = "OpenRouter"
	BASE_URL = "https://openrouter.ai/api/v1"
	PROVIDER = SingletonObject.API_PROVIDER.OPENROUTER

	# Default model - subclasses override these
	model_name = "kimi-k2"
	api_model_id = "moonshotai/kimi-k2"
	short_name = "KK2"
	input_token_cost = 0.30   # $0.30 per million input tokens
	output_token_cost = 0.90   # $0.90 per million output tokens

	# OpenRouter passes through to underlying model - defaults work for most
	supports_temperature = true
	supports_top_p = true


## Set available tools for agentic mode
func set_tools(tools: Array[Dictionary]) -> void:
	available_tools = tools
	tools_enabled = not tools.is_empty()


## Format tools for OpenAI-compatible API
## OpenRouter uses OpenAI format: {type: "function", function: {name, description, parameters}}
func format_tools_for_request() -> Array:
	var formatted: Array = []
	for tool in available_tools:
		formatted.append({
			"type": "function",
			"function": {
				"name": tool.get("name", ""),
				"description": tool.get("description", ""),
				"parameters": tool.get("input_schema", {"type": "object", "properties": {}})
			}
		})
	return formatted


func _parse_request_results(response: RequestResults) -> BotResponse:
	var bot_response := BotResponse.new()
	bot_response.provider = self  # Always set provider, even for errors

	if not response.success:
		bot_response.error = response.message
		return bot_response

	var data: Variant
	if response.http_request_result == HTTPRequest.RESULT_SUCCESS:
		data = JSON.parse_string(response.body.get_string_from_utf8())

		if response.response_code >= 200 and response.response_code <= 299:
			bot_response = to_bot_response(data)
		else:
			if "error" in data or "message" in data:
				if "error" in data:
					bot_response.error = data["error"]["message"]
				else:
					bot_response.error = data["message"]
			else:
				bot_response.error = "Unexpected error occurred while generating the response"
	else:
		push_error("Invalid result. Response: %s", response.response_code)
		bot_response.error = "Unexpected error occurred with HTTP Client. Code %s" % response.http_request_result
		return bot_response

	return bot_response


func generate_content(prompt: Array[Variant], additional_params: Dictionary = {}) -> BotResponse:
	var request_body = {
		"model": api_model_id,
		"messages": prompt,
	}

	# Add tools if enabled
	print("[OpenRouter] generate_content: tools_enabled=%s, available_tools.size=%d" % [tools_enabled, available_tools.size()])
	if tools_enabled and not available_tools.is_empty():
		request_body["tools"] = format_tools_for_request()
		print("[OpenRouter] Added %d tools to request" % request_body["tools"].size())

	request_body.merge(additional_params)

	var body_stringified: String = JSON.stringify(request_body)

	var response: RequestResults = await make_request(
		"%s/chat/completions" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		[
			"Content-Type: application/json",
			"Authorization: Bearer %s" % API_KEY,
			"HTTP-Referer: https://github.com/minerva-app",
			"X-Title: Minerva"
		],
	)

	var item = _parse_request_results(response)

	SingletonObject.chat_completed.emit(item)

	return item


func Format(chat_item: ChatHistoryItem) -> Variant:
	# Handle TOOL role first (tool results)
	if chat_item.Role == ChatHistoryItem.ChatRole.TOOL:
		return {
			"role": "tool",
			"tool_call_id": chat_item.ToolCallId,
			"content": chat_item.Message
		}

	var role: String

	match chat_item.Role:
		ChatHistoryItem.ChatRole.USER:
			role = "user"
		ChatHistoryItem.ChatRole.ASSISTANT:
			role = "assistant"
		ChatHistoryItem.ChatRole.SYSTEM:
			role = "system"
		ChatHistoryItem.ChatRole.MODEL:
			role = "assistant"
		_:
			push_warning("[OpenRouter] Unknown chat role: %s, defaulting to user" % chat_item.Role)
			role = "user"

	# Handle assistant messages with tool calls (MODEL role is used for bot responses)
	var is_assistant_role = chat_item.Role == ChatHistoryItem.ChatRole.ASSISTANT or chat_item.Role == ChatHistoryItem.ChatRole.MODEL
	if is_assistant_role and chat_item.IsToolCall and not chat_item.ToolCalls.is_empty():
		var tool_calls_formatted: Array = []
		for tool_call in chat_item.ToolCalls:
			# OpenAI expects arguments as a JSON string
			var args = tool_call.get("arguments", {})
			var args_string: String
			if args is String:
				args_string = args
			else:
				args_string = JSON.stringify(args)

			tool_calls_formatted.append({
				"id": tool_call.get("id", ""),
				"type": "function",
				"function": {
					"name": tool_call.get("name", ""),
					"arguments": args_string
				}
			})

		var result: Dictionary = {
			"role": "assistant",
			"tool_calls": tool_calls_formatted
		}
		# Add content if there's any text
		if not chat_item.Message.is_empty():
			result["content"] = chat_item.Message
		else:
			result["content"] = null
		return result

	# Collect text notes and media notes separately
	var text_notes: = PackedStringArray()
	var media_notes: Array = []

	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			text_notes.append(note)
		elif note is Image:
			media_notes.append(note)

	# Wrap all text notes together once
	var notes_section := ""
	if not text_notes.is_empty():
		notes_section = "### Reference Information ###\n"
		notes_section += "\n\n".join(text_notes)
		notes_section += "\n### End Reference Information ###\n\n"

	# Combine notes section with user message
	var full_text := "%s%s" % [notes_section, chat_item.Message]
	full_text = full_text.strip_edges()

	# Content can be a string, but also an array of dictionaries, to handle different media types
	var content: = [
		{
			"type": "text",
			"text": full_text
		},
	]

	# Add image notes
	for img in media_notes:
		content.append({
			"type": "image_url",
			"image_url": {
				"url": "data:image/png;base64,%s" % Marshalls.raw_to_base64(img.save_png_to_buffer())
			}
		})

	return {
		"role": role,
		"content": content
	}


func wrap_memory(item: Note) -> Variant:
	if item.type == Note.Type.IMAGE:
		return (item.get_controls_container() as NoteImageControls).image

	elif item.type == Note.Type.TEXT:
		return (item.get_controls_container() as NoteTextControls).content

	else:
		push_warning("Tried to wrap memory but the given note type is not implemented")
		print_stack()

	return ""


# Response format (OpenAI-compatible):
# {
#   "choices": [{
#     "message": {
#       "role": "assistant",
#       "content": "Hello!",
#       "tool_calls": [...]  # optional
#     },
#     "finish_reason": "stop" | "tool_calls" | "length"
#   }],
#   "usage": {...}
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()

	response.provider = self
	response.id = data.get("id", "")

	var message: Dictionary = data["choices"][0]["message"]
	var finish_reason = data["choices"][0].get("finish_reason", "stop")

	if finish_reason == "length":
		response.complete = false

	var usage = data.get("usage", {})
	response.prompt_tokens = usage.get("prompt_tokens", 0)
	response.completion_tokens = usage.get("completion_tokens", 0)

	# Get text content (may be null for tool-only responses)
	var content = message.get("content")
	if content != null and content is String:
		response.text = content
	else:
		response.text = ""

	# Parse tool calls if present
	var tool_calls = message.get("tool_calls", [])
	if tool_calls is Array:
		for tool_call in tool_calls:
			if tool_call.get("type") == "function":
				var func_data: Dictionary = tool_call.get("function", {})
				var args_string: String = func_data.get("arguments", "{}")
				var args: Dictionary = {}
				var parsed = JSON.parse_string(args_string)
				if parsed is Dictionary:
					args = parsed

				response.add_tool_call(
					tool_call.get("id", ""),
					func_data.get("name", ""),
					args
				)

	return response


func estimate_tokens(input: String) -> int:
	return roundi(input.get_slice_count(" ") * 1.335)


func estimate_tokens_from_prompt(input: Array[Variant]):
	var text_tokens: float = 0.0

	for msg: Dictionary in input:
		var content = msg.get("content")

		if content is String:
			text_tokens += estimate_tokens(content)
		elif content is Array:
			for part: Dictionary in content:
				if part.get("type") == "text":
					text_tokens += estimate_tokens(part.get("text"))

	return text_tokens + estimate_image_tokens_from_prompt(input)


func estimate_image_tokens_from_prompt(input: Array[Variant]) -> float:
	var image_tokens := 0.0
	for msg: Dictionary in input:
		var content = msg.get("content")
		if content is Array:
			for part in content:
				if part.get("type") == "image_url":
					var b64: String = part["image_url"]["url"]
					# Extract base64 data after the prefix
					if b64.begins_with("data:"):
						b64 = b64.split(",")[1] if "," in b64 else b64
					var img = Image.new()
					img.load_png_from_buffer(Marshalls.base64_to_raw(b64))
					image_tokens += (ceil(img.get_size().x / 512.0) * ceil(img.get_size().y / 512.0)) * 170 + 85
	return image_tokens


func continue_partial_response(_partial_chi: ChatHistoryItem):
	var chi = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	chi.Message = "finish"
	return chi


# ============================================================================
# Model Variants
# ============================================================================

## GLM-4.7 from Zhipu AI - Advanced reasoning model
class GLM47 extends OpenRouterProvider:
	func _init():
		super()
		api_model_id = "z-ai/glm-4.7"
		model_name = "glm-4.7"
		display_name = "GLM-4.7"
		short_name = "GLM"
		input_token_cost = 0.20   # $0.20 per million input tokens
		output_token_cost = 0.60   # $0.60 per million output tokens
		is_reasoning_model = true


## Minimax M2.1 - Efficient coding and agentic model
class MinimaxM21 extends OpenRouterProvider:
	func _init():
		super()
		api_model_id = "minimax/minimax-m2.1"
		model_name = "minimax-m2.1"
		display_name = "Minimax M2.1"
		short_name = "MM2"
		input_token_cost = 0.13   # $0.13 per million input tokens
		output_token_cost = 0.40   # $0.40 per million output tokens


## Kimi K2 from Moonshot AI - Large MoE model for long-context
class KimiK2 extends OpenRouterProvider:
	func _init():
		super()
		api_model_id = "moonshotai/kimi-k2"
		model_name = "kimi-k2"
		display_name = "Kimi K2"
		short_name = "KK2"
		input_token_cost = 0.30   # $0.30 per million input tokens
		output_token_cost = 0.90   # $0.90 per million output tokens
