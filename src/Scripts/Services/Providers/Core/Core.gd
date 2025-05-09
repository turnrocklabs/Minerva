extends Node

# Signal emitted when a specific service/action is chosen from the preferences popup
signal service_selected(service: Service, action: Action)

# Preload the client script
@onready var _client_script: = preload("res://Scripts/Services/Providers/Core/core_client.gd")

# Flag to track if the client successfully registered with the core
var registered: = false

# The WebSocket client instance
var client: CoreClient
# HTTPRequest node for making the initial authentication call
var http_request: HTTPRequest = HTTPRequest.new()

# Array to store fetched services (might be populated after connection)
var services: Array[Service]

# JWT token obtained after successful login
var _jwt_token: String = ""


func _ready() -> void:
	# Instantiate and add the CoreClient node
	var cn = Node.new()
	cn.set_script(_client_script)
	add_child(cn)
	client = cn # Assign the client instance

	# Add the HTTPRequest node to the scene tree to make it process
	add_child(http_request)
	# Connect the request_completed signal to handle the HTTP response
	http_request.request_completed.connect(_on_auth_request_completed)


# --- MODIFIED Start Function ---
# Attempts to authenticate via HTTP and then connect to the Core WebSocket.
# Returns true if both authentication and WebSocket connection/registration succeed, false otherwise.
func start(core_ws_url: String, auth_http_base_url: String, username: String, password: String) -> bool:

	# --- 1. Authentication via HTTP ---
	var auth_endpoint = auth_http_base_url.path_join("login") # Construct the full login URL
	var headers = PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/json" # Good practice to specify accepted response type
	])
	var body = JSON.stringify({
		"username": username,
		"password": password
	})

	# Clear previous token
	_jwt_token = ""

	print("Attempting authentication to: ", auth_endpoint)
	var err = http_request.request(auth_endpoint, headers, HTTPClient.METHOD_POST, body)

	if err != OK:
		var err_msg = "HTTP Auth Request failed immediately: %s" % error_string(err)
		push_error(err_msg)
		SingletonObject.ErrorDisplay("Authentication Failed", err_msg)
		# Ensure button is re-enabled in PreferencesPopup if needed (handled there)
		return false

	# Wait for the HTTP request to complete (handled by _on_auth_request_completed)
	var result = await http_request.request_completed

	# --- 2. Check Authentication Result (Set by Signal Handler) ---
	if _jwt_token.is_empty():
		# Error occurred during HTTP request or token extraction (error already displayed)
		prints("Authentication failed or token not received.")
		return false # _on_auth_request_completed handles error display

	print("Authentication successful. Token received.")

	# --- 3. Connect to Core WebSocket ---
	print("Attempting WebSocket connection to: ", core_ws_url)
	var connected_ws: bool = client.connect_to_core(core_ws_url)

	if not connected_ws:
		var err_msg = "WebSocket connection failed."
		push_error(err_msg)
		SingletonObject.ErrorDisplay("Connection Failed", err_msg)
		# Reset token maybe? Or let user retry.
		_jwt_token = ""
		return false

	# Wait for the WebSocket connection to be established
	await client.connection_established
	print("WebSocket connection established.")

	# --- 4. Register with Core using the obtained JWT ---
	client.register_with_core(_jwt_token) # Use the JWT token for registration
	# Note: We assume registration happens quickly. If it could fail and require feedback,
	# we might need an await signal for registration completion/error from CoreClient.
	# For now, assume connection_established + register_with_core implies success.
	registered = true # Mark as registered (might need better tracking based on CoreClient signals)

	print("Core registration initiated with token.")
	return true


# --- NEW: Handles the response from the HTTP authentication request ---
func _on_auth_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray):
	if result != HTTPRequest.RESULT_SUCCESS:
		var err_msg = "HTTP Auth Request Failed: %s" % _get_http_result_string(result)
		push_error(err_msg)
		SingletonObject.ErrorDisplay("Authentication Network Error", err_msg)
		_jwt_token = "" # Ensure token is empty on failure
		return

	var response_body_text = body.get_string_from_utf8()
	print("Auth Response Code: ", response_code)
	#print("Auth Response Body: ", response_body_text) # Debug: careful logging passwords/tokens

	if response_code != 200: # Check for successful HTTP status
		var err_msg = "Authentication Failed: Server returned status %d. Response: %s" % [response_code, response_body_text]
		push_error(err_msg)
		SingletonObject.ErrorDisplay("Authentication Failed", "Server returned status %d. Check credentials or server logs." % response_code)
		_jwt_token = ""
		return

	# Parse the JSON response
	var json = JSON.parse_string(response_body_text)
	if typeof(json) != TYPE_DICTIONARY:
		var err_msg = "Failed to parse authentication response JSON."
		push_error(err_msg)
		SingletonObject.ErrorDisplay("Authentication Error", err_msg)
		_jwt_token = ""
		return

	# --- Extract the token ---
	# Adjust this path based on the *actual* structure of your successful login response!
	# Example assumes: {"params": {"result": {"token": "..."}}} like the old code structure
	# If the swagger definition's 200 response is just e.g. {"token": "..."}, adjust accordingly.
	# Let's assume a simpler structure first based on common practice: {"token": "..."}
	if json.has("token"):
		_jwt_token = json["token"]
		if typeof(_jwt_token) != TYPE_STRING or _jwt_token.is_empty():
			var err_msg = "Authentication response token is invalid or empty."
			push_error(err_msg)
			SingletonObject.ErrorDisplay("Authentication Error", err_msg)
			_jwt_token = ""
	# Fallback to checking the more nested structure if simple 'token' not found
	elif json.has("params") and json["params"].has("result") and json["params"]["result"].has("token"):
		_jwt_token = json["params"]["result"]["token"]
		if typeof(_jwt_token) != TYPE_STRING or _jwt_token.is_empty():
			var err_msg = "Authentication response token (nested) is invalid or empty."
			push_error(err_msg)
			SingletonObject.ErrorDisplay("Authentication Error", err_msg)
			_jwt_token = ""
	else:
		var err_msg = "Authentication response does not contain a 'token'."
		push_error(err_msg, " Received JSON: ", json)
		SingletonObject.ErrorDisplay("Authentication Error", err_msg)
		_jwt_token = ""
		return

	# If we reach here, token *should* be set. The await in 'start' will resume.


# Helper to convert HTTPRequest result enum to string
func _get_http_result_string(result_enum: int) -> String:
	match result_enum:
		HTTPRequest.RESULT_SUCCESS: return "Success"
		HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH: return "Chunked Body Size Mismatch"
		HTTPRequest.RESULT_CONNECTION_ERROR: return "Connection Error"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: return "Body Size Limit Exceeded"
		HTTPRequest.RESULT_CANT_CONNECT: return "Cannot Connect"
		HTTPRequest.RESULT_CANT_RESOLVE: return "Cannot Resolve Host"
		HTTPRequest.RESULT_NO_RESPONSE: return "No Response"
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: return "Redirect Limit Reached"
		HTTPRequest.RESULT_REQUEST_FAILED: return "Request Failed"
		HTTPRequest.RESULT_TIMEOUT: return "Timeout"
		# Added missing Download File results for completeness, although less likely relevant here
		HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN: return "Download File Cannot Open"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR: return "Download File Write Error"
		_: return "Unknown HTTP Request Result (%d)" % result_enum


# Sends a message via the WebSocket client and returns an AwaitMessage object
func send_message(topic: String, msg: Dictionary) -> AwaitMessage:
	if not client._connected:
		push_warning("Attempted to send message while not connected to Core.")
		# Return an AwaitMessage that will likely time out? Or handle differently?
		var awaiter = AwaitMessage.new(client)
		awaiter.timeout = 0.1 # Make it timeout quickly
		return awaiter

	var request_id: String = client.send_message(topic, msg)
	return await_message().with_request_id(request_id)

# Fetches the list of available services from the Core
func fetch_services() -> Array[Service]:
	if not client._connected:
		push_warning("Attempted to fetch services while not connected.")
		return []

	client.request_connections() # Send the request to the core

	# Wait for the response message
	var msg = await await_message().with_cmd("response").with_topic("skills/discovery").receive()

	if not msg:
		push_error("Did not receive response for skills/discovery or timed out.")
		return [] # Timeout or error

	# Check structure and extract services array
	var services_array: Array = []
	if msg.has("params") and msg["params"].has("result") and msg["params"]["result"].has("services"):
		services_array = msg["params"]["result"]["services"]
	else:
		push_error("Received skills/discovery response in unexpected format: ", msg)
		return []

	# Clear existing services and parse new ones
	services.clear()
	for srvc_dta in services_array:
		if srvc_dta.has("params") and typeof(srvc_dta["params"]) == TYPE_DICTIONARY:
			#print("\nParsing Service data:") # Debug
			#print(srvc_dta["params"])      # Debug
			services.append(Service.new(srvc_dta["params"]))
		else:
			push_warning("Skipping service entry with invalid format: ", srvc_dta)

	#print("\n\nParsed Services:") # Debug
	#print(services)               # Debug

	return services


# --- AwaitMessage Class (Helper for handling asynchronous responses) ---
class AwaitMessage extends RefCounted:
	var topic: String
	var cmd: String
	var request_id: String
	var timeout: float = 5.0 # Default timeout in seconds

	var client: CoreClient # Reference to the WebSocket client

	var _received_message = null # Stores the received message if matched
	var _stop: bool = false      # Flag to stop waiting (e.g., on timeout)
	var _timer: SceneTreeTimer = null # Timer node for timeout
	var _signal_connection: Callable # Stores the signal connection for later disconnect

	# Signal emitted for receive_all() functionality
	signal message_received(msg: Dictionary)

	func _init(client_: CoreClient) -> void:
		if not is_instance_valid(client_):
			push_error("AwaitMessage initialized with invalid CoreClient!")
			# How to handle this? Maybe set a flag?
			return
		client = client_

	# Checks if incoming data matches the specified filters (topic, cmd, request_id)
	func _check_message(data: Dictionary) -> bool:
		if not cmd.is_empty():
			var msg_cmd = data.get("cmd")
			if cmd != msg_cmd:
				#prints("Cmd mismatch:", cmd, msg_cmd) # Debug
				return false

		if not topic.is_empty():
			var msg_topic = data.get("topic")
			if topic != msg_topic:
				#prints("Topic mismatch:", topic, msg_topic) # Debug
				return false

		if not request_id.is_empty():
			# Ensure params exists and is a dictionary before checking request_id
			var params = data.get("params", {})
			if typeof(params) == TYPE_DICTIONARY:
				var msg_request_id = params.get("request_id")
				if request_id != msg_request_id:
					#prints("Request ID mismatch:", request_id, msg_request_id) # Debug
					return false
			else: # If params isn't a dictionary, it can't contain the request_id we need
				return false

		# If all checks passed (or weren't applicable)
		return true

	# Internal handler connected to the client's message_received signal
	func _on_client_message(data: Dictionary):
		if _check_message(data):
			_received_message = data
			# For receive(), we found our message, stop the timer and disconnect
			if is_instance_valid(_timer):
				_timer.disconnect("timeout", _on_timeout) # Prevent timeout signal
				_timer = null
			if _signal_connection.is_valid():
				client.message_received.disconnect(_signal_connection)
			_stop = true # Stop the await loop in receive()

	# Internal handler connected to the client's message_received signal for receive_all
	func _on_client_message_for_all(data: Dictionary):
		if _check_message(data):
			message_received.emit(data) # Emit the signal for external listeners

	# Handler for the timeout timer
	func _on_timeout():
		#print("AwaitMessage timed out.") # Debug
		_stop = true
		if _signal_connection.is_valid():
			client.message_received.disconnect(_signal_connection)
		_timer = null # Timer is done

	# Waits for a single message matching the criteria or times out.
	func receive():
		if not is_instance_valid(client):
			push_error("Cannot receive message, CoreClient is invalid.")
			return null

		_received_message = null
		_stop = false

		# Store the callable for disconnecting later
		_signal_connection = Callable(self, "_on_client_message")
		client.message_received.connect(_signal_connection)

		# Setup timeout timer
		_timer = client.get_tree().create_timer(timeout)
		_timer.timeout.connect(_on_timeout)

		# Wait until stopped (by message received or timeout)
		while not _stop:
			await client.get_tree().process_frame # Use process_frame for non-physics waiting

		# Disconnect signal if it wasn't already disconnected by _on_client_message
		if _signal_connection.is_valid() and client.message_received.is_connected(_signal_connection):
			client.message_received.disconnect(_signal_connection)

		# Clean up timer if it still exists (e.g., message arrived before timeout)
		if is_instance_valid(_timer):
			_timer.queue_free()
			_timer = null

		return _received_message # Return the found message or null if timed out

	# Connects to the client's signal and returns a signal that emits *all* matching messages.
	# Note: Does not automatically disconnect. Caller needs to manage the returned signal connection.
	func receive_all() -> Signal:
		if not is_instance_valid(client):
			push_error("Cannot receive_all messages, CoreClient is invalid.")
			# Return a dummy signal? Or handle error? For now, proceed but warn.
			return message_received # Return the internal signal, might never emit

		# Store callable for potential (manual) disconnect later if needed, though typically not for 'receive_all'
		_signal_connection = Callable(self, "_on_client_message_for_all")
		client.message_received.connect(_signal_connection)

		# No timeout for receive_all by default; it just forwards messages.
		# If a timeout mechanism is needed for 'receive_all', it would need custom implementation.
		return message_received


	# --- Builder Methods ---
	func with_timeout(timeout_: float) -> AwaitMessage:
		timeout = timeout_
		return self

	func with_topic(topic_: String) -> AwaitMessage:
		topic = topic_
		return self

	func with_request_id(request_id_: String) -> AwaitMessage:
		request_id = request_id_
		return self

	func with_cmd(cmd_: String) -> AwaitMessage:
		cmd = cmd_
		return self


# Factory function to create a new AwaitMessage instance
func await_message() -> AwaitMessage:
	return AwaitMessage.new(client)
