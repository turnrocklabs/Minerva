class_name SkillDefinition
extends RefCounted
## Data model for a runtime skill — a composable capability bundle
## that brings together tool sets, MCP servers, and prompt fragments.

var id: String = ""
var name: String = ""
var description: String = ""
var origin: String = "preset"  # "preset" | "user"

## Minerva tool categories to enable (empty = all enabled)
var tool_sets: Array[String] = []

## MCP servers to auto-connect when this skill is activated
var required_servers: Array[String] = []

## System prompt additions injected when this skill is active
var prompt_fragments: Array[String] = []

## Suggested model hint (not enforced)
var suggested_model: String = ""

## Whether this skill persists across sessions
var persistent: bool = true


func _init(p_id: String = "", p_name: String = "", p_desc: String = "") -> void:
	id = p_id
	name = p_name
	description = p_desc


func serialize() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"description": description,
		"origin": origin,
		"tool_sets": Array(tool_sets),
		"required_servers": Array(required_servers),
		"prompt_fragments": Array(prompt_fragments),
		"suggested_model": suggested_model,
		"persistent": persistent,
	}


static func deserialize(data: Dictionary) -> SkillDefinition:
	var skill := SkillDefinition.new()
	skill.id = data.get("id", "")
	skill.name = data.get("name", "")
	skill.description = data.get("description", "")
	skill.origin = data.get("origin", "user")
	var ts = data.get("tool_sets", [])
	for t in ts:
		skill.tool_sets.append(str(t))
	var rs = data.get("required_servers", [])
	for r in rs:
		skill.required_servers.append(str(r))
	var pf = data.get("prompt_fragments", [])
	for p in pf:
		skill.prompt_fragments.append(str(p))
	skill.suggested_model = data.get("suggested_model", "")
	skill.persistent = data.get("persistent", true)
	return skill
