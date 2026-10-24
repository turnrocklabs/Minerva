class_name CoreProvider
extends BaseProvider

var _active_core_requests: Array[Core.AwaitMessage] = []
var _active_chat_jobs: Array[CoreChatJob] = []
static var _classic_models: Dictionary = {}

func cancel_active_resquests() -> void:
	for job: CoreChatJob in _active_chat_jobs.duplicate():
		job.cancel()
	for request in _active_core_requests.duplicate():
		request.cancel()
	super.cancel_active_resquests()

func _exit_tree() -> void:
	cancel_active_resquests()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		cancel_active_resquests()


var service: Service
var action: Action
## Catalog-created chat providers revalidate their identity before every invocation.
var requires_chat_model: bool = false
var _selected_model_spec: Dictionary = {}

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
		model_name = CoreActionCatalog.display_for(service, action)

	short_name = service.name[0] if service else "C"

	# HCP services - approximate pricing
	input_token_cost = 10.0   # $10 per million input tokens
	output_token_cost = 20.0   # $20 per million output tokens

	# Set default timeout based on service type (increased for long-running e.g. Qwen 2511 flex)
	default_timeout = 1800.0  # HCP default (30 min)
	if service and service.client_id == "model-chat":
		default_timeout = 1800.0  # Chat models (30 min)

	_apply_model_descriptor()


func _apply_model_descriptor() -> void:
	var descriptor := CoreModelDescriptor.describe(service, action)
	var options: Dictionary = descriptor.generation_options if descriptor.valid else {}
	supports_temperature = options.has("temperature")
	supports_top_p = false
	supports_num_ctx = options.has("num_ctx")
	supports_num_gpu = options.has("num_gpu")
	default_context = int(options.get("num_ctx", {}).get("default", 0))
	default_num_gpu = int(options.get("num_gpu", {}).get("default", -1))


func get_model_spec() -> Dictionary:
	return _selected_model_spec.duplicate(true) if not _selected_model_spec.is_empty() else CoreActionCatalog.spec_for(service, action)


func set_chat_model_spec(spec: Dictionary) -> void:
	_selected_model_spec = spec.duplicate(true)
	requires_chat_model = true
	model_name = str(spec.get("action_name", "selection required")) if spec.get("service_client_id") == "model-chat" else "%s (%s)" % [spec.get("service_name", spec.get("service_client_id", "TurnRock")), spec.get("action_name", "selection required")]
	var resolved := CoreModelCatalog.resolve(spec)
	if resolved.success:
		service = resolved.service
		action = resolved.action
		_apply_model_descriptor()


func get_model_settings_key() -> String:
	var spec := get_model_spec()
	var key := CoreModelCatalog.settings_key(spec)
	if key.is_empty() or (not requires_chat_model and not CoreModelDescriptor.describe(service, action).eligible):
		return model_name
	CoreModelPreferences.ensure_migrated(spec)
	return key


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
		var error_msg: String = params.get("error", "Unknown Error")
		# Check if the error indicates rate limiting (HTTP 429 passed through by the backend)
		if "429" in error_msg or "rate limit" in error_msg.to_lower() or "rate_limit" in error_msg.to_lower():
			bot_response.is_rate_limited = true
			bot_response.error = "Rate limited by TurnRock"
			print("[CoreProvider] Rate limited (error: %s)" % error_msg)
		else:
			bot_response.error = error_msg
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
	if result is Dictionary and result.has("choices"):
		print("[CoreProvider] Detected OpenAI format, calling to_bot_response")
		bot_response = to_bot_response(result)  # Parse as OpenAI format
	else:
		print("[CoreProvider] Using HCP format")
		bot_response.hcp_data = result  # Parse as HCP format (ETSU, etc.)

	return bot_response


## Shared, inspectable construction used by every Core chat invocation.
func build_chat_payload(prompt: Array[Variant], params: Dictionary = {}) -> Dictionary:
	var resolved := GenerationOptions.for_provider(self, params)
	if not resolved.success:
		return resolved
	var messages: Array = []
	if not system_prompt.is_empty() and supports_system_prompt:
		messages.append({"role": "system", "content": system_prompt})
	messages.append_array(prompt)
	resolved.payload["messages"] = messages
	if tools_enabled and not available_tools.is_empty():
		resolved.payload["tools"] = format_tools_for_request()
	return resolved


func get_effective_context() -> int:
	var resolved := GenerationOptions.for_provider(self)
	return int(resolved.values.get("num_ctx", 0)) if resolved.success else 0


func get_effective_num_gpu() -> int:
	var resolved := GenerationOptions.for_provider(self)
	return int(resolved.values.get("num_gpu", -1)) if resolved.success else -1


func _job_model_key() -> String:
	return service.client_id + "/" + action.name if service != null and action != null else ""

func supports_async_chat() -> bool:
	if not requires_chat_model or service == null or service.client_id != "model-chat" or action == null:
		return false
	if _classic_models.has(_job_model_key()):
		return false
	for offered: Action in service.actions:
		if offered.topic == "model-chat/jobs/submit":
			return true
	return false

func create_chat_job(item: ChatHistoryItem, persist: Callable, status: Callable) -> CoreChatJob:
	return CoreChatJob.new(_job_request, func() -> bool: return Core.registered,
		_job_pause, UUIDGen.v7, persist, status, item)

func _job_input(data: Dictionary, model: String) -> Dictionary:
	var body: Dictionary = data.duplicate(true)
	body["model"] = model
	body["stream"] = false
	return body

func _job_pause(seconds: float) -> void:
	await Core.get_tree().create_timer(seconds).timeout

func _job_response(result: Dictionary) -> BotResponse:
	var response: BotResponse = to_bot_response(result.get("value", {}))
	if not result.get("success", false):
		response.error = str(result.get("error_message", "Async chat failed."))
		response.set_meta("error_code", str(result.get("error_code", "async_job_failed")))
	SingletonObject.chat_completed.emit(response)
	return response

func _job_request(kind: String, data: Dictionary) -> Dictionary:
	var selected: Service = service
	for known: Service in Core.services:
		if known.client_id == "model-chat":
			selected = known
			break
	var offered: Action = null
	if selected != null:
		for candidate: Action in selected.actions:
			if candidate.topic == "model-chat/jobs/" + kind:
				offered = candidate
				break
	if offered == null:
		return {"success": false, "remote_error": true, "not_started": true,
			"error_code": "ASYNC_UNAVAILABLE", "error_message": "Async job topic is unavailable."}
	var request := Core.send_message(selected, offered, data, "json", 20.0)
	_active_core_requests.append(request)
	var completed: Dictionary = await request.receive_result()
	_active_core_requests.erase(request)
	if not completed.get("success", false):
		return completed
	var params: Dictionary = completed.get("json", {}).get("params", {})
	if not params.get("result") is Dictionary:
		return {"success": false, "error_code": "INVALID_JOB_REPLY", "error_message": "Invalid async job reply."}
	return {"success": true, "value": params["result"]}

func generate_content(prompt: Array[Variant], additional_params: Dictionary={}):
	var chat_job: CoreChatJob = additional_params.get("_core_chat_job")
	additional_params = additional_params.duplicate()
	additional_params.erase("_core_chat_job")
	if chat_job != null and not chat_job.pending_item.PendingJob.is_empty():
		_active_chat_jobs.append(chat_job)
		var resumed: Dictionary = await chat_job.run({}, chat_job.pending_item, str(chat_job.pending_item.PendingJob.get("model", "")))
		_active_chat_jobs.erase(chat_job)
		return _job_response(resumed)
	if requires_chat_model:
		var resolved := CoreModelCatalog.resolve(get_model_spec())
		if not resolved.success:
			var failure := BotResponse.new()
			failure.provider = self
			failure.error = resolved.error_message
			failure.set_meta("error_code", resolved.error_code)
			return failure
		# A refresh can replace service objects while preserving the selected tuple.
		service = resolved.service
		action = resolved.action
		_apply_model_descriptor()
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
		var prepared := build_chat_payload(prompt, additional_params)
		if not prepared.success:
			var failure := BotResponse.new()
			failure.provider = self
			failure.error = prepared.error_message
			failure.set_meta("error_code", prepared.error_code)
			return failure
		msg_data = prepared.payload
	else:
		# HCP format: send last message as-is
		var last_msg = prompt.back() if not prompt.is_empty() else {}
		msg_data = last_msg

	if chat_job != null and (not chat_job.pending_item.PendingJob.is_empty() or supports_async_chat()):
		_active_chat_jobs.append(chat_job)
		var model: String = str(chat_job.pending_item.PendingJob.get("model", action.name))
		var job_result: Dictionary = await chat_job.run(_job_input(msg_data, model), chat_job.pending_item, model)
		_active_chat_jobs.erase(chat_job)
		if job_result.get("classic_fallback", false):
			_classic_models[_job_model_key()] = true
		else:
			return _job_response(job_result)

	var awaiter := Core.send_message(service, action, msg_data, "json", get_effective_timeout())
	_active_core_requests.append(awaiter)
	var completed := await awaiter.receive_result()
	_active_core_requests.erase(awaiter)
	if not completed.success:
		var failure := BotResponse.new()
		failure.provider = self
		failure.error = completed.error_message
		failure.set_meta("error_code", completed.error_code)
		return failure
	var msg: Dictionary = completed.json

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
	var descriptor := CoreModelDescriptor.describe(service, action)
	return requires_chat_model or (descriptor.eligible and descriptor.valid)

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
	var response := BotResponse.new()
	response.provider = self
	if not data is Dictionary or not data.get("choices") is Array or data["choices"].is_empty() or not data["choices"][0] is Dictionary:
		response.error = "Invalid chat result."
		return response
	response.id = str(data.get("id", ""))
	var first: Dictionary = data["choices"][0]
	if not first.get("message") is Dictionary:
		response.error = "Invalid chat result."
		return response
	var message: Dictionary = first["message"]
	response.complete = first.get("finish_reason", "stop") != "length"
	var usage: Dictionary = data.get("usage", {}) if data.get("usage") is Dictionary else {}
	response.prompt_tokens = int(usage.get("prompt_tokens", 0))
	response.completion_tokens = int(usage.get("completion_tokens", 0))
	if data.has("model"):
		response.set_meta("model", str(data["model"]))
	if message.get("reasoning_content") is String and not message["reasoning_content"].is_empty():
		response.add_reasoning(message["reasoning_content"])

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
