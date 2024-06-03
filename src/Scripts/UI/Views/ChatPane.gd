class_name ChatPane
extends TabContainer

var Chat: BaseProvider

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
	## Check if there is an active tab first
	if current_tab == -1:
		print("No active tab to send the chat.")
		return
	
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

	
func _on_close_tab(tab: int, container: TabContainer):
	# Remove the tab control
	var control = container.get_tab_control(tab)
	container.remove_child(control)

	# If there are still tabs left, set the correct current_tab index
	if container.get_tab_count() > 0:
		if tab <= current_tab:
			# Adjust the current_tab index if necessary
			if current_tab > 0:
				current_tab -= 1
			else:
				current_tab = 0
	else:
		# If no tabs are left, reset current_tab and do not create a new chat
		current_tab = -1

	# Remove the corresponding ChatHistory entry from ChatList
	if tab < SingletonObject.ChatList.size():
		SingletonObject.ChatList.remove_at(tab)

	# Render the new active tab or do nothing if no tabs are left
	if SingletonObject.ChatList.size() > 0:
		render_history(SingletonObject.ChatList[current_tab])

# Called every frame. 'delta' is the elapsed time since the previous frame.
# func _process(delta):
# 	pass

func _on_btn_memorize_pressed():
	var user_title = %txtMemoryTitle.text
	var user_body = %txtMainUserInput.text
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
Certainly! Here's a revised version of the `MessageMarkdown` class with added comment headers for each function and inline comments to make the code more readable and understandable for novice Godot 4 programmers.
```gdscript
class_name MessageMarkdown
extends HBoxContainer

# Exported variables for UI components and colors
@export var left_control: Control
@export var right_control: Control
@export var label: MarkdownLabel

@export var user_message_color: Color
@export var bot_message_color: Color
@export var error_message_color: Color

# Function to create a MessageMarkdown instance for bot messages
static func bot_message(message: BotResponse) -> MessageMarkdown:
	# Instantiate a new MessageMarkdown scene
	var msg: MessageMarkdown = preload("res://Scenes/MessageMarkdown.tscn").instantiate()
	
	# Set visibility and text for the left control (bot indicator)
	msg.left_control.visible = true
	msg.left_control.get_node("PanelContainer/Label").text = "O4"
	msg.left_control.get_node("PanelContainer").tooltip_text = "gpt-4"
	msg.label.set("theme_override_colors/default_color", Color.BLACK)
	
	# Get the style box for the panel container
	var style: StyleBox = msg.get_node("%PanelContainer").get("theme_override_styles/panel")
	
	# Check if there's an error in the bot message
	if message.Error:
		# Display error message
		msg.label.text = "An error occurred:\n%s" % message.Error
		style.bg_color = msg.error_message_color
	else:
		# Display the bot message
		msg.label.markdown_text = message.FullText
		style.bg_color = msg.bot_message_color

	return msg

# Function to create a MessageMarkdown instance for user messages
static func user_message(message: BotResponse) -> MessageMarkdown:
	# Instantiate a new MessageMarkdown scene
	var msg: MessageMarkdown = preload("res://Scenes/MessageMarkdown.tscn").instantiate()
	
	# Set visibility and text for the right control (user indicator)
	msg.right_control.visible = true
	msg.right_control.get_node("PanelContainer/Label").text = SingletonObject.preferences_popup.get_user_initials()
	msg.right_control.get_node("PanelContainer").tooltip_text = SingletonObject.preferences_popup.get_user_full_name()
	msg.label.markdown_text = message.FullText
	msg.label.set("theme_override_colors/default_color", Color.WHITE)

	# Get the style box for the panel container
	var style: StyleBoxFlat = msg.get_node("%PanelContainer").get("theme_override_styles/panel")
	style.bg_color = msg.user_message_color

	return msg

# Helper class representing a segment of text with optional syntax highlighting
class TextSegment:
	var syntax: String
	var content: String

	# Initialize the TextSegment with content and optional syntax
	func _init(content_: String, syntax_: String = ""):
		content = content_
		syntax = syntax_

	# Convert the TextSegment to a string representation
	func _to_string() -> String:
		if syntax:
			return "%s: %s" % [syntax, content]
		else:
			return content

# Called when the node is added to the scene
func _ready():
	# Compile a regex pattern to match [code]...[/code] blocks
	var regex = RegEx.new()
	regex.compile(r"(\\[code\\])((.|\\n)*?)(\\[\\/code\\])")

	# Get the text from the label
	var text = label.text

	# Find all matches of the regex in the text
	var matches = regex.search_all(text)

	# Array to hold segments of text
	var text_segments: Array[TextSegment] = []

	# Iterate over all matches
	for m in matches:
		var code_text = m.get_string()
		var one_line = code_text.count("\n") == 0

		# Skip single-line code segments
		if one_line:
			continue

		var first_part_len = text.find(code_text)
		var second_part_start = first_part_len + code_text.length()
		var second_part_len = text.length()

		# Create text segments before, during, and after the code block
		var ts1 = TextSegment.new(text.substr(0, first_part_len).strip_edges())
		var ts3 = TextSegment.new(text.substr(second_part_start, second_part_len).strip_edges())

		# Extract syntax from the first line of the markdown text
		var syntax = label.markdown_text.substr(first_part_len, code_text.length()).strip_edges().split("\n")[0]
		syntax = syntax.replace("`", "")

		# Include the [code] and [/code] tags in the content
		var ts2 = TextSegment.new(code_text, syntax)

		# Add the text segments to the array
		text_segments.append(ts1)
		text_segments.append(ts2)
		text_segments.append(ts3)

	# If there are no matches, return early
	if not matches:
		return

	# Clear all children of the label's parent
	for ch in label.get_parent().get_children():
		label.get_parent().remove_child(ch)

	# If there are no text segments, create a new RichTextLabel
	if len(text_segments) == 0:
		var node: Node = RichTextLabel.new()
		node.fit_content = true
		node.bbcode_enabled = true
		node.text = label.markdown_text
		get_node("%PanelContainer/v").add_child(node)
	else:
		# Otherwise, create nodes for each text segment
		for ts in text_segments:
			var node: Node
			if ts.syntax:
				node = CodeMarkdownLabel.create(ts.content, ts.syntax)
			else:
				node = RichTextLabel.new()
				node.fit_content = true
				node.bbcode_enabled = true
				node.text = ts.content

			# Add the node to the panel container
			get_node("%PanelContainer/v").add_child(node)

```

This version contains detailed comments to help novice Godot programmers understand the different sections of the code, as well as the purpose and functionality of each part.
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
