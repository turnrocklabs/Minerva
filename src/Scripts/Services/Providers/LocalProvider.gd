class_name SGLangProvider
extends ChatGPTBase

func _init():
	super()
	provider_name = "SGLang"
	BASE_URL = "http://localhost:30000"
	PROVIDER = SingletonObject.API_PROVIDER.LOCAL

	model_name = "Qwen/Qwen3-8B-FP8"
	short_name = "Q3"
	token_cost = 0.0 # local model

func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
	
	additional_params.merge({
		"temperature": 0.7,
		"top_p": 0.8,
		"top_k": 20,
		"max_tokens": 32768,
		"presence_penalty": 1.5,
		"chat_template_kwargs": {"enable_thinking": false}
  	}, true)

	return await super(prompt, additional_params)



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

	# content can be a string, but also an array of dictionaries, to handle different media types
	# message and each note will be it's own dictionary
	var content: = [
		{
			"type": "text",
			"text": chat_item.Message
		},
	]

	# handle text and image notes
	for note: Variant in chat_item.InjectedNotes:
		if note is String:
			content.append({
				"type": "text",
				"text": note
			})
		
		# if we have a image, encode it to base64 and send it as a image_url
		elif note is Image:
			content.append({
				"type": "image_url",
				"image_url": {
					"url": "data:image/png;base64,%s" % Marshalls.raw_to_base64(note.save_png_to_buffer())
				}
			})

	return {
		"role": role,
		"content": content
	}

# reimplemented to handle image notes properly
func wrap_memory(item: MemoryItem) -> Variant:
	# Return either string for text notes or Image for image notes

	if item.MemoryImage:
		return item.MemoryImage
	
	else:
		var output = "Given this background information:\n\n"
		output += "### Reference Information ###\n"
		output += item.Content
		output += "### End Reference Information ###\n\n"
		output += "Respond to the user's message: \n\n"
		return output.json_escape()


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
