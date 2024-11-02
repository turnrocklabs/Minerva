class_name ChatGPT4o
extends ChatGPTBase

func _init():
	super()

	model_name = "gpt-4o"
	short_name = "O4"
	token_cost = 0.00000125 # https://openai.com/api/pricing/


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
		return output
