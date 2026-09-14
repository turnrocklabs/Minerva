extends Node
## Default detector transport for the localhost Docker voice gateway.

signal connected
signal disconnected
signal event_received(event: Dictionary)
signal start_failed(reason: String)

const GATEWAY_URL := "ws://localhost:8090/audio"
const HEALTH_URL := "http://localhost:8090/health"
const MAX_HEALTH_RETRIES := 20
const HEALTH_POLL_INTERVAL := 1.5

var _ws: WebSocketPeer
var _reconnect_timer: Timer
var _should_connect := false
var _connected := false
var _health_retries := 0
var _generation := 0
var _configuration: Dictionary = {}


func _ready() -> void:
	_reconnect_timer = Timer.new()
	_reconnect_timer.wait_time = 3.0
	_reconnect_timer.timeout.connect(_try_connect)
	add_child(_reconnect_timer)


func start(configuration: Dictionary) -> void:
	_generation += 1
	_should_connect = true
	_configuration = configuration.duplicate(true)
	_health_retries = 0
	_poll_health(_generation)


func stop() -> void:
	_generation += 1
	_should_connect = false
	_reconnect_timer.stop()
	if _ws != null:
		_ws.close()
		_ws = null
	_connected = false


func update_config(configuration: Dictionary) -> void:
	_configuration = configuration.duplicate(true)
	if not _should_connect:
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result, _code, _headers, _body): http.queue_free())
	if http.request("http://localhost:8090/config", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(_configuration)) != OK:
		http.queue_free()


func send_audio(pcm: PackedByteArray) -> Error:
	if not _connected or _ws == null:
		return ERR_CONNECTION_ERROR
	return _ws.send(pcm, WebSocketPeer.WRITE_MODE_BINARY)


func _process(_delta: float) -> void:
	if _ws == null:
		return
	var socket := _ws
	var generation := _generation
	socket.poll()
	var state := socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			connected.emit()
			if socket != _ws or generation != _generation:
				return
		while socket == _ws and generation == _generation and socket.get_available_packet_count() > 0:
			var parsed: Variant = JSON.parse_string(socket.get_packet().get_string_from_utf8())
			if parsed is Dictionary:
				event_received.emit(parsed)
	elif state == WebSocketPeer.STATE_CLOSED:
		var was_connected := _connected
		_connected = false
		_ws = null
		if was_connected:
			disconnected.emit()
			if generation != _generation:
				return
		if _should_connect:
			_reconnect_timer.start()


func _poll_health(generation: int) -> void:
	if not _should_connect or generation != _generation:
		return
	var http := HTTPRequest.new()
	http.timeout = 3.0
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray):
		http.queue_free()
		_handle_health_result(generation, result, code)
	)
	if http.request(HEALTH_URL) != OK:
		http.queue_free()
		_handle_health_result(generation, HTTPRequest.RESULT_CANT_CONNECT, 0)


func _handle_health_result(generation: int, result: int, code: int) -> void:
	if not _should_connect or generation != _generation:
		return
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		print("[VoiceGateway] Gateway healthy after %d poll(s)" % (_health_retries + 1))
		update_config(_configuration)
		_try_connect()
		return
	_health_retries += 1
	if _health_retries >= MAX_HEALTH_RETRIES:
		_should_connect = false
		start_failed.emit("Gateway not responding after %d health checks" % _health_retries)
		return
	get_tree().create_timer(HEALTH_POLL_INTERVAL).timeout.connect(_poll_health.bind(generation), CONNECT_ONE_SHOT)


func _try_connect() -> void:
	if not _should_connect or _connected or _ws != null:
		return
	_ws = WebSocketPeer.new()
	if _ws.connect_to_url(GATEWAY_URL) != OK:
		_ws = null
		if _should_connect:
			_reconnect_timer.start()
