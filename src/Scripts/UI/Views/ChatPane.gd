extends TabContainer


var ChatList: Array[ChatHistory]
var last_tab_index: int
var active_chatindex: int
var Provider
var GoogleChat: GoogleVertex

func _on_new_chat():
	active_chatindex = last_tab_index
	var tab_name:String = "Chat" + str(last_tab_index)
	last_tab_index += 1
	var history: ChatHistory = ChatHistory.new(self.GoogleChat)
	history.HistoryName = tab_name
	history.HistoryItemList = []
	self.ChatList.append(history)
	render_history(history)
	pass

## Function:
# create_prompt generates the full turn prompt
func create_prompt(append_item:ChatHistoryItem = null, disable_notes: bool = false) -> Array[Variant]:
	# make sure we have an active chat
	if len(self.ChatList) <= active_chatindex:
		_on_new_chat()

	## Get the working memory and append the user message to chat history
	var prompt_for_turn: String = ""
	var working_memory:String = SingletonObject.NotesTab.To_Prompt(GoogleChat)
	
	# disable the notes if we are asked
	if disable_notes:
		SingletonObject.NotesTab.Disable_All()

	## get the message for completion, appending a new items if given
	var history: ChatHistory = self.ChatList[active_chatindex]
	if append_item != null:
		if len(working_memory) > 0:
			append_item.Message = working_memory + "\n" + append_item.Message
		 
		history.HistoryItemList.append(append_item)
		self.ChatList[active_chatindex] = history
	
	var history_list: Array[Variant] = history.To_Prompt();
	return history_list

func _on_btn_inspect_pressed():
	## generate the JSON string we would send to the model.
	var history_list: Array[Variant] = self.create_prompt()
	
	## append the message to the history
	var new_history_item: ChatHistoryItem = ChatHistoryItem.new()
	new_history_item.Message = %txtMainUserInput.text
	new_history_item.Role = ChatHistoryItem.ChatRole.USER
	var formatted = Provider.Format(new_history_item)
	history_list.append(formatted)

	var stringified_history:String = JSON.stringify(history_list)
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
	GoogleChat.generate_content(history_list)
	self.ChatList[active_chatindex].VBox.add_user_message(temp_user_data)
	pass

## Render a full chat history response
func render_single_chat(response:BotResponse):
	# create a chat history item and append it to the list
	var item: ChatHistoryItem = ChatHistoryItem.new()
	item.Role = ChatHistoryItem.ChatRole.ASSISTANT
	item.Message = response.FullText
	self.ChatList[active_chatindex].HistoryItemList.append(item)

	# Ask the Vbox to add the message
	self.ChatList[active_chatindex].VBox.add_bot_message(response)
	pass


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
	scroll_container.name = _name
	%tcChats.add_child(scroll_container)
	pass

# Called when the node enters the scene tree for the first time.
func _ready():
	last_tab_index = 0
	active_chatindex = 0
	ChatList = []
	GoogleChat = GoogleVertex.new()
	Provider = GoogleChat ## We can change this to other providers later.
	add_child(GoogleChat)
	GoogleChat.chat_completed.connect(self.render_single_chat)
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
# func _process(delta):
# 	pass

func _on_btn_memorize_pressed():
	var user_title = %txtMemoryTitle.text
	var user_body = %txtMainUserInput.text
	SingletonObject.NotesTab.add_note(user_title, user_body)
	pass # Replace with function body.

## Feature development -- create a button and add it to the upper chat vbox?
func _on_btn_test_pressed():
	if len(self.ChatList) <= active_chatindex:
		_on_new_chat()

	# Pretend we did a chat like "Write hello world in python" and got a BotResponse that made sense.
	var test_response:BotResponse = BotResponse.new()
	#test_response.FullText = "Here is how you write hello world in python:\n```python\nprint (\"Hello World\")\n```"
	test_response.FullText = "## Markdown\n Here is how you write hello world in python:\n```python\nprint (\"Hello World\")\n```"
	self.render_single_chat(test_response)
	pass # Replace with function body.
