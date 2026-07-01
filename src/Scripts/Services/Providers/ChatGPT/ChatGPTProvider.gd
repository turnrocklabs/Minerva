class_name ChatGPTProvider
extends BaseProvider
## ChatGPT provider that authenticates via OAuth PKCE and calls the ChatGPT
## backend API (chatgpt.com/backend-api/codex/responses) using the Responses API format.
## This lets ChatGPT Plus/Pro subscribers use their subscription inside Minerva.

const CHATGPT_BASE_URL = "https://chatgpt.com/backend-api"
const CODEX_ENDPOINT = "/codex/responses"
const ChatGPTAuthScript = preload("res://Scripts/Services/Providers/ChatGPT/ChatGPTAuth.gd")
const GENERATED_IMAGES_DIR := "user://chatgpt_generated_images"

## System prompt to send with the request (set by ChatPane)
var system_prompt: String

## Available tools for agentic mode
var available_tools: Array[Dictionary] = []
var tools_enabled: bool = false

## Catalog-discovered model options.
var reasoning_effort: String = "medium"
var supported_reasoning_levels: Array = []
var supports_reasoning_summaries: bool = true
var default_reasoning_summary: String = "auto"

## Per-request toggle for asking the backend for a human-readable reasoning
## summary. Set per-chat by ChatPane from ServiceHistory.ReasoningSummary; when
## false, no summary is requested (saves summary tokens; the collapse stays empty).
var request_reasoning_summary: bool = true
var support_verbosity: bool = false
var default_verbosity: Variant = null
var additional_speed_tiers: Array = []
var input_modalities: Array = ["text", "image"]
var supports_parallel_tool_calls: bool = false
var supports_search_tool: bool = false
var web_search_tool_type: String = "text"
var apply_patch_tool_type: Variant = null
var experimental_supported_tools: Array = []
var supports_image_generation: bool = false
var raw_model_info: Dictionary = {}

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
	if supports_image_generation:
		formatted.append({
			"type": "image_generation",
			"output_format": "png",
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
	var scene_tree := _get_scene_tree()
	if scene_tree == null:
		bot_response.error = "ChatGPT provider is not attached to the scene tree."
		SingletonObject.chat_completed.emit(bot_response)
		return bot_response
	var token_valid: bool = await chatgpt_auth.ensure_valid_token(scene_tree)
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
		"include": ["reasoning.encrypted_content"],
	}

	var reasoning := _build_reasoning_options()
	if not reasoning.is_empty():
		request_body["reasoning"] = reasoning
	var text_options := _build_text_options()
	if not text_options.is_empty():
		request_body["text"] = text_options

	# Add tools if enabled
	if (tools_enabled and not available_tools.is_empty()) or supports_image_generation:
		request_body["tools"] = format_tools_for_request()

	request_body.merge(additional_params)

	var body_str := JSON.stringify(request_body)
	var url := "%s%s" % [CHATGPT_BASE_URL, CODEX_ENDPOINT]

	var headers: Array[String] = [
		"Content-Type: application/json",
		"Authorization: Bearer %s" % chatgpt_auth.access_token,
		"ChatGPT-Account-ID: %s" % chatgpt_auth.account_id,
		"OpenAI-Beta: responses=experimental",
		"originator: codex_cli_rs",
		"accept: text/event-stream",
	]

	var response := await make_request(url, HTTPClient.METHOD_POST, body_str, headers)

	bot_response = _parse_sse_response(response)

	SingletonObject.chat_completed.emit(bot_response)
	return bot_response


func _get_scene_tree() -> SceneTree:
	if is_inside_tree():
		return get_tree()
	if SingletonObject != null and SingletonObject.is_inside_tree():
		return SingletonObject.get_tree()
	return null


func generate_image(prompt: String, options: Dictionary = {}) -> BotResponse:
	var image_tool := {
		"type": "image_generation",
		"output_format": str(options.get("output_format", "png")),
	}
	for key in ["size", "quality", "background", "action", "partial_images"]:
		if options.has(key):
			image_tool[key] = options[key]

	var input := [{
		"type": "message",
		"role": "user",
		"content": [{"type": "text", "text": prompt}]
	}]

	var old_tools := available_tools
	var old_tools_enabled := tools_enabled
	var old_supports_image_generation := supports_image_generation
	available_tools = []
	tools_enabled = false
	supports_image_generation = false

	var response := await generate_content(input, {
		"tools": [image_tool],
		"tool_choice": {"type": "image_generation"},
	})

	available_tools = old_tools
	tools_enabled = old_tools_enabled
	supports_image_generation = old_supports_image_generation
	return response


func _build_reasoning_options() -> Dictionary:
	var reasoning := {}
	if not _is_reasoning_effort_supported(reasoning_effort):
		reasoning_effort = _default_supported_reasoning_effort()
	if not reasoning_effort.is_empty():
		reasoning["effort"] = reasoning_effort
	# Request a human-readable reasoning summary whenever the model supports one
	# and the chat hasn't turned it off. The raw chain-of-thought comes back
	# encrypted (reasoning.encrypted_content); the summary is the only displayable
	# part, so default to "auto" when the catalog leaves default_reasoning_summary
	# blank.
	if supports_reasoning_summaries and request_reasoning_summary:
		var summary := _valid_reasoning_summary(default_reasoning_summary)
		if summary.is_empty():
			summary = "auto"
		reasoning["summary"] = summary
	return reasoning


func _build_text_options() -> Dictionary:
	if not support_verbosity or default_verbosity == null:
		return {}
	return {"verbosity": str(default_verbosity)}


func _is_reasoning_effort_supported(effort: String) -> bool:
	if effort.is_empty() or supported_reasoning_levels.is_empty():
		return true
	for preset in supported_reasoning_levels:
		if preset is Dictionary and str(preset.get("effort", "")) == effort:
			return true
	return false


func _default_supported_reasoning_effort() -> String:
	if supported_reasoning_levels.is_empty():
		return ""
	for preset in supported_reasoning_levels:
		if preset is Dictionary:
			return str(preset.get("effort", ""))
	return ""


func _valid_reasoning_summary(summary: String) -> String:
	var normalized := summary.strip_edges().to_lower()
	if normalized in ["concise", "detailed", "auto"]:
		return normalized
	return ""


## ChatGPT also exposes effort in the gears picker (in addition to the per-effort
## model entries), so the picker can override effort at request time.
func uses_reasoning_effort_picker() -> bool:
	return true


## Offer exactly the effort levels this model advertises; fall back to a standard
## set when the catalog didn't provide any.
func reasoning_effort_levels() -> Array:
	var levels: Array = []
	for preset in supported_reasoning_levels:
		if preset is Dictionary and preset.has("effort"):
			levels.append(str(preset["effort"]))
	if levels.is_empty():
		return ["low", "medium", "high"]
	return levels


## Override the model-entry effort at request time from the gears picker. gpt-5.x
## reasoning models can't fully disable thinking, so "off" maps to the lowest
## advertised effort rather than removing reasoning.
func apply_reasoning_options(_params: Dictionary, level: String, enabled: bool) -> void:
	var levels := reasoning_effort_levels()
	if not enabled:
		if not levels.is_empty():
			reasoning_effort = str(levels[0])
		return
	if not level.is_empty() and level in levels:
		reasoning_effort = level


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
	var generated_image: Image = null

	# Track function call metadata from output_item events (name, call_id)
	# since function_call_arguments.done may have name=null (known OpenAI API bug)
	var _pending_func_calls: Dictionary = {}  # item_id → {"name": ..., "call_id": ...}
	var reasoning_parts := PackedStringArray()
	# Raw reasoning items (id → item) captured for round-trip replay in tool loops.
	var reasoning_items: Dictionary = {}

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
					elif item is Dictionary and item.get("type") == "image_generation_call":
						var image := _image_from_generation_item(item)
						if image != null:
							generated_image = image
					elif item is Dictionary and item.get("type") == "reasoning":
						# Capture the full reasoning item (id + encrypted_content) so
						# it can be replayed verbatim in the next tool-loop request.
						var rid: String = str(item.get("id", ""))
						if not rid.is_empty():
							reasoning_items[rid] = item

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

						# Capture reasoning items from the final output (fallback if the
						# per-item events were missed) for round-trip replay.
						var completed_output = resp.get("output", [])
						if completed_output is Array:
							for oi in completed_output:
								if oi is Dictionary and oi.get("type") == "reasoning":
									var oid: String = str(oi.get("id", ""))
									if not oid.is_empty():
										reasoning_items[oid] = oi

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
									elif item is Dictionary and item.get("type") == "image_generation_call":
										var image := _image_from_generation_item(item)
										if image != null:
											generated_image = image

	bot_response.text = "".join(text_parts)
	if generated_image != null:
		bot_response.image = generated_image
	# Surface the accumulated reasoning summary (OpenAI Responses streams the raw
	# chain-of-thought only as encrypted_content; the human-readable part is the
	# reasoning_summary_text deltas) into the display sequence as one summary segment.
	var reasoning_summary: String = "".join(reasoning_parts)
	if not reasoning_summary.is_empty():
		bot_response.add_reasoning(reasoning_summary, "summary", false)
	# Raw reasoning items (insertion order preserved) for same-model tool-loop replay.
	if not reasoning_items.is_empty():
		bot_response.reasoning_raw = reasoning_items.values()
	bot_response.id = response_id
	bot_response.prompt_tokens = prompt_tokens
	bot_response.completion_tokens = completion_tokens

	return bot_response


func _image_from_generation_item(item: Dictionary) -> Image:
	var result_b64: String = str(item.get("result", ""))
	if result_b64.is_empty():
		return null
	if result_b64.begins_with("data:") and "," in result_b64:
		result_b64 = result_b64.split(",", true, 1)[1]

	var bytes := Marshalls.base64_to_raw(result_b64)
	if bytes.is_empty():
		push_warning("[ChatGPT] image_generation_call returned invalid base64")
		return null

	var image := Image.new()
	var err := image.load_png_from_buffer(bytes)
	if err != OK:
		push_warning("[ChatGPT] image_generation_call PNG decode failed: %s" % error_string(err))
		return null

	var output_path := _save_generated_image(bytes, str(item.get("id", "")))
	if not output_path.is_empty():
		image.set_meta("output_path", output_path)
		image.set_meta("caption", str(item.get("revised_prompt", "Generated by ChatGPT")))
	return image


func _save_generated_image(bytes: PackedByteArray, call_id: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GENERATED_IMAGES_DIR))
	var safe_id := sanitize_tool_id(call_id)
	if safe_id.is_empty():
		safe_id = "image"
	var timestamp := Time.get_datetime_string_from_system(false, true).replace(":", "").replace("-", "").replace(" ", "_")
	var path := "%s/%s_%s.png" % [GENERATED_IMAGES_DIR, timestamp, safe_id]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_warning("[ChatGPT] Could not save generated image: %s" % error_string(FileAccess.get_open_error()))
		return ""
	file.store_buffer(bytes)
	file.close()
	return path


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

		# Replay this turn's raw reasoning items (encrypted_content) so the model
		# retains its chain of thought across tool calls. Reasoning items must
		# precede the function_call items. SAME-MODEL ONLY — replaying another
		# model's reasoning items would 400; ReasoningRaw is transient so it is
		# empty for reloaded history (only live in-loop turns carry it).
		if chat_item.ModelName == model_name:
			for r_item in chat_item.ReasoningRaw:
				items.append(r_item)

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


# ============================================================================
# Dynamic Model Factory
# ============================================================================

static func create_from_config(config: Dictionary) -> ChatGPTProvider:
	var p := ChatGPTProvider.new()
	p.model_name = config.get("model_name", p.model_name)
	p.display_name = config.get("display_name", p.model_name)
	p.short_name = config.get("short_name", "CG")
	p.input_token_cost = config.get("input_token_cost", 0.0)
	p.output_token_cost = config.get("output_token_cost", 0.0)
	p.reasoning_effort = str(config.get("reasoning_effort", config.get("default_reasoning_level", "")))
	p.supported_reasoning_levels = config.get("supported_reasoning_levels", [])
	p.supports_reasoning_summaries = bool(config.get("supports_reasoning_summaries", false))
	p.default_reasoning_summary = str(config.get("default_reasoning_summary", "auto"))
	p.support_verbosity = bool(config.get("support_verbosity", false))
	p.default_verbosity = config.get("default_verbosity", null)
	p.additional_speed_tiers = config.get("additional_speed_tiers", [])
	p.input_modalities = config.get("input_modalities", ["text", "image"])
	p.supports_parallel_tool_calls = bool(config.get("supports_parallel_tool_calls", false))
	p.supports_search_tool = bool(config.get("supports_search_tool", false))
	p.web_search_tool_type = str(config.get("web_search_tool_type", "text"))
	p.apply_patch_tool_type = config.get("apply_patch_tool_type", null)
	p.experimental_supported_tools = config.get("experimental_supported_tools", [])
	p.raw_model_info = config.get("raw_model_info", {})
	p.is_reasoning_model = not p.supported_reasoning_levels.is_empty() or not p.reasoning_effort.is_empty()
	p.supports_image_generation = "image" in p.input_modalities
	var max_ctx = config.get("max_context_window", config.get("context_window", null))
	if max_ctx != null:
		p.default_context = int(max_ctx)
	return p
