class_name PluginDB
extends RefCounted
## Persistent registry of installed Minerva plugins.
## Stores plugin records as JSON at user://plugins/plugins.json.
## Manages install/remove/state CRUD; does not start or stop processes.

const DB_PATH := "user://plugins/plugins.json"
const DB_VERSION := 1

## In-memory store: plugin_id -> PluginDefinition
var _plugins: Dictionary = {}

signal plugins_changed()


func _init() -> void:
	_ensure_data_dir()
	load_db()


# ---------------------------------------------------------------------------
# Install / Remove
# ---------------------------------------------------------------------------

## Register a new plugin from a manifest.json path.
## Returns the parsed PluginDefinition on success, or null on failure.
func install(manifest_path: String) -> PluginDefinition:
	var def := PluginDefinition.from_manifest(manifest_path)
	if def == null:
		push_error("[PluginDB] Failed to parse manifest: %s" % manifest_path)
		return null

	if _plugins.has(def.id):
		push_warning("[PluginDB] Plugin '%s' is already installed — use update_definition() to replace it" % def.id)
		return null

	_plugins[def.id] = def
	_save()
	plugins_changed.emit()
	return def


## Remove a plugin by id. Returns true if it was found and removed.
func remove(plugin_id: String) -> bool:
	if not _plugins.has(plugin_id):
		return false
	_plugins.erase(plugin_id)
	_save()
	plugins_changed.emit()
	return true


# ---------------------------------------------------------------------------
# Read
# ---------------------------------------------------------------------------

## Get a plugin by id, or null if not found.
func get_by_id(plugin_id: String) -> PluginDefinition:
	return _plugins.get(plugin_id, null)


## Get all installed plugins as an Array[PluginDefinition].
func get_all() -> Array[PluginDefinition]:
	var result: Array[PluginDefinition] = []
	for def in _plugins.values():
		result.append(def)
	return result


## Get all plugins in a specific runtime state.
func get_by_status(status: PluginDefinition.State) -> Array[PluginDefinition]:
	var result: Array[PluginDefinition] = []
	for def in _plugins.values():
		if def.state == status:
			result.append(def)
	return result


## Get all plugins with autostart = true.
func get_autostart_plugins() -> Array[PluginDefinition]:
	var result: Array[PluginDefinition] = []
	for def in _plugins.values():
		if def.autostart:
			result.append(def)
	return result


## Returns true if a plugin with the given id is registered.
func has_plugin(plugin_id: String) -> bool:
	return _plugins.has(plugin_id)


# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

## Update the runtime state of a plugin.
## This is the only mutation that does NOT trigger a file save, since state
## is transient and reconstructed on each launch.
func update_state(plugin_id: String, new_state: PluginDefinition.State) -> bool:
	var def: PluginDefinition = _plugins.get(plugin_id, null)
	if def == null:
		return false
	def.state = new_state
	return true


## Replace the stored definition for an already-installed plugin.
## Use this to apply manifest changes after an upgrade.
func update_definition(def: PluginDefinition) -> bool:
	if not _plugins.has(def.id):
		push_warning("[PluginDB] Cannot update unknown plugin '%s' — install it first" % def.id)
		return false
	# Preserve runtime state across updates
	def.state = _plugins[def.id].state
	_plugins[def.id] = def
	_save()
	plugins_changed.emit()
	return true


## Set the autostart flag for a plugin and persist the change.
func set_autostart(plugin_id: String, enabled: bool) -> bool:
	var def: PluginDefinition = _plugins.get(plugin_id, null)
	if def == null:
		return false
	def.autostart = enabled
	_save()
	return true


## Set the auto_reload flag for a plugin and persist the change.
## When true, PluginManager will restart this plugin automatically when
## its source files change (hot reload for development).
func set_auto_reload(plugin_id: String, enabled: bool) -> bool:
	var def: PluginDefinition = _plugins.get(plugin_id, null)
	if def == null:
		return false
	def.auto_reload = enabled
	_save()
	return true


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

## Load plugin records from disk. Called automatically in _init().
func load_db() -> Error:
	if not FileAccess.file_exists(DB_PATH):
		return OK  # Empty database is valid

	var file := FileAccess.open(DB_PATH, FileAccess.READ)
	if not file:
		push_error("[PluginDB] Cannot open %s" % DB_PATH)
		return FileAccess.get_open_error()

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("[PluginDB] Failed to parse %s" % DB_PATH)
		return ERR_PARSE_ERROR

	var root: Dictionary = json.data if json.data is Dictionary else {}
	var records: Array = root.get("plugins", [])

	_plugins.clear()
	for record in records:
		if not record is Dictionary:
			continue
		var def := PluginDefinition.from_dict(record)
		if def == null:
			push_warning("[PluginDB] Skipping invalid plugin record: %s" % JSON.stringify(record))
			continue
		# Validate after loading (log warnings but don't discard)
		var errors := def.validate()
		for e in errors:
			push_warning("[PluginDB] Plugin '%s': %s" % [def.id, e])
		# State is always reconstructed as INSTALLED (not persisted)
		def.state = PluginDefinition.State.INSTALLED
		_plugins[def.id] = def

	return OK


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _save() -> void:
	var records: Array = []
	for def in _plugins.values():
		records.append(def.to_dict())

	var data := {
		"version": DB_VERSION,
		"plugins": records,
	}

	var json := JSON.stringify(data, "\t")
	var file := FileAccess.open(DB_PATH, FileAccess.WRITE)
	if not file:
		push_error("[PluginDB] Cannot write %s: %s" % [DB_PATH, FileAccess.get_open_error()])
		return

	file.store_string(json)
	file.close()


func _ensure_data_dir() -> void:
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("plugins"):
		dir.make_dir("plugins")
