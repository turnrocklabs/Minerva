class_name MultiMessageContainer extends Control

signal message_updated(message_index: int)

var current_index: int = 0
var messages: Array[ChatHistoryItem] = []

func add_item(node: Control) -> void:
	%SliderContainer.add_child(node)
	messages.append(node.history_item)

func update_message(index: int, new_history_item: ChatHistoryItem) -> void:
	if index >= 0 and index < messages.size():
		# Get the MessageMarkdown node at this index
		var msg_node = %SliderContainer.get_child(index) as MessageMarkdown
		if msg_node:
			msg_node.history_item = new_history_item
			messages[index] = new_history_item
			message_updated.emit(index)

func get_current_message() -> ChatHistoryItem:
	if messages.size() > 0 and current_index < messages.size():
		return messages[current_index]
	return null

func _on_prev_button_pressed() -> void:
	%SliderContainer.previous_child()
	current_index = wrapi(current_index - 1, 0, messages.size())

func _on_next_button_pressed() -> void:
	%SliderContainer.next_child()
	current_index = wrapi(current_index + 1, 0, messages.size())
