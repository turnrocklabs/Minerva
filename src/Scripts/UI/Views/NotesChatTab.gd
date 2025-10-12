class_name NotesPane
extends TabContainer

@onready var txt_main_user_input: TextEdit = %txtMainUserInput
@onready var _provider_option_button: ProviderOptionButton = %ProviderOptionButton
@onready var buffer_control_notes: Control = %BufferControlChats
@onready var dynamic_ui_container: Container = %DynamicUIContainer

var _active_notes_request: bool = false

func _ready():
	self.get_tab_bar().tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ALWAYS
	self.get_tab_bar().tab_close_pressed.connect(_on_close_tab.bind(self))
	
	if get_tab_count() < 1:
		buffer_control_notes.show()
	
	SingletonObject.Notes = self

## Add new notes session
func _on_new_notes():
	var last_notes_number: int = -1

	# Find last largest number after the Notes string literal
	for i in range(get_tab_count()-1, -1, -1):
		var tab_title: = get_tab_title(i)
		
		if tab_title == "Notes":
			last_notes_number = max(last_notes_number, 0)
		elif tab_title.begins_with("Notes"):
			var suffix = tab_title.right(-"Notes".length()).strip_edges()
			if suffix.is_valid_int():
				last_notes_number = max(last_notes_number, int(suffix))

	var tab_name: = "Notes" if last_notes_number == -1 else "Notes %s" % (last_notes_number+1)

	var provider_obj: BaseProvider

	# If there are no open notes tabs, use provider from the dropdown
	if SingletonObject.NotesList.is_empty():
		provider_obj = _provider_option_button.get_selected_provider()
	else:
		# Use first available provider
		var first_provider: = _provider_option_button.get_item_id(0) as SingletonObject.API_MODEL_PROVIDERS
		provider_obj = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[first_provider].new()

	# Create new notes history
	var history: NotesServiceHistory = NotesServiceHistory.new(provider_obj)
	history.HistoryName = tab_name
	history.HistoryItemList = []
	SingletonObject.NotesList.append(history)
	render_history(history)

	current_tab = get_tab_count()-1
	
	if get_tab_count() > 0:
		buffer_control_notes.hide()

## Opens a notes tab if one isn't open yet
func ensure_notes_open() -> void:
	if SingletonObject.NotesList.is_empty():
		_on_new_notes()

## Create prompt from current notes history
func create_prompt(append_item: ChatHistoryItem = null, provider_fallback: BaseProvider = null) -> Array[Variant]:
	var history_list: Array[Variant] = []
	var provider: BaseProvider = provider_fallback

	if not SingletonObject.NotesList.is_empty():
		var history: NotesServiceHistory = SingletonObject.NotesList[current_tab]
		if not provider:
			provider = history.provider
		history_list = history.to_prompt()
	
	if not provider:
		return []
	
	# Add the new item if provided
	if append_item:
		var item = provider.Format(append_item)
		if item: 
			history_list.append(item)
	
	return history_list

func execute_notes_action():
	ensure_notes_open()

	var history: NotesServiceHistory = SingletonObject.NotesList[current_tab]

	if not history.provider is CoreProvider:
		push_error("'execute_notes_action' called while current provider is not CoreProvider")
		return

	var provider: CoreProvider = history.provider

	var user_history_item: = ChatHistoryItem.new()
	user_history_item.HcpData = Core.dynamic_ui_generator.get_user_input(dynamic_ui_container)
	user_history_item.HcpStructure = provider.action.input_parameters
	user_history_item.Role = ChatHistoryItem.ChatRole.USER
	user_history_item.Type = ChatHistoryItem.PartType.TEXT

	var user_msg_node: = history.VBox.add_history_item(user_history_item)
	
	history.HistoryItemList.append(user_history_item)
	
	var history_list: = create_prompt(user_history_item)

	# Render the message
	user_msg_node.first_time_message = true
	history.VBox.ensure_node_is_visible(user_msg_node)
	user_msg_node.render()

	# Create response placeholder
	var dummy_item = ChatHistoryItem.new()
	dummy_item.Role = ChatHistoryItem.ChatRole.MODEL
	dummy_item.provider = history.provider
	var model_msg_node = history.VBox.add_history_item(dummy_item)
	
	model_msg_node.loading = true 
	_active_notes_request = true

	var hcp_provider: CoreProvider = history.provider
	var bot_response = await hcp_provider.generate_content(history_list)

	var chi = ChatHistoryItem.new()
	if bot_response != null: 
		chi.Id = bot_response.id
		chi.Role = ChatHistoryItem.ChatRole.MODEL
		chi.HcpStructure = provider.action.output_parameters
		chi.HcpData = bot_response.hcp_data
		chi.Error = bot_response.error
		chi.provider = history.provider
		chi.Complete = bot_response.complete
		chi.TokenCost = bot_response.completion_tokens
		if bot_response.image:
			chi.Images = ([bot_response.image] as Array[Image])

		# Update user message node
		user_history_item.TokenCost = bot_response.prompt_tokens
		user_msg_node.render()

		# Update model message node
		model_msg_node.history_item = chi
		history.HistoryItemList.append(chi)

		await get_tree().process_frame
		history.VBox.ensure_node_is_visible(model_msg_node)
		model_msg_node.loading = false
		model_msg_node.first_time_message = true
	else:
		model_msg_node.queue_free()
	
	_active_notes_request = false

func render_history(notes_history: NotesServiceHistory):
	# Create a ScrollContainer and set flags
	var scroll_container = ScrollContainer.new()
	scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Create a VBoxChat for notes and add to the scroll container
	var vboxNotes: VBoxChat = VBoxChat.new(self)
	vboxNotes.chat_history = notes_history
	notes_history.VBox = vboxNotes

	scroll_container.add_child(vboxNotes)

	# Set the scroll container name and add it to the pane
	var _name = notes_history.HistoryName
	add_child(scroll_container)
	var tab_idx = get_tab_idx_from_control(scroll_container)
	set_tab_title(tab_idx, _name)
	
	# Render existing history items
	for item in notes_history.HistoryItemList:
		vboxNotes.add_history_item(item)

func _on_close_tab(tab: int, closed_tab_container: TabContainer):
	var control = closed_tab_container.get_tab_control(tab)
	closed_tab_container.remove_child(control)
	control.queue_free()
	
	# Remove from notes list
	if tab < SingletonObject.NotesList.size():
		SingletonObject.NotesList.remove_at(tab)
	
	if get_tab_count() < 1:
		buffer_control_notes.show()

# When tab changes, update provider dropdown
func _on_tab_changed(tab: int):
	if tab >= 0 and tab < SingletonObject.NotesList.size():
		var active_history = SingletonObject.NotesList[tab]
		
		# Update provider dropdown to match the active tab's provider
		if _provider_option_button and is_instance_valid(active_history.provider):
			var provider = active_history.provider
			var provider_index = _provider_option_button.get_item_index_for_provider(provider)
			if provider_index != -1:
				_provider_option_button.select(provider_index)

func _on_provider_option_button_provider_selected(provider_: BaseProvider):
	if provider_ is CoreProvider:
		var o_params: = (provider_ as CoreProvider).action.input_parameters
		var controls: = Core.dynamic_ui_generator.process_parameters(o_params)
		
		for ch in dynamic_ui_container.get_children():
			ch.queue_free()

		for ctrl in controls:
			dynamic_ui_container.add_child(ctrl)

	if SingletonObject.NotesList.is_empty(): 
		return

	var history = SingletonObject.NotesList[current_tab]
	history.provider = provider_
	
	if not provider_.is_inside_tree():
		history.VBox.add_child(provider_)

	history.VBox.add_program_message("Changed provider to %s %s" % [provider_.provider_name, provider_.display_name])

func clear_all_notes():
	for child in get_children():
		remove_child(child)
		child.queue_free()
	
	SingletonObject.NotesList.clear()

# Show title edit dialog for notes tabs
func show_title_edit_dialog(tab: int):
	# You can implement this similar to ChatPane if needed
	pass

# Get notes for current tab
func get_current_notes_history() -> NotesServiceHistory:
	if current_tab >= 0 and current_tab < SingletonObject.NotesList.size():
		return SingletonObject.NotesList[current_tab]
	return null


func _on_note_action_send_button_pressed() -> void:
	if _active_notes_request: return
	execute_notes_action()
