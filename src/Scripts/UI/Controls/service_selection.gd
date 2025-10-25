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

var _selected_service_ids: Array[String]

## Dictionary of service ids and its related check box
var _checkboxes: Dictionary[String, CheckBox] = {}

func _ready() -> void:

	Core.client.connection_established.connect(_on_core_connected)

	Core.http_connection_changed.connect(
		func(active: bool):
			if active:
				set_warning("Connecting to the core...")
			elif not Core.connecting and not Core.registered:
				set_warning("Cannot fetch services. Please connect to Core first. HERE HERE")
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


func get_selected_service_ids() -> PackedStringArray:
	var selected: = PackedStringArray()

	for service_id in _checkboxes:
		var check_box: = _checkboxes[service_id]
		if check_box.button_pressed:
			selected.append(service_id)
	
	return selected


## Sets the available services, and clear the present warning if [param clear_warning] is true.
func set_services(services: Array[Service], clear_warning_: = true):
	if clear_warning_: clear_warning()
	
	item_list.clear()
	for child in _check_boxes_container.get_children(): child.queue_free()
	_checkboxes.clear()

	for service in services:
		var idx: = item_list.add_item(service.name)
		item_list.set_item_metadata(idx, service)

		var check_box = CheckBox.new()
		check_box.flat = true
		check_box.toggled.connect(_on_service_check_box_toggled.bind(service))

		_check_boxes_container.add_child(check_box)

		_checkboxes[service.client_id] = check_box

		if _selected_service_ids.has(service.client_id):
			check_box.button_pressed = true



func mark_service_as_selected(service_id: String, state: = true) -> void:
	if _checkboxes.has(service_id):
		_checkboxes[service_id].set_pressed_no_signal(state)
	
	if not state:
		_selected_service_ids.erase(service_id)
		return

	# state is true here, add if missing
	if not _selected_service_ids.has(service_id):
		_selected_service_ids.append(service_id)


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

func _on_service_check_box_toggled(on: bool, service: Service) -> void:
	mark_service_as_selected(service.client_id, on)
	
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
