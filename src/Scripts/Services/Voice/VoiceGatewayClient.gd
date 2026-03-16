class_name VoiceGatewayClient
extends Node
## Connects to the local voice gateway container via WebSocket.
## Streams mic audio, receives wake word + VAD events.
## Manages STANDBY/ENGAGED state machine.
##
## T2: State machine  T3: Always-listening  T4: Barge-in
## T5: playback_finished  T6: Dismiss/timeout/PTT

signal engagement_changed(state: String)  # "STANDBY" or "ENGAGED"
signal vad_started()
signal vad_ended()
signal wake_word_detected(confidence: float)
signal transcription_ready(audio_wav: PackedByteArray)  # VAD-endpointed audio ready for STT
signal connected_to_gateway()
signal disconnected_from_gateway()

const GATEWAY_URL := "ws://localhost:8090/audio"
const ENGAGEMENT_IDLE_TIMEOUT := 20.0  # seconds after TTS ends before STANDBY
const PRE_VAD_BUFFER_MAX_BYTES := 32000  # ~1 second at 16kHz s16le

## Current engagement state
var engagement_state: String = "STANDBY"

## WebSocket connection
var _ws: WebSocketPeer = null
var _connected := false

## Audio capture
var _mic_player: AudioStreamPlayer = null
var _record_effect: AudioEffectRecord = null
var _capture_timer: Timer = null  # polls mic data at ~60Hz

## Recording state
var _recording := false
var _audio_buffer: PackedByteArray = PackedByteArray()
var _pre_vad_buffer: Array[PackedByteArray] = []
var _vad_active := false

## TTS playback tracking (for barge-in)
var _tts_playing := false

## Idle timer
var _idle_timer: Timer = null

## PTT state
var _ptt_active := false
var _ptt_saved_engagement: String = ""

## Reconnection
var _reconnect_timer: Timer = null
var _should_connect := false


func _ready() -> void:
	# Mic capture timer (polls audio data)
	_capture_timer = Timer.new()
	_capture_timer.wait_time = 0.016  # ~60Hz
	_capture_timer.timeout.connect(_on_capture_tick)
	add_child(_capture_timer)

	# Engagement idle timer
	_idle_timer = Timer.new()
	_idle_timer.one_shot = true
	_idle_timer.wait_time = ENGAGEMENT_IDLE_TIMEOUT
	_idle_timer.timeout.connect(_on_idle_timeout)
	add_child(_idle_timer)

	# Reconnection timer
	_reconnect_timer = Timer.new()
	_reconnect_timer.wait_time = 3.0
	_reconnect_timer.timeout.connect(_try_connect)
	add_child(_reconnect_timer)

	# Setup mic capture on "Rec" bus
	var rec_idx: int = AudioServer.get_bus_index("Rec")
	if rec_idx >= 0 and AudioServer.get_bus_effect_count(rec_idx) > 0:
		_record_effect = AudioServer.get_bus_effect(rec_idx, 0) as AudioEffectRecord


func _process(_delta: float) -> void:
	if _ws:
		_ws.poll()
		var state: int = _ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			if not _connected:
				_connected = true
				connected_to_gateway.emit()
				print("[VoiceGateway] Connected")
			# Read incoming messages
			while _ws.get_available_packet_count() > 0:
				var packet: PackedByteArray = _ws.get_packet()
				_handle_gateway_message(packet)
		elif state == WebSocketPeer.STATE_CLOSED:
			if _connected:
				_connected = false
				disconnected_from_gateway.emit()
				print("[VoiceGateway] Disconnected")
			_ws = null
			if _should_connect and not _reconnect_timer.is_stopped():
				_reconnect_timer.start()


# ── Connection ──────────────────────────────────────────────────────────

func start() -> void:
	"""Start the gateway client. Connects to container and begins mic capture."""
	_should_connect = true
	_try_connect()
	_start_mic_capture()
	_capture_timer.start()


func stop() -> void:
	"""Stop the gateway client."""
	_should_connect = false
	_capture_timer.stop()
	_stop_mic_capture()
	_reconnect_timer.stop()
	if _ws:
		_ws.close()
		_ws = null
	_connected = false


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
	_mic_player.bus = &"Rec"
	_mic_player.stream = AudioStreamMicrophone.new()
	add_child(_mic_player)
	_mic_player.play()
	if _record_effect:
		_record_effect.set_recording_active(true)


func _stop_mic_capture() -> void:
	if _record_effect:
		_record_effect.set_recording_active(false)
	if _mic_player:
		_mic_player.stop()
		_mic_player.queue_free()
		_mic_player = null


func _on_capture_tick() -> void:
	"""Called ~60Hz. Grabs mic audio and sends to gateway."""
	if not _connected or not _record_effect:
		return
	if not _record_effect.is_recording_active():
		return

	# Get recorded audio as WAV, extract PCM
	var recording: AudioStreamWAV = _record_effect.get_recording()
	if not recording:
		return

	# Restart recording for next chunk
	_record_effect.set_recording_active(false)
	_record_effect.set_recording_active(true)

	var pcm: PackedByteArray = recording.data
	if pcm.is_empty():
		return

	# Send to gateway for wake word + VAD processing
	_ws.send(pcm, WebSocketPeer.WRITE_MODE_BINARY)

	# Manage pre-VAD buffer (always keep last ~1s)
	_pre_vad_buffer.append(pcm)
	var total_size: int = 0
	for chunk in _pre_vad_buffer:
		total_size += chunk.size()
	while total_size > PRE_VAD_BUFFER_MAX_BYTES and _pre_vad_buffer.size() > 1:
		total_size -= _pre_vad_buffer[0].size()
		_pre_vad_buffer.remove_at(0)

	# If recording (ENGAGED + VAD active), accumulate audio
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
		# T4: Barge-in during TTS playback
		print("[VoiceGateway] Wake word during playback (%.3f) — barge-in" % confidence)
		_set_engagement("ENGAGED", "wake word barge-in")
		_cancel_idle_timer()
		# Clear pre-VAD buffer (contains the wake word, not a command)
		_pre_vad_buffer.clear()
		return

	if engagement_state == "STANDBY":
		# T2: STANDBY → ENGAGED
		print("[VoiceGateway] Wake word in STANDBY (%.3f) — engaging" % confidence)
		_set_engagement("ENGAGED", "wake word")
		_cancel_idle_timer()
		# Clear pre-VAD buffer (contains "Minerva", not a command)
		_pre_vad_buffer.clear()


func _handle_vad_start() -> void:
	_vad_active = true
	vad_started.emit()

	if not is_engaged_or_ptt():
		return  # STANDBY: ignore speech

	if _tts_playing:
		return  # Don't record while TTS plays

	# T3: Start recording with pre-VAD buffer
	if not _recording:
		_recording = true
		_audio_buffer = PackedByteArray()
		# Prepend pre-VAD buffer to capture speech onset
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

		if _audio_buffer.size() > 1600:  # At least 50ms of audio
			# T6: Check for dismiss phrase after STT
			# Package as WAV and emit for STT processing
			var wav: PackedByteArray = _pcm_to_wav(_audio_buffer)
			transcription_ready.emit(wav)

		_audio_buffer = PackedByteArray()


# ── Engagement State Machine (T2, T6) ──────────────────────────────────

func is_engaged_or_ptt() -> bool:
	return engagement_state == "ENGAGED" or _ptt_active


func _set_engagement(new_state: String, reason: String = "") -> void:
	if engagement_state == new_state:
		return
	var old: String = engagement_state
	engagement_state = new_state
	print("[VoiceGateway] %s → %s (%s)" % [old, new_state, reason])
	engagement_changed.emit(new_state)


## T6: "stop listening" check — call after STT returns text
func check_dismiss_phrase(text: String) -> bool:
	var clean: String = text.strip_edges().to_lower().rstrip(".!,")
	if clean in ["stop listening", "stop listen"]:
		_set_engagement("STANDBY", "user said 'stop listening'")
		_cancel_idle_timer()
		return true
	return false


## T5: Call when TTS playback starts
func notify_tts_started() -> void:
	_tts_playing = true
	_cancel_idle_timer()


## T5: Call when TTS playback finishes
func notify_tts_finished() -> void:
	_tts_playing = false
	# Start idle timer if ENGAGED
	if engagement_state == "ENGAGED":
		_start_idle_timer()


## T6: PTT override
func ptt_down() -> void:
	_ptt_active = true
	_ptt_saved_engagement = engagement_state
	_cancel_idle_timer()


## T6: PTT release — restore previous engagement state
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
	"""Wrap raw PCM s16le mono 16kHz in a WAV header."""
	var sample_rate: int = 16000
	var channels: int = 1
	var bits_per_sample: int = 16
	var byte_rate: int = sample_rate * channels * bits_per_sample / 8
	var block_align: int = channels * bits_per_sample / 8
	var data_size: int = pcm.size()
	var file_size: int = 36 + data_size

	var wav := PackedByteArray()
	wav.resize(44 + data_size)

	# RIFF header
	wav[0] = 0x52; wav[1] = 0x49; wav[2] = 0x46; wav[3] = 0x46  # "RIFF"
	wav.encode_u32(4, file_size)
	wav[8] = 0x57; wav[9] = 0x41; wav[10] = 0x56; wav[11] = 0x45  # "WAVE"

	# fmt chunk
	wav[12] = 0x66; wav[13] = 0x6D; wav[14] = 0x74; wav[15] = 0x20  # "fmt "
	wav.encode_u32(16, 16)  # chunk size
	wav.encode_u16(20, 1)  # PCM format
	wav.encode_u16(22, channels)
	wav.encode_u32(24, sample_rate)
	wav.encode_u32(28, byte_rate)
	wav.encode_u16(32, block_align)
	wav.encode_u16(34, bits_per_sample)

	# data chunk
	wav[36] = 0x64; wav[37] = 0x61; wav[38] = 0x74; wav[39] = 0x61  # "data"
	wav.encode_u32(40, data_size)

	# PCM data
	for i in range(data_size):
		wav[44 + i] = pcm[i]

	return wav
