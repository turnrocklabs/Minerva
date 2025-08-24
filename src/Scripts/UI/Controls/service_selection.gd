class_name ServiceSelection
extends Window

signal service_selected(service: Service, action: Action)

@onready var item_list: ItemList = %ItemList
@onready var description_label: Label = %DescriptionLabel
@onready var action_description_button: RichTextLabel = %ActionDescriptionLabel
@onready var action_item_list: ItemList = %ActionItemList
@onready var choose_button: Button = %Button

var selected_service: Service
var selected_actions: Array[Action]

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
	_on_action_item_list_multi_selected(0, true)

	selected_service = service

func _on_button_pressed() -> void:

	for selected_item_idx in action_item_list.get_selected_items():
		var action: Action = action_item_list.get_item_metadata(selected_item_idx)

		service_selected.emit(selected_service, action)

	hide()




func _on_action_item_list_multi_selected(index:int, _selected:bool) -> void:
	if index == -1:
		choose_button.disabled = true
		return

	choose_button.disabled = false
	
	var action: Action = action_item_list.get_item_metadata(index)
	
	action_description_button.text = action.description

	# if selected:
	# 	selected_actions.append(action)
	# else:
	# 	selected_actions.erase(action)

