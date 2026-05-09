class_name PluginDB
extends RefCounted
## Persistent registry of installed Minerva plugins.
## Stores plugin records as JSON at user://plugins/plugins.json.
## Manages install/remove/state CRUD; does not start or stop processes.

const DB_PATH := "user://plugins/plugins.json"
const DB_VERSION := 1

## In-memory store: plugin_id -> PluginDefinition
var _plugins: Dictionary = {}

## class_name -> plugin_id for all installed plugins.
## Built lazily during install and loaded from DB at startup.
var _class_name_registry: Dictionary = {}

signal plugins_changed()


func _init() -> void:
	_ensure_data_dir()
	load_db()


# ---------------------------------------------------------------------------
# Install / Remove
# ---------------------------------------------------------------------------

## Register a new plugin from a manifest.json path.
## Returns the parsed PluginDefinition on success, or null on failure.
## Returns a structured error Dictionary instead of null when class_name validation
## fails: {"error": String, "detail": Dictionary} — callers may inspect this.
## For backward-compatibility with callers that check `== null`, failure still
## returns null; the last structured error is available via get_last_install_error().
var _last_install_error: Dictionary = {}

func get_last_install_error() -> Dictionary:
	return _last_install_error

func install(manifest_path: String) -> PluginDefinition:
	_last_install_error = {}
	var def := PluginDefinition.from_manifest(manifest_path)
	if def == null:
		push_error("[PluginDB] Failed to parse manifest: %s" % manifest_path)
		return null

	if _plugins.has(def.id):
		push_warning("[PluginDB] Plugin '%s' is already installed — use update_definition() to replace it" % def.id)
		return null

	# --- class_name validation (design §6.2) ---
	# Scan all panel scripts for class_name declarations.
	def.scan_class_names()

	# Build the cross-plugin registry view (exclude this plugin — it's not installed yet).
	var other_names := _build_class_name_map(def.id)

	# Fetch or lazily build the core class_names index.
	# NOTE: method is `get_all`, not `get`, because GDScript's resolver picks
	# `Object.get(name)` (one-arg) over a class's static `get()` (zero-arg),
	# producing a parse-time "Too few arguments" error.  See _core_class_names.gd.
	var CoreCN = load("res://Scripts/Services/Plugins/_core_class_names.gd")
	var core_names: Array = CoreCN.get_all() if CoreCN != null else []

	var cn_error: Dictionary = def.validate_class_names(other_names, core_names)
	if not cn_error.is_empty():
		_last_install_error = cn_error
		push_error(("[PluginDB] class_name validation failed for '%s': %s — %s") %
			[def.id, str(cn_error.get("error", "")), str(cn_error.get("detail", {}))])
		return null

	# --- Capability validation (DCR-1 grandchild 019dc5d4f6877ae5be60ea02e51dcd38) ---
	# Each declared capability requires specific panel hooks and/or manifest channels.
	# Failing here surfaces silent participation gaps at install time rather than at
	# project save/load.
	var cap_error: Dictionary = def.validate_capabilities()
	if not cap_error.is_empty():
		_last_install_error = cap_error
		push_error(("[PluginDB] capability validation failed for '%s': %s — %s") %
			[def.id, str(cap_error.get("error", "")), str(cap_error.get("detail", {}))])
		return null

	# Register this plugin's class_names into the in-process registry.
	_register_class_names(def)

	_plugins[def.id] = def
	_save()
	plugins_changed.emit()
	return def


## Remove a plugin by id. Returns true if it was found and removed.
func remove(plugin_id: String) -> bool:
	if not _plugins.has(plugin_id):
		return false
	_unregister_class_names(plugin_id)
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
	_class_name_registry.clear()
	for record in records:
		if not record is Dictionary:
			continue
		var def := PluginDefinition.from_dict(record)
		if def == null:
			push_warning("[PluginDB] Skipping invalid plugin record: %s" % JSON.stringify(record))
			continue
		# Reject persisted records that fail validation. Same contract as
		# from_manifest at install time: an invalid definition does not register.
		# Otherwise stale or now-disallowed manifests survive a Minerva restart
		# silently, defeating the install-time deny-by-default gate.
		var errors := def.validate()
		if not errors.is_empty():
			for e in errors:
				push_error("[PluginDB] Plugin '%s' failed validation on reload: %s" % [def.id, e])
			push_warning("[PluginDB] Skipping '%s' (fix manifest and reinstall)" % def.id)
			continue
		# State is always reconstructed as INSTALLED (not persisted)
		def.state = PluginDefinition.State.INSTALLED
		# Restore class_names from persisted data and rebuild registry.
		_register_class_names(def)
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


# ---------------------------------------------------------------------------
# class_name registry helpers
# ---------------------------------------------------------------------------

## Add all class_names from `def` into _class_name_registry.
## No-op if def.class_names is empty.
func _register_class_names(def: PluginDefinition) -> void:
	for cn in def.class_names:
		_class_name_registry[cn] = def.id


## Remove all class_names belonging to `plugin_id` from _class_name_registry.
func _unregister_class_names(plugin_id: String) -> void:
	var to_erase: Array[String] = []
	for cn in _class_name_registry:
		if _class_name_registry[cn] == plugin_id:
			to_erase.append(cn)
	for cn in to_erase:
		_class_name_registry.erase(cn)


## Return a snapshot of the class_name -> plugin_id map, optionally excluding
## one plugin (used during install to check against peers, not self).
func _build_class_name_map(exclude_plugin_id: String = "") -> Dictionary:
	var result: Dictionary = {}
	for cn in _class_name_registry:
		if _class_name_registry[cn] != exclude_plugin_id:
			result[cn] = _class_name_registry[cn]
	return result


## Read-only access to the class_name registry (used by tests and PluginManager).
func get_class_name_registry() -> Dictionary:
	return _class_name_registry.duplicate()
