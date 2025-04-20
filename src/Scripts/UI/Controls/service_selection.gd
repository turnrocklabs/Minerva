class_name ServiceSelection
extends Window

signal service_selected(service: Service, action: Action)

@onready var item_list: ItemList = %ItemList
@onready var description_label: Label = %DescriptionLabel
@onready var action_description_button: RichTextLabel = %ActionDescriptionLabel
@onready var action_option_button: OptionButton = %ActionOptionButton
@onready var choose_button: Button = %Button

var selected_service: Service
var selected_action: Action

func _ready() -> void:
	close_requested.connect(hide)


func set_services(services: Array[Service]):
	item_list.clear()
	
	for service in services:
		var idx: = item_list.add_item(service.name)
		item_list.set_item_metadata(idx, service)


func _on_item_list_item_selected(index: int) -> void:
	var service: Service = item_list.get_item_metadata(index)
	description_label.text = service.description

	action_option_button.clear()

	for action in service.actions:
		action_option_button.add_item(action.name)
		action_option_button.set_item_metadata(
			action_option_button.item_count-1,
			action
		)
	
	action_option_button.select(0)
	_on_action_option_button_item_selected(0)

	selected_service = service

func _on_button_pressed() -> void:
	service_selected.emit(selected_service, selected_action)
	hide()


func _on_action_option_button_item_selected(index: int) -> void:
	if index == -1:
		choose_button.disabled = true
		return

	choose_button.disabled = false
	
	var action: Action = action_option_button.get_item_metadata(index)
	action_description_button.text = action.description

	selected_action = action
