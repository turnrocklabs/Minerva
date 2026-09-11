extends VoiceServiceClient
## Keep the paid HTTP fallback outside local contract tests.
var whisper_calls := 0

func transcribe_whisper_result(_audio: PackedByteArray) -> Dictionary:
	whisper_calls += 1
	return {"success": true, "text": "fallback"}
