class_name MediaGenSocket extends Node

signal  pass_image_to_editor(filename: String, image: PackedByteArray)
# Configuration from the working test
var REST_BRIDGE_LOGIN_URL = "https://www.turnrock.ai:4040/v1/login"
var CORE_WS_URL = "wss://www.turnrock.ai:27500/connect"
var TEST_USERNAME = "test2"
var TEST_PASSWORD = "test"

# Binary frame types
var NEW_MESSAGE = 0
var FILE_INFO = 1
var FILE_DATA = 2
var FILE_END = 3

# Flag to track if the client successfully registered with the core
var registered: = false
# HTTPRequest node for making the initial authentication call
var http_request: HTTPRequest = HTTPRequest.new()
# The WebSocket client instance
var client: CoreClient = CoreClient.new()
# JWT token obtained after successful login
var _jwt_token: String = ""
# Client ID returned after successful login
var _client_id: String = ""

const MEDIA_GEN_DIVISIBLE_BY: int = 64
func _ready() -> void:
	add_child(client)
	add_child(http_request)
	
	client.binary_file_saved.connect(_on_binary_file_saved_received)
	client.image_received.connect(_on_image_response_received)
	http_request.request_completed.connect(on_log_in_http_request_completed)
	
	get_access_token(TEST_USERNAME, TEST_PASSWORD)


func _process(_delta: float) -> void:
	pass


func get_access_token(username: String, password: String) -> bool:
	var headers = PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json" # Good practice to specify accepted response type
	])
	var body = JSON.stringify({
		"username": username,
		"password": password
	})
	
	var err = http_request.request(REST_BRIDGE_LOGIN_URL, headers, HTTPClient.METHOD_POST, body)

	if err != OK:
		var err_msg = "HTTP Auth Request failed immediately: %s" % error_string(err)
		push_error(err_msg)
		# Ensure button is re-enabled in PreferencesPopup if needed (handled there)
		return false

	# Wait for the HTTP request to complete (handled by _on_auth_request_completed)
	var result = await http_request.request_completed
	
	if _jwt_token.is_empty():
		# Error occurred during HTTP request or token extraction (error already displayed)
		prints("Authentication failed or token not received.")
		return false # _on_auth_request_completed handles error display
	
	if _client_id.is_empty():
		prints("Authentication failed or client ID not received.")
		return false # _on_auth_request_completed handles error display
	
	print("Authentication successful. Token received.")

	# --- 3. Connect to Core WebSocket ---
	print("Attempting WebSocket connection to: ", CORE_WS_URL)
	var connected_ws: bool = await client.connect_to_core(CORE_WS_URL)

	if not connected_ws:
		var err_msg = "WebSocket connection failed."
		push_error(err_msg)
		# Reset token maybe? Or let user retry.
		_jwt_token = ""
		_client_id = ""
		return false

	# Wait for the WebSocket connection to be established
	await client.connection_established
	print("WebSocket connection established.")

	# --- 4. Register with Core using the obtained JWT ---
	client.register_with_core(_jwt_token, _client_id) # Use the JWT token for registration
	# Note: We assume registration happens quickly. If it could fail and require feedback,
	# we might need an await signal for registration completion/error from CoreClient.
	# For now, assume connection_established + register_with_core implies success.
	registered = true # Mark as registered (might need better tracking based on CoreClient signals)

	print("Core registration initiated with token.")
	await get_tree().create_timer(0.1).timeout
	print("====================================")
	print(client.get_service_actions("media-gen"))
	return true


func on_log_in_http_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or body.is_empty():
		push_error("http request not successful. error code:" + str(response_code))
		return
	var response_body: = body.get_string_from_utf8()
	var data_dic: Dictionary = {}
	if response_body != null:
		data_dic = JSON.parse_string(response_body)
	else:
		return
	if response_code in range(200, 202):
		_jwt_token = data_dic["data"].get("token")
		var jwt: = JWT.decode(_jwt_token)
		_client_id = jwt.get_claim("sub")
		
		
		client.client_id = _client_id 
		client.TOKEN = _jwt_token
	elif response_code in range(400, 451):
		var error: String = data_dic["error"].get("message")
		
	elif  response_code in range(500, 511):
		var error: String = data_dic["error"].get("message")
	else:
		print("Unknown Error")

func send_media_gen_request(params: Dictionary) -> void:
	if !params.has("positive_prompt") and !params.has("negative_prompt"):
		return
	
	client.send_media_gen_request(params)

func _exit_tree() -> void:
	client.close_connection()


func _on_binary_file_saved_received(file_index: int, filename: String, path: String) -> void:
	#pass_image_to_editor.emit(file_index, filename, path)
	pass


func _on_image_response_received(fname: String, buffer: PackedByteArray) -> void:
	pass_image_to_editor.emit(fname, buffer)


func send_media_edit_request(editing_params: Dictionary, \
							image_buffer: PackedByteArray, \
							image_filename: String = "input_image.png") -> void:
	client.send_media_edit_request(editing_params, image_buffer, image_filename)


# NEW: Method to generate a circular grayscale mask as a PackedByteArray (PNG format)
func generate_circular_mask_bytes(size: int = 1024, circle_radius: int = 200) -> PackedByteArray:
	print("Generating circular mask with Image API...")
	
	var mask_image := Image.create(size, size, false, Image.FORMAT_L8) # Grayscale image
	mask_image.fill(Color.BLACK) # Black background (value 0)
	
	var center_x: int = size / 2
	var center_y: int = size / 2
	
	#mask_image.lock() # Lock for pixel manipulation
	
	for y in range(size):
		for x in range(size):
			var dist_sq: float = float((x - center_x) * (x - center_x) + (y - center_y) * (y - center_y))
			if dist_sq <= float(circle_radius * circle_radius):
				mask_image.set_pixel(x, y, Color.WHITE) # White circle (value 255)
	
	#mask_image.unlock() # Unlock after manipulation
	
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


func send_media_selective_edit_request(params: Dictionary, \
									base_image_buffer: PackedByteArray, \
									base_image_filename: String, \
									mask_image_buffer: PackedByteArray, \
									mask_image_filename: String = "generated_mask.png") -> void:
										
	client.send_media_selective_edit_request(params, base_image_buffer, base_image_filename, mask_image_buffer, mask_image_filename)
