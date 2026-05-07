## Helpers for skill records with plugin-shipped lifecycle metadata (DCR 019df57b).
##
## Skill records (docket type=skill) gained 6 metadata fields in the docket
## schema chore (docket:019e0020200e) that's the substrate for this work:
##
##   source            "user" | "master" | "plugin:<plugin_id>" (empty = user)
##   customised        bool — true once user has edited a plugin-seeded skill
##   pristine_hash     sha256 hex of canonical JSON of the original manifest entry
##   pristine_content  Dictionary — original manifest entry, kept for diff on update
##   unsatisfied_deps  [str] — tool_deps not currently resolvable in the registry
##   deprecated        bool — true if upstream removed the skill in a later version
##
## This file provides the static helpers Minerva uses to compute the hash, classify
## a record by source, and extract the plugin id.  Persistence is handled by the
## docket layer; nothing here touches disk.
##
## T2 boundary: the install/update/uninstall *flows* live in T3 / T4 / T6.  This
## file owns only the pure-function helpers those flows depend on.
class_name PluginSkillRecord extends RefCounted

const SOURCE_USER := "user"
const SOURCE_MASTER := "master"
const SOURCE_PLUGIN_PREFIX := "plugin:"

## Fields that participate in the skill content hash.
## Whitelist (not blacklist) so newly-added docket fields don't accidentally
## shift the hash and trigger spurious "skill changed upstream" prompts at T4.
## Mirrors `PluginDefinition.REQUIRED_SKILL_FIELDS` + optional `optimization`.
const SKILL_CONTENT_FIELDS := [
	"id", "title", "summary", "system_prompt", "outcome",
	"preconditions", "steps", "tool_deps", "target", "optimization",
]


## Compute a stable hash of a skill manifest entry or saved skill record.
##
## Selects only fields in SKILL_CONTENT_FIELDS, then `JSON.stringify(... sort_keys=true)`
## for canonical (key-order-independent) serialization, and returns a 64-char hex
## SHA-256 digest.
##
## Both shapes hash to the same value as long as the content fields match:
##   - A manifest entry (no source/customised/etc.) coming straight from
##     manifest.json's skills[] array, AND
##   - A docket record (with full runtime metadata) read back via docket_get.
## That equivalence is what T4's update reconciliation relies on to decide if a
## new manifest version is content-identical to what's already installed.
static func compute_hash(entry: Dictionary) -> String:
	var content := {}
	for key in SKILL_CONTENT_FIELDS:
		if entry.has(key):
			content[key] = entry[key]
	var canonical := JSON.stringify(content, "", true)
	return canonical.sha256_text()


## True iff the record came from a plugin install (source begins with "plugin:").
static func is_plugin_seeded(record: Dictionary) -> bool:
	var source := str(record.get("source", ""))
	return source.begins_with(SOURCE_PLUGIN_PREFIX)


## Extract the plugin id from a plugin-sourced record, or "" if not plugin-sourced.
##
## "plugin:demo" → "demo".  "plugin:obs_controller" → "obs_controller".
static func get_plugin_id(record: Dictionary) -> String:
	var source := str(record.get("source", ""))
	if not source.begins_with(SOURCE_PLUGIN_PREFIX):
		return ""
	return source.substr(SOURCE_PLUGIN_PREFIX.length())


## Resolve the canonical source label for a record.
##
## The docket schema's column default is empty string (per ALTER TABLE migration
## of pre-DCR records).  Treat empty as SOURCE_USER so consumers don't have to
## special-case backward compatibility at every read site.
static func normalize_source(record: Dictionary) -> String:
	var source := str(record.get("source", ""))
	if source.is_empty():
		return SOURCE_USER
	return source


## True iff a record has unresolved tool_deps and should be hidden from the
## active picker (T5 reads this).
static func has_unsatisfied_deps(record: Dictionary) -> bool:
	var deps = record.get("unsatisfied_deps", [])
	return deps is Array and not (deps as Array).is_empty()


## True iff the user has edited a plugin-seeded record since install.
## Forms the "fork" branch of the D2 fork-model: customised records get prompt-on-update,
## pristine records get silent overwrite (T4).
static func is_customised(record: Dictionary) -> bool:
	return bool(record.get("customised", false))


## True iff upstream removed this skill in a later plugin version.
## Picker hides deprecated records by default (T5 read site).
static func is_deprecated(record: Dictionary) -> bool:
	return bool(record.get("deprecated", false))
