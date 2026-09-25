class_name MCPSkillTools
extends MCPToolModule

const ExecutionContext = preload("res://Scripts/Services/MCP/MCPExecutionContext.gd")
## MCP tool module for Skill management and Voice tools.
## Combines _register_skill_tools and _register_voice_tools from MinervaMCPServer.


func get_tool_names() -> Array[String]:
	return [
		"minerva_list_skills",
		"minerva_get_skill",
		"minerva_skill_create",
		"minerva_skill_update",
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

	var create_desc := "Create a new skill in the docket with tool_deps for auto-activation. Use this to author skills at runtime — it handles insertion, active-status transition, and tool activation in one call. Writes to user://master.dct (the runtime docket). Do NOT use minerva_docket_create for skills — its schema omits tool_deps so auto-activation stays empty."
	var create_schema := {
		"type": "object",
		"properties": {
			"title": {"type": "string", "description": "Skill title — appears in the skill chooser. Keep short."},
			"description": {"type": "string", "description": "One-line explanation shown in skill_list results. Lead with when the skill should be used."},
			"steps": {"type": "string", "description": "Numbered imperative steps. Use exact tool names (not paraphrases). Include recovery patterns and a call budget."},
			"preconditions": {"type": "string", "description": "What must be true before using this skill."},
			"outcome": {"type": "string", "description": "What success looks like when the skill completes."},
			"tool_deps": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Exact MCP tool names this skill needs. Auto-activated on skill load.",
			},
			"tags": {"type": "array", "items": {"type": "string"}, "description": "Category filters (e.g. 'editor', 'notes', 'tool-suite')."},
			"optimization": {"type": "object", "description": "Optional runtime profile: {context_window: int, summary_mode: 'deterministic'|'llm', tool_idle_turns: int, tool_budget: int (TOKENS), max_tool_call_rounds: int (raises the per-message tool-call ROUND cap for this skill's workflow)}"},
			"status": {"type": "string", "enum": ["active", "draft"], "description": "Initial status (default 'active')."},
			"project": {"type": "string", "description": "Target docket project (default 'master')."},
		},
		"required": ["title"],
	}
	server._register_tool("minerva_skill_create", create_desc, create_schema, "utility")

	var update_desc := "Update fields on an existing skill, including tool_deps (which minerva_docket_update's schema omits). Pass only the fields you want to change. Use this to evolve skills as their workflows mature. Does NOT transition status — use minerva_docket_transition for that."
	var update_schema := {
		"type": "object",
		"properties": {
			"id": {"type": "string", "description": "Skill id (from minerva_get_skill or minerva_skill_create). Full id or short prefix."},
			"title": {"type": "string"},
			"description": {"type": "string"},
			"steps": {"type": "string"},
			"preconditions": {"type": "string"},
			"outcome": {"type": "string"},
			"tool_deps": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Replaces the existing tool_deps list. Auto-activation re-runs after update.",
			},
			"tags": {"type": "array", "items": {"type": "string"}},
			"optimization": {"type": "object"},
			"project": {"type": "string", "description": "Target docket project (default 'master')."},
		},
		"required": ["id"],
	}
	server._register_tool("minerva_skill_update", update_desc, update_schema, "utility")

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
	return await handle_with_context(tool_name, arguments, ExecutionContext.create("module"))


func handle_with_context(tool_name: String, arguments: Dictionary, context: ExecutionContext) -> Dictionary:
	match tool_name:
		"minerva_list_skills": return _skill_list(arguments)
		"minerva_get_skill": return _skill_get(arguments, context)
		"minerva_skill_create": return _skill_create(arguments)
		"minerva_skill_update": return _skill_update(arguments)
		"minerva_activate_skill": return await _skill_activate(arguments, context)
		"minerva_deactivate_skill": return _skill_deactivate(arguments)
		"minerva_update_skill_instructions": return _skill_update_instructions(arguments)
		"minerva_speak": return await _speak(arguments)
		"minerva_list_voices": return await _list_voices(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


## Resolves requested skills, all or none, before anything is created for
## them: {status: "ok", tools (the union of their tool_deps), instructions
## (each skill's under a "## Skill:" header), skills: [{ref, title, origin}]},
## or {status: "error", code, message, skill, candidates?} for the first that
## cannot be resolved (missing, ambiguous, or its owner unreadable). No
## requested skill is an empty success. Each name is resolved by
## _resolve_skill.
func resolve_skills(skill_names: Array[String]) -> Dictionary:
	var all_tools: Array[String] = []
	var all_instructions: Array[String] = []
	var skills: Array = []
	for skill_name in skill_names:
		var resolved := await _resolve_skill(str(skill_name))
		if resolved.status != "found":
			return resolved
		for dep in resolved.tools:
			if dep not in all_tools:
				all_tools.append(dep)
		if not str(resolved.instructions).is_empty():
			all_instructions.append("## Skill: %s\n\n%s" % [resolved.title, resolved.instructions])
		skills.append({"ref": resolved.ref, "title": resolved.title, "origin": resolved.origin})
	return {"status": "ok", "tools": all_tools, "instructions": "\n\n".join(all_instructions), "skills": skills}


## One requested skill: {status: "found", ref, title, origin, tools,
## instructions} or {status: "error", code, message, skill, candidates?}.
## A qualified reference (SkillRef) names its origin; a legacy name that is a
## SkillManager id is that local skill (so local skills work while Docket is
## unavailable); any other legacy name is looked up in Docket, through the
## embedded DocketManager while it exists, else through DocketHost. A Docket
## failure is never answered from SkillManager.
func _resolve_skill(skill_name: String) -> Dictionary:
	var failed := func(code: String, why: String) -> Dictionary:
		return {"status": "error", "code": code, "skill": skill_name,
			"message": "Skill '%s' could not be resolved: %s" % [skill_name, why]}
	var qualified := SkillRef.parse(skill_name)
	if qualified.is_empty() and SkillRef.is_qualified(skill_name):
		return failed.call("bad_ref", "it is not a valid skill reference")
	var skill_manager = SingletonObject.get_skill_manager()
	var local_id := ""
	if qualified.get("origin", "") == SkillRef.LOCAL:
		local_id = str(qualified.id)
	elif qualified.is_empty() and skill_manager and skill_manager.get_skill(skill_name):
		local_id = skill_name
	if not local_id.is_empty():
		var skill = skill_manager.get_skill(local_id) if skill_manager else null
		if skill == null:
			return failed.call("missing", "no such local skill")
		var deps: Array[String] = []
		for dep in (skill.tool_deps if "tool_deps" in skill else []):
			deps.append(str(dep))
		return {"status": "found", "ref": SkillRef.local(skill.id), "title": skill.name, "origin": SkillRef.LOCAL,
			"tools": deps, "instructions": skill.instructions}

	var found := await docket_skill(skill_name)
	match found.status:
		"found":
			var record: Dictionary = found.item
			var tools: Array[String] = []
			tools.assign(record.tool_deps)
			return {"status": "found", "ref": record.ref, "title": record.title, "origin": SkillRef.DOCKET,
				"tools": tools, "instructions": _compose_skill_instructions(record)}
		"missing":
			return failed.call("missing", "no skill has that id or title")
	var refused: Dictionary = failed.call(str(found.get("code", "error")), str(found.get("message", "")))
	if found.has("candidates"):
		refused["candidates"] = found.candidates
	return refused


## The Docket skill `selector` names (as DocketHost.skill_lookup: a
## qualified reference, else id then title), through the embedded
## DocketManager while it exists (the first loaded project holding it by id,
## else by title), else through DocketHost: {status: "found", item: skill
## record (DocketHost.skill_record), ref}, {status: "missing"}, or {status:
## "error", code, message, candidates?}.
func docket_skill(selector: String) -> Dictionary:
	var dm: DocketManager = SingletonObject.docket_manager
	if dm != null:
		var qualified := SkillRef.parse(selector)
		var only := str(qualified.get("project_path", ""))
		for proj_name in dm.get_loaded_projects():
			var path := dm.get_project_path(proj_name)
			if not only.is_empty() and path != only:
				continue
			var project := {"name": proj_name, "display_name": proj_name, "path": path}
			var tries: Array = [{"id": qualified.id}] if not qualified.is_empty() \
				else [{"id": selector}, {"title": selector}]
			for args in tries:
				var got: Dictionary = dm.call_tool("docket_skill_get", args.merged({"project": proj_name}))
				if not got.has("error"):
					var record := DocketHost.skill_record(got, project)
					return {"status": "found", "item": record, "ref": record.ref}
		return {"status": "missing", "selector": selector}
	var host: DocketHost = SingletonObject.docket_host
	if host == null:
		return {"status": "error", "code": "unavailable", "message": "no Docket owns Minerva's projects"}
	return await host.skill_lookup(selector)


## The active Docket skills of every open project, for choosing among them:
## {status: "ok", skills: [skill records]} or {status: "error", code,
## message}. Through the embedded DocketManager while it exists (a skill
## whose full record cannot be read is left out, never listed without its
## tool_deps), else through DocketHost.
func docket_skill_catalog() -> Dictionary:
	var dm: DocketManager = SingletonObject.docket_manager
	if dm != null:
		var skills := []
		for proj_name in dm.get_loaded_projects():
			var project := {"name": proj_name, "display_name": proj_name, "path": dm.get_project_path(proj_name)}
			var listed: Dictionary = dm.call_tool("docket_skill_list", {"project": proj_name})
			for entry in listed.get("skills", []):
				var got: Dictionary = dm.call_tool("docket_skill_get", {"id": str(entry.get("id", "")), "project": proj_name})
				if not got.has("error"):
					skills.append(DocketHost.skill_record(got, project))
		return {"status": "ok", "skills": skills}
	var host: DocketHost = SingletonObject.docket_host
	if host == null:
		return {"status": "error", "code": "unavailable", "message": "no Docket owns Minerva's projects"}
	return await host.skill_catalog()


## Concat a docket skill record's prompt_text + steps into a single instructions
## body. prompt_text holds the long-form §0–§N system prompt (manifest's
## `system_prompt` field), steps holds the numbered checklist. Skills shipped
## via plugin manifests rely on prompt_text — without this concat the §0
## "MCAD is NOT OpenSCAD" callout (and similar) never reaches the agent.
static func _compose_skill_instructions(record: Dictionary) -> String:
	var prompt_text: String = str(record.get("prompt_text", "")).strip_edges()
	var steps: String = str(record.get("steps", "")).strip_edges()
	if prompt_text.is_empty():
		return steps
	if steps.is_empty():
		return prompt_text
	return "%s\n\n---\n\n%s" % [prompt_text, steps]


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


func _activate_dependencies(tool_deps: Array) -> Dictionary:
	var schemas: Array[Dictionary] = []
	var skipped: Array[String] = []
	for dep_name: Variant in tool_deps:
		var name := str(dep_name)
		var search_results: Array[Dictionary] = server.tool_search_index.search(name, "", 1)
		if search_results.is_empty() or str(search_results[0].get("name", "")) != name:
			skipped.append(name)
			continue
		var schema: Dictionary = search_results[0].get("schema", {})
		if schema.is_empty():
			skipped.append(name)
		else:
			schemas.append(schema)

	var admission: Dictionary = server.tool_budget_manager.activate_group(schemas)
	var unavailable: Array[String] = []
	for rejected: Dictionary in admission.get("rejected", []):
		unavailable.append(str(rejected.get("name", "")))
	return {
		"activated_tools": admission.get("activated", []),
		"unavailable_tools": unavailable,
		"skipped_tools": skipped,
		"evicted_tools": admission.get("evicted", []),
		"activation_failures": admission.get("rejected", []),
	}


static func _activation_message(activation: Dictionary) -> String:
	var activated: Array = activation.get("activated_tools", [])
	var unavailable: Array = activation.get("unavailable_tools", [])
	var skipped: Array = activation.get("skipped_tools", [])
	var message := "%d tools activated and ready to use." % activated.size()
	if not unavailable.is_empty():
		message += " %d could not fit the active tool budget." % unavailable.size()
	if not skipped.is_empty():
		message += " %d tool names were not found." % skipped.size()
	return message


func _skill_get(arguments: Dictionary, context: ExecutionContext) -> Dictionary:
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
					"instructions": _compose_skill_instructions(docket_result),
					"preconditions": str(docket_result.get("preconditions", "")),
					"outcome": str(docket_result.get("outcome", "")),
				}
				# Apply the skill's budget before admitting its dependency group.
				var optimization: Dictionary = docket_result.get("optimization", {})
				if not optimization.is_empty():
					var optimization_result := _apply_skill_optimization(
						optimization, context)
					if not (optimization_result.applied as Dictionary).is_empty():
						result["optimization_applied"] = optimization_result.applied
					if not (optimization_result.failures as Array).is_empty():
						result["optimization_failures"] = optimization_result.failures

				# Auto-activate tools listed in tool_deps as one protected group.
				var tool_deps: Array = docket_result.get("tool_deps", [])
				if not tool_deps.is_empty():
					result["tool_deps"] = tool_deps
					var activation := _activate_dependencies(tool_deps)
					for key: String in activation:
						if not (activation[key] as Array).is_empty():
							result[key] = activation[key]
					result["message"] = _activation_message(activation)

				# Surface model-targeted insights/hints for this skill's domain
				var targeted := _query_targeted_knowledge(dm, proj_name, docket_result, context.caller_chat_id)
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


func _skill_activate(arguments: Dictionary, context: ExecutionContext) -> Dictionary:
	var skill_manager = SingletonObject.get_skill_manager()
	if not skill_manager:
		return MCPToolUtils.error("Skill manager not available")

	var skill_id: String = arguments.get("skill_id", "")
	if skill_id.is_empty():
		return MCPToolUtils.error("skill_id is required")

	var skill = skill_manager.get_skill(skill_id)
	if not skill:
		# Fall through to docket — activate_skill should work for docket skills too
		var docket_result := _skill_get(arguments, context)
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


## Create a new docket-backed skill, including tool_deps (which docket_create's
## MCP schema omits). Defaults to status=active and auto-activates the tools
## in the caller's budget manager so the skill is immediately usable.
func _skill_create(arguments: Dictionary) -> Dictionary:
	var title: String = str(arguments.get("title", "")).strip_edges()
	if title.is_empty():
		return MCPToolUtils.error("title is required")

	var dm: DocketManager = SingletonObject.docket_manager
	if dm == null:
		return MCPToolUtils.error("DocketManager not available")

	var project: String = str(arguments.get("project", "master"))

	# Forward skill fields to docket_create. DataModel.create_item copies any
	# field listed in the skill type's optional_fields (including tool_deps and
	# optimization), so the persisted item will carry them — the only gap was
	# the MCP-layer schema on docket_create itself.
	var create_args := {
		"project": project,
		"type": "skill",
		"title": title,
	}
	var forwarded := ["description", "steps", "preconditions", "outcome",
		"tool_deps", "optimization", "tags", "component", "topic", "subtopic", "target"]
	for key in forwarded:
		if arguments.has(key):
			create_args[key] = arguments[key]

	var create_result := dm.call_tool("docket_create", create_args)
	if create_result.has("error"):
		return create_result

	var skill_id: String = str(create_result.get("id", ""))
	if skill_id.is_empty():
		return MCPToolUtils.error("docket_create returned no id")

	# Transition to active unless caller asked for draft. New skills start in
	# "draft" state per the schema (skill.initial_state); skill_list filters
	# out drafts by default so we flip to active immediately.
	var requested_status: String = str(arguments.get("status", "active"))
	var final_status: String = "draft"
	var transition_warning := ""
	if requested_status == "active":
		var transition_result := dm.call_tool("docket_transition", {
			"project": project,
			"id": skill_id,
			"to": "active",
		})
		if transition_result.has("error"):
			transition_warning = "Skill created in draft; transition to active failed: %s" % str(transition_result.get("error", ""))
		else:
			final_status = "active"

	# Auto-activate declared tools in the caller's budget manager so the
	# skill is immediately usable without a second minerva_activate_skill call.
	var tool_deps: Array = arguments.get("tool_deps", [])
	var activation := _activate_dependencies(tool_deps)

	var result := {
		"success": true,
		"id": skill_id,
		"title": title,
		"status": final_status,
		"project": project,
		"activated_tools": activation.activated_tools,
	}
	for key: String in ["unavailable_tools", "skipped_tools", "evicted_tools",
			"activation_failures"]:
		if not (activation[key] as Array).is_empty():
			result[key] = activation[key]
	result["message"] = "Skill created. " + _activation_message(activation)
	if not transition_warning.is_empty():
		result["warning"] = transition_warning
	return result


## Update fields on an existing docket-backed skill, including tool_deps
## (which minerva_docket_update's MCP schema omits). Re-runs auto-activation
## for tool_deps when they change.
func _skill_update(arguments: Dictionary) -> Dictionary:
	var id: String = str(arguments.get("id", "")).strip_edges()
	if id.is_empty():
		return MCPToolUtils.error("id is required")

	var dm: DocketManager = SingletonObject.docket_manager
	if dm == null:
		return MCPToolUtils.error("DocketManager not available")

	var project: String = str(arguments.get("project", "master"))

	var update_args := {"project": project, "id": id}
	var forwarded := ["title", "description", "steps", "preconditions", "outcome",
		"tool_deps", "optimization", "tags", "component", "topic", "subtopic", "target"]
	var has_changes := false
	for key in forwarded:
		if arguments.has(key):
			update_args[key] = arguments[key]
			has_changes = true

	if not has_changes:
		return MCPToolUtils.error("No updatable fields provided")

	var update_result := dm.call_tool("docket_update", update_args)
	if update_result.has("error"):
		return update_result

	var result := {
		"success": true,
		"id": id,
		"project": project,
		"updated_fields": update_args.keys().filter(func(k): return k != "id" and k != "project"),
	}

	# If tool_deps was part of the update, re-activate them so the caller's
	# budget manager reflects the new set immediately. We don't try to
	# deactivate removed tools — activation is idempotent and old deps
	# expire naturally via tool_idle_turns.
	if arguments.has("tool_deps"):
		var tool_deps: Array = arguments.get("tool_deps", [])
		var activation := _activate_dependencies(tool_deps)
		for key: String in activation:
			if not (activation[key] as Array).is_empty():
				result[key] = activation[key]

	return result


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

	var cfg := SingletonObject.get_voice_config()
	var voice_id: String = arguments.get("voice_id", "")
	if voice_id.is_empty():
		voice_id = cfg.voice_name if not cfg.voice_name.is_empty() else cfg.voice_id
	var backend: String = arguments.get("backend", "")
	if backend.is_empty():
		backend = cfg.tts_backend

	var client := SingletonObject.get_voice_client()
	var outcome := await client.synthesize_result(text, voice_id, backend)
	if not outcome.success:
		return outcome
	var wav_data: PackedByteArray = outcome.audio

	# The pane supplies playback availability; MCP owns a separate player.
	var chats = SingletonObject.Chats
	if is_instance_valid(chats) and is_instance_valid(chats._tts_player):
		var stream := VoiceServiceClient.decode_audio(wav_data)
		if stream == null:
			return VoiceServiceClient.failure("invalid_audio", "Speech audio could not be decoded.")
		# MCP playback owns its player, independent of an in-flight chat speech.
		var player := AudioStreamPlayer.new()
		chats.add_child(player)
		player.stream = stream
		player.volume_db = linear_to_db(cfg.tts_volume)
		player.finished.connect(player.queue_free, CONNECT_ONE_SHOT)
		player.play()
	else:
		push_warning("[MCPSkillTools] No TTS player available for minerva_speak")
		return VoiceServiceClient.failure("no_audio_player", "No audio player available")

	return {
		"success": true,
		"message": "Speaking: %s" % text.substr(0, 100),
		"text_length": text.length(),
		"voice_id": voice_id,
		"backend": backend,
	}


func _list_voices(arguments: Dictionary) -> Dictionary:
	var backend: String = arguments.get("backend", "")
	return await SingletonObject.get_voice_client().list_voices_result(backend)


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


## Apply optimization knobs from a skill's "optimization" dict and report any
## setting that could not be enforced.
func _apply_skill_optimization(optimization: Dictionary,
		context: ExecutionContext) -> Dictionary:
	var applied := optimization.duplicate(true)
	var failures: Array[Dictionary] = []
	# Tool budget knobs
	if optimization.has("tool_budget"):
		var budget_result: Dictionary = server.tool_budget_manager.set_budget(
			int(optimization["tool_budget"]))
		if not budget_result.get("applied", false):
			applied.erase("tool_budget")
			var failure := budget_result.duplicate(true)
			failure["setting"] = "tool_budget"
			failures.append(failure)
	if optimization.has("tool_idle_turns"):
		server.tool_budget_manager.set_max_idle_turns(int(optimization["tool_idle_turns"]))

	# Round-cap knob (W10): a skill can raise the per-message tool-call ROUND
	# limit for its multi-step workflow without touching the global default.
	# Distinct from tool_budget (which is a TOKEN budget) — this is the
	# MaxToolCallRounds count enforced in ChatPane.handle_tool_calls.
	if optimization.has("max_tool_call_rounds"):
		var rounds_history = MCPToolUtils.find_chat_by_id(context.caller_chat_id)
		if rounds_history and rounds_history is ChatHistory:
			rounds_history.MaxToolCallRounds = int(optimization["max_tool_call_rounds"])

	# ToolMemoryManager knobs (per-chat)
	if optimization.has("context_window") or optimization.has("summary_mode"):
		var history = MCPToolUtils.find_chat_by_id(context.caller_chat_id)
		if history and history is ChatHistory and history.tool_memory_manager:
			var tmm = history.tool_memory_manager
			if optimization.has("context_window"):
				tmm.dehydrate_after_n_rounds = int(optimization["context_window"])
			if optimization.has("summary_mode"):
				var mode: String = str(optimization["summary_mode"])
				if mode == "deterministic":
					# Disable LLM summary calls — use deterministic fallback only
					tmm.summary_call_fn = Callable()
					tmm.fallback_summary_call_fn = Callable()
	return {"applied": applied, "failures": failures}

#endregion
