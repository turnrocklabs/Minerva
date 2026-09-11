class_name VoiceSelection
extends RefCounted
## Stable voice names take precedence over ephemeral server IDs; no first-row fallback.

static func resolve(voices: Array, name: String, id: String, backend: String) -> Dictionary:
	var matches: Array[Dictionary] = []
	for value: Variant in voices:
		if not value is Dictionary:
			continue
		if (not name.is_empty() and value.get("name") == name) or (name.is_empty() and not id.is_empty() and value.get("id") == id):
			matches.append(value)
	if matches.size() != 1:
		var reason := "voice_ambiguous" if matches.size() > 1 else "voice_unavailable"
		return {"success": false, "error_code": reason, "error_message": "Saved voice is ambiguous." if matches.size() > 1 else "Saved voice is unavailable in this inventory."}
	var selected: Dictionary = matches[0]
	if selected.has("available_backends"):
		if not selected.available_backends is Array:
			return {"success": false, "error_code": "invalid_voice_metadata", "error_message": "Voice backend metadata is malformed."}
		if not backend.is_empty() and backend not in selected.available_backends:
			return {"success": false, "error_code": "voice_backend_unavailable", "error_message": "Selected voice does not advertise backend '%s'." % backend}
	return {"success": true, "voice": selected, "metadata_mode": "advertised" if selected.has("available_backends") else "legacy"}

static func describe(voice: Dictionary) -> String:
	var details: Array[String] = []
	for key in ["backend_family", "voice_type", "latency_class", "quality_class", "available_backends", "capabilities"]:
		if voice.has(key):
			details.append("%s: %s" % [key, str(voice[key])])
	return "\n".join(details) if not details.is_empty() else "Legacy voice metadata; the configured backend is retained."

static func populate(selector: OptionButton, voices: Array, config: VoiceConfig) -> Dictionary:
	selector.clear()
	var selection := resolve(voices, config.voice_name, config.voice_id, config.tts_backend)
	var selected := -1
	for voice: Dictionary in voices:
		var label: String = voice.get("name", voice.get("id", "unknown"))
		if not str(voice.get("backend_family", "")).is_empty():
			label += " (%s)" % str(voice.backend_family)
		selector.add_item(label)
		var index := selector.item_count - 1
		selector.set_item_metadata(index, voice)
		selector.set_item_tooltip(index, describe(voice))
		var usable := resolve(voices, str(voice.get("name", "")), str(voice.get("id", "")), config.tts_backend)
		if not usable.success:
			selector.set_item_disabled(index, true)
			selector.set_item_tooltip(index, usable.error_message)
		if selection.success and selection.voice == voice:
			selected = index
	if selected < 0:
		var saved := config.voice_name if not config.voice_name.is_empty() else config.voice_id
		selector.add_item("Unavailable: %s" % saved if not saved.is_empty() else "Select a voice")
		selected = selector.item_count - 1
		selector.set_item_disabled(selected, true)
		selector.set_item_tooltip(selected, selection.error_message)
	selector.select(selected)
	selector.disabled = voices.is_empty()
	return selection

static func show_saved_option(selector: OptionButton, value: String, known: Dictionary) -> void:
	while selector.item_count > known.size():
		selector.remove_item(selector.item_count - 1)
	if known.has(value):
		selector.select(known[value])
	else:
		selector.add_item("%s (saved legacy choice)" % value)
		selector.set_item_disabled(selector.item_count - 1, true)
		selector.select(selector.item_count - 1)
