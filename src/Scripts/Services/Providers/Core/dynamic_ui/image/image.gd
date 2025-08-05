class_name ImageField
extends VBoxContainer

static var _scene: = preload("res://Scripts/Services/Providers/Core/dynamic_ui/image/image.tscn")


@onready var _field_name_label: Label = %FieldName
@onready var _texture_rect: TextureRect = %TextureRect
@onready var _file_dialog: FileDialog = %FileDialog
@onready var _button: Button = %Button



var image_path: String

static func create(field_params: Dictionary, input: = true) -> ImageField:
	
	var scn: ImageField = _scene.instantiate()

	scn.ready.connect(
		func():

			scn._field_name_label.text = field_params["display_name"]
			scn._texture_rect.tooltip_text = field_params["description"]

			if not input:
				scn._file_dialog.visible = false
				scn._button.visible = false
	)

	return scn

func get_user_data():
	if image_path.is_empty():
		return null

	var fa: = FileAccess.open(image_path, FileAccess.READ)
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
	
	var img: = Image.new()
	img.load_png_from_buffer(fa.get_buffer(fa.get_length()))

	var tex: = ImageTexture.create_from_image(img)
	
	_texture_rect.texture = tex

func _on_button_pressed() -> void:
	_file_dialog.show()


func _on_file_dialog_file_selected(path: String) -> void:
	# TODO: add error handling
	image_path = path
	var img: = Image.load_from_file(path)
	var tex: = ImageTexture.create_from_image(img)
	_texture_rect.texture = tex
