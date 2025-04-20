class_name ListItemContainer
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/list/item_container/item_container.tscn")

@onready var _items_container: VBoxContainer = %VBoxContainer
@onready var _items_label: Label = %Label
@onready var _remove_button: Button = %RemoveButton

var _parent_list: ListField

static func create(parent_list: ListField) -> ListItemContainer:
	var scn: = _scene.instantiate()

	scn.ready.connect(
		func():
			scn._parent_list = parent_list
			# TODO: update the index when items are deleted
			scn._items_label.text = "%s %s" % [parent_list._label.text, scn.get_index()]

			scn._remove_button.visible = parent_list._is_input
	)

	return scn


func get_user_data():
	var data: Dictionary

	for child in _items_container.get_children():
		if child.has_method("get_user_data"):
			var child_data = child.get_user_data()

			var field_name = child.get_meta("field_name")

			data[field_name] = child_data
	
	return data

func update_data(data: Dictionary) -> void:
	for key in data.keys():
		var field_data = data[key]

		# find control node thats responsible for this field
		for child in _items_container.get_children():

			var field_name = child.get_meta("field_name", "")

			if field_name == key:
				child.update_output(field_data)

func add_field(field_control: Control) -> void:
	_items_container.add_child(field_control)
	# _items_container.move_child(field_control, -1)

func _on_remove_button_pressed() -> void:
	_parent_list.remove_item(self)
