### Reference Information ###
### Title: ChatImage
class_name ChatImage
extends PanelContainer

@warning_ignore("unused_signal")
signal image_active_state_changed(active: bool)

const _scene: PackedScene = preload("res://Scenes/ChatImage.tscn")
@onready var _save_dialog = %SaveFileDialog as FileDialog
@onready var _mask_button = %MaskButton as Button

@export var image: Image:
	set(value):
		image = value
		
		# Example dimensions to fit the image within, modify these based on your editor window
		var max_width = 1000  # Example max width
		var max_height = 800  # Example max height
		_resize_image_to_fit(max_width, max_height)
		
		%TextureRect.texture = ImageTexture.create_from_image(image)

		# Show the caption of the image as a tooltip
		var tt = image.get_meta("caption", "")
		if tt.length() > 60: tt = tt.left(57) + "..."
		%TextureRect.tooltip_text = tt

		image.set_meta("rendered_node", self)

		# define the signal that's emitted when mask is changed
		if not image.has_user_signal("mask_changed"):
			image.add_user_signal("mask_changed")
			image.connect(
				"mask_changed",
				func():
					_mask_button.visible = image.has_meta("mask")
			)

func _resize_image_to_fit(max_width: int, max_height: int):
	# Get the original size of the image
	var original_size = Vector2(image.get_width(), image.get_height())
	
	# Calculate the scaling factor to fit within the max dimensions
	var scale_factor = min(max_width / original_size.x, max_height / original_size.y)
	
	# Resize only if the image is larger than the max dimensions
	if scale_factor < 1.0:
		var new_size = original_size * scale_factor
		image.resize(new_size.x, new_size.y)
		# Update the texture
		%TextureRect.texture = ImageTexture.create_from_image(image)


static func create(image_: Image) -> ChatImage:
	var node = _scene.instantiate()
	node.image = image_
	node._resize_image_to_fit(1000, 800)  # Use the same dimensions here
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
	#var caption_title: String = image.get_meta("caption", "")
	#if caption_title.length() > 15:
		#caption_title = caption_title.substr(0, 15) + "..."
	SingletonObject.is_masking = true
	SingletonObject.is_picture = true
	var editor: = SingletonObject.editor_container.editor_pane.add(Editor.Type.GRAPHICS, null, "Graphic Note", self)
	editor.graphics_editor.setup_from_image(image)
	



func _on_note_button_pressed():
	var caption_title: String = image.get_meta("caption", "")
	#if caption_title.length() > 25:
		#caption_title = caption_title.substr(0, 25) + "..."
	SingletonObject.NotesTab.add_image_note("Graphic Note", image, image.get_meta("caption", ""))
