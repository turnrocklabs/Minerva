class_name LocalProvider
extends ChatGPTBase

var max_tokens: int

func _init():
	super()
	provider_name = "Ollama"
	BASE_URL = "http://localhost:30000"
	PROVIDER = SingletonObject.API_PROVIDER.LOCAL

	model_name = "deepseek-r1:14b"
	max_tokens = 8192
	short_name = "d1"
	token_cost = 0.0 # local model

func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
	
	additional_params.merge({
		"temperature": 0.7,
		"top_p": 0.8,
		"top_k": 20,
		"max_tokens": self.max_tokens,
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
		token_cost = 0.0 # local model