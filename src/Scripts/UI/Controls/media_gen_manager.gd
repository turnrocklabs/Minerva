extends Node
# The WebSocket client instance
var client: CoreClient = null

signal  pass_image_to_editor(filename: String, request_id: String, image: PackedByteArray)
signal lock_media_gen_ui(lock: bool)

func _ready() -> void:
	# Connect Core.client signals to our handlers
	client = Core.client
	#client.binary_file_saved.connect(_on_binary_file_saved_received)
	client.image_received.connect(_on_image_response_received)


func send_media_gen_request(params: Dictionary) -> String:
	if !params.has("positive_prompt") and !params.has("negative_prompt"):
		return ""
	# Extract topic from params, default to original if not provided
	var topic: String = params.get("topic", "media_gen/image_generation")
	params.erase("topic")  # Remove from params so it's not sent in data payload
	lock_media_gen_ui.emit(true)
	return client.send_media_gen_request(params, topic)


func _on_image_response_received(fname: String, request_id: String, buffer: PackedByteArray) -> void:
	lock_media_gen_ui.emit(false)
	pass_image_to_editor.emit(fname, request_id, buffer)


func send_media_edit_request(editing_params: Dictionary, \
							image_buffer: PackedByteArray, \
							image_filename: String = "input_image.png") -> String:
	lock_media_gen_ui.emit(true)
	return client.send_media_edit_request(editing_params, image_buffer, image_filename)


# NEW: Method to generate a circular grayscale mask as a PackedByteArray (PNG format)
func generate_circular_mask_bytes(size: int = 1024, circle_radius: int = 200) -> PackedByteArray:
	var mask_image := Image.create(size, size, false, Image.FORMAT_L8) # Grayscale image
	mask_image.fill(Color.BLACK) # Black background (value 0)
	
	var center_x: int = int(size / 2.0)
	var center_y: int = int(size / 2.0)
	
	for y in range(size):
		for x in range(size):
			var dist_sq: float = float((x - center_x) * (x - center_x) + (y - center_y) * (y - center_y))
			if dist_sq <= float(circle_radius * circle_radius):
				mask_image.set_pixel(x, y, Color.WHITE) # White circle (value 255)
	
	
	# Convert to RGBA8 for consistent PNG saving if needed, although L8 should be fine.
	# The Python client's PIL saves a 'L' mode image directly to PNG.
	# Let's keep it L8, as it's a mask, but convert if PNG saving fails or produces odd results.
	# If output image expects RGBA, it can be converted before use.
	
	var mask_buffer: PackedByteArray = mask_image.save_png_to_buffer()
	
	if mask_buffer.is_empty():
		push_error("Failed to save generated mask to PNG buffer.")
		return PackedByteArray()
	
	print("   📊 Generated mask: %s bytes." % mask_buffer.size())
	return mask_buffer


func generate_mask_bytes(mask_layer_image: Image, _mask_color: Color, channel: String) -> PackedByteArray:

	var mask_image := Image.create(mask_layer_image.get_width(), mask_layer_image.get_height(), false, Image.FORMAT_RGBA8) # RGBA image for color channel support
	mask_image.fill(Color.BLACK)
	var final_mask_color: Color = Color.WHITE
	#match channel:
		#"red":
			#final_mask_color = Color.RED
		#"blue":
			#final_mask_color = Color.BLUE
		#"green":
			#final_mask_color = Color.GREEN
		#_:
			#final_mask_color = Color.WHITE
	for y in range(mask_layer_image.get_height()):
		for x in range(mask_layer_image.get_width()):
			if mask_layer_image.get_pixel(x, y).a != 0:
				mask_image.set_pixel(x, y, final_mask_color)
	
	
	
	var mask_buffer: PackedByteArray = mask_image.save_png_to_buffer()
	
	
	var time: = Time.get_datetime_string_from_system().replace(":", "_")
	var fname: String = "generated_mask_" + time  + ".png"# Explicitly type
	var out_path: String = "user://temp/" + fname
	
	var file = FileAccess.open(out_path, FileAccess.WRITE)
	if file:
		file.store_buffer(mask_buffer)
		file.close()
		print("   ✅ mask saved to temp folder")
	
	if mask_buffer.is_empty():
		push_error("Failed to save generated mask to PNG buffer.")
		return PackedByteArray()
	
	print("   📊 Generated mask: %s bytes." % mask_buffer.size())
	return mask_buffer

func send_media_selective_edit_request(params: Dictionary, images_dir: Array) -> String:
	lock_media_gen_ui.emit(true)
	return client.send_media_selective_edit_request(params, images_dir)
