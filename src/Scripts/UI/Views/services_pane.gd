class_name ServicesPane
extends Control

@onready var services_option_button: OptionButton = %ServicesOptionButton
@onready var actions_option_button: OptionButton = %ActionsOptionButton

@onready var _dynamic_ui_container: Container = %DynamicUIContainer

func _ready() -> void:

	Core.service_selected.connect(_on_service_selected)



func _on_service_selected(service: Service):
	
	if service.name.containsn("chat"):
		print("Services pane: Service %s contains 'chat' literal, skipping..." % service.name)
		return

	for i in services_option_button.item_count:
		var id: = services_option_button.get_item_id(i)
		
		var attached_service: Service = services_option_button.get_item_metadata(id)

		# Service already present
		if service == attached_service:
			return

	var idx: = services_option_button.item_count

	var selected_item: = services_option_button.selected

	services_option_button.add_item(service.name, idx)
	services_option_button.set_item_metadata(idx, service)

	services_option_button.selected = selected_item


func _on_services_option_button_item_selected(index: int) -> void:
	actions_option_button.disabled = index == -1

	if index == -1:
		actions_option_button.clear()
		return
	
	
	var id: = services_option_button.get_item_id(index)

	var service: Service = services_option_button.get_item_metadata(id)

	SingletonObject.notes_sync_manger.set_active_service(service)
	
	SingletonObject.notes_sync_manger.sync_with_remote()

	actions_option_button.clear()

	for i in service.actions.size():
		var action = service.actions[i]
		actions_option_button.add_item(action.name, i)



func _on_actions_option_button_item_selected(index: int) -> void:
	for child in _dynamic_ui_container.get_children():
		child.queue_free()

	if index == -1: return
	
	var id = actions_option_button.get_item_id(index)

	var service: Service = services_option_button.get_item_metadata(services_option_button.get_selected_id())

	var action: = service.actions[id]

	var controls: = Core.dynamic_ui_generator.process_parameters(action.input_parameters, true)

	for control in controls:
		_dynamic_ui_container.add_child(control)




func _on_send_button_pressed() -> void:
	# for now keep recreating the provider here

	var service: Service = services_option_button.get_item_metadata(services_option_button.get_selected_id())

	var action: = service.actions[actions_option_button.get_selected_id()]

	var provider: = CoreProvider.new(service, action)

	prints("Created: ", provider)

	var data = Core.dynamic_ui_generator.get_user_input(_dynamic_ui_container)

	print(data)

	var response: BotResponse = await provider.generate_content([data])

	Core.dynamic_ui_generator.set_output(_dynamic_ui_container, {"notes": []})

	print(response.hcp_data)

	
