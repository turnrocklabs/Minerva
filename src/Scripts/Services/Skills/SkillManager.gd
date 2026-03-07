class_name SkillManager
extends RefCounted
## Manages runtime skills — loading, activation, persistence, and tool set recomputation.

const SKILLS_CONFIG_PATH := "user://skills.json"

## All available skills (presets + user-created)
var skills: Array[SkillDefinition] = []

## Currently active skill IDs (global default)
var active_skills: Array[String] = []

## Computed merged tool sets from all active skills (empty = all enabled)
var _enabled_tool_sets: Array[String] = []

signal skills_changed()
signal active_skills_changed()


func _init() -> void:
	_load_presets()
	_load_user_skills()


## Load preset skills
func _load_presets() -> void:
	for preset in SkillPresets.get_all():
		# Don't duplicate if already loaded
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

	# Load user skills
	var user_skills_data: Array = data.get("user_skills", [])
	for skill_data in user_skills_data:
		var skill := SkillDefinition.deserialize(skill_data)
		if not get_skill(skill.id):
			skills.append(skill)

	# Load active skills
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
		"version": 1,
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


## Get a skill by ID
func get_skill(id: String) -> SkillDefinition:
	for skill in skills:
		if skill.id == id:
			return skill
	return null


## Check if a skill is currently active
func is_active(id: String) -> bool:
	return id in active_skills


## Activate a skill by ID. Optionally auto-connects required MCP servers.
func activate_skill(id: String, mcp_manager = null) -> void:
	if id in active_skills:
		return

	var skill := get_skill(id)
	if not skill:
		push_warning("[SkillManager] Unknown skill: %s" % id)
		return

	active_skills.append(id)
	_recompute_tool_sets()

	# Auto-connect required MCP servers
	if mcp_manager and not skill.required_servers.is_empty():
		for server_name in skill.required_servers:
			if not mcp_manager.is_server_connected(server_name):
				var err = await mcp_manager.connect_server(server_name)
				if err != OK:
					push_warning("[SkillManager] Failed to auto-connect %s for skill %s" % [server_name, id])

	save_config()
	active_skills_changed.emit()


## Deactivate a skill by ID
func deactivate_skill(id: String, _mcp_manager = null) -> void:
	var idx := active_skills.find(id)
	if idx < 0:
		return

	active_skills.remove_at(idx)
	_recompute_tool_sets()
	save_config()
	active_skills_changed.emit()


## Add a user-created skill
func add_skill(skill: SkillDefinition) -> void:
	if get_skill(skill.id):
		push_warning("[SkillManager] Skill already exists: %s" % skill.id)
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
		push_warning("[SkillManager] Cannot remove preset skill: %s" % id)
		return false

	# Deactivate first
	deactivate_skill(id)

	for i in range(skills.size()):
		if skills[i].id == id:
			skills.remove_at(i)
			break

	save_config()
	skills_changed.emit()
	return true


## Recompute merged tool sets from all active skills.
## If any active skill has empty tool_sets (= all), the result is empty (= all).
func _recompute_tool_sets() -> void:
	if active_skills.is_empty():
		_enabled_tool_sets = []
		return

	var merged: Dictionary = {}
	for skill_id in active_skills:
		var skill := get_skill(skill_id)
		if not skill:
			continue
		if skill.tool_sets.is_empty():
			# Empty = all enabled, so merged result is all enabled
			_enabled_tool_sets = []
			return
		for ts in skill.tool_sets:
			merged[ts] = true

	_enabled_tool_sets = []
	for key in merged:
		_enabled_tool_sets.append(key)


## Get the effective tool sets for a given scope.
## Per-chat skills override per-agent which override global.
func get_effective_tool_sets(chat_skills: Array[String] = [], agent_skills: Array[String] = []) -> Array[String]:
	var skill_ids: Array[String] = []

	# Precedence: per-chat > per-agent > global
	if not chat_skills.is_empty():
		skill_ids = chat_skills
	elif not agent_skills.is_empty():
		skill_ids = agent_skills
	else:
		skill_ids = active_skills

	if skill_ids.is_empty():
		return []  # All enabled

	var merged: Dictionary = {}
	for skill_id in skill_ids:
		var skill := get_skill(skill_id)
		if not skill:
			continue
		if skill.tool_sets.is_empty():
			return []  # All enabled
		for ts in skill.tool_sets:
			merged[ts] = true

	var result: Array[String] = []
	for key in merged:
		result.append(key)
	return result


## Get prompt fragments from active skills for a given scope.
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
