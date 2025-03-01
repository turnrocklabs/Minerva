extends ColorRect

func get_all_messages() -> Array[String]:
	var messages: Array[String] = []
	
	# Find the MessagesHolder node
	var MessagesHolder = get_parent().get_parent().get_parent().get_parent().get_parent().get_parent().get_parent().find_child("UnsplitedChatMessages").find_child("MessagesHolder")
	
	# Iterate through all children of MessagesHolder
	for child in MessagesHolder.get_children():
		if child is MessageMarkdown and child.content is String:
			# Ensure the child is a MessageMarkdown instance
			messages.append(child.content)  # Add the message content to the array
	
	return messages

func _on_apply_changes_pressed() -> void:
	var current_message = SingletonObject.current_message
	var all_messages = get_all_messages()
	var combined_message = ""
	
	if all_messages.size() == 0:
		SingletonObject.Chats.remove_chat_history_item(current_message.history_item)
	else:
		for message in all_messages:
			combined_message += "\n" + message + "\n" + "\u200B\u200C\u200D"
		combined_message = combined_message.strip_edges()
	
	
		if current_message:
			current_message.content = combined_message
			current_message.render()
	
	for i in  $VBoxContainer/ScrollContainer/MessagesHolder.get_children():
		i.queue_free()
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
