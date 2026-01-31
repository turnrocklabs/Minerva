extends Node
# The WebSocket client instance
var client: CoreClient = null

signal  pass_image_to_editor(filename: String, request_id: String, image: PackedByteArray)
signal lock_media_gen_ui(lock: bool)
signal media_gen_request_timeout(request_id: String)

const MEDIA_GEN_REQUEST_TIMEOUT_SEC: float = 120.0

var _media_gen_timeout_timer: Timer
var _pending_request_id: String = ""

func _ready() -> void:
	# Connect Core.client signals to our handlers
	client = Core.client
	#client.binary_file_saved.connect(_on_binary_file_saved_received)
	client.image_received.connect(_on_image_response_received)
	_media_gen_timeout_timer = Timer.new()
	_media_gen_timeout_timer.one_shot = true
	_media_gen_timeout_timer.timeout.connect(_on_media_gen_timeout)
	add_child(_media_gen_timeout_timer)


func _start_request_timeout(request_id: String) -> void:
	_pending_request_id = request_id
	_media_gen_timeout_timer.start(MEDIA_GEN_REQUEST_TIMEOUT_SEC)


func _clear_request_timeout() -> void:
	if _media_gen_timeout_timer.time_left > 0:
		_media_gen_timeout_timer.stop()
	_pending_request_id = ""


func _on_media_gen_timeout() -> void:
	var timed_out_id: String = _pending_request_id
	_pending_request_id = ""
	lock_media_gen_ui.emit(false)
	media_gen_request_timeout.emit(timed_out_id)


func send_media_gen_request(params: Dictionary) -> String:
	if !params.has("positive_prompt") and !params.has("negative_prompt"):
		return ""
	# Extract topic from params, default to original if not provided
	var topic: String = params.get("topic", "media_gen/image_generation")
	params.erase("topic")  # Remove from params so it's not sent in data payload
	lock_media_gen_ui.emit(true)
	var request_id: String = client.send_media_gen_request(params, topic)
	if request_id != "":
		_start_request_timeout(request_id)
	return request_id


func _on_image_response_received(fname: String, request_id: String, buffer: PackedByteArray) -> void:
	_clear_request_timeout()
	lock_media_gen_ui.emit(false)
	pass_image_to_editor.emit(fname, request_id, buffer)


func send_media_edit_request(editing_params: Dictionary, \
							image_buffer: PackedByteArray, \
							image_filename: String = "input_image.png") -> String:
	lock_media_gen_ui.emit(true)
	var request_id: String = client.send_media_edit_request(editing_params, image_buffer, image_filename)
	if request_id != "":
		_start_request_timeout(request_id)
	return request_id


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


func generate_mask_bytes(mask_layer_image: Image, _mask_color: Color, _channel: String) -> PackedByteArray:

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
	var request_id: String = client.send_media_selective_edit_request(params, images_dir)
	if request_id != "":
		_start_request_timeout(request_id)
	return request_id


## Send a flex request for the qwen_2511_flex workflow.
## images should be an array of dictionaries with: {buffer: PackedByteArray, role: String, filename: String}
func send_media_flex_request(params: Dictionary, images: Array = []) -> String:
	lock_media_gen_ui.emit(true)
	var request_id: String = client.send_media_flex_request(params, images)
	if request_id != "":
		_start_request_timeout(request_id)
	return request_id


## Send a flex request with 3 images, where the third image is always the pose editor texture.
## Use for qwen_2511_flex 3-image composition (e.g. use_empty_image1=false, use_empty_image2=false, use_empty_image3=false).
## image1 and image2 are optional: pass empty dict {} when use_empty_image1/use_empty_image2 is true.
## When provided, each must be {buffer: PackedByteArray, role: String, filename: String} with role "image1" or "image2".
## pose_image_buffer is sent as image3 with role "image3" and filename "pose_control.png".
## Returns request_id or "" if pose_image_buffer is empty.
func send_media_flex_request_three_with_pose(params: Dictionary, image1: Dictionary, image2: Dictionary, pose_image_buffer: PackedByteArray) -> String:
	if pose_image_buffer.is_empty():
		return ""
	var combined: Array = []
	if image1.get("buffer", PackedByteArray()).size() > 0:
		combined.append({
			"buffer": image1["buffer"],
			"role": image1.get("role", "image1"),
			"filename": image1.get("filename", "image1.png")
		})
	if image2.get("buffer", PackedByteArray()).size() > 0:
		combined.append({
			"buffer": image2["buffer"],
			"role": image2.get("role", "image2"),
			"filename": image2.get("filename", "image2.png")
		})
	combined.append({
		"buffer": pose_image_buffer,
		"role": "image3",
		"filename": "pose_control.png"
	})
	return send_media_flex_request(params, combined)
