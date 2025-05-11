# res://scripts/providers/LoadableRestProvider.gd
class_name LoadableRestProvider
extends BaseProvider

var config: Dictionary
var system_prompt: String # Used by some providers like Google

func _init(provider_config: Dictionary):
	self.config = provider_config

	# Initialize BaseProvider properties from config
	var base_url_val = config.get("api_base_url", "")
	if base_url_val is String:
		BASE_URL = base_url_val
	
	var provider_name_val = config.get("display_name", config.get("model_name_config", "Unknown Provider"))
	if provider_name_val is String:
		self.provider_name = provider_name_val 

	var model_name_val = config.get("model_name_config", "unknown_model")
	if model_name_val is String:
		self.model_name = model_name_val

	var display_name_val = config.get("display_name", "")
	if display_name_val is String:
		self.display_name = display_name_val 

	var short_name_val = config.get("short_name_ui", "NA")
	if short_name_val is String:
		self.short_name = short_name_val
	
	if config.has("token_cost_usd_per_million_total"):
		var token_cost_val = config.get("token_cost_usd_per_million_total", 0.0)
		if token_cost_val is float or token_cost_val is int:
			self.token_cost = float(token_cost_val) / 1_000_000.0
	elif config.has("cost_per_action_usd"): 
		var action_cost_val = config.get("cost_per_action_usd", 0.0)
		if action_cost_val is float or action_cost_val is int:
			self.token_cost = float(action_cost_val) 


	var provider_key_str = config.get("provider_enum_key", "OPENAI") 
	if provider_key_str is String:
		match provider_key_str.to_upper():
			"GOOGLE": PROVIDER = SingletonObject.API_PROVIDER.GOOGLE
			"OPENAI": PROVIDER = SingletonObject.API_PROVIDER.OPENAI
			"ANTHROPIC": PROVIDER = SingletonObject.API_PROVIDER.ANTHROPIC
			"TURNROCK": PROVIDER = SingletonObject.API_PROVIDER.TURNROCK
			"NONE": PROVIDER = SingletonObject.API_PROVIDER.NONE 
			_:
				push_warning("LoadableRestProvider: Unknown provider_enum_key '%s' for %s. Defaulting to OPENAI for API key." % [provider_key_str, self.provider_name])
				PROVIDER = SingletonObject.API_PROVIDER.OPENAI
	else:
		PROVIDER = SingletonObject.API_PROVIDER.OPENAI 


#region METHODS TO REIMPLEMENT (Using Config)

func Format(chat_item: ChatHistoryItem) -> Variant: # Return type is Variant
	var fmt_rules = config.get("formatting_rules", {})
	var role_map: Dictionary = fmt_rules.get("role_map", {})
	
	var game_role_enum_val = chat_item.Role
	var game_role_key = ChatHistoryItem.ChatRole.keys()[game_role_enum_val] 
	var api_role = role_map.get(game_role_key, "user") 

	var format_type = fmt_rules.get("format_type", "default_openai_chat") 

	match format_type:
		"anthropic_chat", "openai_chat_array_content": 
			var content_array = []
			var text_content_key = fmt_rules.get("content_array_item_text_field", "text")
			var text_type_key = fmt_rules.get("content_array_item_type_field", "type")
			var text_type_value = fmt_rules.get("content_array_item_type_text_value", "text")
			
			content_array.append({
				text_type_key: text_type_value,
				text_content_key: chat_item.Message
			})

			var image_rules = fmt_rules.get("image_handling_rules", {})
			var image_type_value = image_rules.get("type_value", "image_url") 
			var image_data_key = image_rules.get("data_key", "image_url") 

			for note: Variant in chat_item.InjectedNotes:
				if note is String:
					content_array.append({text_type_key: text_type_value, text_content_key: note})
				elif note is Image:
					var image_payload = {}
					if image_type_value == "image_url": 
						image_payload = {
							"url": "data:%s;base64,%s" % [
								image_rules.get("mime_type", "image/png"), 
								Marshalls.raw_to_base64(note.save_png_to_buffer())
							]
						}
					elif image_type_value == "image": 
						image_payload = {
							"type": image_rules.get("source_type_value", "base64"),
							"media_type": image_rules.get("mime_type", "image/png"),
							"data": Marshalls.raw_to_base64(note.save_png_to_buffer())
						}
					content_array.append({text_type_key: image_type_value, image_data_key: image_payload})
			
			return {"role": api_role, "content": content_array} # Returns Dictionary

		"google_chat":
			if api_role == fmt_rules.get("google_system_role_indicator", "system_handler_google_api"): 
				system_prompt = chat_item.Message
				# FIX 1: Return empty dictionary for Google system message case
				return {} # Returns Dictionary
			
			var parts_array = []
			var text_part_key = fmt_rules.get("parts_array_text_field", "text")
			var combined_text = chat_item.Message 
			for note in chat_item.InjectedNotes:
				if note is String: combined_text += "\n" + note
			parts_array.append({text_part_key: combined_text})

			var media_rules = fmt_rules.get("media_handling_rules", {}) 
			for note: Variant in chat_item.InjectedNotes:
				var media_part = _format_google_media_part(note, media_rules)
				if media_part: # media_part will be a Dictionary or null
					parts_array.append(media_part)
			
			return {"role": api_role, "parts": parts_array} # Returns Dictionary
		
		"dalle_image_prompt": 
			var text_notes = chat_item.InjectedNotes.filter(func(note): return note is String)
			var text_prompt: String = chat_item.Message
			if not text_notes.is_empty():
				text_prompt = "%s\n%s" % ["\n".join(text_notes), chat_item.Message]
			# This "prompt_field" should match "prompt_field_internal" in generate_content's config
			return { fmt_rules.get("prompt_field", "prompt"): text_prompt } # Returns Dictionary
		
		"human_passthrough": 
			return {} # Returns Dictionary

		_: 
			var final_content = chat_item.Message
			for note in chat_item.InjectedNotes:
				if note is String: final_content += "\n" + note
			return {"role": api_role, "content": final_content} # Returns Dictionary


func _format_google_media_part(note_data: Variant, media_rules: Dictionary) -> Dictionary: # Explicitly Dictionary or null
	var inline_data_key = media_rules.get("inline_data_key", "inline_data")
	var mime_type_key = media_rules.get("mime_type_key", "mime_type")
	var data_key = media_rules.get("data_key", "data")

	if note_data is Image:
		return {
			inline_data_key: {
				mime_type_key: media_rules.get("image_mime_type", "image/png"),
				data_key: Marshalls.raw_to_base64(note_data.save_png_to_buffer())
			}
		}
	return {} # Return null if not an image, explicitly


func wrap_memory(item: MemoryItem) -> Variant:
	var wrap_rules = config.get("memory_wrap_rules", {})
	var image_handling_type = wrap_rules.get("image_handling_type", "passthrough") 

	if item.MemoryImage:
		match image_handling_type:
			"passthrough":
				return item.MemoryImage
			"google_inline_data":
				var media_rules = config.get("formatting_rules", {}).get("media_handling_rules", {})
				var inline_data_key = media_rules.get("inline_data_key", "inline_data")
				var mime_type_key = media_rules.get("mime_type_key", "mime_type")
				var data_key = media_rules.get("data_key", "data")
				return {
					inline_data_key: {
						mime_type_key: media_rules.get("image_mime_type", "image/png"),
						data_key: Marshalls.raw_to_base64(item.MemoryImage.save_png_to_buffer())
					}
				}
			_:
				return item.MemoryImage 
	else: 
		var prefix = wrap_rules.get("text_prefix", "")
		var suffix = wrap_rules.get("text_suffix", "")
		return "%s%s%s" % [prefix, item.Content, suffix]


func generate_content(_prompt: Array[Variant], _additional_params: Dictionary={}) -> BotResponse:
	var action_config = config 
	var action_type = action_config.get("action_type", "json_chat") 

	if action_type == "local_human":
		var human_bot_response := BotResponse.new()
		human_bot_response.provider = self
		SingletonObject.chat_completed.emit(human_bot_response)
		return human_bot_response

	var endpoint_path_tmpl = action_config.get("chat_endpoint", "/default_chat")
	var http_method_str: String = action_config.get("chat_http_method", "POST")
	var http_method = HTTPClient.METHOD_POST
	if http_method_str.to_upper() == "GET": http_method = HTTPClient.METHOD_GET

	var request_body: Dictionary = {} # Initialize as Dictionary
	var req_body_rules: Dictionary = action_config.get("request_body_structure", {})

	# FIX 3: Refactored request_body construction
	if action_type == "json_image_generation":
		if _prompt is Array and not _prompt.is_empty():
			var last_formatted_message = _prompt.back() # This is what Format() returned for the last chat item
			if last_formatted_message is Dictionary:
				if req_body_rules.has("model_field"):
					request_body[req_body_rules.get("model_field")] = self.model_name
				
				# "prompt_field_internal" is the key used by Format() for the text (e.g., "prompt")
				# "prompt_field_external" is the key for the final API JSON (e.g., "prompt")
				var internal_prompt_key = req_body_rules.get("prompt_field_internal", "prompt")
				var external_prompt_key = req_body_rules.get("prompt_field_external", "prompt")
				request_body[external_prompt_key] = last_formatted_message.get(internal_prompt_key, "")

				for field_key_suffix in ["n", "size", "response_format", "quality", "style"]:
					var rule_key = field_key_suffix + "_field" # e.g., "n_field"
					var default_rule_key = "default_" + field_key_suffix # e.g., "default_n"
					if req_body_rules.has(rule_key) and req_body_rules.has(default_rule_key):
						request_body[req_body_rules.get(rule_key)] = req_body_rules.get(default_rule_key)
			else:
				push_error("Image generation expected last formatted prompt to be a Dictionary.")
		else:
			push_error("Image generation prompt array is empty.")
			
	elif action_type == "form_data_image_generation":
		if _prompt is Array and not _prompt.is_empty():
			var last_formatted_message = _prompt.back()
			if last_formatted_message is Dictionary:
				var internal_prompt_key = req_body_rules.get("prompt_field_internal", "prompt")
				var external_prompt_key = req_body_rules.get("prompt_field_external", "prompt")
				request_body[external_prompt_key] = last_formatted_message.get(internal_prompt_key, "")
				# Add other text fields for the form from req_body_rules
				if req_body_rules.has("model_field"):
					request_body[req_body_rules.get("model_field")] = self.model_name
				# ... (e.g., n, size, if they are text fields in the form)
			else:
				push_error("Form data image generation: last formatted message not a Dictionary.")
		else:
			push_error("Form data image generation: prompt array empty.")

	else: # Default "json_chat" behavior
		if req_body_rules.has("model_field"):
			request_body[req_body_rules.get("model_field")] = self.model_name
		
		# For chat, _prompt is the array of formatted messages.
		# Handle Google's case where Format returns {} for system messages.
		var actual_prompt_for_api: Array = []
		if _prompt is Array:
			for p_item in _prompt:
				if p_item is Dictionary and not p_item.is_empty(): # Skip empty dicts (from Google system messages)
					actual_prompt_for_api.append(p_item)
		
		if req_body_rules.has("messages_field"): 
			request_body[req_body_rules.get("messages_field")] = actual_prompt_for_api
		elif req_body_rules.has("contents_field"): 
			request_body[req_body_rules.get("contents_field")] = actual_prompt_for_api
		
		if req_body_rules.has("max_tokens_field") and req_body_rules.has("default_max_tokens"):
			request_body[req_body_rules.get("max_tokens_field")] = _additional_params.get(
				req_body_rules.get("max_tokens_field"), 
				req_body_rules.get("default_max_tokens")
			)
		if req_body_rules.has("system_prompt_field") and not system_prompt.is_empty():
			request_body[req_body_rules.get("system_prompt_field")] = system_prompt
	
	request_body.merge(_additional_params, true) 

	var final_headers: Array[String] = []
	var config_headers: Array = action_config.get("headers", [])
	for header_item_var in config_headers:
		if header_item_var is Dictionary:
			var header_item = header_item_var as Dictionary
			var header_value: String = header_item.get("value", "")
			header_value = header_value.replace("{API_KEY}", API_KEY)
			final_headers.append("%s: %s" % [header_item.get("name", "X-ERROR-HeaderName"), header_value])

	var final_url: String = str(BASE_URL)
	var endpoint_path = endpoint_path_tmpl.replace("{model_name_config}", self.model_name).replace("{API_KEY}", API_KEY)
	if not endpoint_path.begins_with("/") and not final_url.ends_with("/"):
		final_url += "/"
	final_url += endpoint_path
	
	var response: RequestResults
	var request_payload: Variant

	if action_type == "form_data_image_generation":
		var image_to_edit: Image = _additional_params.get("source_image") 
		var mask_image: Image = _additional_params.get("mask_image")
		var form_data_rules = action_config.get("form_data_rules", {})
		var boundary = _generate_form_data_boundary()
		# `request_body` here contains the text fields for the form.
		request_payload = _construct_form_data_body(request_body, image_to_edit, mask_image, boundary, form_data_rules)
		var content_type_header_found = false
		for i in range(final_headers.size()):
			if final_headers[i].begins_with("Content-Type:"):
				final_headers[i] = 'Content-Type: multipart/form-data;boundary=%s' % boundary
				content_type_header_found = true
				break
		if not content_type_header_found:
			final_headers.append('Content-Type: multipart/form-data;boundary=%s' % boundary)
	else: 
		request_payload = JSON.stringify(request_body)

	response = await make_request(
		final_url,
		http_method,
		request_payload, 
		final_headers
	)

	var item = _parse_request_results(response)
	SingletonObject.chat_completed.emit(item)
	return item


func _parse_request_results(response_obj: RequestResults) -> BotResponse:
	var bot_response := BotResponse.new()
	bot_response.provider = self

	if not response_obj.success:
		bot_response.error = response_obj.message
		return bot_response

	var data: Variant
	if response_obj.http_request_result == HTTPRequest.RESULT_SUCCESS:
		var json_parser = JSON.new()
		var error = json_parser.parse(response_obj.body.get_string_from_utf8())
		if error != OK:
			bot_response.error = "Failed to parse JSON response: %s" % json_parser.get_error_message()
			push_error(bot_response.error)
			return bot_response
		data = json_parser.get_data()

		if (response_obj.response_code >= 200 and response_obj.response_code <= 299):
			return to_bot_response(data) 
		else: 
			var resp_parsing_rules = config.get("response_parsing", {})
			var error_path = resp_parsing_rules.get("error_path", "error.message") 
			var error_message = _get_value_from_path(data, error_path)
			if error_message is String:
				bot_response.error = error_message
			elif data != null and data is Dictionary and data.has("error") and data["error"] is String: 
				bot_response.error = data["error"]
			else:
				bot_response.error = "API Error (Code %s): %s" % [response_obj.response_code, response_obj.body.get_string_from_utf8().left(200)]
			push_error("API Error for %s: %s" % [self.provider_name, bot_response.error])
	else:
		bot_response.error = "HTTPRequest Error: Code %s" % response_obj.http_request_result
		push_error(bot_response.error)
	
	return bot_response


func to_bot_response(data: Variant) -> BotResponse: 
	var bot_resp := BotResponse.new()
	bot_resp.provider = self
	var rules:Dictionary = config.get("response_parsing", {})

	bot_resp.id = _get_value_from_path(data, rules.get("id_path", "id")) as String

	var text_val = _get_value_from_path(data, rules.get("text_path", "choices[0].message.content")) 
	if text_val == null and rules.has("text_parts_array_path"):
		var parts_array = _get_value_from_path(data, rules.get("text_parts_array_path"))
		if parts_array is Array:
			var combined_text_parts = []
			var text_part_key = rules.get("text_parts_item_text_key", "text")
			for part in parts_array:
				if part is Dictionary and part.has(text_part_key) and part[text_part_key] is String:
					combined_text_parts.append(part[text_part_key])
			if not combined_text_parts.is_empty():
				text_val = "\n".join(combined_text_parts)

	if text_val is String:
		bot_resp.text = text_val

	var stop_reason = _get_value_from_path(data, rules.get("stop_reason_path", "choices[0].finish_reason"))
	var max_tokens_stop_value = rules.get("stop_reason_max_tokens_value", "length") 
	if stop_reason is String and stop_reason == max_tokens_stop_value:
		bot_resp.complete = false
	
	var input_tokens_val = _get_value_from_path(data, rules.get("input_tokens_path", "usage.prompt_tokens"))
	if input_tokens_val is int or input_tokens_val is float: bot_resp.prompt_tokens = int(input_tokens_val)

	var output_tokens_val = _get_value_from_path(data, rules.get("output_tokens_path", "usage.completion_tokens"))
	if output_tokens_val is int or output_tokens_val is float: bot_resp.completion_tokens = int(output_tokens_val)

	var action_type = config.get("action_type", "json_chat")
	if action_type == "form_data_image_generation" or action_type == "json_image_generation":
		var image_b64_path = rules.get("image_b64_json_path", "data[0].b64_json") 
		var image_b64_str = _get_value_from_path(data, image_b64_path)
		if image_b64_str is String and not image_b64_str.is_empty():
			bot_resp.image = Image.new()
			var err = bot_resp.image.load_png_from_buffer(Marshalls.base64_to_raw(image_b64_str))
			if err != OK:
				push_error("Failed to load image from b64 for %s. Error: %s" % [self.provider_name, err])
				bot_resp.image = null 
			else:
				var caption_path = rules.get("image_revised_prompt_path", "data[0].revised_prompt")
				var caption = _get_value_from_path(data, caption_path)
				if caption is String:
					bot_resp.image.set_meta("caption", caption)
	
	return bot_resp


func estimate_tokens(input_str: String) -> int:
	var rules:Dictionary = config.get("token_estimation_rules", {})
	var estimation_type = rules.get("type", "simple_word_count")
	var multiplier = rules.get("multiplier", 1.335) 

	match estimation_type:
		"simple_word_count":
			return roundi(input_str.get_slice_count(" ") * multiplier)
		"char_count_multiplier":
			return roundi(input_str.length() * multiplier)
		"fixed_cost_per_call":
			var fixed_val = rules.get("fixed_cost", 0)
			if fixed_val is int or fixed_val is float:
				return int(fixed_val)
			return 0
		_:
			return roundi(input_str.get_slice_count(" ") * 1.335) 


func estimate_tokens_from_prompt(prompt_input: Array[Variant]) -> float:
	var rules:Dictionary = config.get("token_estimation_rules", {})
	var estimation_type = rules.get("type_from_prompt", "sum_text_tokens")

	if estimation_type == "fixed_cost_per_call":
		var fixed_val = rules.get("fixed_cost", 0)
		if fixed_val is int or fixed_val is float:
			return float(fixed_val)
		return 0.0

	var total_tokens: float = 0.0
	
	match estimation_type:
		"sum_text_tokens":
			var text_key_primary = rules.get("prompt_text_key_primary", "content") 
			var text_key_secondary_array = rules.get("prompt_text_key_secondary_array", "content") 
			var text_key_in_item = rules.get("prompt_text_key_in_item", "text") 
			var parts_array_key = rules.get("prompt_parts_array_key", "parts") 

			for message_variant in prompt_input:
				if message_variant is Dictionary: # Each item in _prompt is a formatted message (Dictionary)
					var message_dict = message_variant as Dictionary
					# Check for direct string content (older OpenAI models)
					if message_dict.has(text_key_primary) and message_dict[text_key_primary] is String:
						total_tokens += estimate_tokens(message_dict[text_key_primary])
					# Check for array of content parts (OpenAI multimodal, Anthropic)
					elif message_dict.has(text_key_secondary_array) and message_dict[text_key_secondary_array] is Array:
						for item_part in message_dict[text_key_secondary_array] as Array: # Renamed 'item' to 'item_part'
							if item_part is Dictionary and item_part.has(text_key_in_item) and item_part[text_key_in_item] is String:
								total_tokens += estimate_tokens(item_part[text_key_in_item])
							# TODO: Add image token estimation from rules if specified for this type
					# Check for Google's 'parts' array
					elif message_dict.has(parts_array_key) and message_dict[parts_array_key] is Array: 
						for item_part in message_dict[parts_array_key] as Array: # Renamed 'item' to 'item_part'
							if item_part is Dictionary and item_part.has(text_key_in_item) and item_part[text_key_in_item] is String:
								total_tokens += estimate_tokens(item_part[text_key_in_item])
							# TODO: Add image/media token estimation for Google parts
			return total_tokens
		_: # Fallback
			for message_variant in prompt_input:
				if message_variant is Dictionary:
					for val_item in message_variant.values(): # Renamed 'val' to 'val_item'
						if val_item is String: total_tokens += estimate_tokens(val_item)
						elif val_item is Array: 
							for sub_item_val in val_item: # Renamed 'sub_item' to 'sub_item_val'
								if sub_item_val is Dictionary and sub_item_val.has("text") and sub_item_val["text"] is String:
									total_tokens += estimate_tokens(sub_item_val["text"])
			return total_tokens if total_tokens > 0 else 0.0


func continue_partial_response(_partial_chi: ChatHistoryItem):
	push_warning("continue_partial_response not generally supported by LoadableRestProvider yet.")
	return null

#endregion

#region Helper Functions

static func _get_value_from_path(source_data: Variant, path_str: String) -> Variant:
	if path_str.is_empty() or source_data == null:
		return null
	
	var parts = path_str.replace("]", "").split(".") 
	var current_data: Variant = source_data
	
	for part_full in parts:
		if current_data == null: return null
		
		var key_to_access: String = part_full
		var index_to_access: int = -1

		var bracket_pos = part_full.find("[")
		if bracket_pos != -1:
			key_to_access = part_full.substr(0, bracket_pos)
			var index_str = part_full.substr(bracket_pos + 1) 
			if index_str.is_valid_int():
				index_to_access = index_str.to_int()
			else: 
				printerr("LoadableRestProvider._get_value_from_path: Invalid array index in path part '%s'" % part_full)
				return null
		
		if typeof(current_data) == TYPE_DICTIONARY:
			var current_dict = current_data as Dictionary
			if not current_dict.has(key_to_access): # Key might be empty if path starts with index like "[0].key"
				if key_to_access.is_empty() and index_to_access != -1: # Path like "[0]"
					pass # Will be handled by array access logic below
				else:
					return null 
			current_data = current_dict.get(key_to_access, null) # Use .get for safety
		elif key_to_access.is_empty() and typeof(current_data) == TYPE_ARRAY: 
			pass 
		else: 
			return null
			
		if index_to_access != -1: 
			if typeof(current_data) == TYPE_ARRAY:
				var current_array = current_data as Array
				if index_to_access >= 0 and index_to_access < current_array.size():
					current_data = current_array[index_to_access]
				else:
					return null 
			else: 
				return null
				
	return current_data

#endregion

#region Form Data Helpers

func _generate_form_data_boundary() -> String:
	var crypto = Crypto.new()
	var random_bytes = crypto.generate_random_bytes(16)
	return "Boundary-%s" % random_bytes.hex_encode() 

func _construct_form_data_body(text_fields: Dictionary, image_field: Image, mask_field: Image, boundary: String, form_data_rules: Dictionary) -> PackedByteArray:
	var body := PackedByteArray()

	var image_field_name = form_data_rules.get("image_field_name", "image")
	var mask_field_name = form_data_rules.get("mask_field_name", "mask")
	
	for key in text_fields:
		# Ensure value is stringifiable or skip
		var value_to_write = text_fields[key]
		if value_to_write is String or value_to_write is int or value_to_write is float or value_to_write is bool:
			_form_data_append_line(body, "--%s" % boundary)
			_form_data_append_line(body, 'Content-Disposition: form-data; name="%s"' % key)
			_form_data_append_line(body, '')
			_form_data_append_line(body, str(value_to_write))
		else:
			push_warning("Skipping non-stringifiable field '%s' for form data." % key)


	if image_field != null:
		_form_data_append_line(body, "--%s" % boundary)
		_form_data_append_line(body, 'Content-Disposition: form-data; name="%s"; filename="image.png"' % image_field_name)
		_form_data_append_line(body, 'Content-Type: image/png')
		_form_data_append_line(body, '')
		_form_data_append_bytes(body, image_field.save_png_to_buffer())
		_form_data_append_line(body, '') 

	if mask_field != null:
		_form_data_append_line(body, "--%s" % boundary)
		_form_data_append_line(body, 'Content-Disposition: form-data; name="%s"; filename="mask.png"' % mask_field_name)
		_form_data_append_line(body, 'Content-Type: image/png')
		_form_data_append_line(body, '')
		_form_data_append_bytes(body, mask_field.save_png_to_buffer())
		_form_data_append_line(body, '')

	_form_data_append_line(body, "--%s--" % boundary) 
	return body


static func _form_data_append_line(buffer:PackedByteArray, line:String) -> void:
	buffer.append_array(line.to_ascii_buffer())
	buffer.append_array('\r\n'.to_ascii_buffer())


static func _form_data_append_bytes(buffer:PackedByteArray, bytes_data:PackedByteArray) -> void:
	buffer.append_array(bytes_data)
#endregion
