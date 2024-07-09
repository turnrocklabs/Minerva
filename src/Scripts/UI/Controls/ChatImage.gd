class_name ChatImage
extends PanelContainer

signal image_active_state_changed(active: bool)

const _scene: PackedScene = preload("res://Scenes/ChatImage.tscn")
@onready var _save_dialog = %SaveFileDialog as FileDialog

@export var image: Image:
	set(value):
		image = value
		%TextureRect.texture = ImageTexture.create_from_image(image)

		# Show the caption of the image as a tooltip
		var tt = image.get_meta("caption", "")
		if tt.length() > 60: tt = tt.left(57) + "..."

		%TextureRect.tooltip_text = tt


## Proxy for this nodes `CheckButton.button_pressed` property.
## Setting this property will result in use of `BaseButton.set_pressed_no_signal`.
var active: = false:
	set(value):
		active = value
		(%CheckButton as CheckButton).set_pressed_no_signal(value)
	get: return %CheckButton.button_pressed



static func create(image_: Image) -> ChatImage:
	var node = _scene.instantiate()

	node.image = image_

	return node


func _on_save_button_pressed():
	_save_dialog.popup_centered()

func _on_save_file_dialog_file_selected(path: String):
	var err = image.save_png(path)

	if err != OK:
		push_error("Couldn't save image at %s. %s" % [path, error_string(err)])
		SingletonObject.ErrorDisplay(
			"Couldn't save",
			error_string(err)
		)

func _on_edit_button_pressed():
	var editor: = SingletonObject.editor_container.editor_pane.add(Editor.TYPE.WhiteBoard, null, "Chat Image")
	editor.whiteB.get_node("%EditPic").texture = ImageTexture.create_from_image(image)

func _on_check_button_toggled(toggled_on: bool):
	image.set_meta("active", toggled_on)

	image_active_state_changed.emit(toggled_on)


func _on_note_button_pressed():
	SingletonObject.NotesTab.add_image_note("Image note", image, image.get_meta("caption", ""))
