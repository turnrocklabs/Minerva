class_name ListField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/list/list.tscn")

# @onready var _field_name_label: Label = %FieldName
# @onready var _field_line_edit: LineEdit = %LineEdit
@onready var _controls_container: VBoxContainer = %VBoxContainer
@onready var _label: Label = %Label
@onready var _button: Button = %Button

var _field_params: Dictionary

var _is_input: = true

static func create(field_params: Dictionary, input: = true) -> ListField:
	
	var scn: ListField = _scene.instantiate()

	print("List")
	print(field_params)

	

	scn.ready.connect(
		func():
			scn._is_input = input

			# Handle both "values" and "items" keys, with fallback to empty dict
			if field_params.has("values"):
				scn._field_params = field_params["values"]
			elif field_params.has("items"):
				scn._field_params = field_params["items"]
			else:
				scn._field_params = {}
				push_warning("ListField: field_params has neither 'values' nor 'items'. Full params: %s" % str(field_params))

			scn._label.text = field_params.get("display_name", "List")

			scn._button.visible = input

			# scn._field_name_label.text = field_params["display_name"]
			# scn._field_line_edit.placeholder_text = field_params["display_name"]
			# scn._field_line_edit.tooltip_text = field_params["description"]
	)

	return scn


func get_user_data():
	var data: Array

	for child in _controls_container.get_children():
		if child.has_method("get_user_data"):
			data.append(child.get_user_data())

	return data

func clear_data() -> void:
	update_output([])

func update_output(data: Array) -> void:
	
	# first make sure we have enough items to match the output data size

	# remove previous items
	for child in _controls_container.get_children():
		child.queue_free()

	# create enough items to match the data size
	for i in range(data.size()):
		_create_new_list_item()

	var i: = 0

	for list_item_container in _controls_container.get_children():
		if list_item_container is ListItemContainer and not list_item_container.is_queued_for_deletion():
			list_item_container.update_data(data[i])
			i += 1

func _create_new_list_item():
	var controls: = Core.dynamic_ui_generator.process_parameters(_field_params, _is_input)

	var list_item_container: = ListItemContainer.create(self)

	_controls_container.add_child(list_item_container)

	for ctrl in controls:
		list_item_container.add_field(ctrl)
	

func _on_button_pressed() -> void:
	_create_new_list_item()


func remove_item(ctrl: Control) -> void:

	_controls_container.remove_child(ctrl)
