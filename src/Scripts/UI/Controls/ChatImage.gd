class_name ChatImage
extends PanelContainer


const _scene: PackedScene = preload("res://Scenes/ChatImage.tscn")
@onready var _save_dialog = %SaveFileDialog as FileDialog

@export var image: Image:
	set(value):
		image = value
		%TextureRect.texture = ImageTexture.create_from_image(image)



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
	var editor: = SingletonObject.editor_container.editor_pane.add(Editor.TYPE.Graphics, null, "Chat Image")
	editor.texture_rect.texture = ImageTexture.create_from_image(image)