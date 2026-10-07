extends SceneTree
## Real chat controls refuse missing service setup before consuming the message.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var singleton = root.get_node("SingletonObject")
	var ui := Control.new()
	root.add_child(ui)
	singleton.main_scene = ui
	var pane = load("res://Scripts/UI/Views/ChatPane.gd").new()
	pane.add_child(Control.new())
	var send := OptionButton.new()
	send.name = "SendMessageButton"
	pane.add_child(send, false, Node.INTERNAL_MODE_BACK)
	send.owner = pane
	send.unique_name_in_owner = true
	var input := TextEdit.new()
	input.name = "txtMainUserInput"
	input.text = "Keep this message"
	pane.add_child(input, false, Node.INTERNAL_MODE_BACK)
	input.owner = pane
	input.unique_name_in_owner = true
	var provider = load("res://Scripts/Services/Providers/Core/CoreProvider.gd").new()
	var history = load("res://Scripts/Models/ChatHistory.gd").new(provider)
	singleton.ChatList.append(history)
	pane._on_send_message_button_item_selected(0)
	var prompt := ui.get_node_or_null("ServiceAccountPrompt")
	var passed: bool = prompt != null and prompt.visible and input.text == "Keep this message" and history.HistoryItemList.is_empty()
	print("PASS: Core chat opens sign-in without consuming input" if passed else "FAIL: Core chat sign-in guard")
	print("=== PASS ===" if passed else "=== FAIL ===")
	singleton.ChatList.clear()
	singleton.main_scene = null
	pane.free()
	provider.free()
	ui.queue_free()
	await process_frame
	quit(0 if passed else 1)
