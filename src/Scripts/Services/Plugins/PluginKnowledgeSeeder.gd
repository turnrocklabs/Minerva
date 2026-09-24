## Plugin-shipped knowledge: a manifest's `knowledge[]` entries seeded as
## Docket kb articles and hints, the counterpart of PluginSkillSeeder.
##
## An entry is {key, type: "kb"|"hint", title, …content}: a kb carries
## `article` (plus optional summary, topic, tags), a hint `value` (plus
## optional component, topic). Records keep the manifest `key` and
## source "plugin:<id>", so skills and people find them by key, never by the
## Docket id. They live in the manifest's `knowledge_project` (default
## "master"), which must already be loaded: a missing project is reported,
## never created, and every Docket call names it.
##
## Provenance: pristine_content is the manifest entry the record was last
## taken from, and pristine_hash the content hash of the record as Docket
## stored it then (read back after each write, so Docket's own text
## normalisation cannot look like an edit). A record whose content no longer
## hashes to pristine_hash has been customised by someone; nothing sets a
## flag for that, so it is always derived.
##
## All Docket access is through `docket_caller.call_tool(name, args)` (the
## DocketManager, or a ToolRegistry in tests).
class_name PluginKnowledgeSeeder extends RefCounted

const Seeder := preload("res://Scripts/Services/Plugins/PluginSkillSeeder.gd")
const Record := preload("res://Scripts/Services/Plugins/PluginSkillRecord.gd")

const DEFAULT_PROJECT := "master"
## Content fields per type: seeded into the record, and hashed. `title` and
## the field after it are required.
const CONTENT_FIELDS := {
	"kb": ["title", "article", "summary", "topic", "tags"],
	"hint": ["title", "value", "component", "topic"],
}
## A plan action for a record whose content is current but which is
## deprecated, has no pristine_hash (its seal was never written), or is a kb
## still in draft: it is revived without touching its text.
const RESTORE := "restore"


## Problems with a manifest's `knowledge` entries and `project`, as
## PluginDefinition.validate reports them. Keys follow the skill id rule
## (^minerva_<plugin_id>_[a-z0-9_]+$) and may not repeat a key or a skill id.
static func validate_manifest(knowledge: Array, project: String, plugin_id: String,
		skill_ids: Array) -> Array[String]:
	var errors: Array[String] = []
	if project.strip_edges().is_empty():
		errors.append("knowledge_project must be a non-empty project name")
	var key_rx := RegEx.create_from_string("^minerva_%s_[a-z0-9_]+$" % plugin_id)
	var seen := {}
	for id in skill_ids:
		seen[str(id)] = true
	for idx in knowledge.size():
		var entry = knowledge[idx]
		if not entry is Dictionary:
			errors.append("knowledge[%d] must be a Dictionary" % idx)
			continue
		var key := str(entry.get("key", ""))
		var label := key if not key.is_empty() else "knowledge[%d]" % idx
		var type := str(entry.get("type", ""))
		if not CONTENT_FIELDS.has(type):
			errors.append("knowledge '%s' type must be kb or hint, not '%s'" % [label, type])
			continue
		if key.is_empty() or key_rx.search(key) == null:
			errors.append("knowledge key '%s' must match '^minerva_%s_[a-z0-9_]+$'" % [label, plugin_id])
		elif seen.has(key):
			errors.append("manifest_duplicate_knowledge_key: '%s'" % key)
		seen[key] = true
		var fields: Array = CONTENT_FIELDS[type]
		for required in fields.slice(0, 2):
			if not entry.get(required, "") is String or entry.get(required, "").strip_edges().is_empty():
				errors.append("knowledge '%s' missing required field '%s'" % [label, required])
		for field in entry:
			if field in ["key", "type"]:
				continue
			if not field in fields:
				errors.append("knowledge '%s' has unknown field '%s'" % [label, field])
			elif field == "tags":
				if not (entry.tags is Array and entry.tags.all(func(t): return t is String)):
					errors.append("knowledge '%s' tags must be an Array of strings" % label)
			elif not entry[field] is String:
				errors.append("knowledge '%s' field '%s' must be a String" % [label, field])
	return errors


## The hash of an entry's (or record's) content fields for its type. Absent,
## null and empty compare equal; tags are compared as a sorted set, the way
## Docket stores them.
static func content_hash(entry: Dictionary) -> String:
	var content := {}
	for field in CONTENT_FIELDS.get(str(entry.get("type", "")), []):
		var value = entry.get(field, "")
		if field == "tags":
			var tags: Array = []
			for tag in (value if value is Array else []):
				if not str(tag) in tags:
					tags.append(str(tag))
			tags.sort()
			value = tags
		else:
			value = str(value) if value != null else ""
		content[field] = value
	return JSON.stringify(content, "", true).sha256_text()


## Whether `project` is loaded (docket_project_list).
static func project_loaded(project: String, docket_caller) -> bool:
	var listed = docket_caller.call_tool("docket_project_list", {})
	if not listed is Dictionary:
		return false
	return listed.get("projects", []).any(func(p) -> bool: return str(p.get("name", "")) == project)


## What seeding `def`'s knowledge would do, with no Docket writes, in the
## shape PluginSkillSeeder.plan_reconcile uses: actions (seed, silent_update,
## prompt_required, restore, no_change; each with `id` = the key, `entry`,
## and for an existing record `record_id` and `existing`), deprecate_record_ids
## for records whose key the manifest dropped, and the `project`. When the
## project is not loaded, nothing is planned, and `missing_project` is set if
## there is knowledge to seed.
static func plan(def, docket_caller) -> Dictionary:
	var project: String = def.knowledge_project
	var result := {"plugin_id": def.id, "project": project, "actions": [], "deprecate_record_ids": []}
	if docket_caller == null:
		return result
	if not project_loaded(project, docket_caller):
		if not def.knowledge.is_empty():
			result["missing_project"] = true
		return result
	var records := _seeded_records(def.id, project, docket_caller)
	var keys := {}
	for entry in def.knowledge:
		var key := str(entry.get("key", ""))
		keys[key] = true
		var existing: Dictionary = records.get(key, {})
		var action := {"id": key, "entry": entry}
		if existing.is_empty():
			action["action"] = Seeder.RECONCILE_SEED
		else:
			action["record_id"] = str(existing.get("id", ""))
			var customised := content_hash(existing) != str(existing.get("pristine_hash", ""))
			var pristine = existing.get("pristine_content", {})
			if content_hash(pristine if pristine is Dictionary else {}) != content_hash(entry):
				action["action"] = Seeder.RECONCILE_PROMPT_REQUIRED if customised else Seeder.RECONCILE_SILENT_UPDATE
				if customised:
					action["existing"] = existing
			elif bool(existing.get("deprecated", false)) or _inactive_kb(existing) \
					or str(existing.get("pristine_hash", "")).is_empty():
				action["action"] = RESTORE
				# An unsealed record still holding the entry's text is sealed.
				action["reseal"] = str(existing.get("pristine_hash", "")).is_empty() \
					and content_hash(existing) == content_hash(entry)
			else:
				action["action"] = Seeder.RECONCILE_NO_CHANGE
		result.actions.append(action)
	for key in records:
		if not keys.has(key) and not bool(records[key].get("deprecated", false)):
			result.deprecate_record_ids.append(str(records[key].get("id", "")))
	return result


## Carry out `plan`. `decisions` maps a key to whether a customised record
## (prompt_required) takes the new content; declined or absent keeps the
## person's text and records the new entry as pristine_content, so the same
## upstream version is not asked about again. Returns counts in
## PluginSkillSeeder's apply_reconcile shape, plus `restored`.
static func apply(plan: Dictionary, decisions: Dictionary, docket_caller) -> Dictionary:
	var counts := {"seeded": 0, "silent_updated": 0, "prompted_accepted": 0, "prompted_declined": 0,
		"restored": 0, "deprecated": 0, "unchanged": 0, "failed": 0}
	if docket_caller == null:
		return counts
	var project := str(plan.get("project", DEFAULT_PROJECT))
	var plugin_id := str(plan.get("plugin_id", ""))
	for action in plan.get("actions", []):
		var entry: Dictionary = action.entry
		var outcome := "unchanged"
		var done := true
		match str(action.action):
			Seeder.RECONCILE_SEED:
				outcome = "seeded"
				done = _create(plugin_id, entry, project, docket_caller)
			Seeder.RECONCILE_SILENT_UPDATE:
				outcome = "silent_updated"
				done = _write(action.record_id, project, entry, true, docket_caller)
			Seeder.RECONCILE_PROMPT_REQUIRED:
				var accepted := bool(decisions.get(action.id, false))
				outcome = "prompted_accepted" if accepted else "prompted_declined"
				done = _write(action.record_id, project, entry, accepted, docket_caller)
			RESTORE:
				outcome = "restored"
				done = _write(action.record_id, project, entry, false, docket_caller, action.get("reseal", false))
		counts[outcome if done else "failed"] += 1
	for record_id in plan.get("deprecate_record_ids", []):
		if _ok(docket_caller.call_tool("docket_update", {"id": record_id, "project": project, "deprecated": true})):
			counts.deprecated += 1
		else:
			counts.failed += 1
	return counts


## At uninstall: unseed `plugin_id`'s knowledge in every loaded project (a
## moved project leaves retired records behind). Returns summed {deleted, kept,
## failed}.
static func unseed_everywhere(plugin_id: String, docket_caller) -> Dictionary:
	var result := {"deleted": 0, "kept": 0, "failed": 0}
	var listed = docket_caller.call_tool("docket_project_list", {}) if docket_caller != null else null
	for project in (listed.get("projects", []) if listed is Dictionary else []):
		var one := unseed(plugin_id, str(project.get("name", "")), docket_caller)
		result.deleted += one.deleted
		result.kept += one.kept
		result.failed += one.failed
	return result


## When a plugin's knowledge moves to another project: mark its records in
## `project` deprecated, keeping them and their ids (a rollback moves back
## and revives them). Returns how many were retired.
static func retire(plugin_id: String, project: String, docket_caller) -> int:
	if docket_caller == null or not project_loaded(project, docket_caller):
		return 0
	var retired := 0
	var records := _seeded_records(plugin_id, project, docket_caller)
	for key in records:
		if not bool(records[key].get("deprecated", false)) and _ok(docket_caller.call_tool("docket_update",
				{"id": str(records[key].get("id", "")), "project": project, "deprecated": true})):
			retired += 1
	return retired


## Delete `plugin_id`'s knowledge records in `project` that nobody changed,
## and hand customised ones to the user, live (source "user", provenance
## cleared, not deprecated, even one the plugin had dropped: the text is the
## person's now). Returns {deleted, kept, failed}, and missing_project when
## `project` is not loaded (nothing was done).
static func unseed(plugin_id: String, project: String, docket_caller) -> Dictionary:
	var result := {"deleted": 0, "kept": 0, "failed": 0}
	if docket_caller == null or not project_loaded(project, docket_caller):
		result["missing_project"] = true
		return result
	var records := _seeded_records(plugin_id, project, docket_caller)
	for key in records:
		var record: Dictionary = records[key]
		var id := str(record.get("id", ""))
		if content_hash(record) == str(record.get("pristine_hash", "")):
			if _ok(docket_caller.call_tool("docket_delete", {"id": id, "project": project})):
				result.deleted += 1
			else:
				result.failed += 1
		elif _ok(docket_caller.call_tool("docket_update", {"id": id, "project": project,
				"source": Record.SOURCE_USER, "pristine_hash": "", "pristine_content": {}, "deprecated": false})):
			result.kept += 1
		else:
			result.failed += 1
	return result


## key -> full record for `plugin_id`'s kb and hint records in `project`.
static func _seeded_records(plugin_id: String, project: String, docket_caller) -> Dictionary:
	var records := {}
	for type in CONTENT_FIELDS:
		var found = docket_caller.call_tool("docket_query", {"project": project,
			"filter": {"type": type, "source": Record.SOURCE_PLUGIN_PREFIX + plugin_id}})
		for item in (found.get("items", []) if found is Dictionary else []):
			var full = _read_record(str(item.get("id", "")), project, docket_caller)
			if not full.is_empty():
				records[str(full.get("key", ""))] = full
	return records


## A kb article still in draft (an archived one was archived by someone).
static func _inactive_kb(record: Dictionary) -> bool:
	return record.get("type") == "kb" and record.get("status") == "draft"


## Every content field of `entry`'s type, absent ones empty, so a field an
## update drops is cleared rather than left behind.
static func _content(entry: Dictionary) -> Dictionary:
	var content := {}
	for field in CONTENT_FIELDS[entry.type]:
		content[field] = entry.get(field, [] if field == "tags" else "")
	return content


static func _create(plugin_id: String, entry: Dictionary, project: String, docket_caller) -> bool:
	var record := _content(entry)
	record.merge({"type": entry.type, "key": entry.key, "project": project,
		"source": Record.SOURCE_PLUGIN_PREFIX + plugin_id, "pristine_content": entry.duplicate(true),
		"deprecated": false})
	var created = docket_caller.call_tool("docket_create", record)
	if not _ok(created):
		push_warning("[PluginKnowledgeSeeder] could not seed '%s': %s" % [entry.key, str(created)])
		return false
	return _settle(str(created.get("id", "")), project, true, docket_caller)


## Update a record from `entry`: its content too when `take_content`, else
## only its provenance (the person's text stays).
## `reseal` re-takes pristine_hash even though the text is kept.
static func _write(record_id: String, project: String, entry: Dictionary, take_content: bool,
		docket_caller, reseal := false) -> bool:
	var changes := _content(entry) if take_content else {}
	changes.merge({"id": record_id, "project": project, "pristine_content": entry.duplicate(true),
		"deprecated": false})
	return _ok(docket_caller.call_tool("docket_update", changes)) \
		and _settle(record_id, project, take_content or reseal, docket_caller)


## After a write: when the plugin's content was stored, take pristine_hash
## from the record as Docket now holds it; and make a kb article active, since
## only active ones are listed (a hint is usable as a draft).
static func _settle(record_id: String, project: String, sealed: bool, docket_caller) -> bool:
	var stored := _read_record(record_id, project, docket_caller)
	if stored.is_empty():
		return false
	if sealed and not _ok(docket_caller.call_tool("docket_update", {"id": record_id, "project": project,
			"pristine_hash": content_hash(stored)})):
		return false
	if _inactive_kb(stored):
		return _ok(docket_caller.call_tool("docket_transition", {"id": record_id, "project": project,
			"to": "active", "note": "plugin knowledge"}))
	return true


static func _read_record(record_id: String, project: String, docket_caller) -> Dictionary:
	var full = docket_caller.call_tool("docket_get", {"id": record_id, "project": project})
	return full if full is Dictionary and not full.has("error") else {}


static func _ok(result) -> bool:
	return result is Dictionary and not result.has("error")
