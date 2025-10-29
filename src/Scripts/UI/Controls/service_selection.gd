class_name ServiceSelection
extends VBoxContainer

signal service_selected(service: Service)
signal service_deselected(service: Service)

@onready var _check_boxes_container: VBoxContainer = %CheckBoxesContainer

@onready var item_list: ItemList = %ItemList
@onready var description_label: Label = %DescriptionLabel
@onready var action_description_button: RichTextLabel = %ActionDescriptionLabel
@onready var action_item_list: ItemList = %ActionItemList
@onready var choose_button: Button = %Button

@onready var _warning_label: Label = %WarningLabel
@onready var _warning_container: Container = %WarningContainer

var selected_service: Service

## Array of selected service ids
# var _selected_service_ids: Array[String]

## Array of service data loaded from the config file
var _loaded_services: Array[Dictionary]

## Dictionary of service ids and its related check box
var _checkboxes: Dictionary[String, CheckBox] = {}

func _ready() -> void:

	Core.client.connection_established.connect(_on_core_connected)

	Core.http_connection_changed.connect(
		func(active: bool):
			if active:
				set_warning("Connecting to the core...")
			elif not Core.connecting and not Core.registered:
				set_warning("Cannot fetch services. Please connect to Core first.")
	)

func _on_core_connected():
	var registration_message = await (
		Core
		.await_message()
		.with_topic("system")
		.with_cmd("registration_confirmed")
		.receive()
	)
	
	if not registration_message: return

	set_services(await Core.fetch_services())

## Returns selected services for the config file
func get_selected_service_data() -> Array[Dictionary]:
	var selected: Array[Dictionary] = []

	for i in _checkboxes.size():
		var service_id: String = _checkboxes.keys()[i]
		var check_box: = _checkboxes[service_id]
		if check_box.button_pressed:
			
			# this is not available if the service is not currently available
			# so we'll take the name from the item list
			var service: Service = check_box.get_meta("service")
			
			var service_name: String

			if service:
				service_name = service.name
			else:
				service_name = item_list.get_item_text(i)

			selected.append({
				"service_id": service_id,
				"name": service_name
			})
	
	return selected

func load_saved_selected_services(services_data: Array) -> void:
	_loaded_services.assign(services_data)

	print("scv: ", _loaded_services)


## Sets the available services, and clear the present warning if [param clear_warning] is true.
func set_services(services: Array[Service], clear_warning_: = true):
	if clear_warning_: clear_warning()
	
	# Store current selection state before making changes
	var current_selections: Dictionary[String, bool] = {}
	for service_id in _checkboxes.keys():
		var checkbox = _checkboxes[service_id]
		if checkbox and not checkbox.is_queued_for_deletion():
			current_selections[service_id] = checkbox.button_pressed
	
	# Build a set of incoming service IDs for quick lookup
	var incoming_service_ids: PackedStringArray = []
	for service in services:
		incoming_service_ids.append(service.client_id)
	
	# Build a set of loaded service IDs
	var loaded_service_ids: PackedStringArray = []
	for srvc_data in _loaded_services:
		var service_id: String = srvc_data.get("service_id", "")
		if service_id:
			loaded_service_ids.append(service_id)
	
	# Remove services that are no longer available (not in services array and not in loaded)
	var service_ids_to_remove: Array[String] = []
	for service_id in _checkboxes.keys():
		if not incoming_service_ids.has(service_id) and not loaded_service_ids.has(service_id):
			service_ids_to_remove.append(service_id)
	
	for service_id in service_ids_to_remove:
		# Find and remove from item_list
		for i in range(item_list.item_count):
			var metadata = item_list.get_item_metadata(i)
			if metadata and metadata is Service and metadata.client_id == service_id:
				item_list.remove_item(i)
				break
		
		# Remove checkbox
		var checkbox = _checkboxes.get(service_id)
		if checkbox and not checkbox.is_queued_for_deletion():
			checkbox.queue_free()
		_checkboxes.erase(service_id)
		
		# Emit deselected signal if it was selected
		if current_selections.get(service_id, false):
			var dummy_service: = Service.new({})
			dummy_service.client_id = service_id
			service_deselected.emit(dummy_service)
	
	# Track which services from loaded_services we've processed
	var processed_loaded_ids: PackedStringArray = []
	
	# Track services that need selection signals emitted
	var services_to_emit: Array[Service] = []
	
	# Add or update services from loaded_services (these go at the top)
	for srvc_data in _loaded_services:
		var service_id: String = srvc_data.get("service_id", "")
		var service_name: String = srvc_data.get("name", "")
		
		if not (service_id or service_name):
			push_error("service_id or service_name empty for a service loaded from config file, skipping...")
			continue
		
		processed_loaded_ids.append(service_id)
		
		# Check if this service already exists
		if _checkboxes.has(service_id):
			# Service exists - preserve its state, but ensure it's marked as loaded
			var checkbox = _checkboxes[service_id]
			# Make sure it stays selected (loaded services should be selected)
			if not checkbox.button_pressed:
				checkbox.button_pressed = true
		else:
			# New loaded service - add it
			var idx: = item_list.add_item(service_name)
			item_list.set_item_disabled(idx, true)
			
			var check_box = CheckBox.new()
			check_box.toggled.connect(_on_service_check_box_toggled)
			check_box.button_pressed = true
			_check_boxes_container.add_child(check_box)
			
			_checkboxes[service_id] = check_box
	
	# Add or update services from the services array
	for service in services:
		var service_id = service.client_id
		
		# Check if this service already exists
		if _checkboxes.has(service_id):
			# Service exists - update its metadata and preserve selection state
			var checkbox = _checkboxes[service_id]
			
			# Check if it was previously selected before we update anything
			var was_previously_selected = current_selections.get(service_id, false)
			
			# Update the checkbox meta if it doesn't have the service object yet
			if not checkbox.has_meta("service"):
				checkbox.set_meta("service", service)
				# Reconnect the signal with the service parameter
				checkbox.toggled.disconnect(_on_service_check_box_toggled)
				checkbox.toggled.connect(_on_service_check_box_toggled.bind(service))
			
			# Find the corresponding item in item_list
			# We need to search by matching against loaded services or by existing metadata
			var item_found = false
			for i in range(item_list.item_count):
				var existing_meta = item_list.get_item_metadata(i)
				
				# Check if this is our service either by metadata OR by being a loaded service
				var is_match = false
				if existing_meta and existing_meta is Service and existing_meta.client_id == service_id:
					is_match = true
				elif not existing_meta and processed_loaded_ids.has(service_id):
					# This is a loaded service (no metadata yet) - match by checking if it's at the expected position
					# We'll match by service name as a fallback
					var item_text = item_list.get_item_text(i)
					if item_text == service.name:
						is_match = true
				
				if is_match:
					item_list.set_item_metadata(i, service)
					item_list.set_item_text(i, service.name)
					item_list.set_item_disabled(i, false)
					item_found = true
					break
			
			# Restore previous selection state
			if current_selections.has(service_id):
				checkbox.button_pressed = current_selections[service_id]
			elif processed_loaded_ids.has(service_id):
				# This was a loaded service, keep it selected
				checkbox.button_pressed = true
			
			# If it's now selected and it's a newly available loaded service, emit the signal
			if checkbox.button_pressed and processed_loaded_ids.has(service_id) and not was_previously_selected:
				services_to_emit.append(service)
		else:
			# New service - add it
			var idx: = item_list.add_item(service.name)
			item_list.set_item_metadata(idx, service)
			
			var check_box = CheckBox.new()
			check_box.set_meta("service", service)
			check_box.toggled.connect(_on_service_check_box_toggled.bind(service))
			
			# Check if this should be selected (was selected before or is a loaded service)
			var should_select = current_selections.get(service_id, false) or processed_loaded_ids.has(service_id)
			check_box.button_pressed = should_select
			
			_check_boxes_container.add_child(check_box)
			_checkboxes[service_id] = check_box
			
			# If this is a newly added service that should be selected, emit the signal
			if should_select:
				services_to_emit.append(service)
	
	# Emit service_selected signals for all services that need it
	# We do this after the loop to ensure all UI is set up first
	for service in services_to_emit:
		service_selected.emit(service)


## Displays a warning label in the services selection container.[br]
## If text is empty the warning is cleared
func set_warning(text: String) -> void:
	if text.is_empty():
		clear_warning()
		return

	_warning_label.text = text
	_warning_container.visible = true


func clear_warning() -> void:
	_warning_container.visible = false
	_warning_label.text = ""

func _on_service_check_box_toggled(on: bool, service: Service = null) -> void:
	if not service: return

	if on:
		service_selected.emit(service)
	else:
		service_deselected.emit(service)

func _on_item_list_item_selected(index: int) -> void:
	var service: Service = item_list.get_item_metadata(index)
	description_label.text = service.description

	action_item_list.clear()

	for action in service.actions:

		action_item_list.add_item(action.name)
		action_item_list.set_item_metadata(
			action_item_list.item_count-1,
			action
		)

	
	action_item_list.select(0)
	_on_action_item_list_item_selected(0)

	selected_service = service

	choose_button.text = "Choose %s" % [selected_service.name]
	choose_button.disabled = false


func _on_action_item_list_item_selected(index: int) -> void:	
	var action: Action = action_item_list.get_item_metadata(index)
	
	action_description_button.text = action.description