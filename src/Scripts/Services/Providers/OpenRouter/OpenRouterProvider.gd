class_name OpenRouterProvider
extends BaseProvider
## OpenRouter provider - unified API for multiple AI models.
## Uses OpenAI-compatible format for requests and responses.

# Provider-specific params
var temperature: float = 1
var topP: float = 1
var FrequencyPenalty: float = 0
var presencePenalty: float = 0

## System prompt to send with the request (set by ChatPane)
var system_prompt: String

## The OpenRouter model ID (e.g., "moonshotai/kimi-k2.5")
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
	model_name = "kimi-k2.5"
	api_model_id = "moonshotai/kimi-k2.5"
	short_name = "KK25"
	input_token_cost = 0.50   # $0.50 per million input tokens
	output_token_cost = 2.80   # $2.80 per million output tokens

	# Request timeout - variable backends may need more time
	default_timeout = 150.0

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
			if SingletonObject.verbose_logging:
				print("[OpenRouter] Error response (code %s): %s" % [response.response_code, data])

			# Check for rate limiting before generic error handling
			if response.response_code == 429:
				bot_response.is_rate_limited = true
				bot_response.rate_limit_retry_after = parse_retry_after(response.headers)
				bot_response.error = "Rate limited by OpenRouter"
				print("[OpenRouter] Rate limited (HTTP 429, retry_after: %s)" % bot_response.rate_limit_retry_after)
			elif "error" in data or "message" in data:
				if "error" in data:
					var error_data = data["error"]
					if error_data is Dictionary:
						# Extract detailed error info from OpenRouter's metadata
						var error_msg: String = error_data.get("message", "Unknown error")
						var error_code = error_data.get("code", "")
						var metadata = error_data.get("metadata", {})

						# The actual useful error is often in metadata.raw
						if metadata is Dictionary and metadata.has("raw"):
							var raw_error: String = metadata.get("raw", "")
							var provider_name_: String = metadata.get("provider_name", "")
							if provider_name_:
								bot_response.error = "[%s] %s" % [provider_name_, raw_error]
							else:
								bot_response.error = raw_error
						elif error_code:
							bot_response.error = "[Error %s] %s" % [error_code, error_msg]
						else:
							bot_response.error = error_msg
					else:
						bot_response.error = str(error_data)
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
	# Build messages array - prepend system prompt if set
	var messages: Array = []
	if not system_prompt.is_empty() and supports_system_prompt:
		messages.append({"role": "system", "content": system_prompt})
	messages.append_array(prompt)

	var request_body = {
		"model": api_model_id,
		"messages": messages,
		"provider": {
			"allow_fallbacks": false
		}
	}

	if SingletonObject.verbose_logging:
		print("[OpenRouter] Requesting model: %s" % api_model_id)

	# Add tools if enabled
	if SingletonObject.verbose_logging:
		print("[OpenRouter] generate_content: tools_enabled=%s, available_tools.size=%d" % [tools_enabled, available_tools.size()])
	if tools_enabled and not available_tools.is_empty():
		request_body["tools"] = format_tools_for_request()
		if SingletonObject.verbose_logging:
			print("[OpenRouter] Added %d tools to request" % request_body["tools"].size())

	request_body.merge(additional_params)

	var body_stringified: String = JSON.stringify(request_body)

	# Debug: print request body (truncated for readability)
	if SingletonObject.verbose_logging:
		var debug_body = body_stringified
		if debug_body.length() > 2000:
			debug_body = debug_body.substr(0, 2000) + "... [truncated]"
		print("[OpenRouter] Request body: %s" % debug_body)

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

	extract_reasoning(data, response)

	return response


## Extract reasoning from an OpenRouter response into the display sequence.
## OpenRouter surfaces reasoning in two shapes (no request param needed for
## models that reason by default):
##   message.reasoning_details: Array of {type, text|summary, ...} — preferred,
##     order-preserving, distinguishes summary vs raw vs encrypted.
##   message.reasoning: String — flat fallback when details are absent.
func extract_reasoning(data: Variant, bot_response: BotResponse) -> void:
	if not (data is Dictionary): return
	var choices = data.get("choices", [])
	if not (choices is Array) or choices.is_empty(): return
	var message = choices[0].get("message", {})
	if not (message is Dictionary): return

	# Preferred: structured, order-preserving reasoning_details
	var details = message.get("reasoning_details", [])
	if details is Array and not details.is_empty():
		for d in details:
			if not (d is Dictionary): continue
			var dtype: String = str(d.get("type", ""))
			var seg_text: String = str(d.get("text", d.get("summary", "")))
			if dtype.ends_with("encrypted"):
				# Opaque/signed payload — render a placeholder, no text to show
				bot_response.add_reasoning("", "thinking", true)
			elif not seg_text.is_empty():
				var kind := "summary" if dtype.ends_with("summary") else "thinking"
				bot_response.add_reasoning(seg_text, kind, false)
		return

	# Fallback: flat reasoning string
	var flat = message.get("reasoning", "")
	if flat is String and not flat.is_empty():
		bot_response.add_reasoning(flat, "thinking", false)


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
# Dynamic Model Factory
# ============================================================================

## Creates a configured OpenRouterProvider instance from a model config dictionary.
## Config keys: api_model_id, display_name, short_name, input_token_cost,
##              output_token_cost, is_reasoning_model
static func create_from_config(config: Dictionary) -> OpenRouterProvider:
	var p := OpenRouterProvider.new()
	p.api_model_id = config.get("api_model_id", "")
	var parts: PackedStringArray = p.api_model_id.split("/")
	p.model_name = parts[-1] if not parts.is_empty() else p.api_model_id
	p.display_name = config.get("display_name", p.model_name)
	p.short_name = config.get("short_name", "OR")
	p.input_token_cost = config.get("input_token_cost", 0.0)
	p.output_token_cost = config.get("output_token_cost", 0.0)
	p.is_reasoning_model = config.get("is_reasoning_model", false)
	return p
