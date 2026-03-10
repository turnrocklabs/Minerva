class_name CoreProvider
extends BaseProvider

var service: Service
var action: Action

## System prompt to send with the request (set by ChatPane)
var system_prompt: String

## Available tools for agentic mode (set by ChatPane when agent mode is enabled)
var available_tools: Array[Dictionary] = []

## Whether tool use is enabled for this provider
var tools_enabled: bool = false

func _init(service_: Service = null, action_: Action = null):
	service = service_
	action = action_

	provider_name = "TurnRock"
	PROVIDER = SingletonObject.API_PROVIDER.TURNROCK

	if action:
		model_name = "%s (%s)" % [service.name if service else "Core", action.name]

	short_name = service.name[0] if service else "C"

	# HCP services - approximate pricing
	input_token_cost = 10.0   # $10 per million input tokens
	output_token_cost = 20.0   # $20 per million output tokens

	# Set default timeout based on service type (increased for long-running e.g. Qwen 2511 flex)
	default_timeout = 1800.0  # HCP default (30 min)
	if service and service.client_id == "model-chat":
		default_timeout = 1800.0  # Chat models (30 min)

	# Enable context window setting for OpenAI-compatible services (model-chat)
	if service and service.client_id == "model-chat":
		supports_num_ctx = true
		default_context = 40000  # Default context window for model-chat
		# model-chat proxies to Ollama, so it supports GPU layer offloading
		supports_num_gpu = true
		default_num_gpu = -1  # -1 means use Ollama default (full GPU)


## Set available tools for agentic mode
func set_tools(tools: Array[Dictionary]) -> void:
	available_tools = tools
	tools_enabled = not tools.is_empty()


## Format tools for OpenAI-compatible API
## OpenAI format: {type: "function", function: {name, description, parameters}}
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


func _parse_request_results(response: Dictionary) -> BotResponse:
	var bot_response:= BotResponse.new()
	bot_response.provider = self  # Always set provider, even for errors

	# { "cmd": "error", "entity_type": "core", "params":
		# { "client_id": "1745160706.99", "error": "Request messages must include a \'data\' field in params", "request_id": "1745160715.808_2592814796" },
	# "topic": "etsu_service/chat" }

	var cmd: String = response.get("cmd")
	var params: Dictionary = response.get("params")


	if cmd == "error":
		bot_response.error = params.get("error", "Unknown Error")
		return bot_response

	if not params.has("result"):
		bot_response.error = params.get("error", "No 'result' field found in received data")
		push_error("%s has no 'result' field." % params)
		return bot_response

	var result = params["result"]

	# Detect OpenAI format (model-chat and similar services)
	print("[CoreProvider] Checking result format - is_dict:%s, has_choices:%s, has_model:%s, has_usage:%s" % [
		result is Dictionary,
		result.has("choices") if result is Dictionary else false,
		result.has("model") if result is Dictionary else false,
		result.has("usage") if result is Dictionary else false
	])
	if result is Dictionary and result.has("choices") and result.has("model") and result.has("usage"):
		print("[CoreProvider] Detected OpenAI format, calling to_bot_response")
		bot_response = to_bot_response(result)  # Parse as OpenAI format
	else:
		print("[CoreProvider] Using HCP format")
		bot_response.hcp_data = result  # Parse as HCP format (ETSU, etc.)

	return bot_response


func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):
	# If a notes adapter can handle this, delegate it to it
	if service.client_id in SingletonObject.notes_sync_manger.service_adapters:
		var adapter: = SingletonObject.notes_sync_manger.service_adapters[service.client_id]

		var last_msg = prompt.back() if not prompt.is_empty() else {}
		# handle action will handle state updates
		await adapter.handle_action(action, last_msg.get("notes"))

		var bot_response:= _parse_request_results(adapter.get_last_action_response())

		return bot_response

	# Prepare message data based on service type
	var msg_data: Dictionary

	if _is_openai_compatible_service():
		# Build Ollama options
		var ollama_options: Dictionary = {
			"num_ctx": additional_params.get("num_ctx", get_effective_context())
		}
		# Only include num_gpu if explicitly set (>= 0), otherwise let Ollama use its default
		var effective_num_gpu = get_effective_num_gpu()
		if effective_num_gpu >= 0:
			ollama_options["num_gpu"] = effective_num_gpu

		# Prepend system prompt if set (same pattern as OpenAIProvider)
		var messages: Array = []
		if not system_prompt.is_empty() and supports_system_prompt:
			messages.append({"role": "system", "content": system_prompt})
		messages.append_array(prompt)

		# OpenAI format: wrap messages in data object with parameters
		msg_data = {
			"messages": messages,
			"temperature": additional_params.get("temperature", 0.7),
			"max_tokens": additional_params.get("max_tokens", 4000),
			# Ollama options - backend will parse and forward these
			"options": ollama_options
		}
		# Include any other additional params
		for key in additional_params:
			if key not in ["temperature", "max_tokens"]:
				msg_data[key] = additional_params[key]

		# Add tools if enabled (for agent mode)
		print("[CoreProvider] generate_content: tools_enabled=%s, available_tools.size=%d" % [tools_enabled, available_tools.size()])
		if tools_enabled and not available_tools.is_empty():
			msg_data["tools"] = format_tools_for_request()
			print("[CoreProvider] Added %d tools to request" % msg_data["tools"].size())
	else:
		# HCP format: send last message as-is
		var last_msg = prompt.back() if not prompt.is_empty() else {}
		msg_data = last_msg

	# Use configurable timeout for requests
	var awaiter = Core.send_message(service, action, msg_data)
	awaiter.with_timeout(get_effective_timeout())

	var msg = await awaiter.receive()

	if not msg:
		var bot_response:= BotResponse.new()
		bot_response.error = "No response received (timeout after %d seconds)" % int(awaiter.timeout)
		return bot_response

	print("\n\nRESPONSE:")
	print(msg)

	var item = _parse_request_results(msg)

	SingletonObject.chat_completed.emit(item)

	return item


# TODO: make other chat messages somehow be sent to the hcp request
# maybe a special field definition to mark it as "notes" or previous messages content...
func Format(chat_item: ChatHistoryItem) -> Variant:
	# Check if this service expects OpenAI format (model-chat and similar services)
	if _is_openai_compatible_service():
		return _format_openai_message(chat_item)
	else:
		return chat_item.HcpData

func _is_openai_compatible_service() -> bool:
	"""Check if service expects OpenAI-compatible message format"""
	if not service:
		return false

	# Explicit check for known OpenAI-compatible services
	if service.client_id == "model-chat":
		return true

	# Check if any action has OpenAI-style output parameters
	for act in service.actions:
		var output = act.output_parameters
		if output.has("choices") and output.has("model") and output.has("usage"):
			return true

	return false

func _format_openai_message(chat_item: ChatHistoryItem) -> Dictionary:
	"""Format a chat history item as an OpenAI-compatible message"""

	# Handle TOOL role first (tool results)
	if chat_item.Role == ChatHistoryItem.ChatRole.TOOL:
		return {
			"role": "tool",
			"tool_call_id": chat_item.ToolCallId,
			"content": chat_item.Message
		}

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

	var role: String

	match chat_item.Role:
		ChatHistoryItem.ChatRole.USER:
			role = "user"
		ChatHistoryItem.ChatRole.ASSISTANT, ChatHistoryItem.ChatRole.MODEL:
			role = "assistant"
		ChatHistoryItem.ChatRole.SYSTEM:
			role = "system"
		_:
			role = "user"  # Default fallback

	# Collect text notes and media notes separately
	var text_notes: PackedStringArray = []
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

	# If we have images, use multi-part content format
	if not media_notes.is_empty():
		var content: Array = [
			{
				"type": "text",
				"text": full_text
			}
		]

		# Add image notes as base64 data URLs
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
	else:
		# Text-only, use simple string content
		return {
			"role": role,
			"content": full_text
		}


func wrap_memory(item: Note) -> Variant:
	# For OpenAI-compatible services, extract note content like other providers
	if _is_openai_compatible_service():
		if item.type == Note.Type.TEXT:
			var controls_container = item.get_controls_container() as NoteTextControls
			return controls_container.content
		elif item.type == Note.Type.IMAGE:
			var controls_container = item.get_controls_container() as NoteImageControls
			return controls_container.image  # Return the Image object, not caption
		else:
			push_warning("CoreProvider: Tried to wrap memory but the given note type is not implemented")
			print_stack()

	# For HCP services, return empty (they handle notes differently)
	return ""

func to_bot_response(data: Variant) -> BotResponse:
	var response = BotResponse.new()

	# set the used provider so update model name
	response.provider = self

	# the id will be useful if we need to complete the response with second request
	response.id = data.get("id", "")

	var message: Dictionary = data["choices"][0]["message"]
	var finish_reason = data["choices"][0].get("finish_reason", "stop")

	if finish_reason == "length":
		response.complete = false

	response.prompt_tokens = data["usage"]["prompt_tokens"]
	response.completion_tokens = data["usage"]["completion_tokens"]

	# Handle content - can be null when there are tool calls
	var content = message.get("content")
	if content is String:
		response.text = content
	else:
		response.text = ""

	# Parse tool calls if present (OpenAI format)
	var tool_calls = message.get("tool_calls", [])
	print("[CoreProvider] Raw tool_calls from message: %s (type: %s)" % [tool_calls, typeof(tool_calls)])
	if tool_calls is Array:
		print("[CoreProvider] tool_calls is Array with %d items" % tool_calls.size())
		for tool_call in tool_calls:
			print("[CoreProvider] Processing tool_call: %s" % tool_call)
			print("[CoreProvider] tool_call type field: '%s'" % tool_call.get("type", "<missing>"))
			if tool_call.get("type") == "function":
				var func_data: Dictionary = tool_call.get("function", {})
				var args_string: String = func_data.get("arguments", "{}")
				var args: Dictionary = {}
				var parsed = JSON.parse_string(args_string)
				if parsed is Dictionary:
					args = parsed

				print("[CoreProvider] Adding tool call: id=%s, name=%s" % [tool_call.get("id", ""), func_data.get("name", "")])
				response.add_tool_call(
					tool_call.get("id", ""),
					func_data.get("name", ""),
					args
				)
			else:
				print("[CoreProvider] Skipping tool_call - type is not 'function'")
	else:
		print("[CoreProvider] tool_calls is NOT an Array, type: %s" % typeof(tool_calls))

	print("[CoreProvider] Final response.tool_calls count: %d" % response.tool_calls.size())
	return response


func estimate_tokens(_input) -> int:
	return 0


func estimate_tokens_from_prompt(_input: Array[Variant]):
	
	return estimate_tokens("")

	# var all_messages: Array[String] = []

	# get all user messages
	# for msg: Dictionary in input:
	# 	var content = msg.get("content")

	# 	if content is String:
	# 		all_messages.append(msg["content"])
		
	# 	elif content is Array:
	# 		for part: Dictionary in content:
	# 			if part.get("type") == "text":
	# 				all_messages.append(part.get("text"))
	

	# return estimate_tokens("".join(all_messages))


func continue_partial_response(_partial_chi: ChatHistoryItem):
	var chi = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	chi.Message = "finish"

	return chi
