## Skill-seeding pipeline for plugin install (DCR 019df57b T3).
##
## Pure-logic helpers that resolve tool_deps, look up existing records by
## (plugin_id, manifest skill id), and materialise new skills via docket_create.
## No UI here — the install dialog is owned by PluginManager.
##
## Storage convention: a plugin-seeded skill record uses the docket `key` field
## to hold the manifest skill id (e.g. "minerva_demo_make_thing").  This is
## distinct from the docket auto-generated `id` (UUIDv7).  Lookups for
## idempotency / update reconciliation / uninstall query by source + key.
class_name PluginSkillSeeder extends RefCounted

const PluginSkillRecordScript = preload("res://Scripts/Services/Plugins/PluginSkillRecord.gd")


## Resolve tool_deps for each skill in the manifest against the available tool set.
##
## available_tools: Dictionary keyed by tool name (any value).  Typically
## SingletonObject.mcp_manager.tool_registry.  Tools declared in the plugin's
## own manifest (def.tools[].name) are always considered satisfied — they'll
## come online when the plugin starts.
##
## Returns: Array of {skill: Dictionary, unsatisfied: Array[String]}, parallel
## to def.skills, in the same order.
static func resolve_deps(def, available_tools: Dictionary) -> Array:
	var own_tool_names: Dictionary = {}
	for t in def.tools:
		var name := str(t.get("name", ""))
		if not name.is_empty():
			own_tool_names[name] = true

	var resolved: Array = []
	for skill in def.skills:
		var deps_raw = skill.get("tool_deps", [])
		var unsatisfied: Array = []
		if deps_raw is Array:
			for dep in deps_raw:
				var dep_name := str(dep)
				if dep_name.is_empty():
					continue
				if not (own_tool_names.has(dep_name) or available_tools.has(dep_name)):
					unsatisfied.append(dep_name)
		resolved.append({"skill": skill, "unsatisfied": unsatisfied})
	return resolved


## Build the docket_create payload for a plugin-seeded skill.
##
## Stores the manifest skill id in `key` for stable lookup.  Captures all
## lifecycle metadata: source, customised=false (initial), pristine_hash,
## pristine_content (verbatim manifest entry), unsatisfied_deps, deprecated=false.
static func build_install_record(plugin_id: String, skill_entry: Dictionary, unsatisfied: Array) -> Dictionary:
	var tool_deps_copy: Array = []
	if skill_entry.get("tool_deps", []) is Array:
		tool_deps_copy = (skill_entry.get("tool_deps", []) as Array).duplicate()
	var optimization_copy: Dictionary = {}
	if skill_entry.get("optimization", {}) is Dictionary:
		optimization_copy = (skill_entry.get("optimization", {}) as Dictionary).duplicate(true)

	return {
		"type": "skill",
		# Stable lookup key — manifest skill id (e.g. "minerva_demo_make_thing").
		# Distinct from the docket record's auto-generated UUIDv7 id.
		"key": str(skill_entry.get("id", "")),
		# Content fields.
		"title": str(skill_entry.get("title", "")),
		"summary": str(skill_entry.get("summary", "")),
		"system_prompt": str(skill_entry.get("system_prompt", "")),
		"outcome": str(skill_entry.get("outcome", "")),
		"preconditions": str(skill_entry.get("preconditions", "")),
		"steps": str(skill_entry.get("steps", "")),
		"tool_deps": tool_deps_copy,
		"target": str(skill_entry.get("target", "all")),
		"optimization": optimization_copy,
		# Plugin-shipped lifecycle metadata (DCR 019df57b).
		"source": PluginSkillRecordScript.SOURCE_PLUGIN_PREFIX + plugin_id,
		"customised": false,
		"pristine_hash": PluginSkillRecordScript.compute_hash(skill_entry),
		"pristine_content": skill_entry.duplicate(true),
		"unsatisfied_deps": unsatisfied.duplicate(),
		"deprecated": false,
	}


## Look up an existing plugin-seeded skill record by (plugin_id, manifest skill id).
##
## docket_caller: any object exposing a `call_tool(name, args)` method.  In
## production this is SingletonObject.docket_manager; in tests pass a
## ToolRegistry directly (call_tool is the same shape).
##
## Returns the full record dict, or {} if none found.
static func find_existing_record(plugin_id: String, manifest_skill_id: String, docket_caller) -> Dictionary:
	if docket_caller == null:
		return {}
	var query_result = docket_caller.call_tool("docket_query", {
		"filter": {
			"type": "skill",
			"source": PluginSkillRecordScript.SOURCE_PLUGIN_PREFIX + plugin_id,
			"key": manifest_skill_id,
		},
	})
	if not (query_result is Dictionary):
		return {}
	var items: Array = query_result.get("items", [])
	if items.is_empty():
		return {}
	# Re-fetch via docket_get for the full record (lean query may omit fields).
	var first_id := str(items[0].get("id", ""))
	if first_id.is_empty():
		return {}
	var full = docket_caller.call_tool("docket_get", {"id": first_id})
	if full is Dictionary and not full.has("error"):
		return full
	return {}


## Materialise resolved skills into the docket as new records.  Idempotent:
##
##   - No existing record       → docket_create  (counted as `seeded`)
##   - Existing, hash matches   → no action      (counted as `skipped`)
##   - Existing, hash differs   → no action      (counted as `deferred_to_update`,
##                                                T4 reconciliation handles it)
##
## Returns: {"seeded": int, "skipped": int, "deferred_to_update": int}.
## On individual create errors, logs and continues — one bad skill doesn't fail
## the whole install.
static func materialize(plugin_id: String, resolved: Array, docket_caller) -> Dictionary:
	var seeded := 0
	var skipped := 0
	var deferred := 0
	if docket_caller == null:
		return {"seeded": 0, "skipped": 0, "deferred_to_update": 0, "error": "no_docket_caller"}

	for entry in resolved:
		var skill = entry.get("skill", {})
		var unsatisfied = entry.get("unsatisfied", [])
		var manifest_skill_id := str(skill.get("id", ""))
		if manifest_skill_id.is_empty():
			continue

		var pristine_hash := PluginSkillRecordScript.compute_hash(skill)
		var existing := find_existing_record(plugin_id, manifest_skill_id, docket_caller)

		if not existing.is_empty():
			var existing_hash := str(existing.get("pristine_hash", ""))
			if existing_hash == pristine_hash:
				skipped += 1
				continue
			else:
				# Content changed since last install — T4 reconciliation owns
				# the update path (silent for pristine, prompt for customised).
				deferred += 1
				continue

		var record := build_install_record(plugin_id, skill, unsatisfied)
		var create_result = docket_caller.call_tool("docket_create", record)
		if create_result is Dictionary and not create_result.has("error"):
			seeded += 1
		else:
			push_warning("[PluginSkillSeeder] docket_create failed for skill '%s' of plugin '%s': %s" %
				[manifest_skill_id, plugin_id, str(create_result)])

	return {"seeded": seeded, "skipped": skipped, "deferred_to_update": deferred}
