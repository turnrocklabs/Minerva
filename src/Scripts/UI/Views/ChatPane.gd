class_name ChatPane
extends TabContainer

var provider: BaseProvider:
	set(value):
		provider = value
		if provider:
			update_token_estimation() # Update token estimation if provider changes

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
	
	# Ensure we have open chat so we can get its history and disable the notes
	ensure_chat_open()
	SingletonObject.NotesTab.Disable_All()

	var history: ChatHistory = SingletonObject.ChatList[current_tab]

	var existing_message = false

	# if last message is user message, that means we have no reply for it.
	# FIXME: if user spams the chat button, this will run multiple times
	var lst_chi = history.HistoryItemList.back() if not history.HistoryItemList.is_empty() else null
	if lst_chi and lst_chi.Role == ChatHistoryItem.ChatRole.USER:
		existing_message = true

	var history_list: Array[Variant]
	var user_msg_node: MessageMarkdown
	var user_history_item: ChatHistoryItem

	if not existing_message:
		## prepare an append item for the history
		user_history_item = ChatHistoryItem.new()
		user_history_item.Message = %txtMainUserInput.text
		user_history_item.Role = ChatHistoryItem.ChatRole.USER

		%txtMainUserInput.text = ""

		# add the message to the history list before we construct the prompt, so it gets included
		history.HistoryItemList.append(user_history_item)
		
		# make a chat request
		history_list = create_prompt(user_history_item)

		user_msg_node = await SingletonObject.ChatList[current_tab].VBox.add_history_item(user_history_item)

		# Set the tokens estimation label. Correct token will be 0 until we get a response
		user_msg_node.update_tokens_cost(SingletonObject.Chats.provider.estimate_tokens(user_history_item.Message), 0)
	
	else:
		# since we already have the message in user history create the prompt with no additional items
		history_list = create_prompt()

		user_msg_node = lst_chi.rendered_node
		user_history_item = lst_chi

	# Add empty history item, to show the loading state
	var dummy_item = ChatHistoryItem.new()
	dummy_item.Role = ChatHistoryItem.ChatRole.MODEL
	
	var model_msg_node = await SingletonObject.ChatList[current_tab].VBox.add_history_item(dummy_item)
	model_msg_node.loading = true

	# This function can be awaited for the request to finish
	var bot_response = await provider.generate_content(history_list)

	# Create history item from bot response
	var chi = ChatHistoryItem.new()
	chi.Id = bot_response.id
	chi.Role = ChatHistoryItem.ChatRole.MODEL
	chi.Message = bot_response.text
	chi.Error = bot_response.error
	chi.provider = SingletonObject.Chats.provider

	# Update user message node
	user_msg_node.update_tokens_cost(SingletonObject.Chats.provider.estimate_tokens(user_history_item.Message), bot_response.prompt_tokens)

	# Change the history item and the mesasge node will update itself
	model_msg_node.history_item = chi
	history.HistoryItemList.append(chi)

	## Inform the user history item that the response has arrived
	user_history_item.response_arrived.emit(chi)

	model_msg_node.loading = false



# TODO: check if changing the active tab during the request causes any trouble

## This function takes `partial_chi` and prompts model to finish the response
## merging the new and the initial response into one and returning it.
func continue_response(partial_chi: ChatHistoryItem) -> ChatHistoryItem:
	# make a chat request with temporary chat history item
	var temp_chi = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	temp_chi.Message = "continue"

	var history_list: Array[Variant] = SingletonObject.Chats.create_prompt(temp_chi)
	
	remove_chat_history_item(partial_chi, SingletonObject.ChatList[current_tab])

	var chi = await SingletonObject.Chats.provider.generate_content(history_list)

	# merge the two responses
	chi.Message = "%s %s" % [partial_chi.Message, chi.Message]

	## Inform the user history item that the response has arrived
	partial_chi.response_arrived.emit(chi)

	return chi

## Render a full chat history response
func render_single_chat(item: ChatHistoryItem):
	SingletonObject.ChatList[current_tab].HistoryItemList.append(item)

	# Ask the Vbox to add the message
	# and save the rendered node to the chat history item, si we can delete it if needed
	item.rendered_node = await SingletonObject.ChatList[current_tab].VBox.add_history_item(item)
	


## Will remove the chat histoy item from the history and remove the rendered node.
## if `auto_merge` is false, this function will only delete the given history item and it's rendered node,
## otherwise, it will automatically merge next message with previous so perserve the user/model turn
func remove_chat_history_item(item: ChatHistoryItem, history: ChatHistory = null, auto_merge:= true):
	if item.rendered_node:
		item.rendered_node.queue_free()
	else:
		push_warning("Trying to delete chat history item %s with no rendered node attached to it" % item)
		return

	if not auto_merge: return

	if not history:
		for h in SingletonObject.ChatList:
			if h.HistoryItemList.has(item):
				history = h
				break

	if not history:
		push_error("Trying to remove history item %s not present in any history item list" % item)
		return

	var item_index = history.HistoryItemList.find(item)

	for citem: ChatHistoryItem in history.HistoryItemList.slice(item_index+1):
		if citem.rendered_node:
			citem.rendered_node.queue_free()
			history.HistoryItemList.erase(citem)
			break

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
		SingletonObject.ChatList[current_tab].VBox.add_history_item(item)



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
	var item:= ChatHistoryItem.new()
	#test_response.FullText = "Here is how you write hello world in python:\n```python\nprint (\"Hello World\")\n```"
	item.Message = """
		## Markdown
		Here is how you write hello world in python:
		```python
		print (\"Hello World\")
		```
	"""
	self.render_single_chat(item)
	pass # Replace with function body.

func clear_all_chats():
	for child in get_children():
		remove_child(child)
	add_child(SingletonObject.Provider)

func update_token_estimation():
	%EstimatedTokensLabel.text = str(provider.estimate_tokens(%txtMainUserInput.text))


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


## When user types in the chat box, estimate tokens count based on selected provider
func _on_txt_main_user_input_text_changed():
	update_token_estimation()


