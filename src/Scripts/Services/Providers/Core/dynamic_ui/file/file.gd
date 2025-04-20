class_name FileField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/file/file.tscn")


@onready var _field_name_label: Label = %FieldName
@onready var _file_dialog: FileDialog = %FileDialog
@onready var _file_select_button: Button = %FileSelectButton
@onready var _file_label: Label = %FileLabel

var file_path: String:
	set(value):
		file_path = value
		_file_label.text = value

static func create(field_params: Dictionary, input: = true) -> FileField:
	
	var scn: FileField = _scene.instantiate()

	scn.ready.connect(
		func():
			scn._field_name_label.text = field_params["display_name"]

			scn._file_select_button.visible = input
	)

	return scn

func get_user_data():
	if file_path.is_empty():
		return null

	var fa: = FileAccess.open(file_path, FileAccess.READ)
	if not fa:
		var err: = FileAccess.get_open_error()
		push_error(error_string(err))
		# var err_window: = ErrorWindow.create("Could not open file", error_string(err))
		# add_child(err_window)
		# err_window.popup_centered()
		return null

	return fa

func update_output(fa: FileAccess) -> void:
	if not fa:
		print_debug("FileAccess object is null")
		return
	
	_file_label.text = fa.get_path()



func _on_file_select_button_pressed() -> void:
	_file_dialog.show()

func _on_file_dialog_file_selected(path: String) -> void:
	file_path = path
