extends ColorRect

func get_all_messages() -> Array[String]:
	var messages: Array[String] = []
	
	# Find the MessagesHolder node
	var MessagesHolder = get_parent().get_parent().get_parent().get_parent().get_parent().get_parent().get_parent().find_child("UnsplitedChatMessages").find_child("MessagesHolder")
	
	# Iterate through all children of MessagesHolder
	for child in MessagesHolder.get_children():
		if child is MessageMarkdown and child.content is String:
			# Ensure the child is a MessageMarkdown instance
			if child != null:
				messages.append(child.content)  # Add the message content to the array
	
	return messages
	
func get_all_images() -> Array[Image]:
	var images: Array[Image] = []
	
	# Find the MessagesHolder node
	var MessagesHolder = get_parent().get_parent().get_parent().get_parent().get_parent().get_parent().get_parent().find_child("UnsplitedChatMessages").find_child("MessagesHolder")
	
	# Iterate through all children of MessagesHolder
	for child in MessagesHolder.get_children():
		if child is MessageMarkdown:
			# Access the images from the history_item
			for image in child.history_item.Images:
				if image != null:
					images.append(image)
	
	return images

func _on_apply_changes_pressed() -> void:
	
	var current_message = SingletonObject.current_message
	var all_messages = get_all_messages()
	var all_images = get_all_images()
	if all_messages.size() + all_images.size() == 1:
		current_message.history_item.isMerged = false
	
	var combined_message = ""
	
	# Only process if there are messages or images
	if all_messages.size() > 0 or all_images.size() > 0:
		for message in all_messages:
			# Strip any leading/trailing whitespace and check if the message is not empty
			var trimmed_message = message.strip_edges()
			if trimmed_message != "":
				combined_message += trimmed_message + "\n\u200B\u200C\u200D\n"
		
		# Remove the last unnecessary separator if there are messages
		if all_messages.size() > 0:
			combined_message = combined_message.strip_edges()
	
	# If no valid messages were found but there are images, keep the message history item
	if combined_message == "" and all_images.size() > 0:
		combined_message = " "  # Set a space or any placeholder to keep the message history item
	
	# If no valid messages and no images were found, remove the chat history item
	if combined_message == "" and all_images.is_empty():
		SingletonObject.Chats.remove_chat_history_item(current_message.history_item)
	else:
		# Update the current message with the combined content and images
		if current_message:
			current_message.content = combined_message
			current_message.history_item.Images.clear()
			if !all_images.is_empty():
				for image in all_images:
					current_message.history_item.Images.append(image)
			current_message.render()
	
	# Clear the MessagesHolder and hide the UI
	for child in $VBoxContainer/ScrollContainer/MessagesHolder.get_children():
		child.queue_free()
	visible = false


func _on_cancel_changes_pressed() -> void:
	for i in $VBoxContainer/ScrollContainer/MessagesHolder.get_children():
		i.queue_free()
		
	visible = false

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.is_pressed():
		var local_event = make_input_local(event)
		
		if not Rect2(Vector2(), size).has_point(local_event.position):
			for i in $VBoxContainer/ScrollContainer/MessagesHolder.get_children():
				i.queue_free()
			visible = false
