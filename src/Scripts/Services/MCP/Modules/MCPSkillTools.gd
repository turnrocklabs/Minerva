class_name MCPSkillTools
extends MCPToolModule
## MCP tool module for Skill management and Voice tools.
## Combines _register_skill_tools and _register_voice_tools from MinervaMCPServer.


func get_tool_names() -> Array[String]:
	return [
		"minerva_list_skills",
		"minerva_get_skill",
		"minerva_activate_skill",
		"minerva_deactivate_skill",
		"minerva_update_skill_instructions",
		"minerva_speak",
		"minerva_list_voices",
	]


func register_tools() -> void:
	# Skill tools
	server._register_tool("minerva_list_skills",
		"List all defined skills with their active state. Skills inject instructions into the system prompt and optionally register executable tools.",
		{
			"type": "object",
			"properties": {
				"include_profiles": {
					"type": "boolean",
					"description": "Also include tool profiles (default false — only user skills)"
				}
			},
			"required": []
		}
	, "utility")

	server._register_tool("minerva_get_skill",
		"Get full details of a skill including its instructions and executable configuration.",
		{
			"type": "object",
			"properties": {
				"skill_id": {
					"type": "string",
					"description": "The skill ID to retrieve"
				}
			},
			"required": ["skill_id"]
		}
	, "utility")

	server._register_tool("minerva_activate_skill",
		"Activate a skill globally. Active skills inject their instructions into the system prompt and register any executable tools.",
		{
			"type": "object",
			"properties": {
				"skill_id": {
					"type": "string",
					"description": "The skill ID to activate"
				}
			},
			"required": ["skill_id"]
		}
	, "utility")

	server._register_tool("minerva_deactivate_skill",
		"Deactivate a skill globally. Removes its instructions from future prompts and unregisters any executable tools.",
		{
			"type": "object",
			"properties": {
				"skill_id": {
					"type": "string",
					"description": "The skill ID to deactivate"
				}
			},
			"required": ["skill_id"]
		}
	, "utility")

	server._register_tool("minerva_update_skill_instructions",
		"Update the instructions text for a user-created skill. Instructions are markdown injected into the system prompt when the skill is active.",
		{
			"type": "object",
			"properties": {
				"skill_id": {
					"type": "string",
					"description": "The skill ID to update"
				},
				"instructions": {
					"type": "string",
					"description": "New markdown instructions text"
				}
			},
			"required": ["skill_id", "instructions"]
		}
	, "utility")

	# Voice tools
	server._register_tool("minerva_speak",
		"Speak text aloud using text-to-speech. Works regardless of auto-play TTS preference — use this when you want to audibly communicate something to the user. Requires voice-service via Core.",
		{
			"type": "object",
			"properties": {
				"text": {
					"type": "string",
					"description": "The text to speak aloud"
				},
				"voice_id": {
					"type": "string",
					"description": "Optional voice ID (uses preference default if omitted)"
				},
				"backend": {
					"type": "string",
					"description": "Optional TTS backend (kokoro, qwen3-base, etc. — uses preference default if omitted)"
				}
			},
			"required": ["text"]
		}
	, "chat")

	server._register_tool("minerva_list_voices",
		"List available TTS voices from the voice-service. Use this to discover voice IDs for minerva_speak. Optionally filter by backend.",
		{
			"type": "object",
			"properties": {
				"backend": {
					"type": "string",
					"description": "Optional backend filter (kokoro, qwen3-base, qwen3-customvoice, qwen3-voicedesign, gpt-sovits)"
				}
			}
		}
	, "chat")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_list_skills": return _skill_list(arguments)
		"minerva_get_skill": return _skill_get(arguments)
		"minerva_activate_skill": return await _skill_activate(arguments)
		"minerva_deactivate_skill": return _skill_deactivate(arguments)
		"minerva_update_skill_instructions": return _skill_update_instructions(arguments)
		"minerva_speak": return await _speak(arguments)
		"minerva_list_voices": return await _list_voices(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


#region Skill Handlers

func _skill_list(arguments: Dictionary) -> Dictionary:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return {"error": "Skill manager not available", "success": false}

	var include_profiles: bool = arguments.get("include_profiles", false)
	var result: Array[Dictionary] = []

	for skill in skill_manager.skills:
		if not include_profiles and skill.is_profile():
			continue
		result.append({
			"id": skill.id,
			"name": skill.name,
			"description": skill.description,
			"origin": skill.origin,
			"type": "profile" if skill.is_profile() else "skill",
			"active": skill_manager.is_active(skill.id),
			"has_instructions": skill.has_instructions(),
			"has_executable": skill.has_executable(),
		})

	return {"success": true, "skills": result, "count": result.size()}


func _skill_get(arguments: Dictionary) -> Dictionary:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return {"error": "Skill manager not available", "success": false}

	var skill_id: String = arguments.get("skill_id", "")
	if skill_id.is_empty():
		return {"error": "skill_id is required", "success": false}

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		return {"error": "Skill not found: %s" % skill_id, "success": false}

	var data := {
		"success": true,
		"id": skill.id,
		"name": skill.name,
		"description": skill.description,
		"origin": skill.origin,
		"type": "profile" if skill.is_profile() else "skill",
		"active": skill_manager.is_active(skill.id),
		"instructions": skill.instructions,
	}

	if skill.has_executable():
		data["executable"] = {
			"path": skill.executable_path,
			"args": Array(skill.executable_args),
			"description": skill.executable_description,
			"working_dir": skill.executable_working_dir,
		}

	if skill.is_profile():
		data["tool_sets"] = Array(skill.tool_sets)
		data["required_servers"] = Array(skill.required_servers)

	return data


func _skill_activate(arguments: Dictionary) -> Dictionary:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return {"error": "Skill manager not available", "success": false}

	var skill_id: String = arguments.get("skill_id", "")
	if skill_id.is_empty():
		return {"error": "skill_id is required", "success": false}

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		return {"error": "Skill not found: %s" % skill_id, "success": false}

	if skill_manager.is_active(skill_id):
		return {"success": true, "skill_id": skill_id, "message": "Already active"}

	await skill_manager.activate_skill(skill_id, server.mcp_manager)
	return {"success": true, "skill_id": skill_id, "message": "Skill activated: %s" % skill.name}


func _skill_deactivate(arguments: Dictionary) -> Dictionary:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return {"error": "Skill manager not available", "success": false}

	var skill_id: String = arguments.get("skill_id", "")
	if skill_id.is_empty():
		return {"error": "skill_id is required", "success": false}

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		return {"error": "Skill not found: %s" % skill_id, "success": false}

	if not skill_manager.is_active(skill_id):
		return {"success": true, "skill_id": skill_id, "message": "Already inactive"}

	skill_manager.deactivate_skill(skill_id, server.mcp_manager)
	return {"success": true, "skill_id": skill_id, "message": "Skill deactivated: %s" % skill.name}


func _skill_update_instructions(arguments: Dictionary) -> Dictionary:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return {"error": "Skill manager not available", "success": false}

	var skill_id: String = arguments.get("skill_id", "")
	if skill_id.is_empty():
		return {"error": "skill_id is required", "success": false}

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		return {"error": "Skill not found: %s" % skill_id, "success": false}

	if not skill.is_skill():
		return {"error": "Cannot update instructions on a profile (only user skills)", "success": false}

	var instructions: String = arguments.get("instructions", "")
	skill.instructions = instructions
	skill_manager.save_config()

	return {
		"success": true,
		"skill_id": skill_id,
		"message": "Instructions updated for: %s" % skill.name,
		"instructions_length": instructions.length(),
	}

#endregion


#region Voice Handlers

func _speak(arguments: Dictionary) -> Dictionary:
	var text: String = arguments.get("text", "")
	if text.is_empty():
		return {"error": "text is required", "success": false}

	if not Core.client._connected:
		return {"error": "Core not connected — cannot use voice-service", "success": false}

	var cfg := SingletonObject.get_voice_config()
	var voice_id: String = arguments.get("voice_id", "")
	if voice_id.is_empty():
		voice_id = cfg.voice_id
	var backend: String = arguments.get("backend", "")
	if backend.is_empty():
		backend = cfg.tts_backend

	var client := SingletonObject.get_voice_client()
	var wav_data: PackedByteArray = await client.synthesize(text, voice_id, backend)

	if wav_data.is_empty():
		return {"error": "TTS synthesis failed", "success": false}

	# Play via the ChatPane TTS player if available
	var chats = SingletonObject.Chats
	if chats and chats._tts_player:
		var stream := AudioStreamWAV.new()
		chats._load_wav_into_stream(stream, wav_data)
		chats._tts_player.stream = stream
		chats._tts_player.volume_db = linear_to_db(cfg.tts_volume)
		chats._tts_player.play()
	else:
		push_warning("[MCPSkillTools] No TTS player available for minerva_speak")
		return {"error": "No audio player available", "success": false}

	return {
		"success": true,
		"message": "Speaking: %s" % text.substr(0, 100),
		"text_length": text.length(),
		"voice_id": voice_id,
		"backend": backend,
	}


func _list_voices(arguments: Dictionary) -> Dictionary:
	if not Core.client._connected:
		return {"error": "Core not connected — cannot query voice-service", "success": false}

	var backend: String = arguments.get("backend", "")
	var client := SingletonObject.get_voice_client()
	var voices: Array = await client.list_voices(backend)

	if voices.is_empty():
		return {"voices": [], "count": 0, "message": "No voices available (voice-service may not be running)", "success": true}

	return {"voices": voices, "count": voices.size(), "success": true}

#endregion
