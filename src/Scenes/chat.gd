class_name Chat
extends Control

@onready var _autocoder_manager: Control = %AutocoderManager
@onready var _v_split_container: Control = %VSplitContainer

@onready var history_option_button: OptionButton = %HistoryOptionButton
@onready var provider_option_button: ProviderOptionButton = %ProviderOptionButton

@onready var tc_chats: Control = %tcChats
@onready var chat_controls: Control = %ChatControls

@onready var tc_notes: Control = %tcNotes
@onready var note_controls: Control = %NoteControls

@onready var clone_chat_btn: Button = %CloneChatButton
@onready var new_chat_button: Button = %btnNewChat

# core UI fields
@onready var dynamic_ui_container: Container = %DynamicUIContainer

# chat UI fields
@onready var txt_main_user_input: TextEdit = %txtMainUserInput

# Track current service type and history collections
var current_service_type: ServiceHistory.ServiceType = ServiceHistory.ServiceType.NONE
var current_histories: Array = []

var service_tab_states: Dictionary = {}  # ServiceType -> {current_tab: int, etc.}

# NEW: Track services grouped by history type
var services_by_type: Dictionary[ServiceHistory.ServiceType, Array] = {}  # ServiceType -> Array[Service]

func _ready() -> void:
	SingletonObject.chat = self
	
	# Initialize the services dictionary
	_initialize_services_by_type()
	
	_setup_chats_service()

	# TODO: testing hardcode
	_setup_coco_service()

	Core.client.connection_established.connect(_on_core_connected)

	Core.service_selected.connect(_on_hcp_service_selected)
	Core.service_deselected.connect(_on_hcp_service_deselected)

	# Right now, if core is disconnected the model response should indicate that
	# In the future we may want to completely remove the item from the dropdown
	# Core.client.connection_closed.connect(_on_core_disconnected)
	# Core.client.message_received.connect(_on_core_message_received)


func _on_core_connected():
	var registration_message = await (
		Core
		.await_message()
		.with_topic("system")
		.with_cmd("registration_confirmed")
		.receive()
	)

	if not registration_message:
		push_error("No registration message received")
		return
	
	# let the services in preferences pane trigger service selection
	# var services: = await Core.fetch_services()
	# for service in services:
	# 	_on_hcp_service_selected(service)

func _initialize_services_by_type():
	services_by_type[ServiceHistory.ServiceType.CHAT] = []
	services_by_type[ServiceHistory.ServiceType.NOTES] = []
	services_by_type[ServiceHistory.ServiceType.COCO] = []

# sets up the internal chat service, and auto selects it
func _setup_chats_service():
	var chat_service: = Service.create_chat_service()
	
	# Add the internal chat service to our tracking
	services_by_type[ServiceHistory.ServiceType.CHAT].append(chat_service)
	
	# Only create dropdown item if it doesn't exist for this service type
	if not _history_type_exists_in_dropdown(ServiceHistory.ServiceType.CHAT):
		var item_id: = history_option_button.item_count
		history_option_button.add_item("Chats", item_id)
		# Store the service type as metadata instead of individual service
		history_option_button.set_item_metadata(history_option_button.get_item_index(item_id), ServiceHistory.ServiceType.CHAT)
		
		history_option_button.select(history_option_button.get_item_index(item_id))
		# trigger the select callback	
		_on_history_option_button_item_selected(history_option_button.get_item_index(item_id))

## TODO: This is showing up for testing only
func _setup_coco_service():
	var coco_service: = Service.new({})
	
	# Add the internal chat service to our tracking
	services_by_type[ServiceHistory.ServiceType.COCO].append(coco_service)
	
	# Only create dropdown item if it doesn't exist for this service type
	if not _history_type_exists_in_dropdown(ServiceHistory.ServiceType.COCO):
		var item_id: = history_option_button.item_count
		history_option_button.add_item("Co-COder", item_id)
		# Store the service type as metadata instead of individual service
		history_option_button.set_item_metadata(history_option_button.get_item_index(item_id), ServiceHistory.ServiceType.COCO)
		
		history_option_button.select(history_option_button.get_item_index(item_id))
		# trigger the select callback	
		_on_history_option_button_item_selected(history_option_button.get_item_index(item_id))


# Updated _on_hcp_service_deselected method for Chat class
# Replace the existing method with this:

func _on_hcp_service_deselected(service: Service) -> void:
	var service_type = Core.get_service_history_type(service)
	if service_type == ServiceHistory.ServiceType.NONE:
		return
	
	if service_type in services_by_type:
		var services_array = services_by_type[service_type]
		for i in range(services_array.size() - 1, -1, -1):
			if services_array[i].is_equal_to(service):
				services_array.remove_at(i)
		
		# If no services left for this type, remove dropdown item
		if services_by_type[service_type].is_empty():
			_remove_history_type_from_dropdown(service_type)
	
	# Clear cached provider sets for this service
	provider_option_button.clear_service_provider_set(service)
	provider_option_button.clear_combined_provider_sets()
	
	# If this was the current service type, rebuild providers
	if service_type == current_service_type:
		_update_provider_options_for_current_type()
		
		# Check if current provider is still available
		var current_provider = provider_option_button.get_selected_provider()
		if not _is_provider_available(current_provider):
			_select_first_available_provider()


# Also update _is_provider_available to properly check:
func _is_provider_available(provider: BaseProvider) -> bool:
	if not provider:
		return false
	
	# Standard providers (OpenAI, Claude, etc.) are always available
	if not provider is CoreProvider:
		return true
	
	# CoreProviders need their service to still be active
	var core_provider := provider as CoreProvider
	var services = services_by_type.get(current_service_type, [])
	
	for service in services:
		if service == core_provider.service:
			return true
	
	return false


func _remove_history_type_from_dropdown(service_type: ServiceHistory.ServiceType):
	for i in range(history_option_button.get_item_count()):
		if history_option_button.get_item_metadata(i) == service_type:
			history_option_button.remove_item(i)
			return

func _select_first_available_provider():
	if provider_option_button.item_count > 0:
		provider_option_button.select(0)
		provider_option_button.item_selected.emit(0)

func _on_hcp_service_selected(service: Service) -> void:
	var service_type = Core.get_service_history_type(service)

	if service_type == ServiceHistory.ServiceType.NONE:
		return
	
	# Add service to the appropriate type group
	if service_type in services_by_type:
		services_by_type[service_type].append(service)
	else:
		services_by_type[service_type] = [service]
	
	# Only add dropdown item if this service type doesn't already exist
	if not _history_type_exists_in_dropdown(service_type):
		var item_id: = history_option_button.item_count
		var display_name = _get_service_type_display_name(service_type)
		history_option_button.add_item(display_name, item_id)
		history_option_button.set_item_metadata(history_option_button.get_item_index(item_id), service_type)
	
	# If this service type is currently selected, update the provider options
	if service_type == current_service_type:
		_update_provider_options_for_current_type()

func _history_type_exists_in_dropdown(service_type: ServiceHistory.ServiceType) -> bool:
	for i in range(history_option_button.get_item_count()):
		var metadata = history_option_button.get_item_metadata(i)
		if metadata == service_type:
			return true
	return false

func _get_service_type_display_name(service_type: ServiceHistory.ServiceType) -> String:
	match service_type:
		ServiceHistory.ServiceType.CHAT:
			return "Chats"
		ServiceHistory.ServiceType.COCO:
			return "CO-COder"
		ServiceHistory.ServiceType.NOTES:
			return "Notes"
		_:
			return "Unknown"

func _on_history_option_button_item_selected(index: int) -> void:
	var item_id: = history_option_button.get_item_id(index)
	var service_type: ServiceHistory.ServiceType = history_option_button.get_item_metadata(item_id)
	
	# Switch to the appropriate history collection and UI
	_switch_to_service_type(service_type)

func _switch_to_service_type(service_type: ServiceHistory.ServiceType):
	print("Switching to service type: ", service_type)
	print("ChatList count before switch: ", SingletonObject.ChatList.size())
	
	if current_service_type != service_type:
		current_service_type = service_type
		_load_histories_for_service_type(service_type)
		_update_ui_for_service_type(service_type)
		_update_provider_options_for_current_type()



func _update_provider_options_for_current_type():
	# Get all services for the current service type and update provider options
	var services_for_type: Array = services_by_type.get(current_service_type, [])
	provider_option_button.switch_to_provider_set_for_services(services_for_type)



func _load_histories_for_service_type(service_type: ServiceHistory.ServiceType):
	print("BEFORE load - ChatList count: ", SingletonObject.ChatList.size())
	
	match service_type:
		ServiceHistory.ServiceType.CHAT:
			print("Loading CHAT histories")
			current_histories = SingletonObject.ChatList
		ServiceHistory.ServiceType.NOTES:
			print("Loading NOTES histories") 
			current_histories = SingletonObject.NotesList
		_:
			current_histories = []
	
	print("AFTER assignment - ChatList count: ", SingletonObject.ChatList.size())
	print("Current histories count: ", current_histories.size())

func _update_ui_for_service_type(service_type: ServiceHistory.ServiceType):
	match service_type:
		ServiceHistory.ServiceType.CHAT:
			_show_chat_ui()
		ServiceHistory.ServiceType.NOTES:
			_show_notes_ui()
		ServiceHistory.ServiceType.COCO:
			_show_coco_ui()
		_:
			_show_default_ui()

func _hide_tabs() -> void:
	tc_chats.visible = false
	tc_notes.visible = false

	chat_controls.visible = false
	note_controls.visible = false

	_autocoder_manager.visible = false # autocoder container
	_v_split_container.visible = false # container with chat controls

func _show_coco_ui():
	_hide_tabs()
	_v_split_container.visible = false

	_autocoder_manager.visible = true

	clone_chat_btn.visible = false
	new_chat_button.visible = false

func _show_chat_ui():
	_hide_tabs()
	_v_split_container.visible = true
	tc_chats.visible = true
	chat_controls.visible = true
	
	dynamic_ui_container.visible = false
	txt_main_user_input.visible = true
	clone_chat_btn.visible = true
	new_chat_button.visible = true

func _show_notes_ui():
	_hide_tabs()
	_v_split_container.visible = true
	tc_notes.visible = true
	note_controls.visible = true

	dynamic_ui_container.visible = true
	txt_main_user_input.visible = false
	clone_chat_btn.visible = false
	new_chat_button.visible = false

func _show_default_ui():
	# Fallback to chat UI
	_show_chat_ui()

func _on_tc_chats_tab_changed(tab: int) -> void:
	# Handle tab switching within the current service type
	if tab >= 0 and tab < current_histories.size():
		var active_history = current_histories[tab]
		
		# Update provider dropdown to match the active tab's provider
		if provider_option_button:
			var provider = active_history.provider
			if is_instance_valid(provider):
				var provider_index = provider_option_button.get_item_index_for_provider(provider)
				if provider_index != -1:
					provider_option_button.select(provider_index)

func get_current_histories() -> Array[ServiceHistory]:
	return current_histories

func get_current_service_type() -> ServiceHistory.ServiceType:
	return current_service_type

# NEW: Get all services for the current service type
func get_services_for_current_type() -> Array[Service]:
	return services_by_type.get(current_service_type, [])

func create_new_history_for_current_service() -> ServiceHistory:
	var provider = provider_option_button.get_selected_provider()
	var new_history: ServiceHistory
	
	match current_service_type:
		ServiceHistory.ServiceType.CHAT:
			new_history = ChatHistory.new(provider)
			SingletonObject.ChatList.append(new_history)
		ServiceHistory.ServiceType.NOTES:
			new_history = NotesServiceHistory.new(provider)
			SingletonObject.NotesList.append(new_history)
		_:
			# Fallback to ChatHistory
			new_history = ChatHistory.new(provider)
			SingletonObject.ChatList.append(new_history)
	
	current_histories.append(new_history)
	return new_history

func continue_response(history_item: ChatHistoryItem) -> ChatHistoryItem:
	if get_current_service_type() == ServiceHistory.ServiceType.CHAT:
		return await SingletonObject.Chats.continue_response(history_item)
	
	return null
