class_name ChatGPTBase
extends BaseProvider


# this params are only used in chatGPT
var temperature: float = 1
var topP: float = 1
var FrequencyPenalty: float = 0
var presencePenalty: float = 0

## Available tools for agentic mode (set by ChatPane when agent mode is enabled)
var available_tools: Array[Dictionary] = []

## Whether tool use is enabled for this provider
var tools_enabled: bool = false

# Change the `model_name` and `short_name` in _ready function

func _init():
	provider_name = "OpenAI"
	BASE_URL = "https://api.openai.com"
	PROVIDER = SingletonObject.API_PROVIDER.OPENAI


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
		return

	return bot_response


# https://platform.openai.com/docs/guides/text-generation/chat-completions-api
func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:

	var request_body = {
		"model": model_name,
		"messages": prompt,
	}

	# Add tools if enabled
	print("[OpenAI] generate_content: tools_enabled=%s, available_tools.size=%d" % [tools_enabled, available_tools.size()])
	if tools_enabled and not available_tools.is_empty():
		request_body["tools"] = format_tools_for_request()
		print("[OpenAI] Added %d tools to request" % request_body["tools"].size())

	# Debug: print all messages being sent
	print("[OpenAI] Messages being sent:")
	for i in range(prompt.size()):
		var msg = prompt[i]
		if msg is Dictionary:
			print("[OpenAI]   [%d] role=%s, has_tool_calls=%s, has_tool_call_id=%s" % [
				i,
				msg.get("role", "MISSING"),
				msg.has("tool_calls"),
				msg.has("tool_call_id")
			])
		else:
			print("[OpenAI]   [%d] NOT A DICT: %s" % [i, typeof(msg)])

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
	print("[OpenAI Format] Role=%s, IsToolCall=%s, ToolCalls.size=%d, ToolCallId=%s" % [
		chat_item.Role, chat_item.IsToolCall, chat_item.ToolCalls.size(), chat_item.ToolCallId
	])

	# Handle TOOL role first (must be before match statement for proper return)
	if chat_item.Role == ChatHistoryItem.ChatRole.TOOL:
		var result = {
			"role": "tool",
			"tool_call_id": chat_item.ToolCallId,
			"content": chat_item.Message
		}
		print("[OpenAI Format] Returning TOOL: %s" % JSON.stringify(result).left(200))
		return result

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
		print("[OpenAI Format] Returning ASSISTANT with tool_calls: %s" % JSON.stringify(result).left(300))
		return result

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

	# Get all image captions in array of strings
	var image_captions_array = chat_item.Images.map(func(img: Image): return img.get_meta("caption", "No caption."))
	var image_captions: String

	# if there are images, construct the image captions into one string for prompt
	if not image_captions_array.is_empty():
		image_captions = "Image Caption: %s" % "\n".join(image_captions_array)

	# Combine everything
	var text := "%s\n%s\n%s" % [image_captions, notes_section, chat_item.Message]
	text = text.strip_edges()

	var final_result = {
		"role": role,
		"content": text
	}
	print("[OpenAI Format] Returning regular message: role=%s, content_len=%d" % [role, text.length()])
	return final_result


func wrap_memory(item: Note) -> Variant:
	if item.type == Note.Type.TEXT:
		var controls_container = item.get_controls_container() as NoteTextControls
		return controls_container.content
	elif item.type == Note.Type.IMAGE:
		var controls_container = item.get_controls_container() as NoteImageControls
		return controls_container.caption
	else:
		push_warning("Tried to wrap memory but the given note type is not implemented")
		print_stack()

	return ""

# {
#   "id": "chatcmpl-9LJ12Ijrr2MAwBtHQdO3xHMut1pAn",
#   "object": "chat.completion",
#   "created": 1714865012,
#   "model": "gpt-3.5-turbo-0125",
#   "choices": [
#     {
#       "index": 0,
#       "message": {
#         "role": "assistant",
#         "content": "Hello! How can I assist you today?"
#       },
#       "logprobs": null,
#       "finish_reason": "stop"
#     }
#   ],
#   "usage": {
#     "prompt_tokens": 8,
#     "completion_tokens": 9,
#     "total_tokens": 17
#   },
#   "system_fingerprint": "fp_3b956da36b"
# }
# Tool call response example:
# {
#   "choices": [{
#     "message": {
#       "role": "assistant",
#       "content": null,
#       "tool_calls": [
#         {"id": "call_xyz", "type": "function", "function": {"name": "get_weather", "arguments": "{\"location\":\"NYC\"}"}}
#       ]
#     },
#     "finish_reason": "tool_calls"
#   }]
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()

	# set the used provider so update model name
	response.provider = self

	# the id will be useful if we need to complete the response with second request
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
				# Parse JSON string arguments
				var parsed = JSON.parse_string(args_string)
				if parsed is Dictionary:
					args = parsed

				response.add_tool_call(
					tool_call.get("id", ""),
					func_data.get("name", ""),
					args
				)

	# Note: tool_calls finish_reason does NOT set complete=false
	# The agentic chat loop handles tool call continuation separately
	# complete=false is only for length truncation

	return response


func estimate_tokens(input) -> int:
	return roundi(input.get_slice_count(" ") * token_cost)


func estimate_tokens_from_prompt(input: Array[Variant]):
	var all_messages: Array[String] = []

	# get all user messages
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
	var chi = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	chi.Message = "finish"

	return chi
