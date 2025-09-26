class_name CoreClient extends Node

signal message_received(data)
signal connection_established
signal connection_closed
signal connection_error(error)
signal service_registered(service_name, input_requirements, output_requirements, service_topics)
signal response_received(data)
@warning_ignore("unused_signal")
signal log_in_response_arrived
signal registered_with_core
signal auth_failed

enum EntityType {
	HUMAN_AGENT,
	SOFTWARE_AGENT,
	SERVICE,
	CLIENT
}

# Configuration from the working test
var REST_BRIDGE_LOGIN_URL = "https://www.turnrock.ai:4040/v1/login"
var CORE_WS_URL = "wss://www.turnrock.ai:27500/connect"
var TEST_USERNAME = "test2"
var TEST_PASSWORD = "test"
var TOKEN: = ""

const TOPIC_SYSTEM = "system"
const TOPIC_DISCOVERY = "service:core-discovery"
const HEARTBEAT_INTERVAL = 20  # seconds
const REGISTER_REQUEST_TIMEOOUT:  = 10 # seconds

var _client: = WebSocketPeer.new()
var _entity_type: = EntityType.SOFTWARE_AGENT
var client_id: = ""
var minerva_secret: String = "cats"
var _connected = false
var _heartbeat_timer: Timer
var register_timer: Timer
var discovery_response_data: Dictionary = {}
var core_services_ids: Dictionary = {}
var tarqet_service_id: String = ""
var _auth_retry_attempted: bool = false
var _message_queue: Array = []
var _is_reconnecting: bool = false

func _ready():
	# Increase the maximum string length for JSON parsing
	ProjectSettings.set_setting("network/limits/websocket/max_in_buffer_kb", 16384)  # 16 MB
	ProjectSettings.set_setting("network/limits/websocket/max_out_buffer_kb", 16384)
	
	client_id = UUID.v7()
	_heartbeat_timer = Timer.new()
	_heartbeat_timer.one_shot = false
	_heartbeat_timer.wait_time = HEARTBEAT_INTERVAL
	_heartbeat_timer.timeout.connect(send_heartbeat)
	register_timer = Timer.new()
	register_timer.wait_time = REGISTER_REQUEST_TIMEOOUT
	register_timer.timeout.connect(_on_registration_failed)
	#connection_established.connect(register_with_core)
	registered_with_core.connect(send_discovery_request)
	connection_closed.connect(_on_connection_closed)
	add_child(_heartbeat_timer)
	add_child(register_timer)
	set_process(false)

func set_entity_type(type):
	_entity_type = type

func connect_to_core(CORE_WS_URL: String):
	# Always check the actual WebSocket state first
	var current_state = _client.get_ready_state()
	
	# If we have an existing connection, close it properly
	if current_state != WebSocketPeer.STATE_CLOSED:
		print("Closing existing connection before reconnecting...")
		close_connection("Reconnecting")
		# Wait a frame for the connection to close
		await get_tree().process_frame
	
	# Reset connection state
	_connected = false
	_auth_retry_attempted = false
	
	# Create a new WebSocket peer to ensure clean state
	_client = WebSocketPeer.new()
	
	# Configure buffers BEFORE connecting
	_client.encode_buffer_max_size = 268435456
	_client.inbound_buffer_size = 268435456
	_client.max_queued_packets = 10000
	_client.outbound_buffer_size = 268435456
	
	var err = _client.connect_to_url(CORE_WS_URL)
	if err != OK:
		connection_error.emit(err)
		return false
	print(err)
	set_process(true)
	return true

func close_connection(reason: String = "") -> void:
	_auth_retry_attempted = false
	_connected = false
	if _heartbeat_timer:
		_heartbeat_timer.stop()
	
	# Only close if the connection is actually open
	var state = _client.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN or state == WebSocketPeer.STATE_CONNECTING:
		_client.close(1000, reason)
		# Wait for the connection to close properly
		while _client.get_ready_state() != WebSocketPeer.STATE_CLOSED:
			_client.poll()
			

func logout():
	print("Logging out...")
	# Clear any queued messages
	_message_queue.clear()
	# Clear service data
	core_services_ids.clear()
	discovery_response_data.clear()
	# Close connection
	close_connection("User logout")
	# Ensure we stop processing
	set_process(false)

var _incomplete_message_buffer: PackedByteArray = []
var _message_buffer: String = ""


func _process(_delta):
	_client.poll()
	var state = _client.get_ready_state()
	
	match state:
		WebSocketPeer.STATE_CONNECTING:
			pass
			
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				connection_established.emit()
				_heartbeat_timer.start()
			while _client.get_available_packet_count():
				var packet = _client.get_packet()
				var packet_string = packet.get_string_from_utf8()
				
				# Check if this is a complete JSON message
				if is_complete_json(packet_string):
					var data = parse_json_packet(packet_string)
					if data != null:
						_handle_message(data)
				else:
					# Handle fragmented messages
					_message_buffer += packet_string
					if is_complete_json(_message_buffer):
						var data = parse_json_packet(_message_buffer)
						if data != null:
							_handle_message(data)
						_message_buffer = ""
			
		WebSocketPeer.STATE_CLOSING:
			# Keep polling to achieve proper close
			pass
			
		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				_heartbeat_timer.stop()
				connection_closed.emit()
				# If we have queued messages and weren't intentionally closing, reconnect
				if _message_queue.size() > 0 and not _is_reconnecting:
					_is_reconnecting = true
					print("Have queued messages, attempting reconnection...")
					connect_to_core(CORE_WS_URL)
			
			# Only stop processing if we're not trying to reconnect
			if not _is_reconnecting:
				set_process(false)


func is_complete_json(text: String) -> bool:
	# Simple check for JSON completeness
	var brace_count = 0
	var in_string = false
	var escape_next = false
	
	for c in text:
		if escape_next:
			escape_next = false
			continue
		
		if c == "\\":
			escape_next = true
			continue
			
		if c == "\"" and not escape_next:
			in_string = not in_string
			continue
		
		if not in_string:
			if c == "{":
				brace_count += 1
			elif c == "}":
				brace_count -= 1
	
	return brace_count == 0 and not in_string

func handle_incoming_packet():
	var packet = _client.get_packet()
	var packet_bytes = packet.size()
	print("📦 Received packet of size: ", packet_bytes, " bytes")
	
	# Add to buffer
	_incomplete_message_buffer.append_array(packet)
	
	# Try to parse complete messages from buffer
	var message_string = _incomplete_message_buffer.get_string_from_utf8()
	
	# Check if we have a complete JSON message
	var json = JSON.new()
	var parse_result = json.parse(message_string)
	
	if parse_result == OK:
		# We have a complete message
		var data = json.get_data()
		_handle_message(data)
		_incomplete_message_buffer.clear()
	else:
		# Check if the error is due to incomplete JSON
		var error_line = json.get_error_line()
		var _error_string = json.get_error_message()
		
		if "EOF" in _error_string or "Unexpected end" in _error_string:
			# Message is incomplete, keep buffering
			print("Buffering incomplete message, current size: ", _incomplete_message_buffer.size())
		else:
			# Real parsing error
			print("JSON Parse Error at line ", error_line, ": ", error_string)
			print("Attempted to parse: ", message_string.substr(0, min(500, message_string.length())))
			_incomplete_message_buffer.clear()


func parse_json_packet(packet_str):
	if packet_str.is_empty():
		print("Warning: Empty packet received")
		return null
		
	var json = JSON.new()
	var err = json.parse(packet_str)
	if err == OK:
		return json.get_data()
	else:
		print("Error parsing JSON: ", json.get_error_message())
		print("Packet length: ", packet_str.length())
		# Log first 500 chars for debugging
		print("Packet preview: ", packet_str.substr(0, 500))
		# Log last 500 chars to see if it's cut off
		if packet_str.length() > 1000:
			print("Packet end: ", packet_str.substr(packet_str.length() - 500, 500))
		return null

func _handle_message(data):
	var json_str = JSON.stringify(data)
	print("Received message length: ", json_str.length(), " bytes")
	print("Received message: \n", json_str)
	
	var cmd = data.get("cmd", "")
	var entity_type = data.get("entity_type", "")
	
	# Handle authentication errors
	if cmd == "error" and entity_type == "core":
		var error_code = data.get("params", {}).get("error_code", "")
		var error_msg = data.get("params", {}).get("error", "")
		
		if error_code == "AUTH_FAILED_PROFILE_CMD_ERROR" or "token" in error_msg.to_lower():
			print("Authentication failed: ", error_msg)
			
			# Only attempt auto-login once per connection
			if not _auth_retry_attempted:
				_auth_retry_attempted = true
				auth_failed.emit()
				return
			else:
				print("Auto-login already attempted, not retrying")
				return
	
	if cmd == "registration_confirmed" and entity_type == "core":
		_auth_retry_attempted = false  # Reset on successful registration
		registered_with_core.emit()
		# Send any queued messages after successful registration
		if _message_queue.size() > 0:
			_send_queued_messages()
	elif cmd == "response" and entity_type == "core":
		# Check if this is a discovery response
		var result = data.get("params", {}).get("result", {})
		var services = result.get("services", [])
		
		if services.size() > 0:
			# This is a discovery response
			discovery_response_data = data
			_process_discovery_response(services)
		
		# Always emit the response_received signal
		response_received.emit(data)
	
	# Always emit the general message_received signal
	message_received.emit(data)
var counter: int = 0

func _queue_message_for_retry(message):
	_message_queue.append(message)


func _send_queued_messages():
	print("Sending %d queued messages..." % _message_queue.size())
	for msg in _message_queue:
		send_message_to_core(msg)
	_message_queue.clear()


func register_with_core(jwt_token: String, client_id: String):
	var register_msg = {
		"cmd": "register",
		"topic": "system",
		"entity_type": "client",
		"params": {
			"client_id": client_id,
			"auth": jwt_token,
			"request_id": UUID.v7()
		}
	}
	register_timer.start()
	send_message_to_core(register_msg)

func request_connections():
	var request_msg = {
		"cmd": "request",
		"entity_type": "software_agent",
		"topic": TOPIC_DISCOVERY,
		"params": {
			"client_id": client_id
		}
	}
	send_message_to_core(request_msg)


func send_request(service_topic: String, user_input: String):
	var message = {
		"cmd": "request",
		"topic": service_topic,  #From discovery response
		"entity_type": "client",
		"params": {
			"request_id": UUID.v7(),
			"client_id": client_id,
			"target_service_id": "Echo1",
			"data": {
				"text": user_input
			},
			"auth": TOKEN
		}
	}
	
	send_message_to_core(message)

func send_media_gen_request(prompt: String) -> void:
	var message = {
		"cmd": "request",
		"topic": "media_gen/generate",  #From discovery response
		"entity_type": "client",
		"params": {
			"request_id": UUID.v7(),
			"client_id": client_id,
			"target_service_id": "media-gen",
			"data": {
					"workflow": "qwen-image-1",
					"positive_prompt": prompt,
					"negative_prompt": "blurry, dark, ugly",
					"width": 1920,
					"height": 1088,
					"steps": 8
				},
			"auth": TOKEN
		}
	}
	
	send_message_to_core(message)


func send_discovery_request() -> void:
	if !register_timer.is_stopped():
		register_timer.stop()
	# Wait for connection to be ready
	if _client.get_ready_state() != WebSocketPeer.STATE_OPEN:
		print("Connection not ready, waiting...")
		await connection_established
	
	print("🔍 Discovering services…")
	var disc_id: = "disc_%s" % UUID.v7()
	var message = {
		"cmd": "request",
		"topic": TOPIC_SYSTEM,  #From discovery response
		"entity_type": "client",
		"params": {
			"request_id": disc_id,
			"client_id": client_id,
			"target_service_id": TOPIC_DISCOVERY,
			"data": {},
			"auth": TOKEN
		}
	}
	send_message_to_core(message)


func _process_discovery_response(services: Array):
	# Clear previous service data
	core_services_ids.clear()
	
	for service_data in services:
		var params = service_data.get("params", {})
		var service_client_id = params.get("client_id", "")
		var service_name = params.get("name", "")
		var service_description = params.get("description", "")
		var actions = params.get("actions", [])
		
		# Store service information
		var service_info = {
			"client_id": service_client_id,
			"name": service_name,
			"description": service_description,
			"actions": []
		}
		
		# Process each action
		for action in actions:
			var action_info = {
				"name": action.get("name", ""),
				"description": action.get("description", ""),
				"topic": action.get("topic", ""),
				"input_parameters": action.get("input_parameters", {}),
				"output_parameters": action.get("output_parameters", {})
			}
			service_info.actions.append(action_info)
		
		# Store by client_id
		core_services_ids[service_client_id] = service_info
		
		# Emit signal for each service discovered
		print("📡 Discovered service: ", service_name)
		for action in service_info.actions:
			service_registered.emit(
				service_name,
				action.input_parameters,
				action.output_parameters,
				[action.topic]
			)
			


func send_message_to_core(message):
	# Check actual WebSocket state, not just our flag
	var state = _client.get_ready_state()
	if state != WebSocketPeer.STATE_OPEN:
		print("WebSocket not open (state: %d). Attempting to reconnect..." % state)
		# Queue the message to send after reconnection
		_queue_message_for_retry(message)
		connect_to_core(CORE_WS_URL)
		return
	
	if validate_message(message):
		var json_string = JSON.stringify(message)
		print("Sending message: ", json_string)
		
		if json_string.length() > 65536:  # 64KB threshold
			print("Large message detected (%d bytes), sending as text" % json_string.length())
		
		_client.send_text(json_string)
	else:
		print("Error: Invalid message format")


func generate_unique_request_id():
	return str(Time.get_unix_time_from_system()) + "_" + str(randi())


func validate_message(message):
	var required_fields = ["cmd", "topic", "entity_type", "params"]
	for field in required_fields:
		if not message.has(field):
			print("Error: Message missing required field: " + field)
			return false
	return true


func merge_dictionaries(dict1: Dictionary, dict2: Dictionary):
	var result = dict1.duplicate()
	for key in dict2.keys():
		result[key] = dict2[key]
	return result


func send_heartbeat():
	if _connected:
		var heartbeat_msg = {
			"cmd": "heartbeat",
			"topic": "system",
			"entity_type": "software_agent",
			"params": {}
		}
		send_message_to_core(heartbeat_msg)
		print("Heartbeat sent")
	else:
		print("Client disconnected from the core.. Attempting to reconnect now")
		connect_to_core(CORE_WS_URL)


func send_service_request(service_id: String, action_topic: String, input_data: Dictionary):
	"""
	Send a request to a specific service with the required input parameters
	
	Args:
		service_id: The client_id of the target service (e.g., "Echo1")
		action_topic: The topic for the specific action (e.g., "echo1/echo")
		input_data: Dictionary containing the input parameters required by the service
	"""
	
	# Validate that we know about this service
	if not core_services_ids.has(service_id):
		print("Error: Unknown service ID: ", service_id)
		return false
	
	var message = {
		"cmd": "request",
		"topic": action_topic,
		"entity_type": "client",
		"params": {
			"request_id": UUID.v7(),
			"client_id": client_id,
			"target_service_id": service_id,
			"data": input_data,
			"auth": TOKEN
		}
	}
	
	send_message_to_core(message)
	return true


func get_available_services() -> Array:
	"""Returns an array of available service names"""
	var services = []
	for service_id in core_services_ids:
		services.append(core_services_ids[service_id].name)
	return services


func get_service_info(service_id: String) -> Dictionary:
	"""Get detailed information about a specific service"""
	return core_services_ids.get(service_id, {})


func get_service_actions(service_id: String) -> Array:
	"""Get all available actions for a service"""
	var service_info = get_service_info(service_id)
	return service_info.get("actions", [])


func get_action_input_requirements(service_id: String, action_name: String) -> Dictionary:
	var actions = get_service_actions(service_id)
	for action in actions:
		if action.name == action_name:
			return action.input_parameters
	return {}


func _on_connection_closed():
	await get_tree().create_timer(2.0).timeout
	connect_to_core(CORE_WS_URL)


func _on_registration_failed() -> void:
	pass
