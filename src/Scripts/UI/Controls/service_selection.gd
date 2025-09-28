class_name ServiceSelection
extends Window

signal service_selected(service: Service)

@onready var item_list: ItemList = %ItemList
@onready var description_label: Label = %DescriptionLabel
@onready var action_description_button: RichTextLabel = %ActionDescriptionLabel
@onready var action_item_list: ItemList = %ActionItemList
@onready var choose_button: Button = %Button

var selected_service: Service

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

func _on_button_pressed() -> void:

	service_selected.emit(selected_service)

	hide()




func _on_action_item_list_item_selected(index: int) -> void:	
	var action: Action = action_item_list.get_item_metadata(index)
	
	action_description_button.text = action.description
