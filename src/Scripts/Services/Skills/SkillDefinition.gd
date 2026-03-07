class_name SkillDefinition
extends RefCounted
## Data model for a tool profile or a skill.
## Profiles (origin="preset") filter tool groups via tool_sets.
## Skills (origin="user") inject instructions into the system prompt
## and optionally register an executable as an LLM-callable tool.

var id: String = ""
var name: String = ""
var description: String = ""
var origin: String = "preset"  # "preset" (profile) | "user" (skill)

## --- Profile fields (used when origin == "preset") ---

## Minerva tool categories to enable (empty = all enabled)
var tool_sets: Array[String] = []

## MCP servers to auto-connect when this profile is activated
var required_servers: Array[String] = []

## --- Skill fields (used when origin == "user") ---

## Markdown instructions injected into the system prompt when active
var instructions: String = ""

## Optional executable path (script/binary the LLM can invoke as a tool)
var executable_path: String = ""

## Default arguments for the executable
var executable_args: Array[String] = []

## Tool description exposed to the LLM for the executable
var executable_description: String = ""

## Working directory for executable invocation
var executable_working_dir: String = ""

## --- Shared fields ---

## System prompt additions (used by presets as hardcoded fragments)
var prompt_fragments: Array[String] = []

## Whether this entry persists across sessions
var persistent: bool = true


func _init(p_id: String = "", p_name: String = "", p_desc: String = "") -> void:
	id = p_id
	name = p_name
	description = p_desc


func is_skill() -> bool:
	return origin == "user"


func is_profile() -> bool:
	return origin == "preset"


func has_executable() -> bool:
	return not executable_path.is_empty()


func has_instructions() -> bool:
	return not instructions.is_empty()


func serialize() -> Dictionary:
	var data := {
		"id": id,
		"name": name,
		"description": description,
		"origin": origin,
		"persistent": persistent,
	}

	# Profile fields
	if not tool_sets.is_empty():
		data["tool_sets"] = Array(tool_sets)
	if not required_servers.is_empty():
		data["required_servers"] = Array(required_servers)

	# Skill fields
	if not instructions.is_empty():
		data["instructions"] = instructions
	if not executable_path.is_empty():
		data["executable_path"] = executable_path
		data["executable_args"] = Array(executable_args)
		data["executable_description"] = executable_description
		data["executable_working_dir"] = executable_working_dir

	# Shared
	if not prompt_fragments.is_empty():
		data["prompt_fragments"] = Array(prompt_fragments)

	return data


static func deserialize(data: Dictionary) -> SkillDefinition:
	var def := SkillDefinition.new()
	def.id = data.get("id", "")
	def.name = data.get("name", "")
	def.description = data.get("description", "")
	def.origin = data.get("origin", "user")
	def.persistent = data.get("persistent", true)

	# Profile fields
	for t in data.get("tool_sets", []):
		def.tool_sets.append(str(t))
	for r in data.get("required_servers", []):
		def.required_servers.append(str(r))

	# Skill fields
	def.instructions = data.get("instructions", "")
	def.executable_path = data.get("executable_path", "")
	for a in data.get("executable_args", []):
		def.executable_args.append(str(a))
	def.executable_description = data.get("executable_description", "")
	def.executable_working_dir = data.get("executable_working_dir", "")

	# Shared
	for p in data.get("prompt_fragments", []):
		def.prompt_fragments.append(str(p))

	return def
