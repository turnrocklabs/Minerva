class_name ChatPane
extends TabContainer


var icActive = preload("res://assets/icons/Microphone_active.png")
var closed_chat_data: ChatHistory  # Store the data of the closed chat
var control: Control  # Store the tab control
var container: TabContainer  # Store the TabContainer

@onready var txt_main_user_input: TextEdit = %txtMainUserInput
@onready var _provider_option_button: ProviderOptionButton = %ProviderOptionButton

# Script of the default provider to use when creating new chat tab
var default_provider_script: Script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[0]


## add new chat 
func _on_new_chat():
	var tab_name: = "Chat %s" % (get_tab_count()+1)

	var provider_obj: BaseProvider = default_provider_script.new()

	# If there are no open chat tabs, use provider from the dropdown as the provider
	if SingletonObject.ChatList.is_empty():
		var p_id = _provider_option_button.get_selected_id()
		provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[p_id].new()

	# use the provider currently set on this object
	var history: ChatHistory = ChatHistory.new(provider_obj)
	history.HistoryName = tab_name
	history.HistoryItemList = []
	SingletonObject.ChatList.append(history)
	render_history(history)

	current_tab = get_tab_count()-1


## Opens a chat tab if one isn't open yet
func ensure_chat_open() -> void:
	if SingletonObject.ChatList.is_empty():
		_on_new_chat()

## Generates the full turn prompt using the history of the active chat and the selected provider.
## `append_item` will be present in the prompt, but WON'T be added to chat history inside this function.
## Check `History.To_Prompt` for explanation on `predicate`.
func create_prompt(append_item: ChatHistoryItem = null, predicate: Callable = Callable()) -> Array[Variant]:
	# get history of the active chat tab if there is one
	if SingletonObject.ChatList.is_empty():
		return []
	
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	
	var working_memory: = SingletonObject.NotesTab.To_Prompt(history.provider)

	# history will turn it into a prompts using the selected provider
	var history_list: Array[Variant] = history.To_Prompt(predicate)

	# If we don't have a new item but we have active notes, we still need new item to add the noted in there
	if not append_item and working_memory:
		append_item = ChatHistoryItem.new(ChatHistoryItem.PartType.TEXT, ChatHistoryItem.ChatRole.USER)
	
	# append the working memory
	if append_item:
		append_item.InjectedNotes = working_memory
		# also append the new item since it's not in the history yet
		var item = history.provider.Format(append_item)
		if item: history_list.append(item)

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
		existing_response.provider = SingletonObject.ChatList[current_tab].provider
		history.HistoryItemList.append(existing_response)
		history.VBox.add_history_item(existing_response)

	# We format items until we get to the user response
	var predicate = func(item: ChatHistoryItem) -> Array:
		return [
			history.HistoryItemList.find(item) < index,
			history.HistoryItemList.find(item) < index,
		]

	var history_list = create_prompt(chi, predicate)

	existing_response.rendered_node.loading = true

	var bot_response = await history.provider.generate_content(history_list)

	# if there was an error with the request
	if not bot_response: return
	
	if bot_response.id: existing_response.Id = bot_response.id
	existing_response.Role = ChatHistoryItem.ChatRole.MODEL
	existing_response.Message = bot_response.text
	existing_response.Error = bot_response.error
	existing_response.provider = history.provider
	existing_response.Complete = bot_response.complete
	existing_response.TokenCost = bot_response.completion_tokens
	if bot_response.image:
		existing_response.Images = ([bot_response.image] as Array[Image])

	existing_response.rendered_node.render()

	existing_response.rendered_node.loading = false
	SingletonObject.NotesTab.Disable_All()


func _on_chat_pressed():
	execute_chat()


func execute_chat():
	if %txtMainUserInput.text.is_empty(): return

	# Ensure we have open chat so we can get its history and disable the notes
	ensure_chat_open()

	var history: ChatHistory = SingletonObject.ChatList[current_tab]

	var last_msg = history.HistoryItemList.back() if not history.HistoryItemList.is_empty() else null
	if last_msg and last_msg.Role == ChatHistoryItem.ChatRole.USER: return

	## prepare an append item for the history
	var user_history_item: = ChatHistoryItem.new()
	user_history_item.Message = %txtMainUserInput.text
	user_history_item.Role = ChatHistoryItem.ChatRole.USER

	%txtMainUserInput.text = ""
	
	# make a chat request
	var history_list: = create_prompt(user_history_item)

	var user_msg_node: = history.VBox.add_history_item(user_history_item)

	# first pass `user_history_item` to `create_prompt` so it gets all the notes, and now add it to history
	history.HistoryItemList.append(user_history_item)

	user_history_item.EstimatedTokenCost = history.provider.estimate_tokens_from_prompt(history_list)
	# rerender the message wince we changed the history item
	user_msg_node.render()

	# Add empty history item, to show the loading state
	var dummy_item = ChatHistoryItem.new()
	dummy_item.Role = ChatHistoryItem.ChatRole.MODEL
	dummy_item.provider = history.provider
	
	var model_msg_node = history.VBox.add_history_item(dummy_item)
	model_msg_node.loading = true

	
	var optional_params = {
		"temperature": history.Temperature,
		"top_p": history.TopP,
		"presence_penalty": history.PresencePenalty,
		"frequency_penalty": history.FrecuencyPenalty,
	}

	var bot_response
	if history.provider.PROVIDER == SingletonObject.API_PROVIDER.OPENAI and not history.provider is DallE:
		bot_response = await history.provider.generate_content(history_list, optional_params)
	else:
		bot_response = await history.provider.generate_content(history_list)

	# we made the prompt, disable the notes now
	SingletonObject.NotesTab.Disable_All()

	# Create history item from bot response
	var chi = ChatHistoryItem.new()
	
	if bot_response != null: 
		chi.Id = bot_response.id
		chi.Role = ChatHistoryItem.ChatRole.MODEL
		chi.Message = bot_response.text
		chi.Error = bot_response.error
		chi.provider = history.provider
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

		## Inform the user history item that the responsew has arrived
		user_history_item.response_arrived.emit(chi)

		history.VBox.scroll_to_bottom()

		model_msg_node.loading = false

# TODO: check if changing the active tab during the request causes any trouble

## This function takes `partial_chi` and prompts model to finish the response
## merging the new and the initial response into one and returning it.
func continue_response(partial_chi: ChatHistoryItem) -> ChatHistoryItem:
	# make a chat request with temporary chat history item
	var temp_chi = partial_chi.provider.continue_partial_response(partial_chi)

	var history_list: Array[Variant] = SingletonObject.Chats.create_prompt(temp_chi)
	
	# remove_chat_history_item(partial_chi, SingletonObject.ChatList[current_tab])

	var bot_response = await partial_chi.provider.generate_content(history_list)

	# if there was an error just return the partial response
	if not bot_response: return partial_chi

	partial_chi.Message += " %s" % bot_response.text
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
	item.rendered_node = SingletonObject.ChatList[current_tab].VBox.add_history_item(item)
	


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

	# create a derived VBoxContainer for chats and add to the scroll container
	var vboxChat: VBoxChat = VBoxChat.new(self)
	vboxChat.chat_history = chat_history
	chat_history.VBox = vboxChat

	scroll_container.add_child(vboxChat)

	# set the scroll container name and add it to the pane.
	var _name = chat_history.HistoryName
	#scroll_container.name = _name
	%tcChats.add_child(scroll_container)
	var tab_idx = %tcChats.get_tab_idx_from_control(scroll_container)
	%tcChats.set_tab_title(tab_idx, _name)
	
	
	for item in chat_history.HistoryItemList:
		vboxChat.add_history_item(item)



# Called when the node enters the scene tree for the first time.
func _ready():
	self.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	self.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(self))
	
	SingletonObject.initialize_chats(self)
	%AISettings.create_system_prompt_message.connect(add_new_system_prompt_item)
	
	#this is for overriding the separation in the open file dialog
	#this seems to be the only way I can access it
	var hbox: HBoxContainer = %AttachFileDialog.get_vbox().get_child(0)
	hbox.set("theme_override_constants/separation", 12)


func _on_close_tab(tab: int, closed_tab_container: TabContainer):
	self.control = closed_tab_container.get_tab_control(tab)
	self.container = closed_tab_container 
	SingletonObject.undo.store_deleted_tab(tab, control,"left")
	closed_tab_container.remove_child(control)

# Function to restore a deleted tab
func restore_deleted_tab(tab_name: String):
	if tab_name in SingletonObject.undo.deleted_tabs:
		var data = SingletonObject.undo.deleted_tabs[tab_name]
		var tab = data["tab"]
		var control_ = data["control"]
		var history = data["history"]
		data["timer"].stop()
		#Add the control back to the TabContainer
		%tcChats.call_deferred("add_child", control_)#add_child(control_)
		
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
		call_deferred("remove_child", child)#remove_child(child)


func update_token_estimation():
	if SingletonObject.ChatList.is_empty(): return

	var chi = ChatHistoryItem.new()
	chi.Message = %txtMainUserInput.text
	
	var provider: = SingletonObject.ChatList[current_tab].provider

	var token_count = provider.estimate_tokens_from_prompt(create_prompt(chi))

	%EstimatedTokensLabel.text = "%s¢" % [snapped( (provider.token_cost * token_count) *100, 0.01)]


# region Edit provider Title

func show_title_edit_dialog(tab: int):
	%EditTitleDialog.set_meta("tab", tab)
	%LineEdit.text = get_tab_title(tab)
	%LineEdit.call_deferred("grab_focus")
	%EditTitleDialog.popup_centered()


func _on_edit_title_dialog_confirmed():
	var tab = %EditTitleDialog.get_meta("tab")
	set_tab_title(tab, %LineEdit.text)


func _on_line_edit_text_submitted(_new_text: String) -> void:
	_on_edit_title_dialog_confirmed()
	%EditTitleDialog.hide()


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
	%AttachFileDialog.exclusive = false
	for fp in paths:
		SingletonObject.AttachNoteFile.emit(fp)
		await get_tree().process_frame


func _on_btn_chat_settings_pressed():
	%AISettings.popup_centered()


func _on_btn_clear_pressed():
	%txtMainUserInput.text = ""


## When user types in the chat box, estimate tokens count based on selected provider
func _on_txt_main_user_input_text_changed():
	update_token_estimation()

func _on_txt_main_user_input_text_set():
	update_token_estimation()

func _on_btn_microphone_pressed():
	SingletonObject.AtT.FieldForFilling = %txtMainUserInput
	SingletonObject.AtT._StartConverting()
	SingletonObject.AtT.btn = %btnMicrophone
	%btnMicrophone.modulate = Color(Color.LIME_GREEN)
	SingletonObject.AtT.btnStop = %AudioStop1

func _on_child_order_changed():
	# Update ChatList in the SingletonObject
	SingletonObject.ChatList = []  # Clear the existing list
	for child in get_children():
		if child is ScrollContainer:
			var vbox_chat = child.get_child(0)
			if vbox_chat is VBoxChat:
				SingletonObject.ChatList.append(vbox_chat.chat_history)


func _on_system_button_pressed() -> void:
	%SystemPrompt.popup()



func _on_provider_option_button_provider_selected(provider_: BaseProvider):
	if SingletonObject.ChatList.is_empty(): return

	var history = SingletonObject.ChatList[current_tab]

	history.provider = provider_
	if not provider_.is_inside_tree():
		history.VBox.add_child(provider_)

	history.VBox.add_program_message("Changed provider to %s %s" % [provider_.provider_name, provider_.model_name])

# when tab changes, set the provider to one that that chat tab is using
func _on_tab_changed(tab: int):
	var active_provider = SingletonObject.get_active_provider(tab)

	var item_index = _provider_option_button.get_item_index(active_provider)

	_provider_option_button.select(item_index)

	SingletonObject.last_tab_index = tab

## if enter is pressed, accept the event and trigger chat
func _on_txt_main_user_input_gui_input(event: InputEvent):
	if event.is_action_pressed("control_enter"):
		_on_chat_pressed()
		accept_event()


#region Add New HistoryItem

func add_new_system_prompt_item(message: String):
	ensure_chat_open() # we check if their a chat open first
	
	var new_chat_history_item: ChatHistoryItem = ChatHistoryItem.new()# we create the chat item
	new_chat_history_item.Message = message
	new_chat_history_item.Role = ChatHistoryItem.ChatRole.SYSTEM
	
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	
	# we check if there is already a System prompt item in the history and remove it if so
	if history.HistoryItemList.size() > 0:
		if history.HasUsedSystemPrompt: #history.HistoryItemList[0].Role == ChatHistoryItem.ChatRole.SYSTEM:
			history.HistoryItemList.pop_front()
	
	# we add the system prompt to the first place in the chat
	history.HasUsedSystemPrompt = true #we save the state so we can replace the chat item
	history.HistoryItemList.insert(0,new_chat_history_item)


func get_first_chat_item() -> ChatHistoryItem:
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	return history.HistoryItemList.front()

#endregion Add New HistoryItem


func _on_audio_stop_1_pressed() -> void:
	SingletonObject.AtT._StopConverting()
