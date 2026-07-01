class_name AnthropicProvider
extends BaseProvider
## Consolidated Anthropic/Claude provider with tool support.
## Supports multimodal content (text, images).

var system_prompt: String
var api_model_id: String
var max_tokens: int

## Path to write HTTP request/response debug logs. Empty = no logging.
static var debug_log_path: String = ""
static var _debug_log_counter: int = 0

## Available tools for agentic mode (set by ChatPane when agent mode is enabled)
var available_tools: Array[Dictionary] = []

## Whether tool use is enabled for this provider
var tools_enabled: bool = false


func _init():
	provider_name = "Anthropic"
	BASE_URL = "https://api.anthropic.com/v1"
	PROVIDER = SingletonObject.API_PROVIDER.ANTHROPIC

	# Default model - subclasses override these
	api_model_id = "claude-sonnet-4-5-20250929"
	max_tokens = 64000
	model_name = "claude-sonnet-4.5"
	short_name = "CS"
	input_token_cost = 3.00   # $3 per million input tokens
	output_token_cost = 15.00  # $15 per million output tokens

	# Request timeout - complex reasoning tasks can take time
	default_timeout = 120.0

	# Claude supports temperature (0-1) and top_p, but not both together
	supports_temperature = true
	supports_top_p = true
	temperature_max = 1.0
	temperature_warning = "Use temperature OR top_p, not both"


## Set available tools for agentic mode
func set_tools(tools: Array[Dictionary]) -> void:
	available_tools = tools
	tools_enabled = not tools.is_empty()


## Format tools for Anthropic API
func format_tools_for_request() -> Array:
	var formatted: Array = []
	for tool in available_tools:
		formatted.append({
			"name": tool.get("name", ""),
			"description": tool.get("description", ""),
			"input_schema": tool.get("input_schema", {"type": "object", "properties": {}})
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
			# Check for rate limiting before generic error handling
			var error_type: String = ""
			if data is Dictionary and "error" in data:
				var err = data["error"]
				if err is Dictionary:
					error_type = err.get("type", "")

			if response.response_code == 429 or error_type in ["rate_limit_error", "overloaded_error"]:
				bot_response.is_rate_limited = true
				bot_response.rate_limit_retry_after = parse_retry_after(response.headers)
				bot_response.error = "Rate limited by Anthropic"
				print("[Anthropic] Rate limited (HTTP %d, type: %s, retry_after: %s)" % [response.response_code, error_type, bot_response.rate_limit_retry_after])
			elif "error" in data:
				bot_response.error = data["error"]["message"]
			else:
				bot_response.error = "Unexpected error occurred while generating the response"
	else:
		push_error("Invalid result. Response: %s", response.response_code)
		bot_response.error = "Unexpected error occurred with HTTP Client. Code %s" % response.http_request_result
		return bot_response

	return bot_response


# https://docs.anthropic.com/en/api/messages
func generate_content(prompt: Array[Variant], additional_params: Dictionary = {}):
	var system_payload: Variant = system_prompt
	if not system_prompt.is_empty():
		system_payload = [{
			"type": "text",
			"text": system_prompt,
			"cache_control": {"type": "ephemeral"}
		}]

	var request_messages: Array[Variant] = prompt.duplicate(true)
	if not request_messages.is_empty():
		var first_message = request_messages[0]
		if first_message is Dictionary:
			var content = first_message.get("content", [])
			if content is Array and not content.is_empty():
				var content_blocks: Array = content.duplicate(true)
				var first_block = content_blocks[0]
				if first_block is Dictionary and first_block.get("type", "") == "text":
					first_block["cache_control"] = {"type": "ephemeral"}
					content_blocks[0] = first_block
					first_message["content"] = content_blocks
					request_messages[0] = first_message

	var request_body = {
		"model": api_model_id,
		"messages": request_messages,
		"max_tokens": max_tokens,
		"system": system_payload
	}

	# Add tools if enabled
	print("[Claude] generate_content: tools_enabled=%s, available_tools.size=%d" % [tools_enabled, available_tools.size()])
	if tools_enabled and not available_tools.is_empty():
		request_body["tools"] = format_tools_for_request()
		print("[Claude] Added %d tools to request" % request_body["tools"].size())

	request_body.merge(additional_params)

	var body_stringified: String = JSON.stringify(request_body)

	print("[AnthropicProvider] generate_content called. debug_log_path='%s' body_chars=%d" % [debug_log_path, body_stringified.length()])
	_debug_log_request(body_stringified)

	var response: RequestResults = await make_request(
		"%s/messages" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		[
			"Content-Type: application/json",
			"x-api-key: %s" % API_KEY,
			"anthropic-version: 2023-06-01",
		],
	)

	_debug_log_response(response)

	var item = _parse_request_results(response)

	SingletonObject.chat_completed.emit(item)

	return item


static func _debug_log_request(body: String) -> void:
	if debug_log_path.is_empty():
		return
	_debug_log_counter += 1
	var entry := {
		"seq": _debug_log_counter,
		"direction": "request",
		"timestamp": Time.get_datetime_string_from_system(true),
		"body_chars": body.length(),
		"body": JSON.parse_string(body),
	}
	_debug_append_log(JSON.stringify(entry, "\t"))


static func _debug_log_response(response: RequestResults) -> void:
	if debug_log_path.is_empty():
		return
	var body_text := response.body.get_string_from_utf8() if response.body else ""
	var entry := {
		"seq": _debug_log_counter,
		"direction": "response",
		"timestamp": Time.get_datetime_string_from_system(true),
		"success": response.success,
		"http_code": response.response_code,
		"body_chars": body_text.length(),
		"body": JSON.parse_string(body_text),
	}
	_debug_append_log(JSON.stringify(entry, "\t"))


static func _debug_append_log(json_line: String) -> void:
	var f := FileAccess.open(debug_log_path, FileAccess.READ_WRITE)
	if not f:
		f = FileAccess.open(debug_log_path, FileAccess.WRITE)
	if not f:
		push_error("[AnthropicProvider] Cannot open debug log: %s" % debug_log_path)
		return
	f.seek_end(0)
	f.store_string(json_line + "\n---\n")
	f.close()


func wrap_memory(item: Note) -> Variant:
	if item.type == Note.Type.IMAGE:
		var controls = item.get_controls_container() as NoteImageControls
		if not controls:
			push_error("[AnthropicProvider] wrap_memory: IMAGE note has no controls!")
			return null
		var img = controls.image
		if not img:
			push_error("[AnthropicProvider] wrap_memory: IMAGE note controls.image is null!")
			return null
		if img.is_empty():
			push_error("[AnthropicProvider] wrap_memory: IMAGE note image is empty! (size: %dx%d)" % [img.get_width(), img.get_height()])
			return null
		print("[AnthropicProvider] wrap_memory: IMAGE note OK (size: %dx%d, format: %s)" % [img.get_width(), img.get_height(), img.get_format()])
		return img

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
		ChatHistoryItem.ChatRole.ASSISTANT:
			role = "assistant"
		ChatHistoryItem.ChatRole.SYSTEM:
			role = "system"
		ChatHistoryItem.ChatRole.MODEL:
			role = "assistant"
		ChatHistoryItem.ChatRole.TOOL:
			# Tool results are sent as user messages with tool_result content
			return {
				"role": "user",
				"content": [{
					"type": "tool_result",
					"tool_use_id": sanitize_tool_id(chat_item.ToolCallId),
					"content": chat_item.Message
				}]
			}

	# Handle assistant messages with tool calls (MODEL role is used for bot responses)
	var is_assistant_role = chat_item.Role == ChatHistoryItem.ChatRole.ASSISTANT or chat_item.Role == ChatHistoryItem.ChatRole.MODEL
	if is_assistant_role and chat_item.IsToolCall and not chat_item.ToolCalls.is_empty():
		var tool_content: Array = []
		# Add any text content first
		if not chat_item.Message.is_empty():
			tool_content.append({
				"type": "text",
				"text": chat_item.Message
			})
		# Add tool_use blocks
		for tool_call in chat_item.ToolCalls:
			tool_content.append({
				"type": "tool_use",
				"id": sanitize_tool_id(tool_call.get("id", "")),
				"name": tool_call.get("name", ""),
				"input": tool_call.get("arguments", {})
			})
		return {
			"role": "assistant",
			"content": tool_content
		}

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
	var content: Array = []

	# Only add text block if there's actual text (Anthropic rejects empty text blocks)
	if not full_text.is_empty():
		content.append({
			"type": "text",
			"text": full_text
		})

	# Add image notes
	for img in media_notes:
		if not img or not img is Image:
			push_warning("[AnthropicProvider] Skipping invalid image note (null or wrong type)")
			continue
		var png_buffer = img.save_png_to_buffer()
		if png_buffer.is_empty():
			push_warning("[AnthropicProvider] Skipping image with empty PNG buffer (size: %dx%d, format: %s)" % [img.get_width(), img.get_height(), img.get_format()])
			continue
		content.append({
			"type": "image",
			"source": {
				"type": "base64",
				"media_type": "image/png",
				"data": Marshalls.raw_to_base64(png_buffer),
			}
		})

	# Anthropic requires non-empty content - if we have nothing, add placeholder
	if content.is_empty():
		content.append({
			"type": "text",
			"text": "(empty message)"
		})

	return {
		"role": role,
		"content": content
	}


func estimate_tokens(input) -> int:
	return roundi(input.get_slice_count(" ") * 1.335)


func estimate_tokens_from_prompt(input: Array[Variant]):
	var all_messages: Array[String] = []
	# Get all user messages
	for msg: Dictionary in input:
		var content = msg.get("content")

		if content is String:
			all_messages.append(msg["content"])

		elif content is Array:
			for part: Dictionary in content:
				if part.get("type") == "text":
					all_messages.append(part.get("text"))

	return estimate_tokens("".join(all_messages))


func continue_partial_response(_partial_chi: ChatHistoryItem):
	return null


# Response format:
# {
#   "content": [
#     {"type": "text", "text": "..."},
#     {"type": "tool_use", "id": "...", "name": "...", "input": {...}}
#   ],
#   "id": "msg_xxx",
#   "model": "claude-...",
#   "role": "assistant",
#   "stop_reason": "end_turn" | "tool_use" | "max_tokens",
#   "usage": {"input_tokens": 10, "output_tokens": 25}
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()

	response.provider = self
	response.id = data["id"]

	var finish_reason = data["stop_reason"]

	if finish_reason == "max_tokens":
		response.complete = false

	response.prompt_tokens = data["usage"]["input_tokens"]
	response.completion_tokens = data["usage"]["output_tokens"]
	response.cache_creation_tokens = int(data["usage"].get("cache_creation_input_tokens", 0))
	response.cache_read_tokens = int(data["usage"].get("cache_read_input_tokens", 0))

	# Parse content blocks - can be text and/or tool_use
	var text_parts: PackedStringArray = []
	var content_array: Array = data.get("content", [])

	for block in content_array:
		var block_type: String = block.get("type", "")

		if block_type == "text":
			text_parts.append(block.get("text", ""))

		elif block_type == "tool_use":
			# Add tool call to response
			response.add_tool_call(
				block.get("id", ""),
				block.get("name", ""),
				block.get("input", {})
			)

	# Combine all text parts
	response.text = "\n".join(text_parts)

	extract_reasoning(data, response)

	return response


## Extract reasoning from an Anthropic response into the display sequence.
## Anthropic emits thinking as distinct content blocks (the main text/tool_use
## loop ignores them, so there is no text-leak risk):
##   {type: "thinking", thinking: "...", signature: "..."} — visible chain-of-thought
##   {type: "redacted_thinking", data: "..."} — encrypted, no readable text
## On display:omitted model generations the thinking block is present but its
## text is empty; that is treated as a redacted placeholder.
func extract_reasoning(data: Variant, bot_response: BotResponse) -> void:
	if not (data is Dictionary): return
	var content_array = data.get("content", [])
	if not (content_array is Array): return

	for block in content_array:
		if not (block is Dictionary): continue
		var block_type: String = str(block.get("type", ""))
		if block_type == "thinking":
			var thinking_text: String = str(block.get("thinking", ""))
			if thinking_text.is_empty():
				bot_response.add_reasoning("", "thinking", true)
			else:
				bot_response.add_reasoning(thinking_text, "thinking", false)
		elif block_type == "redacted_thinking":
			bot_response.add_reasoning("", "thinking", true)


## Claude 4.x models support extended thinking, so always offer the picker.
func uses_reasoning_effort_picker() -> bool:
	return true


## Map the picker's effort onto Anthropic extended thinking. budget_tokens must
## stay below max_tokens, so cap conservatively.
func apply_reasoning_options(params: Dictionary, level: String, enabled: bool) -> void:
	if not enabled:
		params["thinking"] = {"type": "disabled"}
		return
	var budget := 8192
	match level:
		"low": budget = 2048
		"medium": budget = 8192
		"high": budget = 16384
	if budget >= max_tokens:
		budget = maxi(1024, int(max_tokens / 2.0))
	params["thinking"] = {"type": "enabled", "budget_tokens": budget}


# ============================================================================
# Dynamic Model Factory
# ============================================================================

## Creates a configured AnthropicProvider instance from a model config dictionary.
## Config keys: api_model_id, model_name, display_name, short_name, max_tokens,
##              input_token_cost, output_token_cost
static func create_from_config(config: Dictionary) -> AnthropicProvider:
	var p := AnthropicProvider.new()
	p.api_model_id = config.get("api_model_id", p.api_model_id)
	p.model_name = config.get("model_name", p.model_name)
	p.display_name = config.get("display_name", p.model_name)
	p.short_name = config.get("short_name", "A")
	p.max_tokens = config.get("max_tokens", p.max_tokens)
	p.input_token_cost = config.get("input_token_cost", 0.0)
	p.output_token_cost = config.get("output_token_cost", 0.0)
	return p


# ============================================================================
# Model Variants
# ============================================================================

## Claude Haiku 4.5: Fast, cost-effective for simple tasks
class Haiku extends AnthropicProvider:
	func _init():
		super()
		api_model_id = "claude-haiku-4-5"
		model_name = "claude-haiku-4.5"
		display_name = "Claude Haiku 4.5"
		short_name = "CH"
		max_tokens = 8192
		input_token_cost = 0.80   # $0.80 per million input tokens
		output_token_cost = 4.00   # $4 per million output tokens


## Claude Sonnet 4.5: Best balance of speed and capability
class Sonnet extends AnthropicProvider:
	func _init():
		super()
		api_model_id = "claude-sonnet-4-5"
		model_name = "claude-sonnet-4.5"
		display_name = "Claude Sonnet 4.5"
		short_name = "CS"
		max_tokens = 64000
		input_token_cost = 3.00   # $3 per million input tokens
		output_token_cost = 15.00  # $15 per million output tokens


## Claude Opus 4.5: Most capable for complex reasoning
class Opus extends AnthropicProvider:
	func _init():
		super()
		api_model_id = "claude-opus-4-5"
		model_name = "claude-opus-4.5"
		display_name = "Claude Opus 4.5"
		short_name = "CO"
		max_tokens = 32000
		input_token_cost = 5.00   # $5 per million input tokens
		output_token_cost = 25.00  # $25 per million output tokens
