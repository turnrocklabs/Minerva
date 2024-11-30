class_name ImageNoteControls extends VBoxContainer

@export var note_image: TextureRect
@export var image_caption_line_edit: LineEdit


var memory_item: MemoryItem:
	set(value):
		memory_item = value
		set_note_image(value.MemoryImage)
		image_caption_line_edit.text = value.ImageCaption

var downscaled_image: Image


# TODO maybe we could move this function to Singleton so all images 
# can be resized and add another parameter to place the 200 constant
#  this method resizes the image so the texture rec doesn't render images at full res
func downscale_image(image: Image) -> Image:
	if image == null: return
	var image_size = image.get_size()
	if image_size.y > 200:
		var image_ratio = image_size.y/ 200.0
		image_size.y = image_size.y / image_ratio
		image_size.x = image_size.x / image_ratio
		image.resize(image_size.x, image_size.y, Image.INTERPOLATE_LANCZOS)
	return image


# set the image of the note to the given image
func set_note_image(image: Image) -> void:
	# create a copy of a image so we don't downscale the original
	if image == null: return
	downscaled_image = Image.new()
	downscaled_image.copy_from(image)
	
	downscaled_image = downscale_image(downscaled_image)
	
	var image_texture = ImageTexture.new()
	image_texture.set_image(downscaled_image)
	note_image.texture = image_texture


func _on_image_caption_line_edit_text_submitted(new_text: String) -> void:
	image_caption_line_edit.release_focus()
	if memory_item: memory_item.ImageCaption = new_text


func _on_image_caption_line_edit_text_changed(new_text: String) -> void:
	if memory_item: memory_item.ImageCaption = new_text


func _on_image_v_box_container_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				pass
			MOUSE_BUTTON_RIGHT:
				print("right click")
				paste_image_from_clipboard()


# check if display server can paste image from clipboard and does so
func paste_image_from_clipboard():
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		if OS.get_name() == "Windows":
			if DisplayServer.clipboard_has_image():
				var image = DisplayServer.clipboard_get_image()
				memory_item.MemoryImage = image
				set_note_image(image)
		
		if OS.get_name() == "Linux":
			if DisplayServer.clipboard_has():
				var path: String = DisplayServer.clipboard_get().split("\n")[0]
				var file_format: = path.get_extension()
				if file_format in SingletonObject.supported_image_formats:
					var image: Image = Image.new()
					image.load(path)
					memory_item.MemoryImage = image
					set_note_image(image)
				else:
					print_rich("[b]file format not supported :c[/b]")
			else:
				print("no image to put here")
	else: 
		print("Display Server does not support clipboard feature :c, its a godot thing")
