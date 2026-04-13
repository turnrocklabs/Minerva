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
	# Skill tools — these are PROTECTED (always available, never pruned)
	var list_desc := "List available skills (lean: name + description only). Skills provide step-by-step instructions — load before starting unfamiliar work. Key categories: tool-usage (efficient tool patterns), tool-suite (docket, cobrowser, terminal guides — load before first use of a suite), agent-supervision (decompose work, spawn sub-agents, coordinate). Use query/tags to filter. Call minerva_get_skill to load full instructions."
	var list_schema := {
		"type": "object",
		"properties": {
			"query": {
				"type": "string",
				"description": "Text search across skill titles and descriptions"
			},
			"tags": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Filter by tags (e.g. 'tool-suite', 'agent-supervision', 'tool-usage')"
			},
			"include_profiles": {
				"type": "boolean",
				"description": "Also include tool profiles (default false)"
			}
		},
	}
	server._register_tool("minerva_list_skills", list_desc, list_schema, "utility")
	server.tool_budget_manager.activate_tool("minerva_list_skills", {"name": "minerva_list_skills", "description": list_desc, "input_schema": list_schema})

	var get_desc := "Get full skill details: step-by-step instructions, preconditions, and expected outcome. Use skill_id from minerva_list_skills, or search by title. Searches across all loaded docket projects."
	var get_schema := {
		"type": "object",
		"properties": {
			"skill_id": {
				"type": "string",
				"description": "The skill ID to retrieve (from minerva_list_skills)"
			},
			"title": {
				"type": "string",
				"description": "Search by skill title (alternative to skill_id)"
			},
			"project": {
				"type": "string",
				"description": "Docket project name hint (optional — searches all projects if omitted)"
			}
		},
	}
	server._register_tool("minerva_get_skill", get_desc, get_schema, "utility")
	server.tool_budget_manager.activate_tool("minerva_get_skill", {"name": "minerva_get_skill", "description": get_desc, "input_schema": get_schema})

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


## Resolve a list of skill names/IDs into their tool dependencies and instructions.
## Searches both SkillManager (minerva) and DocketManager (docket) for each skill.
## Returns: {"tools": Array[String], "instructions": String}
## - tools: deduplicated union of tool_deps from all matched skills
## - instructions: concatenated skill instructions separated by headers
func resolve_skills(skill_names: Array[String]) -> Dictionary:
	var all_tools: Array[String] = []
	var all_instructions: Array[String] = []

	var skill_manager = SingletonObject.get_skill_manager()
	var dm: DocketManager = SingletonObject.docket_manager

	for skill_name in skill_names:
		var skill_name_str: String = str(skill_name)
		var found: bool = false

		# Try docket first (search all loaded projects by ID then title)
		if dm:
			for proj_name in dm.get_loaded_projects():
				# Try by id
				var by_id := dm.call_tool("docket_skill_get", {"project": proj_name, "id": skill_name_str})
				if not by_id.has("error"):
					var deps: Array = by_id.get("tool_deps", [])
					for dep in deps:
						var dep_str: String = str(dep)
						if dep_str not in all_tools:
							all_tools.append(dep_str)
					var steps: String = str(by_id.get("steps", ""))
					var title: String = str(by_id.get("title", skill_name_str))
					if not steps.is_empty():
						all_instructions.append("## Skill: %s\n\n%s" % [title, steps])
					found = true
					break
				# Try by title
				var by_title := dm.call_tool("docket_skill_get", {"project": proj_name, "title": skill_name_str})
				if not by_title.has("error"):
					var deps: Array = by_title.get("tool_deps", [])
					for dep in deps:
						var dep_str: String = str(dep)
						if dep_str not in all_tools:
							all_tools.append(dep_str)
					var steps: String = str(by_title.get("steps", ""))
					var title: String = str(by_title.get("title", skill_name_str))
					if not steps.is_empty():
						all_instructions.append("## Skill: %s\n\n%s" % [title, steps])
					found = true
					break
			if found:
				continue

		# Fall back to SkillManager (note-based skills)
		if skill_manager:
			var skill = skill_manager.get_skill(skill_name_str)
			if skill:
				var deps: Array = skill.tool_deps if "tool_deps" in skill else []
				for dep in deps:
					var dep_str: String = str(dep)
					if dep_str not in all_tools:
						all_tools.append(dep_str)
				if not skill.instructions.is_empty():
					all_instructions.append("## Skill: %s\n\n%s" % [skill.name, skill.instructions])
				found = true

		if not found:
			push_warning("[MCPSkillTools] resolve_skills: skill not found: %s" % skill_name_str)

	return {
		"tools": all_tools,
		"instructions": "\n\n".join(all_instructions),
	}


#region Skill Handlers

func _skill_list(arguments: Dictionary) -> Dictionary:
	var query_text: String = str(arguments.get("query", "")).to_lower()
	var filter_tags: Array = arguments.get("tags", [])
	var result: Array[Dictionary] = []

	# Minerva SkillManager skills (note-based)
	var skill_manager = SingletonObject.get_skill_manager()
	if skill_manager:
		var include_profiles: bool = arguments.get("include_profiles", false)
		for skill in skill_manager.skills:
			if not include_profiles and skill.is_profile():
				continue
			var entry := {
				"id": skill.id,
				"name": skill.name,
				"description": skill.description,
				"origin": "minerva",
			}
			if _matches_filters(entry, query_text, filter_tags):
				result.append(entry)

	# Docket skills — search ALL loaded projects
	var dm: DocketManager = SingletonObject.docket_manager
	if dm:
		for proj_name in dm.get_loaded_projects():
			# Don't pass query/tags to docket — let it return all skills so we
			# can filter once locally via _matches_filters() for consistency.
			var docket_args := {"project": proj_name}
			var docket_result := dm.call_tool("docket_skill_list", docket_args)
			if not docket_result.has("error") and docket_result.has("skills"):
				for dskill in docket_result["skills"]:
					var entry := {
						"id": str(dskill.get("id", "")),
						"name": str(dskill.get("title", "")),
						"description": str(dskill.get("description", "")),
						"origin": "docket",
						"project": proj_name,
					}
					if _matches_filters(entry, query_text, filter_tags):
						result.append(entry)

	# If filtered search returned nothing, fall back to full catalog
	if result.is_empty() and (not query_text.is_empty() or not filter_tags.is_empty()):
		return _skill_list({})  # Recurse with no filters — return everything

	return {"success": true, "skills": result, "count": result.size()}


func _matches_filters(entry: Dictionary, query_text: String, filter_tags: Array) -> bool:
	# Text search on name + description
	if not query_text.is_empty():
		var name_lower: String = str(entry.get("name", "")).to_lower()
		var desc_lower: String = str(entry.get("description", "")).to_lower()
		if not name_lower.contains(query_text) and not desc_lower.contains(query_text):
			return false
	# Tag filtering (if we have tags on the entry)
	if not filter_tags.is_empty() and entry.has("tags"):
		var entry_tags: Array = entry.get("tags", [])
		for required_tag in filter_tags:
			if str(required_tag) not in entry_tags:
				return false
	return true


func _skill_get(arguments: Dictionary) -> Dictionary:
	var skill_id: String = arguments.get("skill_id", "")
	var title: String = arguments.get("title", "")
	var project_hint: String = arguments.get("project", "")

	if skill_id.is_empty() and title.is_empty():
		return MCPToolUtils.error("skill_id or title is required")

	# Search docket projects for the skill
	var dm: DocketManager = SingletonObject.docket_manager
	if dm and (not title.is_empty() or (not skill_id.is_empty() and skill_id.length() >= 7)):
		# If project hint given, search that project first
		var projects_to_search: Array[String] = []
		if not project_hint.is_empty():
			projects_to_search.append(project_hint)
		# Then search all loaded projects
		for pname in dm.get_loaded_projects():
			if pname not in projects_to_search:
				projects_to_search.append(pname)

		for proj_name in projects_to_search:
			var docket_args := {"project": proj_name}
			if not title.is_empty():
				docket_args["title"] = title
			elif not skill_id.is_empty():
				docket_args["id"] = skill_id
			var docket_result := dm.call_tool("docket_skill_get", docket_args)
			if not docket_result.has("error"):
				var result := {
					"success": true,
					"id": str(docket_result.get("id", "")),
					"name": str(docket_result.get("title", "")),
					"description": str(docket_result.get("description", "")),
					"origin": "docket",
					"project": proj_name,
					"type": "skill",
					"instructions": str(docket_result.get("steps", "")),
					"preconditions": str(docket_result.get("preconditions", "")),
					"outcome": str(docket_result.get("outcome", "")),
				}
				# Auto-activate tools listed in tool_deps
				var tool_deps: Array = docket_result.get("tool_deps", [])
				if not tool_deps.is_empty():
					result["tool_deps"] = tool_deps
					var activated: Array[String] = []
					var skipped: Array[String] = []
					for dep_name in tool_deps:
						var search_results: Array[Dictionary] = server.tool_search_index.search(str(dep_name), "", 1)
						if not search_results.is_empty() and search_results[0].get("name", "") == str(dep_name):
							var schema: Dictionary = search_results[0].get("schema", {})
							server.tool_budget_manager.activate_tool(str(dep_name), schema)
							activated.append(str(dep_name))
						else:
							skipped.append(str(dep_name))
					result["activated_tools"] = activated
					if not skipped.is_empty():
						result["skipped_tools"] = skipped
					if not activated.is_empty():
						result["message"] = "%d tools activated and ready to use. Do NOT call minerva_tool_search for these — they are already available." % activated.size()

				# Surface model-targeted insights/hints for this skill's domain
				var targeted := _query_targeted_knowledge(dm, proj_name, docket_result, server._current_caller_chat_id)
				if not targeted.is_empty():
					result["insights"] = targeted
					var msg: String = result.get("message", "")
					var sep := " " if not msg.is_empty() else ""
					result["message"] = msg + sep + "%d targeted insights — review before starting." % targeted.size()

				return result

	# Fall back to SkillManager (note-based skills)
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return MCPToolUtils.error("Skill not found")

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		return MCPToolUtils.error("Skill not found: %s" % [skill_id if not skill_id.is_empty() else title])

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
		return MCPToolUtils.error("Skill manager not available")

	var skill_id: String = arguments.get("skill_id", "")
	if skill_id.is_empty():
		return MCPToolUtils.error("skill_id is required")

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		# Fall through to docket — activate_skill should work for docket skills too
		var docket_result := _skill_get(arguments)
		if docket_result.get("success", false):
			return docket_result
		return MCPToolUtils.error("Skill not found: %s" % skill_id)

	if skill_manager.is_active(skill_id):
		return {"success": true, "skill_id": skill_id, "message": "Already active"}

	await skill_manager.activate_skill(skill_id, server.mcp_manager)
	return {"success": true, "skill_id": skill_id, "message": "Skill activated: %s" % skill.name}


func _skill_deactivate(arguments: Dictionary) -> Dictionary:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return MCPToolUtils.error("Skill manager not available")

	var skill_id: String = arguments.get("skill_id", "")
	if skill_id.is_empty():
		return MCPToolUtils.error("skill_id is required")

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		return MCPToolUtils.error("Skill not found: %s" % skill_id)

	if not skill_manager.is_active(skill_id):
		return {"success": true, "skill_id": skill_id, "message": "Already inactive"}

	skill_manager.deactivate_skill(skill_id, server.mcp_manager)
	return {"success": true, "skill_id": skill_id, "message": "Skill deactivated: %s" % skill.name}


func _skill_update_instructions(arguments: Dictionary) -> Dictionary:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return MCPToolUtils.error("Skill manager not available")

	var skill_id: String = arguments.get("skill_id", "")
	if skill_id.is_empty():
		return MCPToolUtils.error("skill_id is required")

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		return MCPToolUtils.error("Skill not found: %s" % skill_id)

	if not skill.is_skill():
		return MCPToolUtils.error("Cannot update instructions on a profile (only user skills)")

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
		return MCPToolUtils.error("text is required")

	if not Core.client._connected:
		return MCPToolUtils.error("Core not connected — cannot use voice-service")

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
		return MCPToolUtils.error("TTS synthesis failed")

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
		return MCPToolUtils.error("No audio player available")

	return {
		"success": true,
		"message": "Speaking: %s" % text.substr(0, 100),
		"text_length": text.length(),
		"voice_id": voice_id,
		"backend": backend,
	}


func _list_voices(arguments: Dictionary) -> Dictionary:
	if not Core.client._connected:
		return MCPToolUtils.error("Core not connected — cannot query voice-service")

	var backend: String = arguments.get("backend", "")
	var client := SingletonObject.get_voice_client()
	var voices: Array = await client.list_voices(backend)

	if voices.is_empty():
		return {"voices": [], "count": 0, "message": "No voices available (voice-service may not be running)", "success": true}

	return {"voices": voices, "count": voices.size(), "success": true}


## Query docket for hints/insights relevant to a skill, filtered by model targeting.
## Derives search components from the skill's tags and tool_deps prefixes.
func _query_targeted_knowledge(dm: DocketManager, proj_name: String, skill_data: Dictionary, caller_chat_id: String) -> Array:
	var identity := ModelTargeting.identify_from_chat(caller_chat_id)
	if identity.is_empty():
		return []

	# Derive hint components from skill tags and tool_deps prefixes
	var components: Array[String] = []
	var skill_tags = skill_data.get("tags", [])
	if skill_tags is String:
		skill_tags = skill_tags.split(",")
	for tag in skill_tags:
		var t := str(tag).strip_edges().to_lower()
		if not t.is_empty() and t not in components:
			components.append(t)
	for dep in skill_data.get("tool_deps", []):
		var prefix: String = str(dep).split("_")[0]
		if not prefix.is_empty() and prefix not in components:
			components.append(prefix)

	if components.is_empty():
		return []

	# Query hints and insights for each component
	var raw_items: Array[Dictionary] = []
	for component in components:
		for item_type in ["hint", "insight"]:
			var query_result: Dictionary = dm.call_tool("docket_query", {
				"project": proj_name,
				"filter": {"type": item_type, "component": component},
				"limit": 10,
			})
			for item in query_result.get("items", []):
				if item is Dictionary and not item.get("target", "").is_empty():
					raw_items.append(item)

	# Filter by model target
	var targeted := ModelTargeting.filter_items(raw_items, identity)

	# Build compact output for the LLM
	var result: Array = []
	for item in targeted:
		var entry := {
			"type": str(item.get("type", "")),
			"component": str(item.get("component", "")),
			"title": str(item.get("title", "")),
		}
		if item.get("type") == "hint":
			entry["value"] = str(item.get("value", ""))
		elif item.get("type") == "insight":
			entry["assumed"] = str(item.get("assumed", ""))
			entry["corrected"] = str(item.get("corrected", ""))
		result.append(entry)
	return result

#endregion
