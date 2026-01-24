class_name LocalProvider
extends OpenAIProvider

var max_tokens: int

func _init():
	super()
	provider_name = "Ollama"
	BASE_URL = "http://localhost:11434"  # Standard Ollama port
	PROVIDER = SingletonObject.API_PROVIDER.LOCAL

	model_name = "nemotron-3-nano"
	max_tokens = 8192
	short_name = "N3N"
	display_name = "Nemotron 3 Nano"
	input_token_cost = 0.0   # local model - free
	output_token_cost = 0.0   # local model - free

	# Request timeout - local hardware varies greatly
	default_timeout = 300.0

	# Ollama supports context window configuration
	supports_num_ctx = true
	default_context = 8192

func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
	# Build messages array - prepend system prompt if set
	var messages: Array = []
	if not system_prompt.is_empty() and supports_system_prompt:
		messages.append({"role": "system", "content": system_prompt})
	messages.append_array(prompt)

	var request_body = {
		"model": model_name,
		"messages": messages,
		# Ollama options - use per-model context setting
		"options": {
			"num_ctx": get_effective_context()
		}
	}

	# Add tools if enabled (inherited from OpenAIProvider)
	print("[Ollama] generate_content: tools_enabled=%s, available_tools.size=%d" % [tools_enabled, available_tools.size()])
	if tools_enabled and not available_tools.is_empty():
		request_body["tools"] = format_tools_for_request()
		print("[Ollama] Added %d tools to request" % request_body["tools"].size())

	additional_params.merge({
		"temperature": 0.7,
		"top_p": 0.8,
		"max_tokens": self.max_tokens,
	}, true)

	request_body.merge(additional_params)

	var body_stringified: String = JSON.stringify(request_body)

	# Debug: print full request to see what's being sent
	print("[Ollama] Full request body:")
	print(body_stringified.substr(0, 2000))  # Truncate for readability

	# Ollama doesn't require authentication - no Authorization header needed
	var response: RequestResults = await make_request(
		"%s/v1/chat/completions" % BASE_URL,
		HTTPClient.METHOD_POST,
		body_stringified,
		["Content-Type: application/json"],
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
			push_warning("[Ollama] Unknown chat role: %s, defaulting to user" % chat_item.Role)
			role = "user"

	# Handle assistant messages with tool calls
	var is_assistant_role = chat_item.Role == ChatHistoryItem.ChatRole.ASSISTANT or chat_item.Role == ChatHistoryItem.ChatRole.MODEL
	if is_assistant_role and chat_item.IsToolCall and not chat_item.ToolCalls.is_empty():
		var tool_calls_formatted: Array = []
		for tool_call in chat_item.ToolCalls:
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
		# Strip internal markers like {{TOOL_BLOCK:N}} from content
		var clean_message = chat_item.Message
		var marker_regex = RegEx.new()
		marker_regex.compile(r"\{\{TOOL_BLOCK:\d+\}\}")
		clean_message = marker_regex.sub(clean_message, "", true).strip_edges()

		if not clean_message.is_empty():
			result["content"] = clean_message
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
			"type": "image_url",
			"image_url": {
				"url": "data:image/png;base64,%s" % Marshalls.raw_to_base64(img.save_png_to_buffer())
			}
		})

	return {
		"role": role,
		"content": content
	}

# reimplemented to handle image notes properly
func wrap_memory(item: Note) -> Variant:
	# Return either string for text notes or Image for image notes

	# TODO: handle other types

	if item.type == Note.Type.IMAGE:
		return (item.get_controls_container() as NoteImageControls).image
	
	elif item.type == Note.Type.TEXT:
		return (item.get_controls_container() as NoteTextControls).content
	
	else:
		push_warning("Tried to wrap memory but the given note type is not implemented")
		print_stack()

	return ""


func estimate_tokens(input: String) -> int:
	# Provide a basic token estimation (improve as needed)
	return roundi(input.get_slice_count(" ") * 1.335)

func estimate_tokens_from_prompt(input: Array[Variant]):
	var text_tokens: float = 0.0 # Initialize to 0

	for msg: Dictionary in input:
		var content = msg.get("content")

		if content is String:
			text_tokens += estimate_tokens(content) # Count tokens for text-only messages
		elif content is Array:
			for part: Dictionary in content:
				if part.get("type") == "text":
					text_tokens += estimate_tokens(part.get("text")) # Count tokens for text parts

	return text_tokens + estimate_image_tokens_from_prompt(input)

func estimate_image_tokens_from_prompt(input: Array[Variant]) -> float:
	var image_tokens := 0.0
	for msg: Dictionary in input:
		var content = msg.get("content")
		if content is Array:
			for part in content:
				if part.get("type") == "image_url":
					var b64: String = part["image_url"]["url"]
					var img = Image.new()
					img.load_png_from_buffer(Marshalls.base64_to_raw(b64))
					image_tokens += (ceil(img.get_size().x / 512.0) * ceil(img.get_size().y / 512.0)) * 170 + 85
	return image_tokens

class Gemma3 extends LocalProvider:
	func _init():
		super()
		model_name = "gemma3:12b"
		max_tokens = 8192
		short_name = "g3"
		input_token_cost = 0.0   # local model - free
		output_token_cost = 0.0   # local model - free


class DevstralSmall2 extends LocalProvider:
	func _init():
		super()
		model_name = "devstral-small-2"
		max_tokens = 16384  # Can go higher, 256K context supported
		short_name = "DS2"
		display_name = "Devstral Small 2"
		input_token_cost = 0.0   # local model - free
		output_token_cost = 0.0   # local model - free
		# Mistral-based models have a default "Le Chat" system prompt with date injection
		# that we need to override with our own system prompt
		requires_default_system_prompt = true
		default_system_prompt = "You are Devstral, a helpful AI coding assistant."
