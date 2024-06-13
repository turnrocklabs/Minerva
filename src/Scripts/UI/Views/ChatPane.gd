class_name ChatPane
extends TabContainer

var provider: BaseProvider

## add new chat 
func _on_new_chat():
	var tab_name:String = "Chat" + str(SingletonObject.last_tab_index)
	SingletonObject.last_tab_index += 1
	var history: ChatHistory = ChatHistory.new(self.provider)
	history.HistoryName = tab_name
	history.HistoryItemList = []
	SingletonObject.ChatList.append(history)
	render_history(history)


## Opens a chat tab if one isn't open yet
func ensure_chat_open() -> void:
	if len(SingletonObject.ChatList) <= current_tab:
		_on_new_chat()

## Generates the full turn prompt using the history of the active chat and the selected provider.
## `append_item` will be present in the prompt, but WON'T be added to chat history inside this function.
func create_prompt(append_item: ChatHistoryItem = null) -> Array[Variant]:
	# get history of the active chat tab if there is one
	if len(SingletonObject.ChatList) <= current_tab:
		return []
	
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	
	var working_memory: String = SingletonObject.NotesTab.To_Prompt(provider)

	# history will turn it into a prompts using the selected provider
	var history_list: Array[Variant] = history.To_Prompt()

	# If we don't have a new item but we have active notes, we still need new item to add the noted in there
	if not append_item and working_memory:
		append_item = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	
	# append the working memory
	if append_item:
		append_item.InjectedNote = working_memory

		# also append the new item since it's not in the history yet
		history_list.append(history.Provider.Format(append_item))

	return history_list




func _on_btn_inspect_pressed():
	var new_history_item: ChatHistoryItem = ChatHistoryItem.new()
	new_history_item.Message = %txtMainUserInput.text
	new_history_item.Role = ChatHistoryItem.ChatRole.USER

	## generate the dictionary we would send to the model.
	var history_list: Array[Variant] = create_prompt(new_history_item)

	# we wont add the message to the history

	ensure_chat_open()

	var stringified_history:String = JSON.stringify(history_list, "\t")
	%cdePrompt.text = stringified_history
	
	## show the inspector popup
	var target_size = %tcChats.size
	%InspectorPopup.exclusive = true
	%InspectorPopup.borderless = false
	%InspectorPopup.size = target_size
	%InspectorPopup.popup_centered()


func _on_chat_pressed():
	## prepare an append item for the history
	var new_history_item: ChatHistoryItem = ChatHistoryItem.new()
	new_history_item.Message = %txtMainUserInput.text
	new_history_item.Role = ChatHistoryItem.ChatRole.USER

	
	## Add the user speech bubble to the chat area control.
	var temp_user_data: BotResponse = BotResponse.new()
	temp_user_data.FullText = %txtMainUserInput.text

	# Ensure we have open chat so we can get its history and disable the notes
	ensure_chat_open()
	SingletonObject.NotesTab.Disable_All()

	# add the message to the history list before we construct the prompt, so it gets included
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	history.HistoryItemList.append(new_history_item)
	
	# make a chat request
	var history_list: Array[Variant] = create_prompt(new_history_item)

	SingletonObject.ChatList[current_tab].VBox.add_user_message(temp_user_data)

	%txtMainUserInput.text = ""

	SingletonObject.ChatList[current_tab].VBox.loading_response = true

	# This function can be awaited for the request to finish
	var bot_response = await provider.generate_content(history_list)

	render_single_chat(bot_response)

	SingletonObject.ChatList[current_tab].VBox.loading_response = false

# TODO: check if changing the active tab during the request causes any trouble

## This function takes `partial_response` and prompts model to finish the response
## merging the new and the initial response into one.
func continue_response(partial_response: BotResponse):
	# make a chat request
	var chi = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	chi.Message = "continue"

	var history_list: Array[Variant] = SingletonObject.Chats.create_prompt(chi)
	
	var partial_chi: ChatHistoryItem

	# find the history item that holds `partial_response`, so we can remove it
	# merge it with new response and render the new one
	for item: ChatHistoryItem in SingletonObject.ChatList[current_tab].HistoryItemList:
		if item.bot_response != partial_response: continue
		partial_chi = item
		SingletonObject.ChatList[current_tab].HistoryItemList.erase(item)
		break
	
	remove_chat_history_item(partial_chi, SingletonObject.ChatList[current_tab])

	SingletonObject.ChatList[current_tab].VBox.loading_response = true

	var bot_response = await SingletonObject.Chats.provider.generate_content(history_list)

	SingletonObject.ChatList[current_tab].VBox.loading_response = false

	bot_response.FullText = "%s%s" % [partial_response.FullText, bot_response.FullText]

	SingletonObject.Chats.render_single_chat(bot_response)

## Render a full chat history response
func render_single_chat(response: BotResponse):
	
	# create a chat history item and append it to the list
	var item: ChatHistoryItem = ChatHistoryItem.new()
	item.Role = ChatHistoryItem.ChatRole.ASSISTANT
	item.Message = response.FullText
	# define from which bot response this chat history item was constructed
	item.bot_response = response

	SingletonObject.ChatList[current_tab].HistoryItemList.append(item)

	# Ask the Vbox to add the message
	# and save the rendered node to the chat history item, si we can delete it if needed
	item.rendered_node = await SingletonObject.ChatList[current_tab].VBox.add_bot_message(response)
	


## Will remove the chat histoy item from the history and remove the rendered node.
## TODO: If the item is user message, it will also delete the model response.
func remove_chat_history_item(item: ChatHistoryItem, history: ChatHistory):
	item.rendered_node.queue_free()
	history.HistoryItemList.erase(item)



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

	if provider == null:
		provider = %AISettings.get_selected_provider().new()
		set_provider(provider)
	
	SingletonObject.initialize_chats(provider, self)

## Changes the provider that this chat panes uses to generate responses
func set_provider(new_provider: BaseProvider):
	if provider.is_inside_tree(): remove_child(provider)

	add_child(new_provider)
	# new_provider.chat_completed.connect(self.render_single_chat)

	provider = new_provider


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




# region Edit provider Title

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


func _on_btn_chat_settings_pressed():
	%AISettings.popup_centered()
