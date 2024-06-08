class_name ChatPane
extends TabContainer

var Chat: BaseProvider

## add new chat 
func _on_new_chat():
	var tab_name:String = "Chat" + str(SingletonObject.last_tab_index)
	SingletonObject.last_tab_index += 1
	var history: ChatHistory = ChatHistory.new(self.Chat)
	history.HistoryName = tab_name
	history.HistoryItemList = []
	SingletonObject.ChatList.append(history)
	render_history(history)

## Function:
# create_prompt generates the full turn prompt
func create_prompt(append_item:ChatHistoryItem = null, disable_notes: bool = false, inspect:= false) -> Array[Variant]:
	# make sure we have an active chat
	if len(SingletonObject.ChatList) <= current_tab:
		_on_new_chat()

	## Get the working memory and append the user message to chat history
	# var prompt_for_turn: String = ""

	var working_memory: String = SingletonObject.NotesTab.To_Prompt(Chat)

	# disable the notes if we are asked
	if disable_notes:
		SingletonObject.NotesTab.Disable_All()

	## get the message for completion, appending a new items if given
	var history: ChatHistory = SingletonObject.ChatList[current_tab]

	if append_item != null:
		if len(working_memory) > 0:
			append_item.InjectedNote = working_memory
			append_item.Message = append_item.Message
		
		history.HistoryItemList.append(append_item)
		SingletonObject.ChatList[current_tab] = history
	
	var history_list: Array[Variant] = history.To_Prompt();

	if inspect: history.HistoryItemList.pop_back()

	return history_list

func _on_btn_inspect_pressed():
	var new_history_item: ChatHistoryItem = ChatHistoryItem.new()
	new_history_item.Message = %txtMainUserInput.text
	new_history_item.Role = ChatHistoryItem.ChatRole.USER

	## generate the JSON string we would send to the model.
	var history_list: Array[Variant] = self.create_prompt(new_history_item, false, true)

	# var formatted = SingletonObject.Provider.Format(new_history_item)

	# history_list.append(formatted)

	var stringified_history:String = JSON.stringify(history_list, "\t")
	%cdePrompt.text = stringified_history
	
	## show the inspector popup
	var target_size = %tcChats.size
	%InspectorPopup.exclusive = true
	%InspectorPopup.borderless = false
	%InspectorPopup.size = target_size
	%InspectorPopup.popup_centered()

	pass # Replace with function body.

func _on_chat_pressed():
	## prepare an append item for the history
	var new_history_item: ChatHistoryItem = ChatHistoryItem.new()
	new_history_item.Message = %txtMainUserInput.text
	new_history_item.Role = ChatHistoryItem.ChatRole.USER

	
	## Add the user speech bubble to the chat area control.
	var temp_user_data: BotResponse = BotResponse.new()
	temp_user_data.FullText = %txtMainUserInput.text
	
	# make a chat request
	var history_list: Array[Variant] = self.create_prompt(new_history_item, true)
	Chat.generate_content(history_list)

	SingletonObject.ChatList[current_tab].VBox.add_user_message(temp_user_data)

	SingletonObject.ChatList[current_tab].VBox.loading_response = true
	
	%txtMemoryTitle.text = ""
	%txtMainUserInput.text = ""

## Render a full chat history response
func render_single_chat(response:BotResponse):
	SingletonObject.ChatList[current_tab].VBox.loading_response = false
	# create a chat history item and append it to the list
	var item: ChatHistoryItem = ChatHistoryItem.new()
	item.Role = ChatHistoryItem.ChatRole.ASSISTANT
	item.Message = response.FullText
	SingletonObject.ChatList[current_tab].HistoryItemList.append(item)

	# Ask the Vbox to add the message
	SingletonObject.ChatList[current_tab].VBox.add_bot_message(response)
	pass


func render_history(chat_history: ChatHistory):
	# Create a ScrollContainer and set flags
	var scroll_container = ScrollContainer.new()
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_container.follow_focus = true

	# create a derived VBoxContainer for chats and add to the scroll container
	var vboxChat: VBoxChat = VBoxChat.new(self)
	vboxChat.chat_history = chat_history
	chat_history.VBox = vboxChat

	scroll_container.add_child(vboxChat)

	# set the scroll container name and add it to the pane.
	var _name = chat_history.HistoryName
	scroll_container.name = _name
	%tcChats.add_child(scroll_container)

	for item in chat_history.HistoryItemList:
		if item.Role == item.ChatRole.USER:
			SingletonObject.ChatList[current_tab].VBox.add_user_message(item.to_bot_response())
		elif item.Role in [item.ChatRole.MODEL, item.ChatRole.ASSISTANT]:
			SingletonObject.ChatList[current_tab].VBox.add_bot_message(item.to_bot_response())



# Called when the node enters the scene tree for the first time.
func _ready():
	self.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	self.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(self))

	if Chat == null:
		Chat = OpenAI.new()
		add_child(Chat)
		Chat.chat_completed.connect(self.render_single_chat)
	SingletonObject.initialize_chats(Chat, self)

##        remove chat  
func _on_close_tab(tab: int, container: TabContainer):
	var control = container.get_tab_control(tab)
	container.remove_child(control)
	SingletonObject.ChatList.remove_at(tab)


# Called every frame. 'delta' is the elapsed time since the previous frame.
# func _process(delta):
# 	pass

func _on_btn_memorize_pressed():
	var user_title = %txtMemoryTitle.text
	var user_body = %txtMainUserInput.text
	
	if user_title == "" or user_body == "":
		SingletonObject.ErrorDisplay("Error","Please enter an Title and description for note") 
		
	else:
		SingletonObject.NotesTab.add_note(user_title, user_body)
		%txtMemoryTitle.text = ""
		%txtMainUserInput.text = ""

## Feature development -- create a button and add it to the upper chat vbox?
func _on_btn_test_pressed():
	if len(SingletonObject.ChatList) <= current_tab:
		_on_new_chat()

	# Pretend we did a chat like "Write hello world in python" and got a BotResponse that made sense.
	var test_response:BotResponse = BotResponse.new()
	#test_response.FullText = "Here is how you write hello world in python:\n```python\nprint (\"Hello World\")\n```"
	test_response.FullText = """
		## Markdown
		Here is how you write hello world in python:
		```python
		print (\"Hello World\")
		```
	"""
	self.render_single_chat(test_response)
	pass # Replace with function body.

func clear_all_chats():
	for child in get_children():
		remove_child(child)
	add_child(SingletonObject.Provider)




# region Edit Chat Title

func show_title_edit_dialog(tab: int):
	%EditTitleDialog.set_meta("tab", tab)
	%EditTitleDialog/LineEdit.text = get_tab_title(tab)
	%EditTitleDialog.popup_centered()


func _on_edit_title_dialog_confirmed():
	var tab = %EditTitleDialog.get_meta("tab")

	set_tab_title(tab, %EditTitleDialog/LineEdit.text)


# Detect the double click and open the title edit popup
var clicked:= false
func _on_tab_clicked(tab: int):

	if clicked: show_title_edit_dialog(tab)

	clicked = true
	get_tree().create_timer(0.4).timeout.connect(func(): clicked = false)

# endregion

## Function:
# Loads a file and raises a signal to the singleton for the memory tabs
# to attach a file.
func _on_btn_attach_file_pressed():
	%AttachFileDialog.popup_centered(Vector2i(700, 500))


func _on_attach_file_dialog_files_selected(paths: PackedStringArray):
	for fp in paths:
		SingletonObject.AttachNoteFile.emit(fp)
		await get_tree().process_frame
