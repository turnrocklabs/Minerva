class_name BundledVoiceDetectorAdapter
extends Node
## Detector adapter backed by the trusted bundled voice worker.

signal connected
signal disconnected
signal event_received(event: Dictionary)
signal start_failed(reason: String)

var _ws: WebSocketPeer
var _generation := 0
var _connected := false
var _configuration: Dictionary = {}
const BuiltinVoice = preload("res://Scripts/Services/Voice/BuiltinVoicePlugin.gd")


func start(configuration: Dictionary) -> void:
	_generation += 1
	_configuration = configuration.duplicate(true)
	_start_worker(_generation)


func _start_worker(generation: int) -> void:
	var manager = _get_manager()
	if manager == null:
		_terminal_failure(generation, "Bundled voice worker is unavailable", false)
		return
	var connection = manager.get_connection(BuiltinVoice.ID)
	if connection == null:
		var started: Dictionary = await manager.start_plugin(BuiltinVoice.ID)
		if generation != _generation:
			return
		if started.has("error"):
			_terminal_failure(generation, str(started.error), false)
			return
		connection = manager.get_connection(BuiltinVoice.ID)
	if connection == null:
		_terminal_failure(generation, "Bundled voice worker did not create a control connection")
		return
	var configured: Dictionary = await connection.call_tool("minerva_voice_configure", _configuration)
	if generation != _generation:
		return
	if configured.has("error"):
		_terminal_failure(generation, "Bundled voice worker rejected its configuration")
		return
	var response: Dictionary = await connection.call_tool("minerva_voice_start", {})
	if generation != _generation:
		return
	var endpoint: Dictionary = response
	if not endpoint.get("ready", false):
		_terminal_failure(generation, "Bundled voice detector did not become ready")
		return
	_connect_endpoint(endpoint, generation)


func _connect_endpoint(endpoint: Dictionary, generation: int) -> void:
	if generation != _generation:
		return
	if int(endpoint.get("port", 0)) <= 0 or str(endpoint.get("token", "")).is_empty():
		_terminal_failure(generation, "Bundled voice detector returned an invalid endpoint")
		return
	_ws = WebSocketPeer.new()
	var url := "ws://127.0.0.1:%d%s?token=%s" % [int(endpoint.get("port", 0)), str(endpoint.get("path", "/audio")), str(endpoint.get("token", ""))]
	if _ws.connect_to_url(url) != OK:
		_ws = null
		_terminal_failure(generation, "Could not connect to bundled voice detector")


func _reconnect_audio(generation: int) -> void:
	var manager = _get_manager()
	var connection = manager.get_connection(BuiltinVoice.ID) if manager != null else null
	if connection == null:
		if generation == _generation:
			_terminal_failure(generation, "Bundled voice worker stopped unexpectedly")
		return
	var endpoint: Dictionary = await connection.call_tool("minerva_voice_start", {})
	if generation != _generation:
		return
	if not endpoint.get("ready", false):
		_terminal_failure(generation, "Bundled voice detector could not reconnect")
		return
	_connect_endpoint(endpoint, generation)


func stop() -> void:
	_generation += 1
	if _ws != null:
		_ws.close()
		_ws = null
	_connected = false
	_stop_worker()


func _stop_worker() -> void:
	var manager = _get_manager()
	if manager == null:
		return
	manager.stop_plugin(BuiltinVoice.ID)


func update_config(configuration: Dictionary) -> void:
	_configuration = configuration.duplicate(true)
	var generation := _generation
	var manager = _get_manager()
	var connection = manager.get_connection(BuiltinVoice.ID) if manager != null else null
	if connection != null:
		var configured: Dictionary = await connection.call_tool("minerva_voice_configure", _configuration)
		if generation == _generation and configured.has("error"):
			_terminal_failure(generation, "Bundled voice worker rejected its configuration")


func send_audio(pcm: PackedByteArray) -> Error:
	return _ws.send(pcm, WebSocketPeer.WRITE_MODE_BINARY) if _connected and _ws != null else ERR_CONNECTION_ERROR


func _get_manager():
	return SingletonObject.plugin_manager


func _terminal_failure(generation: int, reason: String, stop_worker := true) -> void:
	if generation != _generation:
		return
	# Invalidate and tear down before notifying listeners; a listener may start a
	# replacement synchronously from the failure signal.
	_generation += 1
	if _ws != null:
		_ws.close()
		_ws = null
	_connected = false
	if stop_worker:
		_stop_worker()
	start_failed.emit(reason)


func _process(_delta: float) -> void:
	if _ws == null:
		return
	var socket := _ws
	var generation := _generation
	socket.poll()
	match socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				connected.emit()
			if generation != _generation or socket != _ws:
				return
			while socket.get_available_packet_count() > 0:
				var event: Variant = JSON.parse_string(socket.get_packet().get_string_from_utf8())
				if event is Dictionary:
					event_received.emit(event)
					if generation != _generation or socket != _ws:
						return
		WebSocketPeer.STATE_CLOSED:
			_ws = null
			if _connected:
				_connected = false
				disconnected.emit()
			if generation == _generation:
				_reconnect_audio(generation)
