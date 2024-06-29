class_name ChatPane
extends TabContainer


var icActive = preload("res://assets/icons/Microphone_active.png")
var closed_chat_data: ChatHistory  # Store the data of the closed chat
var control: Control  # Store the tab control
var container: TabContainer  # Store the TabContainer
@onready var txt_main_user_input: TextEdit = %txtMainUserInput

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
## Check `History.To_Prompt` for explanation on `predicate`.
func create_prompt(append_item: ChatHistoryItem = null, predicate: Callable = Callable()) -> Array[Variant]:
	# get history of the active chat tab if there is one
	if len(SingletonObject.ChatList) <= current_tab:
		return []
	
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	
	var working_memory: String = SingletonObject.NotesTab.To_Prompt(provider)

	print(working_memory)

	# history will turn it into a prompts using the selected provider
	var history_list: Array[Variant] = history.To_Prompt(predicate)

	# If we don't have a new item but we have active notes, we still need new item to add the noted in there
	if not append_item and working_memory:
		append_item = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	
	# append the working memory
	if append_item:
		append_item.InjectedNote = working_memory
		print(append_item)
		# also append the new item since it's not in the history yet
		history_list.append(provider.Format(append_item))

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


## Takes a chat history item and regenerates the prompt for it.
## Regenerates response will be placed in next
func regenerate_response(chi: ChatHistoryItem):
	
	if chi.Role != ChatHistoryItem.ChatRole.USER:
		push_warning("Tried to regenerate response for history item %s who's Role is not user" % chi)
		return

	var history: ChatHistory
	if not history:
		for h in SingletonObject.ChatList:
			if h.HistoryItemList.has(chi):
				history = h
				break

	if not history:
		push_warning("Trying to regenerate response for history item %s not present in any history item list" % chi)
		return
	
	var index = history.HistoryItemList.find(chi)

	var existing_response: ChatHistoryItem

	for item in history.HistoryItemList.slice(index):
		if item.Role == ChatHistoryItem.ChatRole.MODEL:
			existing_response = item
			break

	if not existing_response:
		existing_response = ChatHistoryItem.new()
		existing_response.Role = ChatHistoryItem.ChatRole.MODEL

	# We format items until we get to the user response
	var predicate = func(item: ChatHistoryItem) -> Array:
		return [
			history.HistoryItemList.find(item) < index,
			history.HistoryItemList.find(item) < index,
		]

	var history_list = create_prompt(chi, predicate)

	existing_response.rendered_node.loading = true

	var bot_response = await provider.generate_content(history_list)
	
	existing_response.Id = bot_response.id
	existing_response.Message = bot_response.text
	existing_response.Error = bot_response.error
	existing_response.provider = SingletonObject.Chats.provider
	existing_response.Complete = bot_response.complete

	existing_response.rendered_node.render()

	existing_response.rendered_node.loading = false


func _on_chat_pressed():
	execute_chat()


func execute_chat():
	# Ensure we have open chat so we can get its history and disable the notes
	ensure_chat_open()

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
		history_list = create_prompt()

		user_msg_node = await SingletonObject.ChatList[current_tab].VBox.add_history_item(user_history_item)

		user_history_item.EstimatedTokenCost = provider.estimate_tokens_from_prompt(history_list)
		# rerender the message wince we changed the history item
		user_msg_node.render()
	
	else:
		# since we already have the message in user history create the prompt with no additional items
		history_list = create_prompt()

		user_msg_node = lst_chi.rendered_node
		user_history_item = lst_chi
	
	# we made the prompt, disable the notes now
	SingletonObject.NotesTab.Disable_All()

	# Add empty history item, to show the loading state
	var dummy_item = ChatHistoryItem.new()
	dummy_item.Role = ChatHistoryItem.ChatRole.MODEL
	
	var model_msg_node = await SingletonObject.ChatList[current_tab].VBox.add_history_item(dummy_item)
	model_msg_node.loading = true

	# This function can be awaited for the request to finish
	var bot_response = await provider.generate_content(history_list)

	# Create history item from bot response
	var chi = ChatHistoryItem.new()
	if bot_response.id: chi.Id = bot_response.id
	chi.Role = ChatHistoryItem.ChatRole.MODEL
	chi.Message = bot_response.text
	chi.Error = bot_response.error
	chi.provider = provider
	chi.Complete = bot_response.complete
	chi.TokenCost = bot_response.completion_tokens
	if bot_response.image:
		chi.Images = ([bot_response.image] as Array[Image])

	# Update user message node
	user_history_item.TokenCost = bot_response.prompt_tokens
	user_msg_node.render()

	# Change the history item and the mesasge node will update itself
	model_msg_node.history_item = chi
	history.HistoryItemList.append(chi)

	## Inform the user history item that the response has arrived
	user_history_item.response_arrived.emit(chi)

	SingletonObject.ChatList[current_tab].VBox.scroll_to_bottom()

	model_msg_node.loading = false



# TODO: check if changing the active tab during the request causes any trouble

## This function takes `partial_chi` and prompts model to finish the response
## merging the new and the initial response into one and returning it.
func continue_response(partial_chi: ChatHistoryItem) -> ChatHistoryItem:
	# make a chat request with temporary chat history item
	var temp_chi = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	temp_chi.Message = "continue"

	var history_list: Array[Variant] = SingletonObject.Chats.create_prompt(temp_chi)
	
	# remove_chat_history_item(partial_chi, SingletonObject.ChatList[current_tab])

	var bot_response = await SingletonObject.Chats.provider.generate_content(history_list)

	partial_chi.Message += bot_response.text
	partial_chi.Complete = bot_response.complete

	# set the history item for the rendered node so it gets rerendered
	partial_chi.rendered_node.history_item = partial_chi

	# var chi = ChatHistoryItem.new()
	# chi.Role = ChatHistoryItem.ChatRole.MODEL

	# # merge the two responses
	# chi.Message = "%s %s" % [partial_chi.Message, bot_response.text]

	# ## Inform the user history item that the response has arrived
	# partial_chi.response_arrived.emit(partial_chi)

	return partial_chi

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
	
	# if `auto_merge` is true, keep the item until we find previous and next history items
	# and delete it at the end
	if not auto_merge:
		history.HistoryItemList.erase(item)
		return

	if not history:
		for h in SingletonObject.ChatList:
			if h.HistoryItemList.has(item):
				history = h
				break

	if not history:
		push_error("Trying to remove history item %s not present in any history item list" % item)
		return

	var item_index = history.HistoryItemList.find(item)

	var previous: ChatHistoryItem
	var next: ChatHistoryItem

	if item_index > 0:
		previous = history.HistoryItemList[item_index-1]

	if item_index < history.HistoryItemList.size()-1:
		next = history.HistoryItemList[item_index+1]

	if previous and next and previous.Role == next.Role:
		previous.merge(next)
		remove_chat_history_item(next, history, false)
		previous.rendered_node.history_item = previous # force rerender

	history.HistoryItemList.erase(item)


## Will hide the chat histoy item. If `remove_pair` is true
## and the item is user message it will also hide the answer or 
## the question if the item is bot message if the item is present in any chat history.
func hide_chat_history_item(item: ChatHistoryItem, history: ChatHistory = null, remove_pair: = true):	
	item.Visible = false
	item.rendered_node.render()

	if not remove_pair: return
	
	if not history:
		for h in SingletonObject.ChatList:
			if h.HistoryItemList.has(item):
				history = h
				break

	if not history:
		push_warning("Hiding history item %s not present in any history item list" % item)
		return
		
	var item_index = history.HistoryItemList.find(item)

	## if the item is user message, check if there's next message that's model and hide it
	if item.Role == ChatHistoryItem.ChatRole.USER:
		if history.HistoryItemList.size() > item_index:
			var next_item = history.HistoryItemList[item_index+1]
			if next_item.Role == ChatHistoryItem.ChatRole.MODEL:
				next_item.Visible = false
				next_item.rendered_node.render()

	## if the item is user message, check if there's previous message that's user and hide it
	elif item.Role == ChatHistoryItem.ChatRole.MODEL:
		if item_index > 0:
			var previous_item = history.HistoryItemList[item_index-1]
			if previous_item.Role == ChatHistoryItem.ChatRole.USER:
				previous_item.Visible = false
				previous_item.rendered_node.render()

	


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
	
	SingletonObject.initialize_chats(self)

## Changes the provider that this chat panes uses to generate responses
func set_provider(new_provider: BaseProvider):
	if provider.is_inside_tree(): remove_child(provider)

	add_child(new_provider)
	# new_provider.chat_completed.connect(self.render_single_chat)

	provider = new_provider


func _on_close_tab(tab: int, container: TabContainer):
	self.control = container.get_tab_control(tab)
	self.container = container 
	SingletonObject.undo.store_deleted_tab(tab, control,"left")
	container.remove_child(control)

# Function to restore a deleted tab
func restore_deleted_tab(tab_name: String):
	if tab_name in SingletonObject.undo.deleted_tabs:
		var data = SingletonObject.undo.deleted_tabs[tab_name]
		var tab = data["tab"]
		var control = data["control"]
		var history = data["history"]
		data["timer"].stop()
		#Add the control back to the TabContainer
		%tcChats.add_child(control)
		
		# Set the tab index and restore the history
		set_current_tab(tab)
		SingletonObject.ChatList[tab] = history
		# Clear the deleted tab from the dictionary
		SingletonObject.undo.deleted_tabs.erase(tab_name)

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
	add_child(SingletonObject.Chats.provider)

func update_token_estimation():
	if not SingletonObject.Chats: return

	var chi = ChatHistoryItem.new()
	chi.Message = %txtMainUserInput.text
	
	var token_count = provider.estimate_tokens_from_prompt(create_prompt(chi))

	%EstimatedTokensLabel.text = "%s (%s$)" % [token_count, provider.token_cost * token_count]


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

func _on_txt_main_user_input_text_set():
	update_token_estimation()

func _on_btn_microphone_pressed():
	SingletonObject.AtT.FieldForFilling = %txtMainUserInput
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnMicrophone
	%btnMicrophone.icon = icActive

func _process(_delta: float):
	if txt_main_user_input.has_focus():
		if Input.is_action_just_pressed("control_enter"):
			execute_chat()

func _on_child_order_changed():
	# Update ChatList in the SingletonObject
	SingletonObject.ChatList = []  # Clear the existing list
	for child in get_children():
		if child is ScrollContainer:
			var vbox_chat = child.get_child(0)
			if vbox_chat is VBoxChat:
				SingletonObject.ChatList.append(vbox_chat.chat_history)