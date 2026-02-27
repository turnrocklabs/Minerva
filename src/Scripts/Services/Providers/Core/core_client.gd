class_name CoreClient
extends Node

signal message_received(data: Dictionary)
signal connection_established
signal connection_closed
signal connection_error(error: int)
@warning_ignore("unused_signal")
signal service_registered(service_data: Dictionary)
signal response_received(data, binary_data)
signal registered_with_core
signal auth_failed

# New signals for binary transfer
signal binary_new_message_received(header: Dictionary, num_files: int)
signal binary_file_info_received(file_index: int, filename: String, size: int)
signal binary_file_progress(file_index: int, received: int, total_size: int, progress_pct: float)
#signal binary_file_saved(file_index: int, request_id: String, filename: String, path: String)
signal binary_transfer_complete(request_id: String) # Emitted when the final text response confirms all files for a request are saved.
signal image_received(filename: String, request_id: String, image_buffer: PackedByteArray) # Renamed parameter for clarity
signal artifact_binary_received(request_id: String, filename: String, buffer: PackedByteArray)

enum EntityType {
	HUMAN_AGENT,
	SOFTWARE_AGENT,
	SERVICE,
	CLIENT
}

# Binary frame types (from Python reference)
const NEW_MESSAGE = 0
const FILE_INFO = 1
const FILE_DATA = 2
const FILE_END = 3

var REST_BRIDGE_LOGIN_URL = "https://www.turnrock.ai:4040/v1/login"
var CORE_WS_URL = "wss://www.turnrock.ai:27500/connect"
const TOPIC_SYSTEM = "system"
const TOPIC_DISCOVERY = "skills/discovery"
const SERVICE_DISCOVERY_ID = "service:core-discovery"
const HEARTBEAT_INTERVAL = 15

const MEDIA_GEN_DIVISIBLE_BY: = 64 # The total numgber of pixels must be divisible by 64

var _client: WebSocketPeer = WebSocketPeer.new() # Explicitly type _client
var _entity_type: EntityType = EntityType.SOFTWARE_AGENT # Explicitly type _entity_type
var client_id: String = ""
#var minerva_secret: String = "cats"
var _connected = false
var _heartbeat_timer: Timer
var register_timer: Timer
var discovery_response_data: Dictionary = {}
var core_services_ids: Dictionary = {}
var tarqet_service_id: String = ""
var _auth_retry_attempted: bool = false
var _message_queue: Array = []
var _is_reconnecting: bool = false
var _message_buffer: String = "" # For fragmented text messages


class Transfer extends RefCounted:
	const DIRECTORY: = "user://.temp/transfers"

	var json_data: Dictionary
	var total_files: int
	var received: int
	var directory: String

	# these change everytime there is new FrameType.BINARY_HEADER
	var fa: FileAccess
	var file_size: int
	var file_path: String

# has msg_id, and fa
var _active_transfers: = {}  # Dictionary to track transfers by msg_id


# Binary transfer state (new variables)
var _binary_files: Dictionary = {}  # file_index -> {"size": int, "received": int, "buffer": PackedByteArray}
var _binary_filenames: Dictionary = {}  # file_index -> filename (String)
var _binary_pending_chunks: Dictionary = {}  # file_index -> [PackedByteArray] for defensive buffering
var _binary_expected_files: int = 0
var _binary_files_completed: int = 0
var _current_binary_request_id: String = "" # request_id associated with the *currently streaming* binary data
var _binary_transfer_mode: String = "" # "media_gen" or "artifact"


func _ready():
	ProjectSettings.set_setting("network/limits/websocket/max_in_buffer_kb", 16384)  # 16 MB for text
	ProjectSettings.set_setting("network/limits/websocket/max_out_buffer_kb", 16384)
	
	client_id = UUIDGen.v7()
	if SingletonObject.verbose_logging:
		print("Client ID is %s" % client_id)
	_heartbeat_timer = Timer.new()
	_heartbeat_timer.set_one_shot(false)
	_heartbeat_timer.set_wait_time(HEARTBEAT_INTERVAL)
	_heartbeat_timer.timeout.connect(send_heartbeat)
	add_child(_heartbeat_timer)
	set_process(false)
	#if minerva_secret.is_empty():
		#print("Error: MINERVA_SECRET environment variable is not set")


func _exit_tree() -> void:
	_clean()

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_clean()

func _clean():
	for msg_id in _active_transfers.keys():
		var t: Transfer = _active_transfers[msg_id]

		if SingletonObject.verbose_logging:
			print("Clearing transfer (%s)" % msg_id)
		clear_trasnfer(t)

func clear_trasnfer(t: Transfer) -> void:
	var files: = _find_file_objects(t.json_data)

	for fa in files:
		fa.close()
		var ferr: = DirAccess.remove_absolute(fa.get_path_absolute())

		if ferr == OK:
			if SingletonObject.verbose_logging:
				print("Removed %s" % fa.get_path_absolute())
		else:
			push_error("%s while trying to delete %s" % [error_string(ferr), fa.get_path_absolute()])
	
	var derr: = DirAccess.remove_absolute(t.directory)

	if derr == OK:
		if SingletonObject.verbose_logging:
			print("Removed %s" % t.directory)
	else:
		push_error("%s while trying to delete" % [error_string(derr), t.directory])


func _find_file_objects(current) -> Array[FileAccess]:
	var fas: Array[FileAccess] = []

	if not (current is Dictionary or current is Array):
		return fas

	if current is Dictionary:
		for value in current.values():
			if value is FileAccess: fas.append(value)
			elif value is Array or value is Dictionary:
				fas.append_array(_find_file_objects(value))

	else:
		for value in current:
			if value is FileAccess: fas.append(value)
			elif value is Array or value is Dictionary:
				fas.append_array(_find_file_objects(value))

	return fas

func set_entity_type(type):
	_entity_type = type

func connect_to_core(CORE_WS_URL_param: String) -> bool: # Explicitly type parameter and return (renamed param for clarity)
	# Always check the actual WebSocket state first
	var current_state = _client.get_ready_state()
	
	# If we have an existing connection, close it properly
	if current_state != WebSocketPeer.STATE_CLOSED:
		if SingletonObject.verbose_logging:
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
	_client.max_queued_packets = 10000
	_client.inbound_buffer_size =  32 * 1024 * 1024 # 32 MB to handle large FILE_DATA chunks
	_client.outbound_buffer_size = 32 * 1024 * 1024
	var err = _client.connect_to_url(CORE_WS_URL_param) # Use the renamed parameter
	if err != OK:
		connection_error.emit(err)
		return false
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
				# Get the packet first, then check its type
				var packet_buffer: PackedByteArray = _client.get_packet() # This consumes the packet

				# Debugging: Check packet_buffer size BEFORE was_string_packet()
				# This helps confirm if get_packet() is returning data
				if SingletonObject.verbose_logging:
					print("DEBUG_PROCESS: Packet retrieved. Raw size: %s bytes." % packet_buffer.size())
				
				if _client.was_string_packet(): # Check if the *last* received packet was a string
					var packet_string: String = packet_buffer.get_string_from_utf8() # Explicitly type
					
					# Check if this is a complete JSON message
					if is_complete_json(packet_string):
						var data = parse_json_packet(packet_string)
						if data != null: # parse_json_packet can return null if there's a JSON error
							_handle_message(data)
					else:
						# Handle fragmented messages
						_message_buffer += packet_string
						if is_complete_json(_message_buffer):
							var data = parse_json_packet(_message_buffer)
							if data != null:
								_handle_message(data)
							_message_buffer = ""
				else:
					# It's a binary packet
					print("🔶 BINARY FRAME RECEIVED: %s bytes" % packet_buffer.size())
					_handle_binary_frame(packet_buffer)
		WebSocketPeer.STATE_CLOSING:
			# Keep polling to achieve proper close
			pass
		WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				_heartbeat_timer.stop()
				connection_closed.emit()
				if SingletonObject.verbose_logging:
					print("connection closed !!!")
				# If we have queued messages and weren't intentionally closing, reconnect
				if _message_queue.size() > 0 and not _is_reconnecting:
					_is_reconnecting = true
					if SingletonObject.verbose_logging:
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


func parse_json_packet(packet_str):
	var json = JSON.new()
	var err = json.parse(packet_str)
	if err == OK:
		return json.get_data()
	else:
		print("Error parsing JSON: ", json.get_error_message())
		return null

var _max_chunk_length: = 400
func _handle_message(data: Dictionary) -> void: # Explicitly type parameter
	var cmd: String = data.get("cmd", "") # Explicitly type
	var entity_type: String = data.get("entity_type", "") # Explicitly type
	var request_id: String = ""
	# Handle authentication errors
	if cmd == "error" and entity_type == "core":
		var error_code: String = data.get("params", {}).get("error_code", "") # Explicitly type
		var error_msg: String = data.get("params", {}).get("error", "") # Explicitly type
		
		if error_code == "AUTH_FAILED_PROFILE_CMD_ERROR" or "token" in error_msg.to_lower():
			push_warning("Authentication failed: %s" % error_msg)

			# Only attempt auto-login once per connection
			if not _auth_retry_attempted:
				_auth_retry_attempted = true
				auth_failed.emit()
				return
			else:
				if SingletonObject.verbose_logging:
					print("Auto-login already attempted, not retrying")
				return
	
	elif cmd == "registration_confirmed" and entity_type == "core":
		_auth_retry_attempted = false  # Reset on successful registration
		registered_with_core.emit()
		# Send any queued messages after successful registration
		if _message_queue.size() > 0:
			_send_queued_messages()
	elif cmd == "notification": 
		var _text: String = ((data.get("params", "")as Dictionary).get("data","") as Dictionary).get("message", "")
		if !_text.is_empty() and not _text.to_lower().contains("ComfyUI".to_lower()) :
			var toast: = ToastNotification.create(ToastNotification.Type.INFO, _text)
			SingletonObject.main_scene.add_child(toast)
	elif cmd == "response" and entity_type == "core":
		request_id = data.get("params", {}).get("request_id", "") # Explicitly type
		
		# Check if this is a discovery response
		var result: Dictionary = data.get("params", {}).get("result", {}) # Explicitly type
		var services: Array = result.get("services", []) # Explicitly type
		
		if services.size() > 0:
			# This is a discovery response
			discovery_response_data = data
			#_process_discovery_response(services)
		
		# Handle final response for an image generation request that included binary transfer
		if request_id == _current_binary_request_id:
			if SingletonObject.verbose_logging:
				print("  ✔️ Final SUCCESS for request_id=%s: %s" % [request_id, JSON.stringify(result, "\t", false)])
			if _binary_expected_files > 0 and _binary_files_completed == _binary_expected_files:
				if SingletonObject.verbose_logging:
					print("  📦 All %s files for request %s successfully saved." % [_binary_files_completed, request_id])
				binary_transfer_complete.emit(request_id)
				_reset_binary_transfer_state() # Reset state after full completion
			elif _binary_expected_files > 0:
				if SingletonObject.verbose_logging:
					print("  ⚠️ Received final response but only %s/%s files completed for request %s" % [_binary_files_completed, _binary_expected_files, request_id])
				_reset_binary_transfer_state() # Reset anyway to prevent stale state
		
		# Always emit the response_received signal
		response_received.emit(data)
	
	# Always emit the general message_received signal
	message_received.emit(data)
	
	if request_id != _current_binary_request_id and SingletonObject.verbose_logging:
		var json_str = JSON.stringify(data)
		print("📥 Received text message length: %s bytes" % json_str.length())

		for i in range(0, json_str.length(), _max_chunk_length):
			var chunk: =  json_str.substr(i, _max_chunk_length)
			printraw(chunk)
			# we have to wait for 3 frames in order to avoid output overflow
			await get_tree().process_frame
			await get_tree().process_frame
			await get_tree().process_frame


func register_with_core(auth_token: String, client_id_: String):
	client_id = client_id_
	var register_msg = {
		"cmd": "register",
		"entity_type": "client",
		"topic": TOPIC_SYSTEM,
		"params": {
			"client_id": client_id,
			"auth": auth_token,
			"request_id": UUIDGen.v7()
		}
	}
	send_text_message_to_core(register_msg)


func request_connections() -> String:
	var req_id: = UUIDGen.v7()
	var request_msg = {
		"cmd": "request",
		"entity_type": "client",
		"topic": TOPIC_SYSTEM,
		"params": {
			"client_id": client_id,
			"request_id": req_id,
			"target_service_id": SERVICE_DISCOVERY_ID,
			"data": {}
		}
	}
	send_text_message_to_core(request_msg)

	return req_id


func send_request(service_topic, user_input):
	var request_id = UUIDGen.v7()
	var message = {
		"cmd": "request",
		"topic": service_topic,
		"entity_type": "client",
		"params": {
			"client_id": client_id,
			"request_id": request_id
		}
	}
	message["params"] = merge_dictionaries(message["params"], user_input)
	send_text_message_to_core(message)


func send_text_message_to_core(message):
	var json_string = JSON.stringify(message)
	if SingletonObject.verbose_logging:
		print("Sending message: ", json_string)
	_client.send_text(json_string)


func subscribe(topic: String) -> String:
	var request_id = UUIDGen.v7()
	var message = {
		"cmd": "subscribe",
		"topic": "subscription",
		"params": {
			"client_id": client_id,
			"request_id": request_id,
			"topic": topic
		}
	}

	var json_string = JSON.stringify(message)
	_client.send_text(json_string)

	return request_id

func send_text_message(service: Service, action: Action, data: Dictionary, auth_token: String = "") -> String:
	var request_id = UUIDGen.v7()
	var message = {
		"cmd": "request",
		"topic": action.topic,
		"entity_type": "client",
		"params": {
			"client_id": client_id,
			"user_id": client_id,
			"request_id": request_id,
			"target_service_id": service.client_id,
			"auth": auth_token,
			"data": data
		}
	}
	
	var json_string = JSON.stringify(message)
	_client.send_text(json_string)
	
	return request_id


# Add this helper function to handle packet sending with backpressure
func send_packet(packet: PackedByteArray) -> void:
	# while _client.get_current_outbound_buffered_amount() > 0:
	# 	await get_tree().create_timer(0.1).timeout
	_client.put_packet(packet)


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
			"entity_type": "client",
			"params": {}
		}
		send_text_message_to_core(heartbeat_msg)
		if SingletonObject.verbose_logging:
			print("Heartbeat sent")

#region Cuauh's media gen code
func _reset_binary_transfer_state() -> void:
	_binary_files.clear()
	_binary_filenames.clear()
	_binary_pending_chunks.clear()
	_binary_expected_files = 0
	_binary_files_completed = 0
	_current_binary_request_id = ""
	_binary_transfer_mode = ""
	if SingletonObject.verbose_logging:
		print("Binary transfer state reset.")


func prepare_binary_artifact_download(request_id: String) -> void:
	_reset_binary_transfer_state()
	_current_binary_request_id = request_id
	_binary_transfer_mode = "artifact"


# Helper to read 64-bit unsigned integer (little-endian)
func _decode_u64_le(bytes_array: PackedByteArray, offset: int) -> int: # Explicitly type parameters and return
	if offset + 8 > bytes_array.size():
		push_error("Attempted to read u64 beyond PackedByteArray bounds.")
		return 0 # Or handle error appropriately
	
	var val: int = 0
	for i in range(8):
		val |= int(bytes_array[offset + i]) << (i * 8)
	return val


func _handle_binary_frame(msg: PackedByteArray) -> void: # Explicitly type parameter
	if msg.size() < 17:
		print("❌ Binary frame too short: %s bytes" % msg.size())
		return

	var frame_type: int = msg[0] # Explicitly type
	var payload: PackedByteArray = msg.slice(17) # Explicitly type

	var frame_names: Dictionary = { # Explicitly type
		NEW_MESSAGE: "NEW_MESSAGE",
		FILE_INFO: "FILE_INFO",
		FILE_DATA: "FILE_DATA",
		FILE_END: "FILE_END"
	}

	var frame_name: String = frame_names.get(frame_type, "UNKNOWN(%d)" % frame_type)
	print("🔷 Binary frame: %s, size: %s bytes, transfer_mode=%s, expected_req=%s" % [frame_name, msg.size(), _binary_transfer_mode, _current_binary_request_id])
	
	match frame_type:
		NEW_MESSAGE:
			if payload.size() < 8:
				print("❌ NEW_MESSAGE payload too short")
				return
				
			var json_len: int = payload.decode_u32(0) # little-endian (Explicitly type)
			var num_files: int = payload.decode_u32(4) # little-endian (Explicitly type)
			
			if payload.size() >= 8 + json_len:
				var header_bytes: PackedByteArray = payload.slice(8, 8 + json_len) # Explicitly type
				var header_json_str: String = header_bytes.get_string_from_utf8() # Explicitly type
				var header: Dictionary = parse_json_packet(header_json_str) # Explicitly type

				if SingletonObject.verbose_logging:
					print("   📋 Binary header: %s files" % num_files)
					print("   📋 Header: %s" % JSON.stringify(header, "\t", false))
				
				# Validate this binary stream is for our request
				var req_id: String = header.get("params", {}).get("request_id", "") # Explicitly type
				var hdr_cmd: String = header.get("cmd", "") # Explicitly type
				var hdr_topic: String = header.get("topic", "") # Explicitly type
				
				if hdr_cmd != "response":
					if SingletonObject.verbose_logging:
						print("  ℹ️ Binary header cmd=%s not a response, ignoring." % hdr_cmd)
					return

				if hdr_topic.begins_with("media_gen/"):
					_binary_transfer_mode = "media_gen"
				elif hdr_topic == "artifact/download":
					_binary_transfer_mode = "artifact"
				else:
					if SingletonObject.verbose_logging:
						print("  ℹ️ Binary header topic=%s not handled, ignoring." % hdr_topic)
					return

				# If we receive a NEW_MESSAGE for a different request_id,
				# we should reset and start tracking this new one.
				if _current_binary_request_id != req_id:
					if SingletonObject.verbose_logging:
						print("  ℹ️ New binary stream detected for request_id=%s. Resetting previous state." % req_id)
					_reset_binary_transfer_state()
					_current_binary_request_id = req_id

				_binary_expected_files = num_files
				_binary_files_completed = 0
				if SingletonObject.verbose_logging:
					print("🎯 Expecting %s files in binary transfer for request %s" % [_binary_expected_files, req_id])
				
				binary_new_message_received.emit(header, num_files)
			else:
				print("❌ NEW_MESSAGE payload data too short for JSON length")
		
		FILE_INFO:
			if _binary_transfer_mode == "artifact":
				# Artifact format: [file_index(4B)] + [file_size(8B u64)] + [name_len(4B)] + [name]
				if payload.size() < 16:
					print("❌ FILE_INFO (artifact) payload too short")
					return
				var file_index: int = payload.decode_u32(0)
				var file_size: int = _decode_u64_le(payload, 4)
				var name_len: int = payload.decode_u32(12)
				if payload.size() < 16 + name_len:
					print("❌ FILE_INFO (artifact) payload too short for name")
					return
				var name_bytes: PackedByteArray = payload.slice(16, 16 + name_len).duplicate()
				var _name: String = name_bytes.get_string_from_utf8()
				_binary_filenames[file_index] = _name
				_binary_files[file_index] = {
					"size": file_size, "received": 0, "buffer": PackedByteArray()
				}
				# Apply any buffered chunks for this file_index
				if _binary_pending_chunks.has(file_index):
					var buffered_chunks: Array = _binary_pending_chunks[file_index]
					var buffer_copy: PackedByteArray = (_binary_files[file_index] as Dictionary)["buffer"]
					for buffered_chunk in buffered_chunks:
						buffer_copy.append_array(buffered_chunk)
						(_binary_files[file_index] as Dictionary)["received"] += buffered_chunk.size()
					_binary_pending_chunks.erase(file_index)
					(_binary_files[file_index] as Dictionary)["buffer"] = buffer_copy
				if SingletonObject.verbose_logging:
					print("   📁 FILE_INFO (artifact) idx=%s name=%s size=%s" % [file_index, _name, file_size])
				binary_file_info_received.emit(file_index, _name, file_size)
			else:
				# Media-gen format: [file_size(8B u64)] + [name_len(4B)] + [name]
				if payload.size() < 12:
					print("❌ FILE_INFO payload too short")
					return

				var file_size: int = _decode_u64_le(payload, 0)
				var name_len: int = payload.decode_u32(8)

				if payload.size() >= 12 + name_len:
					var name_bytes: PackedByteArray = payload.slice(12, 12 + name_len).duplicate()
					var _name: String = name_bytes.get_string_from_utf8()

					# FILE_INFO doesn't contain file_index; order defines index
					var file_index: int = _binary_filenames.size()
					_binary_filenames[file_index] = _name

					var new_buffer = PackedByteArray()

					_binary_files[file_index] = {
						"size": file_size,
						"received": 0,
						"buffer": new_buffer
					}

					# Apply any buffered chunks for this file_index
					if _binary_pending_chunks.has(file_index):
						var buffered_chunks: Array = _binary_pending_chunks[file_index]
						var buffer_copy_for_modify: PackedByteArray = (_binary_files[file_index] as Dictionary)["buffer"]
						for buffered_chunk in buffered_chunks:
							buffer_copy_for_modify.append_array(buffered_chunk)
							(_binary_files[file_index] as Dictionary)["received"] += buffered_chunk.size()
						_binary_pending_chunks.erase(file_index)
						(_binary_files[file_index] as Dictionary)["buffer"] = buffer_copy_for_modify
						if SingletonObject.verbose_logging:
							print("   📁 FILE_INFO idx=%s name=%s size=%s (applied %s buffered bytes). Current buffer size: %s bytes." % [file_index, _name, file_size, (_binary_files[file_index] as Dictionary)["received"], buffer_copy_for_modify.size()])
					else:
						if SingletonObject.verbose_logging:
							print("   📁 FILE_INFO idx=%s name=%s size=%s. Current buffer size: %s bytes." % [file_index, _name, file_size, ((_binary_files[file_index] as Dictionary)["buffer"] as PackedByteArray).size()])

					binary_file_info_received.emit(file_index, _name, file_size)
				else:
					print("❌ FILE_INFO payload data too short for name length")
		
		FILE_DATA:
			if _binary_transfer_mode == "artifact":
				# Artifact format: [file_index(4B)] + [chunk_data]
				if payload.size() < 4:
					return
				var file_index: int = payload.decode_u32(0)
				var current_chunk: PackedByteArray = payload.slice(4).duplicate()
				if current_chunk.is_empty():
					return
				if _binary_files.has(file_index):
					var fd: Dictionary = _binary_files[file_index]
					var buf: PackedByteArray = fd["buffer"]
					buf.append_array(current_chunk)
					fd["received"] += current_chunk.size()
					fd["buffer"] = buf
					# Log progress every 1MB
					@warning_ignore("integer_division")
					var prev_mb: int = (fd["received"] - current_chunk.size()) / (1024 * 1024)
					@warning_ignore("integer_division")
					var curr_mb: int = fd["received"] / (1024 * 1024)
					if prev_mb != curr_mb and SingletonObject.verbose_logging:
						var pct: float = (float(fd["received"]) / fd["size"]) * 100.0 if fd["size"] > 0 else 0.0
						print("   📊 FILE_DATA (artifact) idx=%s: %s/%s (%.1f%%)" % [file_index, fd["received"], fd["size"], pct])
						binary_file_progress.emit(file_index, fd["received"] as int, fd["size"] as int, pct)
				else:
					if not _binary_pending_chunks.has(file_index):
						_binary_pending_chunks[file_index] = []
					(_binary_pending_chunks[file_index] as Array).append(current_chunk.duplicate())
					if SingletonObject.verbose_logging:
						print("   ⚠️ FILE_DATA (artifact) for unknown file index %s - buffering %s bytes" % [file_index, current_chunk.size()])
			else:
				# Media-gen format: entire payload is chunk data
				var current_chunk: PackedByteArray = payload.duplicate()

				if current_chunk.is_empty():
					return

				var file_index: int = -1
				# Determine file_index - for single file it's always 0
				if _binary_files.size() == 1:
					file_index = 0
				elif _binary_files.size() > 1:
					# Multi-file: find the first file that's not complete
					var _binrary_keys = (_binary_files.keys() as Array)
					_binrary_keys.sort_custom(func(a,b): return a < b)
					for idx in _binrary_keys:
						if (_binary_files[idx] as Dictionary)["received"] < (_binary_files[idx] as Dictionary)["size"]:
							file_index = idx
							break
					if file_index == -1:
						if SingletonObject.verbose_logging:
							print("   ⚠️ FILE_DATA received but all known files are complete or no files registered. Buffering for index 0.")
						file_index = 0
				else:
					file_index = 0

				if _binary_files.has(file_index):
					var file_data_dict: Dictionary = _binary_files[file_index]
					var buffer_copy_for_modify: PackedByteArray = (file_data_dict["buffer"] as PackedByteArray)
					var current_received_bytes: int = file_data_dict["received"] as int

					buffer_copy_for_modify.append_array(current_chunk)

					file_data_dict["received"] += current_chunk.size()
					file_data_dict["buffer"] = buffer_copy_for_modify
					# Log progress periodically (every 1MB)
					@warning_ignore("integer_division")
					if int(current_received_bytes / (1024 * 1024)) != int((file_data_dict["received"] as int) / (1024 * 1024)):
						var pct: float = 0.0
						if (file_data_dict["size"] as int) > 0:
							pct = (float(file_data_dict["received"]) / (file_data_dict["size"] as int)) * 100.0
						if SingletonObject.verbose_logging:
							print("   📊 FILE_DATA idx=%s: %s/%s (%s%%)" % [file_index, file_data_dict["received"], file_data_dict["size"], "%.1f" % pct])
						binary_file_progress.emit(file_index, file_data_dict["received"] as int, file_data_dict["size"] as int, pct)
				else:
					if not _binary_pending_chunks.has(file_index):
						_binary_pending_chunks[file_index] = []
					(_binary_pending_chunks[file_index] as Array).append(current_chunk.duplicate())
					if SingletonObject.verbose_logging:
						print("   ⚠️ FILE_DATA for unknown file index %s - buffering %s bytes" % [file_index, current_chunk.size()])
		
		FILE_END:
			if payload.size() < 4:
				print("❌ FILE_END payload too short")
				return

			var file_index: int = payload.decode_u32(0)

			if _binary_transfer_mode == "artifact":
				if _binary_files.has(file_index) and _binary_filenames.has(file_index):
					var buf: PackedByteArray = (_binary_files[file_index] as Dictionary)["buffer"]
					var fname: String = _binary_filenames[file_index]
					print("   ✅ FILE_END (artifact) idx=%s name=%s size=%s bytes, emitting signal with req_id=%s" % [file_index, fname, buf.size(), _current_binary_request_id])
					artifact_binary_received.emit(_current_binary_request_id, fname, buf)
					_binary_files_completed += 1
				else:
					print("   ⚠️ FILE_END (artifact) for unknown index %s (files=%s, filenames=%s)" % [file_index, _binary_files.keys(), _binary_filenames.keys()])
				# Don't reset state here — let the text completion handler do it
				# This avoids the stale-FILE_END race condition for sequential downloads
				return

			# Media-gen FILE_END (existing behavior)
			if _binary_files.has(file_index) and _binary_filenames.has(file_index):
				var buf: PackedByteArray = (_binary_files[file_index] as Dictionary)["buffer"]

				# Check if the buffer is correctly filled to the expected size
				var expected_file_size: int = (_binary_files[file_index] as Dictionary)["size"] as int
				if buf.size() != expected_file_size:
					print("❌ FILE_END: Buffer size (%s bytes) does not match expected size (%s bytes). Cannot save file." % [buf.size(), expected_file_size])
					return

				var ext: String = "." + _binary_filenames[file_index].get_extension()
				var time: = Time.get_datetime_string_from_system().replace(":", "_")
				var fname: String = _binary_filenames[file_index].replace(ext, "") + time  + ext
				var out_path: String = "user://temp/" + fname
				image_received.emit(fname, _current_binary_request_id, buf)

				var dir = DirAccess.open("user://temp/")
				if dir == null:
					if SingletonObject.verbose_logging:
						print("Error opening directory 'user://temp/'. Creating it.")
					var err = DirAccess.make_dir_recursive_absolute("user://temp/")
					if err != OK:
						push_error("Failed to create directory 'user://temp/'. Error: %s" % err)
						return

				var file = FileAccess.open(out_path, FileAccess.WRITE)
				if file:
					if SingletonObject.verbose_logging:
						print("file path: %s"  % file.get_path_absolute())
					file.store_buffer(buf)
					file.close()
					_binary_files_completed += 1
					if SingletonObject.verbose_logging:
						print("   ✅ FILE_END idx=%s saved to %s (%s bytes). Total completed: %s/%s" % [file_index, out_path, buf.size(), _binary_files_completed, _binary_expected_files])
				else:
					push_error("FileAccess error: %s" % FileAccess.get_open_error())
					push_error("   ❌ Could not save file %s" % out_path)
				# Do NOT reset state here: multi-file responses (e.g. 2-image compose) send
				# one FILE_END per file. Reset only when we get the final text "response"
				# or a NEW_MESSAGE for another request (handled in _handle_message and NEW_MESSAGE).
			else:
				if SingletonObject.verbose_logging:
					print("   ⚠️ FILE_END for unknown file index %s" % file_index)

		_: # Default case for unknown frame type
			if SingletonObject.verbose_logging:
				print("   ❓ Unknown binary frame type: %s" % frame_type)


func send_media_gen_request(generation_params: Dictionary, topic: String = "media_gen/image_generation") -> String: # Accepts a dictionary of parameters and optional topic
	var request_id: String = UUIDGen.v7() # Generate request_id once (Explicitly type)
	var message: Dictionary = { # Explicitly type
		"cmd": "request",
		"topic": topic,  # Use provided topic parameter
		"entity_type": "client",
		"params": {
			"client_id": Core._client_id,  # Use Core._client_id for consistency with other media gen functions
			"request_id": request_id,
			"target_service_id": "media-gen",
			"data": {
			},
			"auth": Core._jwt_token
		}
	}
	
	# Merge the provided generation_params into the 'data' dictionary
	(message["params"] as Dictionary)["data"] = merge_dictionaries((message["params"] as Dictionary)["data"] as Dictionary, generation_params)
	
	# Store the request_id locally, so _handle_message can track the binary response.
	_current_binary_request_id = request_id
	send_message_to_core(message)
	return request_id


func send_media_edit_request(editing_params: Dictionary, image_buffer: PackedByteArray, image_filename: String = "input_image.png") -> String:
	var request_id: String = UUIDGen.v7()
	
	# Base64 encode the image buffer
	var base64_image_data: String = Marshalls.raw_to_base64(image_buffer)#.base64_encode(image_buffer).get_string_from_utf8()

	var message: Dictionary = {
		"cmd": "request",
		"topic": "media_gen/image_editing", # <--- IMPORTANT: Correct topic for image editing
		"entity_type": "client",
		"params": {
			"client_id": Core._client_id,  # Use Core._client_id for consistency with other media gen functions
			"request_id": request_id,
			"target_service_id": "media-gen",
			"data": {
				"workflow": "image_editing", # <--- IMPORTANT: Correct workflow for image editing
				"files": [ # Attach the image here
					{
						"filename": image_filename,
						"role": "image",
						"data": base64_image_data,
						"content_type": "image/png" # Assuming PNG as default
					}
				]
			},
			"auth": Core._jwt_token
		}
	}
	(message["params"] as Dictionary)["data"] = merge_dictionaries((message["params"] as Dictionary)["data"] as Dictionary, editing_params)
	_current_binary_request_id = request_id
	send_message_to_core(message)
	return request_id

# This function is the one used for mask image editing
func send_media_selective_edit_request(editing_params: Dictionary, images_dir: Array) -> String:
	var request_id: String = UUIDGen.v7()

	var message: Dictionary = {
		"cmd": "request",
		"topic": "media_gen/image_selective_editing", # Match Python's Test 3 topic
		"entity_type": "client",
		"params": {
			"client_id": Core._client_id,
			"request_id": request_id,
			"target_service_id": "media-gen",
			"data": {
				"workflow": "image_selective_editing", # Match Python's Test 3 workflow
				# All editing_params passed directly here
			},
			"auth": Core._jwt_token
		}
	}

	# Merge the provided editing_params into the 'data' dictionary
	var data_payload: Dictionary = (message["params"] as Dictionary)["data"] as Dictionary
	data_payload = merge_dictionaries(data_payload, editing_params)

	# Attach both the base image and the mask image to the files array
	data_payload["files"] = images_dir
	(message["params"] as Dictionary)["data"] = data_payload

	_current_binary_request_id = request_id
	send_message_to_core(message)

	return request_id
#endregion

## Send a media flex request for the qwen_2511_flex workflow.
## This workflow uses boolean switches to control operation mode:
## - create: all use_empty_* = true (generate from noise)
## - edit: use_empty_latent=false, use_empty_image1=false (edit image1)
## - compose_2: use_empty_latent=true, use_empty_image1/2=false, use_empty_image3=true (combine 2 images; send images with roles "image1", "image2")
## - compose_3: use_empty_latent=true, use_empty_image1/2/3=false (combine 3 images; the 3rd image is always from the Pose Editor when using compose_3_with_pose)
func send_media_flex_request(params: Dictionary, images: Array = []) -> String:
	var request_id: String = UUIDGen.v7()

	var message: Dictionary = {
		"cmd": "request",
		"topic": "media_gen/qwen_2511_flex",
		"entity_type": "client",
		"params": {
			"client_id": Core._client_id,
			"request_id": request_id,
			"target_service_id": "media-gen",
			"data": {
				"workflow": "qwen_2511_flex"
			},
			"auth": Core._jwt_token
		}
	}

	# Merge the provided params into the 'data' dictionary
	var data_payload: Dictionary = (message["params"] as Dictionary)["data"] as Dictionary
	data_payload = merge_dictionaries(data_payload, params)

	# Build files array from images
	# Each image should have: {buffer: PackedByteArray, role: String, filename: String}
	if images.size() > 0:
		var files_array: Array = []
		for img in images:
			var buffer: PackedByteArray = img.get("buffer", PackedByteArray())
			var role: String = img.get("role", "image1")
			var filename: String = img.get("filename", "image.png")

			if buffer.size() > 0:
				var base64_data: String = Marshalls.raw_to_base64(buffer)
				files_array.append({
					"filename": filename,
					"role": role,
					"data": base64_data,
					"content_type": "image/png"
				})

		if files_array.size() > 0:
			data_payload["files"] = files_array

	(message["params"] as Dictionary)["data"] = data_payload

	_current_binary_request_id = request_id
	send_message_to_core(message)

	return request_id


## Send a flex request for 3-image composition: image1, image2, and image3 = pose editor texture.
## Use for qwen_2511_flex compose_3_with_pose (use_empty_image1/2/3=false).
## image1 and image2 are dicts: {buffer: PackedByteArray, role: String, filename: String}.
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


func _queue_message_for_retry(message: Dictionary) -> void: # Explicitly type parameter
	_message_queue.append(message)


func _send_queued_messages() -> void:
	if SingletonObject.verbose_logging:
		print("Sending %d queued messages..." % _message_queue.size())
	for msg in _message_queue:
		send_message_to_core(msg)
	_message_queue.clear()


func send_message_to_core(message: Dictionary) -> void: # Explicitly type parameter
	# Check actual WebSocket state, not just our flag
	var state = _client.get_ready_state()
	if state != WebSocketPeer.STATE_OPEN:
		if SingletonObject.verbose_logging:
			print("WebSocket not open (state: %s). Attempting to reconnect..." % state)
		# Queue the message to send after reconnection
		_queue_message_for_retry(message)
		connect_to_core(CORE_WS_URL)
		return

	if validate_message(message):
		var json_string: String = JSON.stringify(message) # Explicitly type
		if SingletonObject.verbose_logging:
			print("Sending message: %s" % json_string)

		if json_string.length() > 65536:  # 64KB threshold
			if SingletonObject.verbose_logging:
				print("Large message detected (%s bytes), sending as text" % json_string.length())

		_client.send_text(json_string)
	else:
		print("Error: Invalid message format")


func validate_message(message: Dictionary) -> bool: # Explicitly type parameter and return
	var required_fields: Array[String] = ["cmd", "topic", "entity_type", "params"] # Explicitly type Array
	for field in required_fields:
		if not message.has(field):
			print("Error: Message missing required field: %s" % field) # Corrected string formatting
			return false
	return true
