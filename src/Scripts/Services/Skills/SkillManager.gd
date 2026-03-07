class_name SkillManager
extends RefCounted
## Manages tool profiles and skills — loading, activation, persistence, and tool set recomputation.

const SKILLS_CONFIG_PATH := "user://skills.json"

## All available entries (presets/profiles + user skills)
var skills: Array[SkillDefinition] = []

## Currently active entry IDs (global default)
var active_skills: Array[String] = []

## Computed merged tool sets from all active profiles (empty = all enabled)
var _enabled_tool_sets: Array[String] = []

## Tool names registered by active skill executables (for cleanup on deactivate)
var _registered_skill_tools: Dictionary = {}  # skill_id -> tool_name

signal skills_changed()
signal active_skills_changed()


func _init() -> void:
	_load_presets()
	_load_user_skills()


## Load preset profiles
func _load_presets() -> void:
	for preset in SkillPresets.get_all():
		if not get_skill(preset.id):
			skills.append(preset)


## Load user-created skills from config
func _load_user_skills() -> void:
	if not FileAccess.file_exists(SKILLS_CONFIG_PATH):
		return

	var file := FileAccess.open(SKILLS_CONFIG_PATH, FileAccess.READ)
	if not file:
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("[SkillManager] Failed to parse skills config")
		return

	var data: Dictionary = json.data if json.data is Dictionary else {}

	var user_skills_data: Array = data.get("user_skills", [])
	for skill_data in user_skills_data:
		var skill := SkillDefinition.deserialize(skill_data)
		if not get_skill(skill.id):
			skills.append(skill)

	var active_data: Array = data.get("active_skills", [])
	active_skills.clear()
	for skill_id in active_data:
		active_skills.append(str(skill_id))

	_recompute_tool_sets()


## Save user skills and active state to config
func save_config() -> Error:
	var user_skills_data: Array = []
	for skill in skills:
		if skill.origin == "user" and skill.persistent:
			user_skills_data.append(skill.serialize())

	var data := {
		"version": 2,
		"user_skills": user_skills_data,
		"active_skills": Array(active_skills),
	}

	var json := JSON.stringify(data, "\t")
	var file := FileAccess.open(SKILLS_CONFIG_PATH, FileAccess.WRITE)
	if not file:
		return FileAccess.get_open_error()

	file.store_string(json)
	file.close()
	return OK


## Get an entry by ID
func get_skill(id: String) -> SkillDefinition:
	for skill in skills:
		if skill.id == id:
			return skill
	return null


## Check if an entry is currently active
func is_active(id: String) -> bool:
	return id in active_skills


## Get all profiles (presets)
func get_profiles() -> Array[SkillDefinition]:
	var result: Array[SkillDefinition] = []
	for skill in skills:
		if skill.is_profile():
			result.append(skill)
	return result


## Get all skills (user-created)
func get_skills_only() -> Array[SkillDefinition]:
	var result: Array[SkillDefinition] = []
	for skill in skills:
		if skill.is_skill():
			result.append(skill)
	return result


## Activate an entry by ID. Optionally auto-connects required MCP servers.
func activate_skill(id: String, mcp_manager = null) -> void:
	if id in active_skills:
		return

	var skill := get_skill(id)
	if not skill:
		push_warning("[SkillManager] Unknown entry: %s" % id)
		return

	active_skills.append(id)
	_recompute_tool_sets()

	# Warn if the resulting tool_sets exclude "chat" (the most critical tool set)
	if not _enabled_tool_sets.is_empty() and "chat" not in _enabled_tool_sets:
		push_warning("[SkillManager] Active profiles exclude 'chat' tool set — LLM may not be able to respond")

	# Auto-connect required MCP servers (profiles)
	if mcp_manager and not skill.required_servers.is_empty():
		for server_name in skill.required_servers:
			if not mcp_manager.is_server_connected(server_name):
				var err = await mcp_manager.connect_server(server_name)
				if err != OK:
					push_warning("[SkillManager] Failed to auto-connect %s for %s" % [server_name, id])

	# Register executable tool (skills)
	if skill.has_executable() and mcp_manager:
		_register_executable_tool(skill, mcp_manager)

	save_config()
	active_skills_changed.emit()


## Deactivate an entry by ID
func deactivate_skill(id: String, mcp_manager = null) -> void:
	var idx := active_skills.find(id)
	if idx < 0:
		return

	active_skills.remove_at(idx)
	_recompute_tool_sets()

	# Unregister executable tool
	if mcp_manager and _registered_skill_tools.has(id):
		_unregister_executable_tool(id, mcp_manager)

	save_config()
	active_skills_changed.emit()


## Add a user-created skill
func add_skill(skill: SkillDefinition) -> void:
	if get_skill(skill.id):
		push_warning("[SkillManager] Entry already exists: %s" % skill.id)
		return
	skills.append(skill)
	save_config()
	skills_changed.emit()


## Remove a user-created skill (presets cannot be removed)
func remove_skill(id: String) -> bool:
	var skill := get_skill(id)
	if not skill:
		return false
	if skill.origin == "preset":
		push_warning("[SkillManager] Cannot remove preset: %s" % id)
		return false

	deactivate_skill(id)

	for i in range(skills.size()):
		if skills[i].id == id:
			skills.remove_at(i)
			break

	save_config()
	skills_changed.emit()
	return true


## Register a skill's executable as an internal tool
func _register_executable_tool(skill: SkillDefinition, mcp_manager) -> void:
	var tool_name := "skill_%s" % skill.id
	var tool_def = load("res://Scripts/Services/MCP/MCPToolDefinition.gd").new()
	tool_def.name = tool_name
	tool_def.description = skill.executable_description if not skill.executable_description.is_empty() else "Run %s" % skill.name
	tool_def.server_name = "minerva"
	tool_def.tool_set = ""  # Always passes tool_set filters
	tool_def.input_schema = {
		"type": "object",
		"properties": {
			"args": {
				"type": "string",
				"description": "Arguments to pass to the executable (space-separated)"
			}
		}
	}

	if mcp_manager.has_method("_register_tool"):
		mcp_manager._register_tool(tool_def)
	elif "tool_registry" in mcp_manager:
		mcp_manager.tool_registry[tool_name] = tool_def

	_registered_skill_tools[skill.id] = tool_name
	print("[SkillManager] Registered executable tool: %s -> %s" % [tool_name, skill.executable_path])


## Unregister a skill's executable tool
func _unregister_executable_tool(skill_id: String, mcp_manager) -> void:
	var tool_name: String = _registered_skill_tools.get(skill_id, "")
	if tool_name.is_empty():
		return

	if "tool_registry" in mcp_manager and mcp_manager.tool_registry.has(tool_name):
		mcp_manager.tool_registry.erase(tool_name)

	_registered_skill_tools.erase(skill_id)
	print("[SkillManager] Unregistered executable tool: %s" % tool_name)


## Execute a skill's executable and return the result
func execute_skill_tool(skill_id: String, args_str: String = "") -> Dictionary:
	var skill := get_skill(skill_id)
	if not skill or not skill.has_executable():
		return {"error": "Skill not found or has no executable"}

	if not FileAccess.file_exists(skill.executable_path):
		return {"error": "Executable not found: %s" % skill.executable_path}

	var cmd_args: PackedStringArray = []
	for arg in skill.executable_args:
		cmd_args.append(arg)
	if not args_str.is_empty():
		for arg in args_str.split(" ", false):
			cmd_args.append(arg)

	var output: Array = []
	var exit_code := OS.execute(skill.executable_path, cmd_args, output, true, false)

	var stdout := ""
	for line in output:
		stdout += str(line)

	return {
		"exit_code": exit_code,
		"output": stdout,
		"executable": skill.executable_path,
	}


## Recompute merged tool sets from all active profiles.
## If any active profile has empty tool_sets (= all), the result is empty (= all).
func _recompute_tool_sets() -> void:
	if active_skills.is_empty():
		_enabled_tool_sets = []
		return

	var merged: Dictionary = {}
	for skill_id in active_skills:
		var skill := get_skill(skill_id)
		if not skill or not skill.is_profile():
			continue  # Skills don't affect tool_set filtering
		if skill.tool_sets.is_empty():
			_enabled_tool_sets = []
			return
		for ts in skill.tool_sets:
			merged[ts] = true

	_enabled_tool_sets = []
	for key in merged:
		_enabled_tool_sets.append(key)


## Get the effective tool sets for a given scope.
## Per-chat overrides per-agent which overrides global.
func get_effective_tool_sets(chat_skills: Array[String] = [], agent_skills: Array[String] = []) -> Array[String]:
	var skill_ids: Array[String] = []

	if not chat_skills.is_empty():
		skill_ids = chat_skills
	elif not agent_skills.is_empty():
		skill_ids = agent_skills
	else:
		skill_ids = active_skills

	if skill_ids.is_empty():
		return []

	var merged: Dictionary = {}
	for skill_id in skill_ids:
		var skill := get_skill(skill_id)
		if not skill or not skill.is_profile():
			continue
		if skill.tool_sets.is_empty():
			return []
		for ts in skill.tool_sets:
			merged[ts] = true

	var result: Array[String] = []
	for key in merged:
		result.append(key)
	return result


## Get prompt fragments from active profiles for a given scope.
func get_prompt_fragments(chat_skills: Array[String] = [], agent_skills: Array[String] = []) -> Array[String]:
	var skill_ids: Array[String] = []

	if not chat_skills.is_empty():
		skill_ids = chat_skills
	elif not agent_skills.is_empty():
		skill_ids = agent_skills
	else:
		skill_ids = active_skills

	var fragments: Array[String] = []
	for skill_id in skill_ids:
		var skill := get_skill(skill_id)
		if not skill:
			continue
		for frag in skill.prompt_fragments:
			if frag not in fragments:
				fragments.append(frag)

	return fragments


## Get instruction text from active skills for a given scope.
func get_skill_instructions(chat_skills: Array[String] = [], agent_skills: Array[String] = []) -> String:
	var skill_ids: Array[String] = []

	if not chat_skills.is_empty():
		skill_ids = chat_skills
	elif not agent_skills.is_empty():
		skill_ids = agent_skills
	else:
		skill_ids = active_skills

	var result := ""

	for skill_id in skill_ids:
		var skill := get_skill(skill_id)
		if not skill or not skill.is_skill():
			continue
		if not skill.has_instructions():
			continue

		if not result.is_empty():
			result += "\n\n"
		result += "## Skill: %s\n%s" % [skill.name, skill.instructions]

	return result
