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

## Typed panel definitions this plugin contributes.
## Each entry is a Dictionary with at minimum {name, kind} plus kind-specific fields.
## See design §2.2 for the full schema.
var ui_panels: Array[Dictionary] = []

## Parallel array of panel names extracted from ui_panels, for fast broker lookups.
## Kept in sync with ui_panels by _from_dict_internal().
var ui_panel_names: Array[String] = []

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

## Whether Minerva should automatically reload this plugin when its files change.
## Separate from autostart — autostart means "start on boot", auto_reload means
## "restart when source files change" (hot reload during development).
var auto_reload: bool = false

## Editor items this plugin contributes to the "New -> Item" creation flow.
## Each entry: {id: String, name: String, panel: String}
var editor_items: Array[Dictionary] = []

## Event declarations from manifest. Each entry: {name: String, payload_schema: Dictionary}
## These are top-level manifest fields — a headless plugin can emit events without a webview.
var events: Array[Dictionary] = []

## State schema from manifest. Describes the shape of the plugin's state updates.
var state_schema: Dictionary = {}

## Current runtime state (set by PluginDB / supervisor, not persisted in manifest)
var state: State = State.INSTALLED

## class_names declared by scripts in this plugin's ui_panels.
## Populated by PluginDB.install() via scan_class_names(); empty until then.
var class_names: Array[String] = []

# ---------------------------------------------------------------------------
# Project-file and project-export hook channels (design §8)
# ---------------------------------------------------------------------------

## Channel the plugin uses to serialise a plugin-scene tab into a .minproj entry.
## Empty string means the plugin has not declared this hook.
## Both project_file channels MUST appear in ui_ipc_messages (allowlist check in
## _from_dict_internal).  Stored as a flat pair for easy lookup; the manifest uses
## a nested { "project_file": { "serialize_channel": "...", "deserialize_channel": "..." } }
## shape which is normalised here.
var project_file_serialize_channel: String = ""

## Channel the plugin uses to deserialise a saved tab_state back into an open panel.
var project_file_deserialize_channel: String = ""

## Channel the plugin calls to collect sidecar files for .minpackage export.
var project_export_collect_channel: String = ""

## Channel the plugin calls after unpack to rewrite absolute paths.
var project_export_apply_channel: String = ""


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
			"panels": ui_panels.duplicate(true),
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
		"auto_reload": auto_reload,
	}
	if not editor_items.is_empty():
		result["editor_items"] = editor_items.duplicate(true)
	if not events.is_empty():
		result["events"] = events.duplicate(true)
	if not state_schema.is_empty():
		result["state"] = {"schema": state_schema}
	if not class_names.is_empty():
		result["class_names"] = Array(class_names)
	if not project_file_serialize_channel.is_empty() or not project_file_deserialize_channel.is_empty():
		result["project_file"] = {
			"serialize_channel": project_file_serialize_channel,
			"deserialize_channel": project_file_deserialize_channel,
		}
	if not project_export_collect_channel.is_empty() or not project_export_apply_channel.is_empty():
		result["project_export"] = {
			"collect_channel": project_export_collect_channel,
			"apply_channel": project_export_apply_channel,
		}
	return result


## Deserialize from a Dictionary (as stored in plugins.json).
static func from_dict(d: Dictionary) -> PluginDefinition:
	var def := _from_dict_internal(d)
	if def == null:
		return null
	def.data_directory = d.get("data_directory", "")
	def.autostart = bool(d.get("autostart", false))
	def.auto_reload = bool(d.get("auto_reload", false))
	for ei in d.get("editor_items", []):
		if ei is Dictionary:
			def.editor_items.append(ei.duplicate(true))
	for ev in d.get("events", []):
		if ev is Dictionary:
			def.events.append(ev.duplicate(true))
	def.state_schema = d.get("state", {}).get("schema", {})
	for cn in d.get("class_names", []):
		def.class_names.append(str(cn))
	# project_file and project_export hooks (design §8)
	var pf: Dictionary = d.get("project_file", {})
	def.project_file_serialize_channel = str(pf.get("serialize_channel", ""))
	def.project_file_deserialize_channel = str(pf.get("deserialize_channel", ""))
	var pe: Dictionary = d.get("project_export", {})
	def.project_export_collect_channel = str(pe.get("collect_channel", ""))
	def.project_export_apply_channel = str(pe.get("apply_channel", ""))
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

	# Validate editor_items panel references — each must name a known ui panel.
	for ei in editor_items:
		if not (ei is Dictionary):
			continue
		var panel_ref: String = ei.get("panel", "")
		if not panel_ref.is_empty() and not ui_panel_names.has(panel_ref):
			errors.append(
				("editor_items entry '%s' references panel '%s' which is not declared in ui.panels") %
				[str(ei.get("id", "")), panel_ref]
			)

	# Validate panel name uniqueness within the plugin.
	var seen_names: Dictionary = {}
	for panel_dict in ui_panels:
		if not (panel_dict is Dictionary):
			continue
		var pname: String = panel_dict.get("name", "")
		if seen_names.has(pname):
			errors.append("Duplicate panel name '%s' in ui.panels" % pname)
		else:
			seen_names[pname] = true

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
	var ipc_allowlist: Array = ui.get("ipc_messages", [])
	for msg in ipc_allowlist:
		def.ui_ipc_messages.append(str(msg))

	var panel_list: Array = ui.get("panels", [])
	for panel in panel_list:
		# §2.2: String entries are rejected — no backward-compat.
		if panel is String:
			push_error(("[PluginDefinition] panel entry must be a typed Dictionary, " +
				"got String '%s'. Use {\"name\": \"%s\", \"kind\": \"html\", ...}") % [str(panel), str(panel)])
			return null

		if not (panel is Dictionary):
			push_error("[PluginDefinition] panel entry must be a Dictionary")
			return null

		var panel_dict: Dictionary = panel as Dictionary
		var parse_result: Variant = _parse_panel_entry(panel_dict, def.ui_ipc_messages)
		if parse_result is Dictionary and parse_result.has("error"):
			push_error(("[PluginDefinition] panel parse error: %s — %s") %
				[str(parse_result.get("error", "")), str(parse_result.get("detail", {}))])
			return null

		var typed_panel: Dictionary = parse_result as Dictionary
		def.ui_panels.append(typed_panel)
		def.ui_panel_names.append(typed_panel.get("name", "") as String)

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

	# Editor items (top-level)
	for ei in data.get("editor_items", []):
		if ei is Dictionary:
			def.editor_items.append(ei.duplicate(true))

	# Events & State (top-level, not under ui)
	for ev in data.get("events", []):
		if ev is Dictionary:
			def.events.append(ev.duplicate(true))
	def.state_schema = data.get("state", {}).get("schema", {})

	# project_file hook channels (design §8.1)
	# Both channels MUST appear in ui.ipc_messages.
	var pf_raw: Variant = data.get("project_file", null)
	if pf_raw != null:
		if not (pf_raw is Dictionary):
			push_error("[PluginDefinition] 'project_file' must be a Dictionary")
			return null
		var pf: Dictionary = pf_raw as Dictionary
		var ser_ch: String = str(pf.get("serialize_channel", ""))
		var des_ch: String = str(pf.get("deserialize_channel", ""))
		if ser_ch.is_empty() or des_ch.is_empty():
			push_error(
				"[PluginDefinition] 'project_file' requires both serialize_channel and " +
				"deserialize_channel; got serialize='%s' deserialize='%s'" %
				[ser_ch, des_ch]
			)
			return null
		if not def.ui_ipc_messages.has(ser_ch):
			push_error(
				("[PluginDefinition] project_file.serialize_channel '%s' is not in " +
				"ui.ipc_messages (allowlist)") % ser_ch
			)
			return null
		if not def.ui_ipc_messages.has(des_ch):
			push_error(
				("[PluginDefinition] project_file.deserialize_channel '%s' is not in " +
				"ui.ipc_messages (allowlist)") % des_ch
			)
			return null
		def.project_file_serialize_channel = ser_ch
		def.project_file_deserialize_channel = des_ch

	# project_export hook channels (design §8.2)
	# Both channels MUST appear in ui.ipc_messages.
	var pe_raw: Variant = data.get("project_export", null)
	if pe_raw != null:
		if not (pe_raw is Dictionary):
			push_error("[PluginDefinition] 'project_export' must be a Dictionary")
			return null
		var pe: Dictionary = pe_raw as Dictionary
		var col_ch: String = str(pe.get("collect_channel", ""))
		var app_ch: String = str(pe.get("apply_channel", ""))
		if col_ch.is_empty() or app_ch.is_empty():
			push_error(
				"[PluginDefinition] 'project_export' requires both collect_channel and " +
				"apply_channel; got collect='%s' apply='%s'" %
				[col_ch, app_ch]
			)
			return null
		if not def.ui_ipc_messages.has(col_ch):
			push_error(
				("[PluginDefinition] project_export.collect_channel '%s' is not in " +
				"ui.ipc_messages (allowlist)") % col_ch
			)
			return null
		if not def.ui_ipc_messages.has(app_ch):
			push_error(
				("[PluginDefinition] project_export.apply_channel '%s' is not in " +
				"ui.ipc_messages (allowlist)") % app_ch
			)
			return null
		def.project_export_collect_channel = col_ch
		def.project_export_apply_channel = app_ch

	return def


## Parse and validate a single typed panel entry Dictionary (design §2.1, §2.2).
##
## Returns the normalised panel Dictionary on success, or a structured error
## Dictionary {error: String, detail: Dictionary} on failure.
##
## ipc_allowlist is the top-level ui.ipc_messages array (already parsed as
## Array[String]); used to validate ipc_channels intersect.
static func _parse_panel_entry(panel: Dictionary, ipc_allowlist: Array[String]) -> Dictionary:
	# --- name (required) ---
	var panel_name: String = panel.get("name", "")
	if panel_name.is_empty():
		return {
			"error": "panel_missing_name",
			"detail": {"panel": panel},
		}

	# --- kind (default "html") ---
	var kind: String = panel.get("kind", "html")
	if kind != "html" and kind != "godot_scene":
		return {
			"error": "panel_unknown_kind",
			"detail": {"name": panel_name, "kind": kind},
		}

	var result: Dictionary = {
		"name": panel_name,
		"kind": kind,
	}

	if kind == "godot_scene":
		# entry_scene required
		var entry_scene: String = panel.get("entry_scene", "")
		if entry_scene.is_empty():
			return {
				"error": "panel_missing_entry_scene",
				"detail": {"name": panel_name},
			}
		# scripts required
		var scripts_raw: Variant = panel.get("scripts", null)
		if scripts_raw == null or not (scripts_raw is Array) or (scripts_raw as Array).is_empty():
			return {
				"error": "panel_missing_scripts",
				"detail": {"name": panel_name},
			}
		var scripts: Array[String] = []
		for s in (scripts_raw as Array):
			scripts.append(str(s))
		result["entry_scene"] = entry_scene
		result["scripts"] = scripts

	elif kind == "html":
		# entry: explicit path, or derived from name as "ui/<name>.html"
		var entry: String = panel.get("entry", "")
		if entry.is_empty():
			entry = ("ui/%s.html") % panel_name
		result["entry"] = entry

	# --- file_extensions (optional) ---
	var file_exts_raw: Variant = panel.get("file_extensions", null)
	if file_exts_raw != null:
		if not (file_exts_raw is Array):
			return {
				"error": "panel_file_extensions_not_array",
				"detail": {"name": panel_name},
			}
		var file_exts: Array[String] = []
		for ext_raw in (file_exts_raw as Array):
			var ext: String = str(ext_raw).to_lower()
			if not ext.begins_with("."):
				return {
					"error": "panel_file_extension_missing_dot",
					"detail": {"name": panel_name, "extension": ext},
				}
			file_exts.append(ext)
		result["file_extensions"] = file_exts

	# --- ipc_channels (optional) — must intersect ui.ipc_messages allowlist ---
	var channels_raw: Variant = panel.get("ipc_channels", null)
	if channels_raw != null:
		if not (channels_raw is Array):
			return {
				"error": "panel_ipc_channels_not_array",
				"detail": {"name": panel_name},
			}
		var channels: Array[String] = []
		for ch_raw in (channels_raw as Array):
			var ch: String = str(ch_raw)
			if not ipc_allowlist.has(ch):
				return {
					"error": "panel_ipc_channel_not_in_allowlist",
					"detail": {"name": panel_name, "channel": ch},
				}
			channels.append(ch)
		result["ipc_channels"] = channels

	# --- save_mode (optional, default "host_owned") — design §7.5 ---
	# Valid values: "host_owned" | "plugin_owned"
	# "host_owned": Minerva calls _on_panel_save_request(), serialises result, writes file.
	# "plugin_owned": Minerva dispatches capability:editor.request_save; plugin writes the file.
	var save_mode_raw: Variant = panel.get("save_mode", null)
	if save_mode_raw == null:
		result["save_mode"] = "host_owned"
	else:
		var save_mode: String = str(save_mode_raw)
		if save_mode != "host_owned" and save_mode != "plugin_owned":
			return {
				"error": "panel_save_mode_invalid",
				"detail": {"name": panel_name, "save_mode": save_mode,
					"allowed": ["host_owned", "plugin_owned"]},
			}
		result["save_mode"] = save_mode

	# --- fullscreen_capable (optional, default false) ---
	result["fullscreen_capable"] = bool(panel.get("fullscreen_capable", false))

	# --- multi_window (optional, default false) ---
	result["multi_window"] = bool(panel.get("multi_window", false))

	return result


# ---------------------------------------------------------------------------
# class_name scanning and prefix validation (design §6)
# ---------------------------------------------------------------------------

## Return the canonical prefix for a plugin id.
##
## Rule (design §6.1, plan-decision item 2):
##   canonical_prefix: strip underscores, upper-case the first char, lower-case the rest.
##
## We do NOT use GDScript's built-in capitalize() because it inserts spaces at
## non-alpha boundaries (underscores, digits), producing "Pcbv 2" for "pcb_v2".
## Instead: strip("_"), then manually upper[0] + lower[1:].
##
## Examples:
##   "cad"            -> "Cad"
##   "obs_controller" -> "Obscontroller"
##   "pcb_v2"         -> "Pcbv2"
static func canonical_prefix(plugin_id: String) -> String:
	var stripped: String = plugin_id.replace("_", "").to_lower()
	if stripped.is_empty():
		return ""
	return stripped[0].to_upper() + stripped.substr(1)


## Scan a .gd file for a top-level `class_name` declaration.
## Matches `class_name <Identifier>` at file start, allowing leading blank
## lines and # comments.  Returns the identifier string, or "" if none found.
##
## We only look at the first 40 non-blank, non-comment lines — class_name
## must appear before any code in GDScript.
static func _scan_script_for_class_name(abs_path: String) -> String:
	if abs_path.is_empty() or not FileAccess.file_exists(abs_path):
		return ""
	var file := FileAccess.open(abs_path, FileAccess.READ)
	if not file:
		return ""
	var lines_checked := 0
	while not file.eof_reached() and lines_checked < 40:
		var line: String = file.get_line().strip_edges()
		# Skip blank lines and comments.
		if line.is_empty() or line.begins_with("#"):
			continue
		lines_checked += 1
		# Match: class_name <Identifier>  (optionally followed by extends)
		if line.begins_with("class_name"):
			var rest: String = line.substr(len("class_name")).strip_edges()
			# rest is "<Identifier>" or "<Identifier> extends ..."
			var space_pos: int = rest.find(" ")
			var cn: String = rest.substr(0, space_pos) if space_pos != -1 else rest
			cn = cn.strip_edges()
			# Sanity: must start with upper-case letter and be a valid identifier.
			if not cn.is_empty() and cn[0] == cn[0].to_upper() and cn[0] != cn[0].to_lower():
				return cn
		# Stop once we hit real code (not class_name, not @tool, not @icon, not blank/comment).
		# Allow @tool and @icon annotations before class_name.
		if not line.begins_with("@tool") and not line.begins_with("@icon"):
			break
	return ""


## Scan all scripts declared in this plugin's ui_panels and populate class_names.
## Requires data_directory to be set.  Idempotent — replaces any prior scan.
##
## `abs_path_resolver` is an optional Callable(rel_path)->String that converts
## a panel-relative path to an absolute path.  When null, paths are resolved as
## data_directory.path_join(rel_path).simplify_path().
func scan_class_names(abs_path_resolver: Callable = Callable()) -> void:
	class_names.clear()
	var seen: Dictionary = {}
	for panel in ui_panels:
		if not (panel is Dictionary):
			continue
		var scripts: Array = panel.get("scripts", [])
		for rel_path in scripts:
			var abs_path: String
			if abs_path_resolver.is_valid():
				abs_path = abs_path_resolver.call(str(rel_path))
			else:
				abs_path = data_directory.path_join(str(rel_path)).simplify_path()
			var cn: String = _scan_script_for_class_name(abs_path)
			if cn.is_empty():
				continue
			if not seen.has(cn):
				seen[cn] = true
				class_names.append(cn)


## Validate this plugin's declared class_names against the install-time policy.
##
## Checks:
##  1. Each class_name matches the canonical-prefix regex for this plugin id.
##  2. No class_name appears more than once within this plugin's scripts.
##  3. No class_name collides with core Minerva class_names or an already-installed
##     plugin's class_names.
##
## Parameters:
##   other_plugin_class_names: Dictionary { class_name -> plugin_id } for
##     all currently-installed plugins (excluding this one).
##   core_class_names: Array[String] of class_names found in Minerva core scripts.
##
## Returns {} on success.
## Returns {"error": String, "detail": Dictionary} on the first failure found.
func validate_class_names(
		other_plugin_class_names: Dictionary,
		core_class_names: Array) -> Dictionary:

	var prefix: String = canonical_prefix(id)
	# Regex: ^<prefix>_[A-Za-z0-9_]+$  (prefix followed by _ then alphanumeric segments)
	var pattern: String = ("^%s_[A-Za-z0-9_]+$") % prefix
	var rx := RegEx.new()
	if rx.compile(pattern) != OK:
		return {
			"error": "class_name_internal_error",
			"detail": {"reason": "failed to compile prefix regex for plugin '%s'" % id},
		}

	# Track names seen so far within this plugin to detect intra-plugin duplicates.
	var seen_within: Dictionary = {}

	for cn in class_names:
		# --- 1. Intra-plugin duplicate check ---
		if seen_within.has(cn):
			return {
				"error": "class_name_duplicated_in_plugin",
				"detail": {
					"class_name": cn,
					"plugin": id,
				},
			}
		seen_within[cn] = true

		# --- 2. Prefix check ---
		if rx.search(cn) == null:
			return {
				"error": "class_name_bad_prefix",
				"detail": {
					"class_name": cn,
					"plugin": id,
					"expected_prefix": prefix,
				},
			}

		# --- 3a. Core collision ---
		if cn in core_class_names:
			return {
				"error": "class_name collision",
				"detail": {
					"class_name": cn,
					"plugin": id,
					"conflicts_with": "core",
				},
			}

		# --- 3b. Other-plugin collision ---
		if other_plugin_class_names.has(cn):
			return {
				"error": "class_name collision",
				"detail": {
					"class_name": cn,
					"plugin": id,
					"conflicts_with": ("plugin:%s") % str(other_plugin_class_names[cn]),
				},
			}

	return {}


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
