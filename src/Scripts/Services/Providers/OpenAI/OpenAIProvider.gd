class_name OpenAIProvider
extends BaseProvider
## Consolidated OpenAI chat provider with tool support and reasoning levels.
## All GPT models share this implementation with different configs.

# Provider-specific params
var temperature: float = 1
var topP: float = 1
var FrequencyPenalty: float = 0
var presencePenalty: float = 0

## System prompt to send with the request (set by ChatPane)
var system_prompt: String

## Available tools for agentic mode (set by ChatPane when agent mode is enabled)
var available_tools: Array[Dictionary] = []

## Whether tool use is enabled for this provider
var tools_enabled: bool = false

## Reasoning effort level: minimal, low, medium, high, xhigh
var reasoning_effort: String = "medium"


func _init():
	provider_name = "OpenAI"
	BASE_URL = "https://api.openai.com"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI

	# Default model - subclasses override these
	model_name = "gpt-5.2"
	short_name = "G5"
	input_token_cost = 5.00   # $5 per million input tokens
	output_token_cost = 15.00  # $15 per million output tokens

	# Request timeout - reasoning models can be slow
	default_timeout = 120.0

	# GPT-5 reasoning models don't support temperature/top_p
	is_reasoning_model = true
	supports_temperature = false
	supports_top_p = false
	supports_frequency_penalty = false
	supports_presence_penalty = false


## Set available tools for agentic mode
func set_tools(tools: Array[Dictionary]) -> void:
	available_tools = tools
	tools_enabled = not tools.is_empty()


## Format tools for OpenAI API
## OpenAI uses: {type: "function", function: {name, description, parameters}}
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


# https://platform.openai.com/docs/guides/text-generation/chat-completions-api
func generate_content(prompt: Array[Variant], additional_params: Dictionary = {}) -> BotResponse:
	# Build messages array - prepend system prompt if set
	var messages: Array = []
	if not system_prompt.is_empty() and supports_system_prompt:
		messages.append({"role": "system", "content": system_prompt})
	messages.append_array(prompt)

	var request_body = {
		"model": model_name,
		"messages": messages,
	}

	# Add reasoning effort for models that support it
	if not reasoning_effort.is_empty():
		additional_params.merge({"reasoning_effort": reasoning_effort}, true)

	# Add tools if enabled
	print("[OpenAI] generate_content: tools_enabled=%s, available_tools.size=%d" % [tools_enabled, available_tools.size()])
	if tools_enabled and not available_tools.is_empty():
		request_body["tools"] = format_tools_for_request()
		print("[OpenAI] Added %d tools to request" % request_body["tools"].size())

	request_body.merge(additional_params)

	var body_stringified: String = JSON.stringify(request_body)

	var response: RequestResults = await make_request(
		"%s/v1/chat/completions" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		[
			"Content-Type: application/json",
			"Authorization: Bearer %s" % API_KEY
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
			"tool_call_id": sanitize_tool_id(chat_item.ToolCallId),
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
			push_warning("[OpenAI] Unknown chat role: %s, defaulting to user" % chat_item.Role)
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
				"id": sanitize_tool_id(tool_call.get("id", "")),
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


# Reimplemented to handle image notes properly
func wrap_memory(item: Note) -> Variant:
	if item.type == Note.Type.IMAGE:
		return (item.get_controls_container() as NoteImageControls).image

	elif item.type == Note.Type.TEXT:
		return (item.get_controls_container() as NoteTextControls).content

	else:
		push_warning("Tried to wrap memory but the given note type is not implemented")
		print_stack()

	return ""


# Response format:
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
	response.id = data["id"]

	var message: Dictionary = data["choices"][0]["message"]
	var finish_reason = data["choices"][0]["finish_reason"]

	if finish_reason == "length":
		response.complete = false

	response.prompt_tokens = data["usage"]["prompt_tokens"]
	response.completion_tokens = data["usage"]["completion_tokens"]

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
# Model Variants - GPT-5.2 with different reasoning levels
# ============================================================================

## Nano: Fast, cost-effective for simple queries
class Nano extends OpenAIProvider:
	func _init():
		super()
		model_name = "gpt-5-nano"
		display_name = "GPT-5 Nano"
		short_name = "G5N"
		reasoning_effort = ""  # No reasoning for nano model
		input_token_cost = 0.10   # $0.10 per million input tokens
		output_token_cost = 0.40   # $0.40 per million output tokens

		# Nano is not a reasoning model, supports all params
		is_reasoning_model = false
		supports_temperature = true
		supports_top_p = true
		supports_frequency_penalty = true
		supports_presence_penalty = true


## Standard: Medium reasoning (default for daily tasks)
class Standard extends OpenAIProvider:
	func _init():
		super()
		model_name = "gpt-5.2"
		display_name = "GPT-5.2"
		short_name = "G5"
		reasoning_effort = "medium"
		input_token_cost = 5.00   # $5 per million input tokens
		output_token_cost = 15.00  # $15 per million output tokens


## Deep: High reasoning for complex tasks requiring more thought
class Deep extends OpenAIProvider:
	func _init():
		super()
		model_name = "gpt-5.2"
		display_name = "GPT-5.2 Deep"
		short_name = "G5D"
		reasoning_effort = "xhigh"
		input_token_cost = 5.00   # $5 per million input tokens
		output_token_cost = 15.00  # $15 per million output tokens
