class_name ClaudeSonnet
extends BaseProvider

var system_prompt: String
var api_model_id: String
var max_tokens: int

## Available tools for agentic mode (set by ChatPane when agent mode is enabled)
var available_tools: Array[Dictionary] = []

## Whether tool use is enabled for this provider
var tools_enabled: bool = false

func _init():
	provider_name = "Anthropic"
	BASE_URL = "https://api.anthropic.com/v1"
	PROVIDER = SingletonObject.API_PROVIDER.ANTHROPIC
	self.api_model_id = "claude-sonnet-4-5-20250929"
	self.max_tokens = 64000

	model_name = "claude-45-sonnet"
	short_name = "CS"
	token_cost = 0.000015 # https://claude101.com/claude-3-5-sonnet/


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


# https://docs.anthropic.com/en/api/messages
func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):
	var request_body = {
		"model": self.api_model_id,
		"messages": prompt,
		"max_tokens": self.max_tokens,
		"system": system_prompt
	}

	# Add tools if enabled
	print("[Claude] generate_content: tools_enabled=%s, available_tools.size=%d" % [tools_enabled, available_tools.size()])
	if tools_enabled and not available_tools.is_empty():
		request_body["tools"] = format_tools_for_request()
		print("[Claude] Added %d tools to request" % request_body["tools"].size())

	request_body.merge(additional_params)
	
	var body_stringified: String = JSON.stringify(request_body)
	
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

	var item = _parse_request_results(response)
	
	SingletonObject.chat_completed.emit(item)

	return item


func wrap_memory(item: Note) -> Variant:

	if item.type == Note.Type.IMAGE:
		return (item.get_controls_container() as NoteImageControls).image
	
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
					"tool_use_id": chat_item.ToolCallId,
					"content": chat_item.Message
				}]
			}

	# Handle assistant messages with tool calls (MODEL role is used for bot responses)
	var is_assistant_role = chat_item.Role == ChatHistoryItem.ChatRole.ASSISTANT or chat_item.Role == ChatHistoryItem.ChatRole.MODEL
	if is_assistant_role and chat_item.IsToolCall and not chat_item.ToolCalls.is_empty():
		var content: Array = []
		# Add any text content first
		if not chat_item.Message.is_empty():
			content.append({
				"type": "text",
				"text": chat_item.Message
			})
		# Add tool_use blocks
		for tool_call in chat_item.ToolCalls:
			content.append({
				"type": "tool_use",
				"id": tool_call.get("id", ""),
				"name": tool_call.get("name", ""),
				"input": tool_call.get("arguments", {})
			})
		return {
			"role": "assistant",
			"content": content
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

	# content can be a string, but also an array of dictionaries, to handle different media types
	# message and each note will be it's own dictionary
	var content: = [
		{
			"type": "text",
			"text": full_text
		},
	]

	# Add image notes
	for img in media_notes:
		content.append({
			"type": "image",
			"source": {
				"type": "base64",
				"media_type": "image/png",
				"data": Marshalls.raw_to_base64(img.save_png_to_buffer()),
			}
		})

	return {
		"role": role,
		"content": content
	}




func estimate_tokens(input) -> int:
	return roundi(input.get_slice_count(" ") * 1.335)


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
	return null


# {
#   "content": [
#     {
#       "text": "Hi! My name is Claude.",
#       "type": "text"
#     }
#   ],
#   "id": "msg_013Zva2CMHLNnXjNJJKqJ2EF",
#   "model": "claude-3-5-sonnet-20240620",
#   "role": "assistant",
#   "stop_reason": "end_turn",
#   "stop_sequence": null,
#   "type": "message",
#   "usage": {
#     "input_tokens": 10,
#     "output_tokens": 25
#   }
# }
# Tool use response example:
# {
#   "content": [
#     {"type": "text", "text": "I'll help you with that."},
#     {"type": "tool_use", "id": "toolu_01A", "name": "get_weather", "input": {"location": "NYC"}}
#   ],
#   "stop_reason": "tool_use"
# }
func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()

	# set the used provider so update model name
	response.provider = self

	# the id will be useful if we need to complete the response with second request
	response.id = data["id"]

	var finish_reason = data["stop_reason"]

	if finish_reason == "max_tokens":
		response.complete = false

	response.prompt_tokens = data["usage"]["input_tokens"]
	response.completion_tokens = data["usage"]["output_tokens"]

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

	# Note: tool_use stop_reason does NOT set complete=false
	# The agentic chat loop handles tool call continuation separately
	# complete=false is only for max_tokens truncation

	return response

class Opus4_1 extends ClaudeSonnet:
	func _init():
		super()
		self.api_model_id = "claude-opus-4-1"
		self.max_tokens = 32000

		model_name = "claude-opus-4-1"
		short_name = "CO"
		token_cost = 1.1 / 1_000_000 * 100

class Sonnet4 extends ClaudeSonnet:
	func _init():
		super()
		self.api_model_id = "claude-sonnet-4-5"
		self.max_tokens = 64000

		model_name = "claude-sonnet-45"
		short_name = "S45"
		token_cost = 1.1 / 1_000_000 * 100
