class_name ChatGPTProvider
extends BaseProvider
## ChatGPT provider that authenticates via OAuth PKCE and calls the ChatGPT
## backend API (chatgpt.com/backend-api/codex/responses) using the Responses API format.
## This lets ChatGPT Plus/Pro subscribers use their subscription inside Minerva.

const CHATGPT_BASE_URL = "https://chatgpt.com/backend-api"
const CODEX_ENDPOINT = "/codex/responses"
const ChatGPTAuthScript = preload("res://Scripts/Services/Providers/ChatGPT/ChatGPTAuth.gd")

## System prompt to send with the request (set by ChatPane)
var system_prompt: String

## Available tools for agentic mode
var available_tools: Array[Dictionary] = []
var tools_enabled: bool = false

## Shared auth instance (set from PreferencesPopup or singleton)
static var auth: RefCounted = null


static func get_auth() -> RefCounted:
	if auth == null:
		auth = ChatGPTAuthScript.new()
	return auth


func _init():
	provider_name = "ChatGPT"
	BASE_URL = CHATGPT_BASE_URL
	PROVIDER = SingletonObject.API_PROVIDER.CHATGPT

	model_name = "gpt-5.4"
	display_name = "ChatGPT"
	short_name = "CG"

	# Free for subscribers
	input_token_cost = 0.0
	output_token_cost = 0.0

	# Capability flags
	supports_temperature = false
	supports_top_p = false
	supports_system_prompt = true
	is_reasoning_model = true

	default_timeout = 180.0


func set_tools(tools: Array[Dictionary]) -> void:
	available_tools = tools
	tools_enabled = not tools.is_empty()


## Format tools for Responses API format
func format_tools_for_request() -> Array:
	var formatted: Array = []
	for tool in available_tools:
		formatted.append({
			"type": "function",
			"name": tool.get("name", ""),
			"description": tool.get("description", ""),
			"parameters": tool.get("input_schema", {"type": "object", "properties": {}})
		})
	return formatted


func generate_content(prompt: Array[Variant], additional_params: Dictionary = {}) -> BotResponse:
	var bot_response := BotResponse.new()
	bot_response.provider = self

	var chatgpt_auth := get_auth()

	# Ensure we have a valid token
	if not chatgpt_auth.is_authenticated():
		chatgpt_auth.load_tokens()

	if not chatgpt_auth.is_authenticated():
		bot_response.error = "ChatGPT not connected. Please connect via Preferences."
		SingletonObject.chat_completed.emit(bot_response)
		return bot_response

	# Refresh token if needed
	var token_valid: bool = await chatgpt_auth.ensure_valid_token(get_tree())
	if not token_valid:
		bot_response.error = "ChatGPT token expired. Please reconnect via Preferences."
		SingletonObject.chat_completed.emit(bot_response)
		return bot_response

	# Build Responses API input array (flatten arrays from Format())
	# Also convert standard "text" content type to ChatGPT-specific input_text/output_text
	var input_items: Array = []
	for item in prompt:
		if item is Array:
			for sub_item in item:
				if sub_item != null:
					input_items.append(_convert_content_types(sub_item))
		elif item != null:
			input_items.append(_convert_content_types(item))

	# Build request body — instructions is always required by the backend
	var instructions: String = system_prompt if not system_prompt.is_empty() else "You are a helpful AI assistant."
	var request_body: Dictionary = {
		"model": model_name,
		"instructions": instructions,
		"input": input_items,
		"store": false,
		"stream": true,
		"reasoning": {"effort": "medium", "summary": "auto"},
		"include": ["reasoning.encrypted_content"],
	}

	# Add tools if enabled
	if tools_enabled and not available_tools.is_empty():
		request_body["tools"] = format_tools_for_request()

	request_body.merge(additional_params)

	var body_str := JSON.stringify(request_body)
	var url := "%s%s" % [CHATGPT_BASE_URL, CODEX_ENDPOINT]

	var headers: Array[String] = [
		"Content-Type: application/json",
		"Authorization: Bearer %s" % chatgpt_auth.access_token,
		"chatgpt-account-id: %s" % chatgpt_auth.account_id,
		"OpenAI-Beta: responses=experimental",
		"originator: codex_cli_rs",
		"accept: text/event-stream",
	]

	var response := await make_request(url, HTTPClient.METHOD_POST, body_str, headers)

	bot_response = _parse_sse_response(response)

	SingletonObject.chat_completed.emit(bot_response)
	return bot_response


## Parse the SSE response from the ChatGPT backend
func _parse_sse_response(response: RequestResults) -> BotResponse:
	var bot_response := BotResponse.new()
	bot_response.provider = self

	if not response.success:
		bot_response.error = response.message
		return bot_response

	if response.http_request_result != HTTPRequest.RESULT_SUCCESS:
		bot_response.error = "HTTP request failed with code %s" % response.http_request_result
		return bot_response

	if response.response_code < 200 or response.response_code > 299:
		var err_body := response.body.get_string_from_utf8()
		var err_json = JSON.parse_string(err_body)

		# Check for rate limiting first
		if response.response_code == 429:
			bot_response.is_rate_limited = true
			bot_response.rate_limit_retry_after = parse_retry_after(response.headers)
			bot_response.error = "Rate limited by ChatGPT"
			print("[ChatGPT] Rate limited (HTTP 429, retry_after: %s)" % bot_response.rate_limit_retry_after)
			return bot_response

		if err_json is Dictionary:
			var err_msg = ""
			if "error" in err_json:
				var err_obj = err_json["error"]
				if err_obj is Dictionary:
					err_msg = err_obj.get("message", str(err_obj))
				else:
					err_msg = str(err_obj)
			elif "message" in err_json:
				err_msg = err_json["message"]
			else:
				err_msg = err_body
			bot_response.error = err_msg
		else:
			bot_response.error = "ChatGPT API error (HTTP %d)" % response.response_code
		return bot_response

	# Parse SSE events from the response body
	var body_text := response.body.get_string_from_utf8()
	var text_parts := PackedStringArray()
	var response_id := ""
	var prompt_tokens := 0
	var completion_tokens := 0

	# Track function call metadata from output_item events (name, call_id)
	# since function_call_arguments.done may have name=null (known OpenAI API bug)
	var _pending_func_calls: Dictionary = {}  # item_id → {"name": ..., "call_id": ...}
	var reasoning_parts := PackedStringArray()

	# Split on double newline to get individual events
	var events := body_text.split("\n\n")
	for event_str in events:
		if event_str.strip_edges().is_empty():
			continue

		# Extract data lines
		for line in event_str.split("\n"):
			if not line.begins_with("data: "):
				continue

			var data_str := line.substr(6)  # Remove "data: " prefix
			if data_str == "[DONE]":
				continue

			var data = JSON.parse_string(data_str)
			if data == null or not data is Dictionary:
				continue

			# Extract response ID
			if response_id.is_empty() and "id" in data:
				response_id = data["id"]

			var event_type: String = data.get("type", "")

			# Collect text content from various event types
			match event_type:
				"response.output_text.delta":
					var delta_text: String = data.get("delta", "")
					if not delta_text.is_empty():
						text_parts.append(delta_text)

				"response.output_text.done":
					var full_text: String = data.get("text", "")
					if not full_text.is_empty() and text_parts.is_empty():
						text_parts.append(full_text)

				"response.reasoning_summary_text.delta":
					var delta_text: String = data.get("delta", "")
					if not delta_text.is_empty():
						reasoning_parts.append(delta_text)

				"response.output_item.added", "response.output_item.done":
					# Capture function_call metadata (name, call_id) from output items.
					# These events carry the full item including name, which
					# function_call_arguments.done may omit (OpenAI API bug).
					var item = data.get("item", {})
					if item is Dictionary and item.get("type") == "function_call":
						var item_id: String = item.get("id", "")
						if not item_id.is_empty():
							_pending_func_calls[item_id] = {
								"name": str(item.get("name", "")),
								"call_id": str(item.get("call_id", item_id)),
								"arguments": str(item.get("arguments", "")),
							}

				"response.function_call_arguments.done":
					# Individual function call completion — arguments are final here.
					# Name may be null (OpenAI bug), so fall back to _pending_func_calls.
					var item_id: String = data.get("item_id", "")
					var func_name: String = str(data.get("name", ""))
					var call_id: String = str(data.get("call_id", ""))
					var args_str: String = data.get("arguments", "{}")

					# Fall back to pending metadata if name is missing
					if func_name.is_empty() and _pending_func_calls.has(item_id):
						var pending: Dictionary = _pending_func_calls[item_id]
						func_name = pending.get("name", "")
						if call_id.is_empty():
							call_id = pending.get("call_id", item_id)
					if call_id.is_empty():
						call_id = item_id

					var args: Dictionary = {}
					var parsed = JSON.parse_string(args_str)
					if parsed is Dictionary:
						args = parsed
					if not func_name.is_empty():
						bot_response.add_tool_call(call_id, func_name, args)

				"response.completed", "response.done":
					var resp = data.get("response", data)
					if resp is Dictionary:
						if response_id.is_empty() and "id" in resp:
							response_id = resp["id"]
						var usage = resp.get("usage", {})
						if usage is Dictionary:
							prompt_tokens = usage.get("input_tokens", usage.get("prompt_tokens", 0))
							completion_tokens = usage.get("output_tokens", usage.get("completion_tokens", 0))

						# Extract text from output array if we didn't get deltas
						if text_parts.is_empty():
							var output_items = resp.get("output", [])
							if output_items is Array:
								for item in output_items:
									if item is Dictionary and item.get("type") == "message":
										var content = item.get("content", [])
										if content is Array:
											for part in content:
												if part is Dictionary and part.get("type") == "output_text":
													text_parts.append(part.get("text", ""))

						# Parse tool calls from output (fallback if streaming events missed them)
						if bot_response.tool_calls.is_empty():
							var output = resp.get("output", [])
							if output is Array:
								for item in output:
									if item is Dictionary and item.get("type") == "function_call":
										var tc_name: String = str(item.get("name", ""))
										var tc_call_id: String = str(item.get("call_id", item.get("id", "")))
										var tc_args_str: String = item.get("arguments", "{}")
										var tc_args: Dictionary = {}
										var tc_parsed = JSON.parse_string(tc_args_str)
										if tc_parsed is Dictionary:
											tc_args = tc_parsed
										if not tc_name.is_empty():
											bot_response.add_tool_call(tc_call_id, tc_name, tc_args)

	bot_response.text = "".join(text_parts)
	# Reasoning captured but BotResponse has no reasoning field yet — store for future use
	#bot_response.reasoning = "".join(reasoning_parts)
	bot_response.id = response_id
	bot_response.prompt_tokens = prompt_tokens
	bot_response.completion_tokens = completion_tokens

	return bot_response


func Format(chat_item: ChatHistoryItem) -> Variant:
	# Handle TOOL role (function call output)
	if chat_item.Role == ChatHistoryItem.ChatRole.TOOL:
		return {
			"type": "function_call_output",
			"call_id": sanitize_tool_id(chat_item.ToolCallId),
			"output": chat_item.Message,
		}

	var is_assistant := chat_item.Role == ChatHistoryItem.ChatRole.ASSISTANT or chat_item.Role == ChatHistoryItem.ChatRole.MODEL

	# Handle assistant messages with tool calls
	if is_assistant and chat_item.IsToolCall and not chat_item.ToolCalls.is_empty():
		# Return individual function_call items for each tool call
		# The Responses API expects these as separate input items
		var items: Array = []

		# Add text content as a message if present
		if not chat_item.Message.is_empty():
			items.append({
				"type": "message",
				"role": "assistant",
				"content": [{"type": "text", "text": chat_item.Message}]
			})

		for tool_call in chat_item.ToolCalls:
			var args = tool_call.get("arguments", {})
			var args_string: String
			if args is String:
				args_string = args
			else:
				args_string = JSON.stringify(args)

			items.append({
				"type": "function_call",
				"call_id": sanitize_tool_id(tool_call.get("id", "")),
				"name": tool_call.get("name", ""),
				"arguments": args_string,
			})

		# If only one item, return it directly; otherwise the caller
		# needs to handle arrays (will be flattened in generate_content)
		if items.size() == 1:
			return items[0]
		return items

	# Build content based on role
	# Use standard "text" content type for cross-provider compatibility.
	# The ChatGPT-specific input_text/output_text conversion happens in generate_content().
	var role: String

	match chat_item.Role:
		ChatHistoryItem.ChatRole.USER:
			role = "user"
		ChatHistoryItem.ChatRole.ASSISTANT, ChatHistoryItem.ChatRole.MODEL:
			role = "assistant"
		ChatHistoryItem.ChatRole.SYSTEM:
			# System messages are handled via the instructions field
			return null
		_:
			role = "user"

	# Collect text notes
	var text_notes := PackedStringArray()
	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			text_notes.append(note)

	var notes_section := ""
	if not text_notes.is_empty():
		notes_section = "### Reference Information ###\n"
		notes_section += "\n\n".join(text_notes)
		notes_section += "\n### End Reference Information ###\n\n"

	var full_text := "%s%s" % [notes_section, chat_item.Message]
	full_text = full_text.strip_edges()

	return {
		"type": "message",
		"role": role,
		"content": [{"type": "text", "text": full_text}]
	}


## Convert standard "text" content types to ChatGPT Responses API-specific types.
## Format() uses "text" for cross-provider compatibility; this converts at API call time.
func _convert_content_types(item: Variant) -> Variant:
	if not item is Dictionary:
		return item
	# Only convert "message" type items that have content arrays
	if item.get("type", "") != "message":
		return item
	var content: Variant = item.get("content", [])
	if not content is Array:
		return item
	var role: String = item.get("role", "user")
	var target_type: String = "input_text" if role == "user" else "output_text"
	var new_content: Array = []
	for block in content:
		if block is Dictionary and block.get("type", "") == "text":
			new_content.append({"type": target_type, "text": block.get("text", "")})
		else:
			new_content.append(block)
	var result: Dictionary = item.duplicate()
	result["content"] = new_content
	return result


func wrap_memory(item: Note) -> Variant:
	if item.type == Note.Type.IMAGE:
		return (item.get_controls_container() as NoteImageControls).image
	elif item.type == Note.Type.TEXT:
		return (item.get_controls_container() as NoteTextControls).content
	else:
		push_warning("Tried to wrap memory but the given note type is not implemented")
	return ""


func estimate_tokens(input: String) -> int:
	return roundi(input.get_slice_count(" ") * 1.335)


func estimate_tokens_from_prompt(input: Array[Variant]):
	var tokens: float = 0.0
	for item: Variant in input:
		if item is Dictionary:
			var content = item.get("content", [])
			if content is Array:
				for part in content:
					if part is Dictionary and part.get("type", "").ends_with("_text"):
						tokens += estimate_tokens(part.get("text", ""))
			elif content is String:
				tokens += estimate_tokens(content)
	return tokens


func continue_partial_response(_partial_chi: ChatHistoryItem):
	var chi = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	chi.Message = "finish"
	return chi
