class_name VoiceGatewayClient
extends Node
## Connects to the local voice gateway container via WebSocket.
## Streams mic audio, receives wake word + VAD events.
## Manages STANDBY/ENGAGED state machine.

signal engagement_changed(state: String)  # "STANDBY" or "ENGAGED"
signal vad_started()
signal vad_ended()
signal wake_word_detected(confidence: float)
signal transcription_ready(audio_wav: PackedByteArray)
signal connected_to_gateway()
signal disconnected_from_gateway()

const GATEWAY_URL := "ws://localhost:8090/audio"
const ENGAGEMENT_IDLE_TIMEOUT := 20.0
const PRE_VAD_BUFFER_MAX_BYTES := 32000  # ~1 second at 16kHz s16le
const CAPTURE_POLL_HZ := 30  # how often we grab mic audio
const TARGET_SAMPLE_RATE := 16000  # gateway expects 16kHz

var engagement_state: String = "STANDBY"

var _ws: WebSocketPeer = null
var _connected := false

# Mic capture: separate AudioStreamPlayer + AudioEffectCapture (no conflict with AudioToText)
var _mic_player: AudioStreamPlayer = null
var _capture_effect: AudioEffectCapture = null
var _capture_bus_idx: int = -1
var _capture_timer: Timer = null

# Recording state
var _recording := false
var _audio_buffer: PackedByteArray = PackedByteArray()
var _pre_vad_buffer: Array[PackedByteArray] = []
var _vad_active := false

# TTS playback tracking
var _tts_playing := false

# Idle timer
var _idle_timer: Timer = null

# PTT state
var _ptt_active := false
var _ptt_saved_engagement: String = ""

# Reconnection
var _reconnect_timer: Timer = null
var _should_connect := false


func _ready() -> void:
	_capture_timer = Timer.new()
	_capture_timer.wait_time = 1.0 / CAPTURE_POLL_HZ
	_capture_timer.timeout.connect(_on_capture_tick)
	add_child(_capture_timer)

	_idle_timer = Timer.new()
	_idle_timer.one_shot = true
	_idle_timer.wait_time = ENGAGEMENT_IDLE_TIMEOUT
	_idle_timer.timeout.connect(_on_idle_timeout)
	add_child(_idle_timer)

	_reconnect_timer = Timer.new()
	_reconnect_timer.wait_time = 3.0
	_reconnect_timer.timeout.connect(_try_connect)
	add_child(_reconnect_timer)

	# Create a dedicated audio bus for voice gateway capture
	_setup_capture_bus()


func _process(_delta: float) -> void:
	if _ws:
		_ws.poll()
		var state: int = _ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				connected_to_gateway.emit()
				print("[VoiceGateway] Connected to gateway")
			while _ws.get_available_packet_count() > 0:
				var packet: PackedByteArray = _ws.get_packet()
				_handle_gateway_message(packet)
		elif state == WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				disconnected_from_gateway.emit()
				print("[VoiceGateway] Disconnected from gateway")
			_ws = null
			if _should_connect:
				_reconnect_timer.start()


# ── Audio Bus Setup ─────────────────────────────────────────────────────

func _setup_capture_bus() -> void:
	# Add a new bus "VoiceCapture" with AudioEffectCapture for streaming
	var bus_name := "VoiceCapture"
	_capture_bus_idx = AudioServer.get_bus_index(bus_name)
	if _capture_bus_idx < 0:
		AudioServer.add_bus()
		_capture_bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_capture_bus_idx, bus_name)
		AudioServer.set_bus_mute(_capture_bus_idx, true)  # don't output to speakers
		AudioServer.set_bus_send(_capture_bus_idx, "Master")

	# Add or get AudioEffectCapture on this bus
	var has_capture := false
	for i in range(AudioServer.get_bus_effect_count(_capture_bus_idx)):
		if AudioServer.get_bus_effect(_capture_bus_idx, i) is AudioEffectCapture:
			_capture_effect = AudioServer.get_bus_effect(_capture_bus_idx, i) as AudioEffectCapture
			has_capture = true
			break

	if not has_capture:
		_capture_effect = AudioEffectCapture.new()
		AudioServer.add_bus_effect(_capture_bus_idx, _capture_effect)


# ── Connection ──────────────────────────────────────────────────────────

func start() -> void:
	_should_connect = true
	_try_connect()
	_start_mic_capture()
	_capture_timer.start()
	print("[VoiceGateway] Started")


func stop() -> void:
	_should_connect = false
	_capture_timer.stop()
	_stop_mic_capture()
	_reconnect_timer.stop()
	if _ws:
		_ws.close()
		_ws = null
	_connected = false
	print("[VoiceGateway] Stopped")


func _try_connect() -> void:
	if _connected or _ws != null:
		return
	_ws = WebSocketPeer.new()
	var err: int = _ws.connect_to_url(GATEWAY_URL)
	if err != OK:
		_ws = null
		if _should_connect:
			_reconnect_timer.start()


# ── Mic Capture ─────────────────────────────────────────────────────────

func _start_mic_capture() -> void:
	if _mic_player:
		return
	_mic_player = AudioStreamPlayer.new()
	_mic_player.bus = &"VoiceCapture"
	_mic_player.stream = AudioStreamMicrophone.new()
	add_child(_mic_player)
	_mic_player.play()
	print("[VoiceGateway] Mic capture started on VoiceCapture bus")


func _stop_mic_capture() -> void:
	if _mic_player:
		_mic_player.stop()
		_mic_player.queue_free()
		_mic_player = null
	# Drain any remaining captured audio
	if _capture_effect:
		_capture_effect.clear_buffer()


func _on_capture_tick() -> void:
	if not _connected or not _capture_effect:
		return

	var frames_available: int = _capture_effect.get_frames_available()
	if frames_available < 256:
		return

	# Get captured audio as Vector2 frames (stereo float) at native mix rate
	var frames: PackedVector2Array = _capture_effect.get_buffer(frames_available)
	var native_rate: int = AudioServer.get_mix_rate()

	# Convert stereo float to mono float array
	var mono := PackedFloat32Array()
	mono.resize(frames.size())
	for i in range(frames.size()):
		mono[i] = (frames[i].x + frames[i].y) * 0.5

	# Resample from native rate (44100/48000) to 16kHz
	if native_rate != TARGET_SAMPLE_RATE:
		var ratio: float = float(TARGET_SAMPLE_RATE) / float(native_rate)
		var new_len: int = int(mono.size() * ratio)
		var resampled := PackedFloat32Array()
		resampled.resize(new_len)
		for i in range(new_len):
			var src_idx: float = float(i) / ratio
			var idx: int = mini(int(src_idx), mono.size() - 1)
			resampled[i] = mono[idx]
		mono = resampled

	# Convert float [-1,1] to s16le PCM bytes
	var pcm := PackedByteArray()
	pcm.resize(mono.size() * 2)
	for i in range(mono.size()):
		var s16: int = clampi(int(mono[i] * 32767.0), -32768, 32767)
		pcm.encode_s16(i * 2, s16)

	# Send to gateway
	_ws.send(pcm, WebSocketPeer.WRITE_MODE_BINARY)

	# Manage pre-VAD buffer
	_pre_vad_buffer.append(pcm)
	var total_size: int = 0
	for chunk in _pre_vad_buffer:
		total_size += chunk.size()
	while total_size > PRE_VAD_BUFFER_MAX_BYTES and _pre_vad_buffer.size() > 1:
		total_size -= _pre_vad_buffer[0].size()
		_pre_vad_buffer.remove_at(0)

	# Accumulate if recording
	if _recording:
		_audio_buffer.append_array(pcm)


# ── Gateway Events ──────────────────────────────────────────────────────

func _handle_gateway_message(packet: PackedByteArray) -> void:
	var text: String = packet.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return

	var event_type: String = parsed.get("type", "")
	match event_type:
		"wake_word":
			var confidence: float = parsed.get("confidence", 0.0)
			wake_word_detected.emit(confidence)
			_handle_wake_word(confidence)
		"vad_start":
			_handle_vad_start()
		"vad_end":
			_handle_vad_end()


func _handle_wake_word(confidence: float) -> void:
	if _tts_playing:
		print("[VoiceGateway] Wake word during playback (%.3f) — barge-in" % confidence)
		_set_engagement("ENGAGED", "wake word barge-in")
		_cancel_idle_timer()
		_pre_vad_buffer.clear()
		return

	if engagement_state == "STANDBY":
		print("[VoiceGateway] Wake word in STANDBY (%.3f) — engaging" % confidence)
		_set_engagement("ENGAGED", "wake word")
		_cancel_idle_timer()
		_pre_vad_buffer.clear()


func _handle_vad_start() -> void:
	_vad_active = true
	vad_started.emit()

	if not is_engaged_or_ptt():
		return
	if _tts_playing:
		return

	if not _recording:
		_recording = true
		_audio_buffer = PackedByteArray()
		for chunk in _pre_vad_buffer:
			_audio_buffer.append_array(chunk)
		_pre_vad_buffer.clear()
		_cancel_idle_timer()
		print("[VoiceGateway] Recording started (with %d bytes pre-VAD)" % _audio_buffer.size())


func _handle_vad_end() -> void:
	_vad_active = false
	vad_ended.emit()

	if _recording:
		_recording = false
		print("[VoiceGateway] Recording stopped (%d bytes)" % _audio_buffer.size())
		if _audio_buffer.size() > 1600:
			var wav: PackedByteArray = _pcm_to_wav(_audio_buffer)
			transcription_ready.emit(wav)
		_audio_buffer = PackedByteArray()


# ── Engagement State Machine ────────────────────────────────────────────

func is_engaged_or_ptt() -> bool:
	return engagement_state == "ENGAGED" or _ptt_active


func _set_engagement(new_state: String, reason: String = "") -> void:
	if engagement_state == new_state:
		return
	var old: String = engagement_state
	engagement_state = new_state
	print("[VoiceGateway] %s → %s (%s)" % [old, new_state, reason])
	engagement_changed.emit(new_state)


func check_dismiss_phrase(text: String) -> bool:
	var clean: String = text.strip_edges().to_lower().rstrip(".!,")
	if clean in ["stop listening", "stop listen"]:
		_set_engagement("STANDBY", "user said 'stop listening'")
		_cancel_idle_timer()
		return true
	return false


func notify_tts_started() -> void:
	_tts_playing = true
	_cancel_idle_timer()


func notify_tts_finished() -> void:
	_tts_playing = false
	if engagement_state == "ENGAGED":
		_start_idle_timer()


func ptt_down() -> void:
	_ptt_active = true
	_ptt_saved_engagement = engagement_state
	_cancel_idle_timer()


func ptt_up() -> void:
	_ptt_active = false
	var saved: String = _ptt_saved_engagement
	_ptt_saved_engagement = ""
	if saved != "" and saved != engagement_state:
		_set_engagement(saved, "PTT released")


# ── Idle Timer ──────────────────────────────────────────────────────────

func _start_idle_timer() -> void:
	_idle_timer.start(ENGAGEMENT_IDLE_TIMEOUT)

func _cancel_idle_timer() -> void:
	_idle_timer.stop()

func _on_idle_timeout() -> void:
	if engagement_state == "ENGAGED" and not _ptt_active:
		_set_engagement("STANDBY", "%.0fs idle timeout" % ENGAGEMENT_IDLE_TIMEOUT)


# ── Audio Utilities ─────────────────────────────────────────────────────

func _pcm_to_wav(pcm: PackedByteArray) -> PackedByteArray:
	var sample_rate: int = 16000
	var channels: int = 1
	var bits_per_sample: int = 16
	var byte_rate: int = sample_rate * channels * bits_per_sample / 8
	var block_align: int = channels * bits_per_sample / 8
	var data_size: int = pcm.size()
	var file_size: int = 36 + data_size

	var wav := PackedByteArray()
	wav.resize(44 + data_size)

	wav[0] = 0x52; wav[1] = 0x49; wav[2] = 0x46; wav[3] = 0x46
	wav.encode_u32(4, file_size)
	wav[8] = 0x57; wav[9] = 0x41; wav[10] = 0x56; wav[11] = 0x45
	wav[12] = 0x66; wav[13] = 0x6D; wav[14] = 0x74; wav[15] = 0x20
	wav.encode_u32(16, 16)
	wav.encode_u16(20, 1)
	wav.encode_u16(22, channels)
	wav.encode_u32(24, sample_rate)
	wav.encode_u32(28, byte_rate)
	wav.encode_u16(32, block_align)
	wav.encode_u16(34, bits_per_sample)
	wav[36] = 0x64; wav[37] = 0x61; wav[38] = 0x74; wav[39] = 0x61
	wav.encode_u32(40, data_size)

	for i in range(data_size):
		wav[44 + i] = pcm[i]

	return wav
