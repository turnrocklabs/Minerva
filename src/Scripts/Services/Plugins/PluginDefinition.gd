class_name PluginDefinition
extends RefCounted
## Data model for a Minerva plugin.
## Plugins are supervised out-of-process services that communicate via stdio MCP transport.
## A plugin is defined by a manifest.json file in its directory.

# ---------------------------------------------------------------------------
# Runtime state enum
# ---------------------------------------------------------------------------

enum State {
	INSTALLED,    ## Plugin is registered but not running
	STARTING,     ## Process is being launched
	RUNNING,      ## Process is up and MCP handshake completed
	STOPPED,      ## Cleanly stopped by user or Minerva shutdown
	ERROR,        ## Exited with non-zero code
	CRASH_LOOP,   ## Restarted too many times in a short window
}

# ---------------------------------------------------------------------------
# Identity fields
# ---------------------------------------------------------------------------

## Unique machine-readable plugin identifier (e.g. "myplugin")
var id: String = ""

## Human-readable display name
var name: String = ""

## Semantic version string (e.g. "0.1.0")
var version: String = ""

## Minimum host API version this plugin requires (currently "1")
var host_api_version: String = "1"

# ---------------------------------------------------------------------------
# Backend / launch configuration
# ---------------------------------------------------------------------------

## Transport type — only "stdio" is supported in v1
var transport: String = "stdio"

## Command used to launch the plugin process (e.g. "python plugin.py")
var entrypoint: String = ""

## Additional CLI arguments passed after the entrypoint
var args: Array[String] = []

## Working directory for the process. Empty = plugin's own directory.
var working_dir: String = ""

# ---------------------------------------------------------------------------
# UI / IPC configuration
# ---------------------------------------------------------------------------

## Panel names this plugin wants to register (for future UI hosting)
var ui_panels: Array[String] = []

## IPC message names this plugin handles (e.g. "myplugin.do_thing")
var ui_ipc_messages: Array[String] = []

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

## Tool definitions as parsed from the manifest's "tools" array.
## Each entry is a Dictionary with keys: name, description, input_schema.
## Tool names must start with "minerva_<id>_".
var tools: Array[Dictionary] = []

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

## Flat list of host capability grants (e.g. ["notes.create", "artifacts.read"])
var host_capabilities: Array[String] = []

## Network mode ("none" | "localhost" | "unrestricted")
var network_mode: String = "none"

## Filesystem access mode ("none" | "scoped_paths")
var filesystem_mode: String = "none"

## Paths the plugin is allowed to access (only relevant when filesystem_mode = "scoped_paths")
var filesystem_paths: Array[String] = []

# ---------------------------------------------------------------------------
# Runtime / management fields
# ---------------------------------------------------------------------------

## Absolute path to the directory containing the plugin's manifest.json
var data_directory: String = ""

## Whether Minerva should start this plugin automatically on launch
var autostart: bool = false

## Current runtime state (set by PluginDB / supervisor, not persisted in manifest)
var state: State = State.INSTALLED


# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------

func _init(p_id: String = "") -> void:
	id = p_id


# ---------------------------------------------------------------------------
# Manifest parsing
# ---------------------------------------------------------------------------

## Parse a manifest.json file and return a PluginDefinition, or null on failure.
## `path` should be the absolute or res:// path to the manifest.json file.
static func from_manifest(path: String) -> PluginDefinition:
	if not FileAccess.file_exists(path):
		push_error("[PluginDefinition] Manifest not found: %s" % path)
		return null

	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("[PluginDefinition] Cannot open manifest: %s" % path)
		return null

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("[PluginDefinition] Invalid JSON in manifest: %s" % path)
		return null

	var data: Dictionary = json.data if json.data is Dictionary else {}
	var def := _from_dict_internal(data)

	if def == null:
		return null

	# Derive data_directory from the manifest path
	def.data_directory = path.get_base_dir()

	# Validate required fields
	var errors := def.validate()
	if not errors.is_empty():
		for e in errors:
			push_error("[PluginDefinition] Validation error in '%s': %s" % [path, e])
		return null

	return def


# ---------------------------------------------------------------------------
# Serialization
# ---------------------------------------------------------------------------

## Serialize to a Dictionary (for JSON persistence in plugins.json).
func to_dict() -> Dictionary:
	var result := {
		"id": id,
		"name": name,
		"version": version,
		"host_api_version": host_api_version,
		"backend": {
			"transport": transport,
			"entrypoint": entrypoint,
			"args": Array(args),
			"working_dir": working_dir,
		},
		"ui": {
			"panels": Array(ui_panels),
			"ipc_messages": Array(ui_ipc_messages),
		},
		"tools": tools.duplicate(true),
		"permissions": {
			"host_capabilities": Array(host_capabilities),
			"network": {
				"mode": network_mode,
			},
			"filesystem": {
				"mode": filesystem_mode,
				"paths": Array(filesystem_paths),
			},
		},
		"data_directory": data_directory,
		"autostart": autostart,
	}
	return result


## Deserialize from a Dictionary (as stored in plugins.json).
static func from_dict(d: Dictionary) -> PluginDefinition:
	var def := _from_dict_internal(d)
	if def == null:
		return null
	def.data_directory = d.get("data_directory", "")
	def.autostart = bool(d.get("autostart", false))
	return def


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

## Returns an array of error strings. Empty array means the definition is valid.
func validate() -> Array[String]:
	var errors: Array[String] = []

	if id.is_empty():
		errors.append("'id' is required")
	elif not _is_valid_id(id):
		errors.append("'id' must be lowercase alphanumeric with underscores only (got: '%s')" % id)

	if name.is_empty():
		errors.append("'name' is required")

	if version.is_empty():
		errors.append("'version' is required")

	if entrypoint.is_empty():
		errors.append("'backend.entrypoint' is required")

	if transport != "stdio":
		errors.append("'backend.transport' must be 'stdio' (got: '%s')" % transport)

	# Validate tool name prefixes
	var expected_prefix := "minerva_%s_" % id
	for tool_entry in tools:
		var tool_name: String = tool_entry.get("name", "")
		if not tool_name.begins_with(expected_prefix):
			errors.append(
				"Tool '%s' must start with '%s'" % [tool_name, expected_prefix]
			)

	return errors


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Shared parsing logic used by both from_manifest and from_dict.
static func _from_dict_internal(data: Dictionary) -> PluginDefinition:
	if not data is Dictionary or data.is_empty():
		return null

	var def := PluginDefinition.new(data.get("id", ""))
	def.name = data.get("name", "")
	def.version = data.get("version", "")
	def.host_api_version = str(data.get("host_api_version", "1"))

	# Backend
	var backend: Dictionary = data.get("backend", {})
	def.transport = backend.get("transport", "stdio")
	def.entrypoint = backend.get("entrypoint", "")
	def.working_dir = backend.get("working_dir", "")
	for arg in backend.get("args", []):
		def.args.append(str(arg))

	# UI
	var ui: Dictionary = data.get("ui", {})
	for panel in ui.get("panels", []):
		def.ui_panels.append(str(panel))
	for msg in ui.get("ipc_messages", []):
		def.ui_ipc_messages.append(str(msg))

	# Tools
	for tool_entry in data.get("tools", []):
		if tool_entry is Dictionary:
			def.tools.append(tool_entry.duplicate(true))

	# Permissions
	var perms: Dictionary = data.get("permissions", {})
	for cap in perms.get("host_capabilities", []):
		def.host_capabilities.append(str(cap))
	var network: Dictionary = perms.get("network", {})
	def.network_mode = network.get("mode", "none")
	var filesystem: Dictionary = perms.get("filesystem", {})
	def.filesystem_mode = filesystem.get("mode", "none")
	for p in filesystem.get("paths", []):
		def.filesystem_paths.append(str(p))

	return def


## Check that an id string is safe: lowercase letters, digits, underscores only.
static func _is_valid_id(value: String) -> bool:
	if value.is_empty():
		return false
	for i in range(value.length()):
		var ch := value[i]
		if not (ch.is_valid_identifier() or ch == "_"):
			return false
		if ch != ch.to_lower():
			return false
	return true
