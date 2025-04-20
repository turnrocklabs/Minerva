class_name CoreClient
extends Node

signal message_received(data: Dictionary)
signal connection_established
signal connection_closed
signal connection_error(error: int)
signal service_registered(service_data: Dictionary)
signal response_received(data, binary_data)

enum EntityType {
	HUMAN_AGENT,
	SOFTWARE_AGENT,
	SERVICE
}

enum FrameType {
	NEW_MESSAGE = 0,
	BINARY_HEADER = 1,
	BINARY_DATA = 2,
	STREAM_END = 3,
}

const TOPIC_SYSTEM = "system"
const TOPIC_DISCOVERY = "skills/discovery"
const HEARTBEAT_INTERVAL = 15

var _client = WebSocketPeer.new()
var _entity_type = EntityType.SOFTWARE_AGENT
var client_id = ""
var _connected = false
var _heartbeat_timer: Timer
var minerva_secret = ""



class Transfer extends RefCounted:
	var json_data: Dictionary
	var total_files: int
	var received: int

	# these change everytime there is new FrameType.BINARY_HEADER
	var fa: FileAccess
	var file_size: int
	var file_path: String

# has msg_id, and fa
var _active_transfers: = {}  # Dictionary to track transfers by msg_id


func _ready():
	_client.inbound_buffer_size = 32 * 1024 * 1024
	client_id = str(Time.get_unix_time_from_system())
	print("Client ID is %s" % client_id)
	_heartbeat_timer = Timer.new()
	_heartbeat_timer.set_one_shot(false)
	_heartbeat_timer.set_wait_time(HEARTBEAT_INTERVAL)
	_heartbeat_timer.timeout.connect(send_heartbeat)
	add_child(_heartbeat_timer)
	minerva_secret = OS.get_environment("MINERVA_SECRET")
	if minerva_secret.is_empty():
		print("Error: MINERVA_SECRET environment variable is not set")

func set_entity_type(type):
	_entity_type = type

func connect_to_core(url: String) -> bool:
	# FIXME: return this
	# if minerva_secret.is_empty():
	# 	print("Error: Cannot connect without MINERVA_SECRET set")
	# 	return false
	minerva_secret = "cat"

	var err = _client.connect_to_url(url)
	if err != OK:
		connection_error.emit(err)
		return false
	set_process(true)
	return true

func _process(delta):
	_client.poll()
	var state = _client.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			connection_established.emit()
			_heartbeat_timer.start()
		while _client.get_available_packet_count():
			print("receiving packet")
			var packet = _client.get_packet()
			if _client.was_string_packet():
				print("\n\n")
				print(packet.get_string_from_utf8())
				print("\n\n")
				var data = parse_json_packet(packet.get_string_from_utf8())
				if data != null:
					_handle_message(data)
			else:
				_handle_binary_message(packet)
	elif state == WebSocketPeer.STATE_CLOSING:
		pass
	elif state == WebSocketPeer.STATE_CLOSED:
		if _connected:
			_connected = false
			_heartbeat_timer.stop()
		var code = _client.get_close_code()
		var reason = _client.get_close_reason()
		print("WebSocket closed with code: %d, reason %s. Clean: %s" % [code, reason, code != -1])
		connection_closed.emit()
		set_process(false)

func parse_json_packet(packet_str):
	var json = JSON.new()
	var err = json.parse(packet_str)
	if err == OK:
		return json.get_data()
	else:
		print("Error parsing JSON: ", json.get_error_message())
		return null


func _handle_binary_message(packet: PackedByteArray):
	print("Total packet size:", packet.size())
	var offset = 0
	
	while offset < packet.size():
		if offset + 17 >= packet.size():
			break
			
		var frame_type = packet[offset]
		print("\nChecking offset", offset)
		print("Frame type:", frame_type)
		print("Next bytes:", packet.slice(offset, min(offset + 20, packet.size())).hex_encode())
		
		match frame_type:
			0,1,2:
				var msg_id = packet.slice(offset + 1, offset + 17)
				var data = packet.slice(offset + 17)
				_handle_frame(packet.slice(offset, offset + get_frame_size(frame_type, data)))
				offset += get_frame_size(frame_type, data)
			_:
				offset += 1

func get_frame_size(frame_type: int, data: PackedByteArray) -> int:
	var u32_bytes = 4
	match frame_type:
		0: # NEW_MESSAGE
			var json_len = bytes_to_u32(data.slice(0, u32_bytes))
			var num_files = bytes_to_u32(data.slice(u32_bytes, u32_bytes * 2))
			return 1 + 16 + u32_bytes * 2 + json_len # type + msgid + jsonlen + numfiles + json
		1: # BINARY_HEADER  
			var path_len = bytes_to_u32(data.slice(0, u32_bytes))
			var file_size = bytes_to_u32(data.slice(u32_bytes, u32_bytes * 2))
			return 1 + 16 + u32_bytes * 2 + path_len # type + msgid + pathlen + filesize + path
		2: # BINARY_DATA
			return 1 + 16 + data.size() # type + msgid + data
	return 1

func bytes_to_u32(bytes: PackedByteArray) -> int:
	if bytes.size() < 4:
		return 0
	return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]

func _handle_frame(frame: PackedByteArray):
	var frame_type = frame[0]
	var msg_id = frame.slice(1, 17).hex_encode()
	var data = frame.slice(17)
	
	print("frame_type: ", frame_type)
	print("msg_id: ", msg_id)
	# print("data: ", data)

	match frame_type:
		0: _handle_new_message(msg_id, data)
		1: _handle_binary_header(msg_id, data)
		2: _handle_binary_data(msg_id, data)

func _handle_new_message(msg_id: String, data: PackedByteArray):
	var json_len = decode_u32(data, 0)
	var num_files = decode_u32(data, 4)
	var json_data = parse_json_packet(data.slice(8, 8 + json_len).get_string_from_utf8())
	
	print("New message received, json:")
	print(json_data)
	
	# create new transfer
	var t: = Transfer.new()
	t.json_data = json_data
	t.total_files = num_files

	_active_transfers[msg_id] = t

func _handle_binary_header(msg_id: String, data: PackedByteArray):
	var path_len = decode_u32(data, 0)
	var file_size = decode_u32(data, 4)
	var path = data.slice(8, 8 + path_len).get_string_from_utf8()
	
	print("New file received")
	print(path)

	var t: Transfer = _active_transfers[msg_id]

	DirAccess.make_dir_recursive_absolute("user://.temp/")

	t.fa = FileAccess.open("user://.temp/%s.tmp" % [path.replace("/", "_")], FileAccess.WRITE_READ)

	if not t.fa:
		print("ALOALOALO")
		print(error_string(FileAccess.get_open_error()))

	t.file_path = path
	t.file_size = file_size


func _handle_binary_data(msg_id: String, data: PackedByteArray):
	if msg_id in _active_transfers:
		# store data to active transfer file object

		var t: Transfer = _active_transfers[msg_id]

		t.fa.store_buffer(data)

		print("Received binary data")
		print("pos: ", t.fa.get_position())
		print("total: ", t.file_size)

		# file received, store file object in json
		if t.file_size == t.fa.get_position():

			var current = t.json_data["params"]["result"]
			var keys = t.file_path.split("/")
			for i in range(keys.size() - 1):
				current = current[int(keys[i]) if keys[i].is_valid_int() else keys[i]]
			current[keys[-1]] = t.fa

			# seek to beginning to be ready for reading afterwards
			t.fa.seek(0)
			t.received += 1
		print(t.total_files)
		# the transfer is complete or the transfer is a stream with unknown number of files
		if t.received == t.total_files or t.total_files == -1:
			print("emit response received")
			response_received.emit(t.json_data, null)
			message_received.emit(t.json_data)




func _check_transfer_complete(transfer: Dictionary) -> bool:
	for path in transfer.files:
		if transfer.files[path].data.size() < transfer.files[path].size:
			return false
	return true

func decode_u32(data, offset):
	var value = (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3]
	# Handle signed int
	if value & 0x80000000:  # If highest bit is set (negative)
		value = value - 0x100000000
	return value

func _handle_message(data, binary_data = null):
	print("Received message: ", JSON.stringify(data))
	var cmd = data.get("cmd", "")
	var topic = data.get("topic", "")
	var entity_type = data.get("entity_type", "")

	# error response example
	# {"cmd":"error","entity_type":"core","params":{"client_id":"1740244954.312","error":"Missing required field: cmd"},"topic":"skills/discovery"}

	if cmd == "error":
		push_error(data["params"]["error"])
		# var err_window: = ErrorWindow.create("Error", data["params"]["error"])
		# add_child(err_window)
		# err_window.popup_centered()

	elif cmd == "register" and entity_type == "service":
		service_registered.emit(data.get("params", {}))

		# var skill_info = data.get("params", {}).get("skill_info", {})
		# var service_name = skill_info.get("name", "")
		# var description = skill_info.get("description", "No description available.")
		# var input_requirements = skill_info.get("input_parameters", {})
		# var output_requirements = skill_info.get("output_parameters", {})
		# var service_topics = data.get("params", {}).get("topics", [])

	elif cmd == "response":
		if topic == TOPIC_DISCOVERY:
			var services = data.get("params", {}).get("result", {}).get("services", [])
			for service in services:
				var params = service.get("params", {})

				service_registered.emit(params)

				# var actions: Array = params.get("actions", [])

				# if actions.is_empty():
				# 	push_warning("Service has no defined actions..")
				# 	print(params)
				# 	pass

				# for action: Dictionary in actions:
				# 	var service_name = action.get("name", "")
				# 	var description = action.get("description", "No description available.")
				# 	var input_requirements = action.get("input_parameters", {})
				# 	var output_requirements = action.get("output_parameters", {})
				# 	var service_topics = params.get("topics", [])


			response_received.emit(data, binary_data)
		else:
			response_received.emit(data, binary_data)
	elif cmd == "ack":
		print("Received acknowledgment: ", data.get("message", ""))
	
	message_received.emit(data)

func register_with_core(auth_token: String):
	var entity_type_str = "human_agent" if _entity_type == EntityType.HUMAN_AGENT else "software_agent" if _entity_type == EntityType.SOFTWARE_AGENT else "service"
	var register_msg = {
		"cmd": "register",
		"entity_type": entity_type_str,
		"topic": TOPIC_SYSTEM,
		"params": {
			# "secret": minerva_secret,
			"auth": auth_token,
			"client_id": client_id,
			"topics": [TOPIC_SYSTEM, TOPIC_DISCOVERY, client_id]
		}
	}
	send_message_to_core(register_msg)

func request_connections(req_id: String = ""):
	var request_msg = {
		"cmd": "request",
		"entity_type": "software_agent",
		"topic": TOPIC_DISCOVERY,
		"params": {
			"client_id": client_id,
			"data": {}
		}
	}

	if not req_id.is_empty():
		request_msg["params"]["request_id"] = req_id

	send_message_to_core(request_msg)



func send_request(service_topic, user_input):
	var request_id = generate_unique_request_id()
	var message = {
		"cmd": "request",
		"topic": service_topic,
		"entity_type": "software_agent",
		"params": {
			"client_id": client_id,
			"request_id": request_id
		}
	}
	message["params"] = merge_dictionaries(message["params"], user_input)
	send_message_to_core(message)


func send_message_to_core(message):
	var json_string = JSON.stringify(message)
	# print("Sending message: ", json_string)
	_client.send_text(json_string)


func send_message(topic, params: Dictionary) -> String:
	var request_id = generate_unique_request_id()
	var message = {
		"cmd": "request",
		"topic": topic,
		"entity_type": "software_agent",
		"params": {
			"client_id": client_id,
			"request_id": request_id,
			"data": params
		}
	}

	var json_string = JSON.stringify(message)
	# print("Sending message:")
	# print(json_string)
	_client.send_text(json_string)

	return request_id

func send_binary_message(topic, params: Dictionary):
	
	var binary_data = _prepare_binary_data(params)


	var request_id = generate_unique_request_id()
	var message = {
		"cmd": "request",
		"topic": topic,
		"entity_type": "software_agent", # needs this
		"params": {
			"client_id": client_id,
			"request_id": request_id,
			"result": params
		}
	}
	# message["params"] = merge_dictionaries(message["params"], params)

	var json_string: = JSON.stringify(message)
	var json_bytes = json_string.to_utf8_buffer()
	var json_length = json_bytes.size()

	# Generate msg_id (16 bytes)
	var msg_id = PackedByteArray()
	msg_id.resize(16)
	for i in range(16):
		msg_id[i] = randi() % 256

	# NEW_MESSAGE frame
	var frame = PackedByteArray()
	frame.append(FrameType.NEW_MESSAGE)  # frame type
	print("Frame bytes: ", frame.hex_encode())
	frame.append_array(msg_id)  # msg_id
	# json length and number of files
	encode_u32(frame, frame.size(), json_length)
	encode_u32(frame, frame.size(), binary_data.size())
	frame.append_array(json_bytes)

	await send_packet(frame)
	print("sending header + json")

	# Send each file
	const CHUNK_SIZE = 32 * 1024  # Reduced chunk size
	for path in binary_data:
		var fa: FileAccess = binary_data[path]
		
		# BINARY_HEADER frame
		var path_bytes = path.to_utf8_buffer()
		var file_size = fa.get_length()
		
		# Send raw binary header frame
		frame = PackedByteArray()
		frame.append(FrameType.BINARY_HEADER)  # frame type byte
		frame.append_array(msg_id)             # msg_id 16 bytes
		encode_u32(frame, frame.size(), path_bytes.size())  # path length 4 bytes
		encode_u32(frame, frame.size(), file_size)         # file size 4 bytes
		frame.append_array(path_bytes)                      # path bytes
		
		await send_packet(frame)
		print("sending file header")
		
		# BINARY_DATA frames
		fa.seek(0)
		while fa.get_position() < file_size:
			frame = PackedByteArray()
			frame.append(FrameType.BINARY_DATA)   # frame type byte
			frame.append_array(msg_id)            # msg_id 16 bytes
			frame.append_array(fa.get_buffer(CHUNK_SIZE))  # chunk of file data
			
			await send_packet(frame)
		print("sending file content")

	print("Data sending finished")

# Add this helper function to handle packet sending with backpressure
func send_packet(packet: PackedByteArray) -> void:
	while _client.get_current_outbound_buffered_amount() > 0:
		await get_tree().create_timer(0.1).timeout
	_client.put_packet(packet)


func _prepare_binary_data(params, current_path: = "") -> Dictionary:
	var data: = {}

	# Handle arrays
	if params is Array:
		for i in range(params.size()):
			var item = params[i]

			var new_path: = "%s/%s" % [current_path, i]
			if new_path.begins_with("/"):
				new_path = new_path.erase(0)

			data.merge(_prepare_binary_data(item, new_path))
	
	# Handle dictionaries
	elif params is Dictionary:

		for key in params:
			var value = params[key]
			var path: = "%s/%s" % [current_path, key]

			if path.begins_with("/"):
				path = path.erase(0)

			if value is Dictionary or value is Array:
				data.merge(_prepare_binary_data(value, path))
			
			elif value is FileAccess:
				data[path] = value


	# CLAUDE CODE
	# Remove binary data from nested structures
	if current_path.is_empty():
		for binary_path in data.keys():
			var parts = binary_path.split("/")
			var current_dict = params
			
			# Navigate through the path
			for i in range(parts.size() - 1):
				var part = parts[i]
				if current_dict.has(part):
					if current_dict[part] is Array:
						current_dict = current_dict[part][parts[i + 1].to_int()]
						i += 1  # Skip the next part since we used it for array index
					else:
						current_dict = current_dict[part]
			
			# Remove the binary data key
			if current_dict is Dictionary:
				var last_key = parts[-1]
				current_dict.erase(last_key)


	return data

func encode_u32(data: PackedByteArray, offset: int, value: int):
	if offset + 4 > data.size():
		data.resize(offset + 4)
	data[offset] = (value >> 24) & 0xFF
	data[offset + 1] = (value >> 16) & 0xFF
	data[offset + 2] = (value >> 8) & 0xFF
	data[offset + 3] = value & 0xFF

func generate_unique_request_id():
	return str(Time.get_unix_time_from_system()) + "_" + str(randi())

func merge_dictionaries(dict1, dict2):
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
