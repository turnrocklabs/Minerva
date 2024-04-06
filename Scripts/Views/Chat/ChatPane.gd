extends TabContainer

@onready var chat = preload("res://Scripts/Views/Chat/Chat.tscn")

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

func _on_chat_pressed():
	# make sure we have an active chat
	if len(self.ChatList) <= active_chatindex:
		_on_new_chat()
	
	## Get the working memory and append the user message to chat history
	var new_history_item: ChatHistoryItem = ChatHistoryItem.new()
	var prompt_for_turn: String = ""
	var working_memory:String = %tcThreads.To_Prompt(GoogleChat)
	if len(working_memory) > 0:
		%tcThreads.Disable_All()
		prompt_for_turn += working_memory
		prompt_for_turn += %txtMainUserInput.text
	else:
		prompt_for_turn = %txtMainUserInput.text

	var r = BotResponse.new()
	r.FullText = %txtMainUserInput.text
	self.ChatList[active_chatindex].VBox.add_user_message(r)

	r = BotResponse.new()
	r.FullText = %txtMainUserInput.text
	self.ChatList[active_chatindex].VBox.add_bot_message(r)

	## append the message to the history
	new_history_item.Message = prompt_for_turn
	self.ChatList[active_chatindex].HistoryItemList.append(new_history_item)

	## get the message for complettion
	var history: ChatHistory = self.ChatList[active_chatindex]
	var history_list: Array[Variant] = history.To_Prompt();

	# make a chat request
	# GoogleChat.generate_content(history_list)
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
	# scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# create a derived VBoxContainer for chats and add to the scroll container
	var vboxChat: VBoxChat = chat.instantiate()
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
	add_child(GoogleChat)
	GoogleChat.chat_completed.connect(self.render_single_chat)
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
# func _process(delta):
# 	pass
