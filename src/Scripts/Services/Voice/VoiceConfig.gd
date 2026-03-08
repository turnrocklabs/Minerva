class_name VoiceConfig
extends RefCounted
## Persists voice preferences (STT/TTS provider, voice selection, audio settings).

enum STTProvider { VOICE_SERVICE, OPENAI_WHISPER }
enum TTSProvider { VOICE_SERVICE, NONE }
enum SpeakMode { OFF, FULL, SUMMARIZE }

## Current STT provider selection
var stt_provider: STTProvider = STTProvider.VOICE_SERVICE

## STT backend for voice-service (e.g. "faster-whisper", "qwen3-asr")
var stt_backend: String = "faster-whisper"

## Current TTS provider selection
var tts_provider: TTSProvider = TTSProvider.VOICE_SERVICE

## Selected voice ID for TTS (from voice/voices/list)
var voice_id: String = ""

## Selected voice display name (for UI)
var voice_name: String = ""

## TTS backend filter (e.g. "kokoro", "qwen3-base", or "" for all)
var tts_backend: String = "kokoro"

## How to handle auto-speaking responses: OFF, FULL (speak entire response), SUMMARIZE (summarize then speak)
var speak_mode: SpeakMode = SpeakMode.OFF

## Model name for summarization (action name from model-chat service, e.g. "gemma3:12b")
var summary_model: String = ""

## Timeout for summarization requests (seconds)
var summary_timeout: float = 30.0

## TTS playback volume (linear 0.0–1.0)
var tts_volume: float = 1.0

## Auto-send transcription (vs letting user edit first)
var auto_send_transcription: bool = false

## Fallback to OpenAI Whisper when Core disconnected (only relevant when stt_provider == VOICE_SERVICE)
var whisper_fallback: bool = true


func save() -> void:
	SingletonObject.save_to_config_file("Voice", "stt_provider", stt_provider)
	SingletonObject.save_to_config_file("Voice", "stt_backend", stt_backend)
	SingletonObject.save_to_config_file("Voice", "tts_provider", tts_provider)
	SingletonObject.save_to_config_file("Voice", "voice_id", voice_id)
	SingletonObject.save_to_config_file("Voice", "voice_name", voice_name)
	SingletonObject.save_to_config_file("Voice", "tts_backend", tts_backend)
	SingletonObject.save_to_config_file("Voice", "speak_mode", speak_mode)
	SingletonObject.save_to_config_file("Voice", "summary_model", summary_model)
	SingletonObject.save_to_config_file("Voice", "summary_timeout", summary_timeout)
	SingletonObject.save_to_config_file("Voice", "tts_volume", tts_volume)
	SingletonObject.save_to_config_file("Voice", "auto_send_transcription", auto_send_transcription)
	SingletonObject.save_to_config_file("Voice", "whisper_fallback", whisper_fallback)


func load_from_config() -> void:
	if not SingletonObject.config_has_saved_section("Voice"):
		return

	stt_provider = SingletonObject.config_file.get_value("Voice", "stt_provider", STTProvider.VOICE_SERVICE)
	stt_backend = SingletonObject.config_file.get_value("Voice", "stt_backend", "faster-whisper")
	tts_provider = SingletonObject.config_file.get_value("Voice", "tts_provider", TTSProvider.VOICE_SERVICE)
	voice_id = SingletonObject.config_file.get_value("Voice", "voice_id", "")
	voice_name = SingletonObject.config_file.get_value("Voice", "voice_name", "")
	tts_backend = SingletonObject.config_file.get_value("Voice", "tts_backend", "kokoro")
	tts_volume = SingletonObject.config_file.get_value("Voice", "tts_volume", 1.0)
	auto_send_transcription = SingletonObject.config_file.get_value("Voice", "auto_send_transcription", false)
	whisper_fallback = SingletonObject.config_file.get_value("Voice", "whisper_fallback", true)
	summary_model = SingletonObject.config_file.get_value("Voice", "summary_model", "")
	summary_timeout = SingletonObject.config_file.get_value("Voice", "summary_timeout", 30.0)

	# Migrate from old auto_play_tts boolean to speak_mode enum
	if SingletonObject.config_file.has_section_key("Voice", "speak_mode"):
		speak_mode = SingletonObject.config_file.get_value("Voice", "speak_mode", SpeakMode.OFF)
	elif SingletonObject.config_file.has_section_key("Voice", "auto_play_tts"):
		var old_auto_play: bool = SingletonObject.config_file.get_value("Voice", "auto_play_tts", false)
		speak_mode = SpeakMode.FULL if old_auto_play else SpeakMode.OFF


## Get the effective STT provider considering Core connection state
func get_effective_stt_provider() -> STTProvider:
	if stt_provider == STTProvider.VOICE_SERVICE:
		if not Core.client._connected and whisper_fallback:
			return STTProvider.OPENAI_WHISPER
	return stt_provider


## Get the effective TTS provider considering Core connection state
func get_effective_tts_provider() -> TTSProvider:
	if tts_provider == TTSProvider.VOICE_SERVICE:
		if not Core.client._connected:
			return TTSProvider.NONE
	return tts_provider
