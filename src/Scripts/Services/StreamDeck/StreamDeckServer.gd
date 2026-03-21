class_name StreamDeckServer
extends Node

## WebSocket server for Stream Deck plugin communication.
## Listens on localhost and pushes state changes to connected plugins.
## Only active when enabled in Preferences.

signal server_started
signal server_stopped
signal client_connected(peer_id: int)
signal client_disconnected(peer_id: int)

const PROTOCOL_VERSION := 1
const DEFAULT_PORT := 7778
const SHUTDOWN_GRACE_PERIOD := 30.0  # seconds after last client disconnects

var _tcp_server: TCPServer
var _peers: Dictionary = {}  # peer_id → WebSocketPeer
var _peer_ptt_active: Dictionary = {}  # peer_id → bool (tracks PTT ownership)
var _port: int = DEFAULT_PORT
var _enabled: bool = false
var _shutdown_timer: Timer


func _ready() -> void:
	_shutdown_timer = Timer.new()
	_shutdown_timer.one_shot = true
	_shutdown_timer.timeout.connect(_on_shutdown_timeout)
	add_child(_shutdown_timer)


func _process(_delta: float) -> void:
	if not _enabled or _tcp_server == null:
		return

	# Accept new TCP connections
	while _tcp_server.is_connection_available():
		var conn := _tcp_server.take_connection()
		if conn:
			var ws := WebSocketPeer.new()
			ws.accept_stream(conn)
			var peer_id := conn.get_instance_id()
			_peers[peer_id] = ws
			_peer_ptt_active[peer_id] = false

	# Process each peer
	var to_remove: Array[int] = []
	for peer_id in _peers:
		var ws: WebSocketPeer = _peers[peer_id]
		ws.poll()

		var state := ws.get_ready_state()
		match state:
			WebSocketPeer.STATE_OPEN:
				while ws.get_available_packet_count() > 0:
					var data := ws.get_packet().get_string_from_utf8()
					_handle_message(peer_id, data)
			WebSocketPeer.STATE_CLOSING:
				pass  # wait for close to complete
			WebSocketPeer.STATE_CLOSED:
				to_remove.append(peer_id)

	for peer_id in to_remove:
		_remove_peer(peer_id)


# ── Public API ─────────────────────────────────────────────────────────

func start(port: int = DEFAULT_PORT) -> Error:
	if _tcp_server != null:
		return OK  # already running

	_port = port
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(_port, "127.0.0.1")
	if err != OK:
		_tcp_server = null
		SingletonObject.ErrorDisplay("Stream Deck Error", "Server failed to start on port %d: %s" % [_port, error_string(err)])
		return err

	_enabled = true
	_shutdown_timer.stop()
	_connect_signals()
	server_started.emit()
	print("[StreamDeck] Server listening on 127.0.0.1:%d" % _port)
	return OK


func stop() -> void:
	if _tcp_server == null:
		return

	_disconnect_signals()

	# Clean up PTT for any peers that had it active
	for peer_id in _peer_ptt_active:
		if _peer_ptt_active[peer_id]:
			_release_ptt(peer_id)

	# Close all WebSocket connections
	for peer_id in _peers:
		var ws: WebSocketPeer = _peers[peer_id]
		ws.close(1000, "Server shutting down")
	_peers.clear()
	_peer_ptt_active.clear()

	_tcp_server.stop()
	_tcp_server = null
	_enabled = false
	_shutdown_timer.stop()
	server_stopped.emit()
	print("[StreamDeck] Server stopped")


func is_running() -> bool:
	return _tcp_server != null and _enabled


func get_client_count() -> int:
	return _peers.size()


# ── Message Handling ───────────────────────────────────────────────────

func _handle_message(peer_id: int, raw: String) -> void:
	var json := JSON.new()
	if json.parse(raw) != OK:
		_send_error(peer_id, "parse", "Invalid JSON")
		return

	var data: Dictionary = json.data
	if not data.has("action"):
		_send_error(peer_id, "unknown", "Missing 'action' field")
		return

	var action: String = data.get("action", "")
	match action:
		"get_state":
			_send_state(peer_id)
		"ptt_down":
			_handle_ptt_down(peer_id)
		"ptt_up":
			_handle_ptt_up(peer_id)
		"list_input_devices":
			_send_state(peer_id)  # state includes device list
		"set_input_device":
			var device: String = data.get("device", "")
			_handle_set_input_device(peer_id, device)
		_:
			_send_error(peer_id, action, "Unknown action: %s" % action)


func _handle_ptt_down(peer_id: int) -> void:
	# Check if there's an active ChatPane with voice gateway
	var chat_pane = SingletonObject.Chats
	if chat_pane == null:
		_send_error(peer_id, "ptt_down", "No active chat")
		return

	# Start PTT via the same flow as the mic button
	var voice_gateway = chat_pane.get("_voice_gateway")
	if voice_gateway:
		voice_gateway.ptt_down()

	if SingletonObject.AtT._StartConverting() != OK:
		if voice_gateway:
			voice_gateway.ptt_up()
		_send_error(peer_id, "ptt_down", "Failed to start recording")
		return

	# Set up the field and button targets
	var txt_input = chat_pane.find_child("txtMainUserInput", true, false)
	if txt_input:
		SingletonObject.AtT.FieldForFilling = txt_input

	_peer_ptt_active[peer_id] = true
	_broadcast({"event": "ptt_active", "active": true})


func _handle_ptt_up(peer_id: int) -> void:
	if not _peer_ptt_active.get(peer_id, false):
		return  # no active PTT for this peer

	# Stop recording (second call to _StartConverting toggles off)
	SingletonObject.AtT._StartConverting()
	_peer_ptt_active[peer_id] = false
	# ptt_up on gateway will be called by _on_voice_transcription_completed


func _handle_set_input_device(peer_id: int, device: String) -> void:
	if device.is_empty():
		_send_error(peer_id, "set_input_device", "Device name is empty")
		return

	var devices := AudioServer.get_input_device_list()
	if device not in devices:
		_send_error(peer_id, "set_input_device", "Device not found: %s" % device)
		return

	SingletonObject.set_microphone(device)


func _release_ptt(peer_id: int) -> void:
	if not _peer_ptt_active.get(peer_id, false):
		return
	_peer_ptt_active[peer_id] = false

	# If recording is active, stop it
	if SingletonObject.AtT.effect.is_recording_active():
		SingletonObject.AtT._StartConverting()

	# Release gateway PTT
	var chat_pane = SingletonObject.Chats
	if chat_pane:
		var voice_gateway = chat_pane.get("_voice_gateway")
		if voice_gateway:
			voice_gateway.ptt_up()

	_broadcast({"event": "ptt_active", "active": false})


# ── State Snapshot ─────────────────────────────────────────────────────

func _get_state_snapshot() -> Dictionary:
	var ptt_active := false
	for pid in _peer_ptt_active:
		if _peer_ptt_active[pid]:
			ptt_active = true
			break

	var engagement := "STANDBY"
	var chat_pane = SingletonObject.Chats
	if chat_pane:
		var voice_gateway = chat_pane.get("_voice_gateway")
		if voice_gateway:
			engagement = voice_gateway.get("engagement_state", "STANDBY")

	return {
		"event": "state",
		"protocol_version": PROTOCOL_VERSION,
		"input_device": AudioServer.input_device,
		"input_devices": AudioServer.get_input_device_list(),
		"ptt_active": ptt_active,
		"engagement": engagement,
	}


func _send_state(peer_id: int) -> void:
	_send_to_peer(peer_id, _get_state_snapshot())
	# Mark this as a newly connected client
	if not client_connected.is_connected(Callable()):
		client_connected.emit(peer_id)


# ── Signal Connections ─────────────────────────────────────────────────

func _connect_signals() -> void:
	if not SingletonObject.mic_changed.is_connected(_on_mic_changed):
		SingletonObject.mic_changed.connect(_on_mic_changed)
	if not SingletonObject.output_device_changed.is_connected(_on_output_device_changed):
		SingletonObject.output_device_changed.connect(_on_output_device_changed)


func _disconnect_signals() -> void:
	if SingletonObject.mic_changed.is_connected(_on_mic_changed):
		SingletonObject.mic_changed.disconnect(_on_mic_changed)
	if SingletonObject.output_device_changed.is_connected(_on_output_device_changed):
		SingletonObject.output_device_changed.disconnect(_on_output_device_changed)


func _on_mic_changed(mic: String) -> void:
	_broadcast({
		"event": "input_device_changed",
		"device": mic,
		"devices": AudioServer.get_input_device_list(),
	})


func _on_output_device_changed(_device: String) -> void:
	# Not in v1 scope, but signal is connected for future use
	pass


# ── Transport ──────────────────────────────────────────────────────────

func _send_to_peer(peer_id: int, data: Dictionary) -> void:
	if not _peers.has(peer_id):
		return
	var ws: WebSocketPeer = _peers[peer_id]
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(data))


func _send_error(peer_id: int, source_action: String, message: String) -> void:
	_send_to_peer(peer_id, {
		"event": "error",
		"source_action": source_action,
		"message": message,
	})
	# Use toast for non-blocking error feedback instead of modal dialog
	if SingletonObject.has_method("create_toast_notification"):
		SingletonObject.create_toast_notification("[StreamDeck] %s" % message, 2)  # Type.ERROR = 2
	else:
		printerr("[StreamDeck] %s" % message)


func _broadcast(data: Dictionary) -> void:
	var json_str := JSON.stringify(data)
	for peer_id in _peers:
		var ws: WebSocketPeer = _peers[peer_id]
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(json_str)


func _remove_peer(peer_id: int) -> void:
	# Release PTT if this peer had it active
	_release_ptt(peer_id)

	_peers.erase(peer_id)
	_peer_ptt_active.erase(peer_id)
	client_disconnected.emit(peer_id)
	print("[StreamDeck] Client disconnected (peer %d). %d remaining." % [peer_id, _peers.size()])

	# Start shutdown grace period if no clients remain
	if _peers.is_empty():
		_shutdown_timer.wait_time = SHUTDOWN_GRACE_PERIOD
		_shutdown_timer.start()


func _on_shutdown_timeout() -> void:
	# Grace period expired with no reconnections — but we don't auto-stop.
	# The server stays running if the user enabled it in preferences.
	# This timer is here for future use (e.g., auto-disable).
	pass
