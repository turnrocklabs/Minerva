class_name NudgeMCPClient
extends RefCounted
## Specialized client for the Nudge MCP server.
## Provides Godot-friendly API for nudge hint operations.
## Uses MCPManager for proper MCP protocol communication.

## Default component name for Minerva notes
const DEFAULT_COMPONENT := "minerva-notes"

## Reference to the MCP manager
var _mcp_manager = null


func _init(mcp_manager = null) -> void:
	_mcp_manager = mcp_manager


## Get the MCP manager, lazily loading from singleton if needed
func _get_manager():
	if _mcp_manager:
		return _mcp_manager
	# Try to get from singleton
	if SingletonObject and SingletonObject.mcp_manager:
		_mcp_manager = SingletonObject.mcp_manager
	return _mcp_manager


## Check if Nudge server is connected
func is_nudge_connected() -> bool:
	var manager = _get_manager()
	if not manager:
		return false
	return manager.is_server_connected("nudge")


## Execute a Nudge tool via MCPManager
func _call_nudge(tool_name: String, params: Dictionary) -> Dictionary:
	var manager = _get_manager()
	if not manager:
		return {"error": "MCP manager not available", "success": false}

	if not manager.is_server_connected("nudge"):
		return {"error": "Nudge server not connected", "success": false}

	return await manager.execute_tool(tool_name, params)


## Set a hint in the Nudge store
func set_hint(component: String, key: String, value, meta: Dictionary = {}) -> Dictionary:
	var args := {
		"component": component,
		"key": key,
		"value": value
	}
	if not meta.is_empty():
		args["meta"] = meta

	return await _call_nudge("nudge_set_hint", args)


## Get a hint from the Nudge store
func get_hint(component: String, key: String, context: Dictionary = {}) -> Dictionary:
	var args := {
		"component": component,
		"key": key
	}
	if not context.is_empty():
		args["context"] = context

	return await _call_nudge("nudge_get_hint", args)


## Query hints matching criteria
func query(params: Dictionary = {}) -> Dictionary:
	return await _call_nudge("nudge_query", params)


## Delete a hint from the store
func delete_hint(component: String, key: String) -> Dictionary:
	return await _call_nudge("nudge_delete_hint", {
		"component": component,
		"key": key
	})


## List all components with hint counts
func list_components() -> Dictionary:
	return await _call_nudge("nudge_list_components", {})


## Bump frecency counter for a hint
func bump(component: String, key: String, delta: int = 1) -> Dictionary:
	return await _call_nudge("nudge_bump", {
		"component": component,
		"key": key,
		"delta": delta
	})


## Export all hints (or subset)
func export_hints(format: String = "json") -> Dictionary:
	return await _call_nudge("nudge_export", {
		"format": format
	})


## Import hints from a payload
func import_hints(payload: Dictionary, mode: String = "merge") -> Dictionary:
	return await _call_nudge("nudge_import", {
		"payload": payload,
		"mode": mode
	})


# ============================================
# Blob API methods
# ============================================

## Upload a binary blob (base64 encoded)
func blob_upload(data: String, filename: String, content_type: String = "", scope: String = "global") -> Dictionary:
	var args := {
		"data": data,
		"filename": filename,
		"scope": scope
	}
	if not content_type.is_empty():
		args["content_type"] = content_type
	return await _call_nudge("nudge_blob_upload", args)


## Download a blob (returns base64 encoded data)
func blob_download(blob_id: String) -> Dictionary:
	return await _call_nudge("nudge_blob_download", {"blob_id": blob_id})


## List all blobs with metadata
func blob_list(scope: String = "all") -> Dictionary:
	return await _call_nudge("nudge_blob_list", {"scope": scope})


## Delete a blob
func blob_delete(blob_id: String) -> Dictionary:
	return await _call_nudge("nudge_blob_delete", {"blob_id": blob_id})


## Get blob metadata without downloading
func blob_info(blob_id: String) -> Dictionary:
	return await _call_nudge("nudge_blob_info", {"blob_id": blob_id})


# ============================================
# Note-specific convenience methods
# ============================================

## Push a single note to Nudge (legacy format with wrapped data)
func push_note(note, component: String = DEFAULT_COMPONENT) -> Dictionary:
	var note_data := {
		"title": note.title,
		"content": _get_note_content(note),
		"type": note.type,
		"enabled": note.enabled
	}

	var meta := {
		"tags": ["minerva-note"],
		"source": "minerva",
		"ttl": "persistent"
	}

	return await set_hint(component, note.uuid, note_data, meta)


## Push a note using new mapping: title→key, content→value
## Preserves original nudge metadata if available for round-trip
## For binary notes (image/audio), uploads blob and stores reference
func push_note_simple(note, component: String = DEFAULT_COMPONENT) -> Dictionary:
	var key: String = note.title
	var value  # Can be String or Dictionary for blob references

	# Check for stored nudge hint metadata (for round-trip preservation)
	var meta: Dictionary = {}
	if note.has_meta("nudge_hint"):
		var stored_hint: Dictionary = note.get_meta("nudge_hint")
		meta = stored_hint.get("meta", {})

	# Handle different note types
	match note.type:
		0:  # TEXT
			value = _get_note_content(note)
			if meta.is_empty():
				meta = {"source": "minerva", "ttl": "persistent", "note_type": "text"}
			else:
				meta["note_type"] = "text"

		1:  # IMAGE
			var blob_result = await _upload_image_blob(note, key)
			if blob_result.get("error"):
				return blob_result
			value = blob_result.get("value")
			if meta.is_empty():
				meta = {"source": "minerva", "ttl": "persistent", "note_type": "image"}
			else:
				meta["note_type"] = "image"

		3:  # AUDIO
			var blob_result = await _upload_audio_blob(note, key)
			if blob_result.get("error"):
				return blob_result
			value = blob_result.get("value")
			if meta.is_empty():
				meta = {"source": "minerva", "ttl": "persistent", "note_type": "audio"}
			else:
				meta["note_type"] = "audio"

		_:  # Unsupported types (VIDEO, etc.)
			value = "[Unsupported content type: %s]" % note.type
			if meta.is_empty():
				meta = {"source": "minerva", "ttl": "persistent", "note_type": "unsupported"}

	return await set_hint(component, key, value, meta)


## Upload image note content as blob, return value dict with blob reference
func _upload_image_blob(note, key: String) -> Dictionary:
	if not note.has_method("get_controls_container"):
		return {"error": "Note has no controls container"}

	var controls = note.get_controls_container()
	if not controls or not "image" in controls:
		return {"error": "No image in note controls"}

	var image: Image = controls.image
	if not image:
		return {"error": "Image is null"}

	# Encode image as PNG and base64
	var png_data: PackedByteArray = image.save_png_to_buffer()
	var base64_data: String = Marshalls.raw_to_base64(png_data)

	# Upload blob
	var filename := "%s.png" % key
	var result = await blob_upload(base64_data, filename, "image/png")

	if result.get("error"):
		return {"error": "Blob upload failed: %s" % result.get("error")}

	var blob_id: String = result.get("blob_id", "")
	if blob_id.is_empty():
		return {"error": "No blob_id returned from upload"}

	# Return value structure with blob reference
	return {
		"value": {
			"blob_id": blob_id,
			"content_type": "image/png",
			"caption": controls.caption if "caption" in controls else ""
		}
	}


## Upload audio note content as blob, return value dict with blob reference
func _upload_audio_blob(note, key: String) -> Dictionary:
	if not note.has_method("get_controls_container"):
		return {"error": "Note has no controls container"}

	var controls = note.get_controls_container()
	if not controls or not "audio" in controls:
		return {"error": "No audio in note controls"}

	var audio: AudioStream = controls.audio
	if not audio:
		return {"error": "Audio is null"}

	# Get audio data and determine format
	var audio_data: PackedByteArray
	var content_type: String
	var extension: String

	if audio is AudioStreamMP3:
		audio_data = audio.data
		content_type = "audio/mpeg"
		extension = "mp3"
	elif audio is AudioStreamOggVorbis:
		# OggVorbis doesn't expose raw data easily, try to get it
		if "data" in audio:
			audio_data = audio.data
		content_type = "audio/ogg"
		extension = "ogg"
	elif audio is AudioStreamWAV:
		audio_data = audio.data
		content_type = "audio/wav"
		extension = "wav"
	else:
		return {"error": "Unsupported audio format: %s" % audio.get_class()}

	if audio_data.is_empty():
		return {"error": "Audio data is empty"}

	var base64_data: String = Marshalls.raw_to_base64(audio_data)

	# Upload blob
	var filename := "%s.%s" % [key, extension]
	var result = await blob_upload(base64_data, filename, content_type)

	if result.get("error"):
		return {"error": "Blob upload failed: %s" % result.get("error")}

	var blob_id: String = result.get("blob_id", "")
	if blob_id.is_empty():
		return {"error": "No blob_id returned from upload"}

	# Return value structure with blob reference
	return {
		"value": {
			"blob_id": blob_id,
			"content_type": content_type
		}
	}


## Pull a note from Nudge by UUID
func pull_note(uuid: String, component: String = DEFAULT_COMPONENT) -> Dictionary:
	return await get_hint(component, uuid)


## Pull all notes for a component (minerva-note tagged only)
func pull_all_notes(component: String = DEFAULT_COMPONENT) -> Dictionary:
	return await query({
		"component": component,
		"tags": ["minerva-note"]
	})


## Pull all hints from nudge (no filtering - for cross-tool collaboration)
func pull_all_hints(limit: int = 100) -> Dictionary:
	return await query({
		"limit": limit
	})


## Delete a note from Nudge
func delete_note(uuid: String, component: String = DEFAULT_COMPONENT) -> Dictionary:
	return await delete_hint(component, uuid)


## Get content from a note based on its type
func _get_note_content(note) -> String:
	match note.type:
		0:  # TEXT
			# Use get_controls_container() which returns NoteTextControls
			if note.has_method("get_controls_container"):
				var controls = note.get_controls_container()
				if controls and "content" in controls:
					return controls.content
			return ""
		_:
			# For non-text types, we can't easily serialize
			return "[Non-text content: type %s]" % note.type
