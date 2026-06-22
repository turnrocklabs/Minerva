class_name PluginSettingsStore
extends RefCounted
## Single source of truth for host-owned, user/LLM-editable settings.
##
## Two scope families:
##   "core"        — built-in settings groups defined in CORE_SCHEMAS.
##   "plugin:<id>" — declared in a plugin manifest's `settings` array.
##
## Every consumer (Preferences UI, MCP preference tools, host.settings capability)
## reads and writes through this store, so section naming, defaults, type coercion,
## and validation all live here rather than being re-implemented per consumer.
## Values persist in config_file.cfg.

const DEFAULT_SUMMARIZATION_MODEL := "gpt-5.4-mini"
const DEFAULT_SUMMARIZATION_PROMPT := "Summarize this conversation. Preserve: key decisions, facts learned, action items, important code snippets, and any unresolved questions. Be concise but complete."

## Built-in settings groups. Each scope maps to a config-file section and a field
## list using the same schema shape as a plugin manifest's `settings` array.
const CORE_SCHEMAS := {
	"core": {
		"section": "Summarization",
		"fields": [
			{
				"key": "model",
				"type": "string",
				"label": "Summarization model",
				"default": DEFAULT_SUMMARIZATION_MODEL,
				"help": "Model id used to distill a conversation into a note.",
			},
			{
				"key": "prompt",
				"type": "multiline",
				"label": "Summarization prompt",
				"default": DEFAULT_SUMMARIZATION_PROMPT,
				"help": "Instruction text; the conversation transcript is appended automatically.",
			},
		],
	},
}

var _plugin_db = null  # PluginDB

## Persistence backend with read(section, key) / write(section, key, value).
## Production injects ConfigSettingsPersist (config_file.cfg); tests inject a fake.
## Keeping the config/autoload reference out of this class keeps it pure and unit-testable.
var _persist = null


func _init(p_plugin_db = null, p_persist = null) -> void:
	_plugin_db = p_plugin_db
	_persist = p_persist


## Resolved value for a key: the persisted value if set, else the schema default,
## else null when the scope or key is unknown.
func get_value(scope: String, key: String) -> Variant:
	var field := _field(scope, key)
	if field.is_empty():
		return null
	var stored: Variant = _read_persisted(_section(scope), key)
	if stored != null:
		return stored
	return field.get("default", null)


## Persist a value after validating it against the field schema.
## Returns {"success": true, "value": <coerced>} or {"success": false, "error": ...}.
func set_value(scope: String, key: String, value: Variant) -> Dictionary:
	var field := _field(scope, key)
	if field.is_empty():
		return _err("unknown setting '%s' for scope '%s'" % [key, scope])
	var res := _coerce(field, value)
	if not res.get("ok", false):
		return _err(res.get("error", "invalid value"))
	_write_persisted(_section(scope), key, res["value"])
	return {"success": true, "value": res["value"]}


## All fields for a scope merged with their current values (for UI + MCP list).
## Returns {"success": true, "scope": ..., "fields": [{...schema, "value": ...}]}.
func list_settings(scope: String) -> Dictionary:
	if not _scope_known(scope):
		return _err("unknown scope '%s'" % scope)
	var out: Array[Dictionary] = []
	for field in _schema(scope):
		if not (field is Dictionary):
			continue
		var entry: Dictionary = (field as Dictionary).duplicate(true)
		entry["value"] = get_value(scope, str(field.get("key", "")))
		out.append(entry)
	return {"success": true, "scope": scope, "fields": out}


## Scopes that currently expose settings: core groups plus plugins declaring `settings`.
func list_scopes() -> Array[String]:
	var scopes: Array[String] = []
	for s in CORE_SCHEMAS.keys():
		scopes.append(s)
	if _plugin_db != null:
		for def in _plugin_db.get_all():
			if def != null and not def.settings.is_empty():
				scopes.append("plugin:%s" % def.id)
	return scopes


# ---------------------------------------------------------------------------
# Persistence (delegated to the injected backend)
# ---------------------------------------------------------------------------

func _read_persisted(section: String, key: String) -> Variant:
	if _persist == null:
		return null
	return _persist.read(section, key)


func _write_persisted(section: String, key: String, value: Variant) -> void:
	if _persist != null:
		_persist.write(section, key, value)


# ---------------------------------------------------------------------------
# Schema + scope resolution
# ---------------------------------------------------------------------------

func _scope_known(scope: String) -> bool:
	if CORE_SCHEMAS.has(scope):
		return true
	if scope.begins_with("plugin:") and _plugin_db != null:
		return _plugin_db.get_by_id(scope.substr(7)) != null
	return false


## Field schema list for a scope, or [] if the scope is unknown.
func _schema(scope: String) -> Array:
	if CORE_SCHEMAS.has(scope):
		return (CORE_SCHEMAS[scope] as Dictionary).get("fields", [])
	if scope.begins_with("plugin:") and _plugin_db != null:
		var def = _plugin_db.get_by_id(scope.substr(7))
		if def != null:
			return def.settings
	return []


## config_file.cfg section backing a scope.
func _section(scope: String) -> String:
	if CORE_SCHEMAS.has(scope):
		return str((CORE_SCHEMAS[scope] as Dictionary).get("section", scope))
	if scope.begins_with("plugin:"):
		return "Plugin:%s" % scope.substr(7)
	return scope


## The schema entry for a single key, or {} if absent.
func _field(scope: String, key: String) -> Dictionary:
	for field in _schema(scope):
		if field is Dictionary and str(field.get("key", "")) == key:
			return field
	return {}


## Coerce and validate a value against a field's declared type.
## Returns {"ok": true, "value": <coerced>} or {"ok": false, "error": ...}.
func _coerce(field: Dictionary, value: Variant) -> Dictionary:
	var t := str(field.get("type", "string"))
	match t:
		"string", "multiline":
			return {"ok": true, "value": str(value)}
		"enum":
			var v := str(value)
			var options: Array = field.get("options", [])
			if not options.has(v):
				return {"ok": false, "error": "'%s' not in options %s" % [v, str(options)]}
			return {"ok": true, "value": v}
		"bool":
			if value is bool:
				return {"ok": true, "value": value}
			if value is String:
				var lv := (value as String).to_lower()
				if lv == "true":
					return {"ok": true, "value": true}
				if lv == "false":
					return {"ok": true, "value": false}
			if value is int or value is float:
				return {"ok": true, "value": bool(value)}
			return {"ok": false, "error": "expected a boolean"}
		"number":
			if value is int or value is float:
				return {"ok": true, "value": value}
			if value is String and (value as String).is_valid_float():
				return {"ok": true, "value": (value as String).to_float()}
			return {"ok": false, "error": "expected a number"}
	return {"ok": false, "error": "unknown setting type '%s'" % t}


func _err(msg: String) -> Dictionary:
	return {"success": false, "error": msg}
