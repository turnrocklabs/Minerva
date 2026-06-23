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

## Skill records contributed by this plugin (DCR 019df57b).
## Each entry is a Dictionary mirroring the docket skill schema with required
## keys: id, title, summary, system_prompt, outcome, preconditions, steps,
## tool_deps, target.  Optional: optimization.
## Skill IDs MUST match "^minerva_<id>_[a-z0-9_]+$" (mirrors tool prefix rule).
## Materialised into user.dct on install with source="plugin:<id>".
var skills: Array[Dictionary] = []

## Declarative user-editable settings contributed to the host Preferences UI.
## Each entry: {key, type, label, default?, options? (enum only), help?}.
## type is one of SETTING_TYPES. Values are host-owned and persisted in
## config_file.cfg under [Plugin:<id>]; structural validation is in validate().
var settings: Array[Dictionary] = []

## Optional title for this plugin's Preferences tab. Defaults to the plugin's
## display name when empty.
var settings_title: String = ""

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

## Flat list of host capability grants (e.g. ["notes.create", "artifacts.read"])
var host_capabilities: Array[String] = []

## Network mode ("none" | "localhost" | "unrestricted")
var network_mode: String = "none"

## Filesystem access mode ("none" | "scoped_paths" | "unrestricted")
## "unrestricted" lets a plugin read/write any absolute path the agent supplies —
## parity with Minerva's core MCP file tools (minerva_disk_write / minerva_doc_*),
## which enforce no path policy. Opt-in per plugin; install is the trust act.
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

## Capabilities the plugin opts into.  Each capability is a contract: the platform
## promises certain behavior (e.g. routing serialize/deserialize through the
## plugin), and the plugin promises certain hooks exist on its panel scripts and
## manifest.  Validated at install time by validate_capabilities().
##
## Allowed values: see CAPABILITIES.  Unknown values rejected at parse time.
##
## Plugins MAY ship without any capabilities — they are *opt-in*.  Plugins that
## decline a capability (e.g. a stateless dev-tool that doesn't care about
## project save/load) simply omit it; the platform never asks them to participate.
var capabilities: Array[String] = []

## Allowed capability identifiers.  See validate_capabilities() for the
## per-capability requirement contract.
const CAPABILITIES := [
	"project_state",      # participates in .minproj save/load (panel + server hooks)
	"host_owned_save",    # panel writes its own document file via Ctrl+S
	"project_export",     # contributes sidecar files to .minpackage export
]

## Exact host_capability identifiers that are always permitted.
##
## Two transports exist for plugin↔host calls; THIS list governs only the
## CapabilityBroker transport (backend MCP plugins, declared via
## permissions.host_capabilities). Panel-broker channels (e.g. host.fs.watch,
## attach_buffer) live in ui.panels[].ipc_channels and are NOT validated here.
## See validate_host_capabilities() and CapabilityBroker for the dispatch contract.
const ALLOWED_HOST_CAPABILITIES := [
	"host.echo",
	"host.documents.list_open",
	"host.documents.get_state",
	"host.documents.set_state",
	"host.documents.mark_dirty",
	"host.documents.get_node",
	"host.documents.get_blob",
	"host.documents.patch_state",
	"host.documents.put_blob",
	"host.files.read",
	"host.files.write",
	"host.files.list",
	"host.files.exists",
	"host.files.stat",
	"host.files.mkdir",
	"host.files.delete",
	"host.files.move",
	"host.editors.list",
	"host.editors.export",
	"host.editors.open",
	"host.providers.chat",
	"host.core.session",
	"host.project.open",
	"host.project.current",
	"host.dialogs.file_picker",
	"host.dialogs.directory_picker",
	"host.permissions.grant_scope",
	"host.notify",
	"host.settings.get",
	"host.settings.list",
	"host.models.list_providers",
	"host.models.list_models",
	"host.chat_providers.register",
	"host.pdf.generate",
	"host.terminal.exec",
	"host.terminal.list",
	"host.terminal.read",
	"host.terminal.write",
	"host.terminal.wait",
]

## Namespace prefixes for host_capability values that require at least one
## character after the colon (e.g. "mcp.proxy:minerva_foo" or "secrets:get:h").
## The broker dispatches these families without a fixed enumeration.
const ALLOWED_HOST_CAPABILITY_NAMESPACES := [
	"mcp.proxy:",
	"secrets:",
]

## Required fields on each entry of manifest.skills[] (DCR 019df57b).
## "optimization" is allowed but optional; absent → record stores {}.
const REQUIRED_SKILL_FIELDS := [
	"id", "title", "summary", "system_prompt", "outcome",
	"preconditions", "steps", "tool_deps", "target",
]

## Allowed `type` values for entries in manifest settings[]. "provider" renders a
## dropdown of enabled providers; "model" renders the enabled models of the
## provider named by the field's "provider_key".
const SETTING_TYPES := ["string", "multiline", "enum", "bool", "number", "provider", "model"]

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
	if not skills.is_empty():
		result["skills"] = skills.duplicate(true)
	if not editor_items.is_empty():
		result["editor_items"] = editor_items.duplicate(true)
	if not events.is_empty():
		result["events"] = events.duplicate(true)
	if not settings.is_empty():
		result["settings"] = settings.duplicate(true)
	if not settings_title.is_empty():
		result["settings_title"] = settings_title
	if not state_schema.is_empty():
		result["state"] = {"schema": state_schema}
	if not class_names.is_empty():
		result["class_names"] = Array(class_names)
	if not capabilities.is_empty():
		result["capabilities"] = Array(capabilities)
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
	for cn in d.get("class_names", []):
		def.class_names.append(str(cn))
	# editor_items, events, capabilities, state_schema, project_file, and
	# project_export are already populated by _from_dict_internal; do not
	# re-append here or persisted plugin definitions multiply entries on reload.
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

	# Validate skills (DCR 019df57b).
	# Rules:
	#  - Each entry must be a Dictionary.
	#  - Each entry must contain every key in REQUIRED_SKILL_FIELDS.
	#  - skill.id must match "^minerva_<id>_[a-z0-9_]+$".
	#  - skill.tool_deps must be an Array of non-empty strings (may be empty array).
	#  - skill.id values must be unique within the manifest (manifest_duplicate_skill_id).
	# tool_deps RESOLUTION against the active registry is NOT done here — that
	# happens at install time (T3) where the registry is available.
	if not id.is_empty() and not skills.is_empty():
		var skill_id_rx := RegEx.new()
		var _skill_rx_ok := skill_id_rx.compile("^minerva_%s_[a-z0-9_]+$" % id)
		var seen_skill_ids: Dictionary = {}
		for idx in skills.size():
			var skill_entry: Variant = skills[idx]
			if not (skill_entry is Dictionary):
				errors.append("skills[%d] must be a Dictionary" % idx)
				continue
			var skill_dict: Dictionary = skill_entry as Dictionary
			var s_id: String = str(skill_dict.get("id", ""))
			# Required-field presence
			for field_name in REQUIRED_SKILL_FIELDS:
				if not skill_dict.has(field_name):
					errors.append(
						"skill '%s' missing required field '%s'" %
						[s_id if not s_id.is_empty() else "skills[%d]" % idx, field_name]
					)
			# Prefix
			if s_id.is_empty():
				errors.append("skills[%d] has empty 'id'" % idx)
			elif _skill_rx_ok == OK and skill_id_rx.search(s_id) == null:
				errors.append(
					"skill id '%s' must match '^minerva_%s_[a-z0-9_]+$'" % [s_id, id]
				)
			# Duplicate id
			if not s_id.is_empty():
				if seen_skill_ids.has(s_id):
					errors.append("manifest_duplicate_skill_id: '%s'" % s_id)
				else:
					seen_skill_ids[s_id] = true
			# tool_deps shape
			if skill_dict.has("tool_deps"):
				var tool_deps_raw: Variant = skill_dict.get("tool_deps")
				if not (tool_deps_raw is Array):
					errors.append("skill '%s' tool_deps must be an Array of strings" % s_id)
				else:
					for dep in (tool_deps_raw as Array):
						if not (dep is String):
							errors.append(
								"skill '%s' tool_deps entry must be a String" % s_id
							)
						elif (dep as String).is_empty():
							errors.append(
								"skill '%s' tool_deps entry must be non-empty" % s_id
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

	# Validate host_capabilities entries against the allow-list and namespace rules.
	var hcap_errors := validate_host_capabilities()
	for e in hcap_errors:
		errors.append(e)

	# Validate settings declarations: unique non-empty keys, a known type, and
	# enum entries carrying a non-empty options array.
	if not settings.is_empty():
		var seen_setting_keys: Dictionary = {}
		for idx in settings.size():
			var setting_entry: Variant = settings[idx]
			if not (setting_entry is Dictionary):
				errors.append("settings[%d] must be a Dictionary" % idx)
				continue
			var sd: Dictionary = setting_entry as Dictionary
			var s_key: String = str(sd.get("key", ""))
			var s_ref: String = s_key if not s_key.is_empty() else "settings[%d]" % idx
			if s_key.is_empty():
				errors.append("settings[%d] has empty 'key'" % idx)
			elif seen_setting_keys.has(s_key):
				errors.append("manifest_duplicate_setting_key: '%s'" % s_key)
			else:
				seen_setting_keys[s_key] = true
			var s_type: String = str(sd.get("type", ""))
			if not SETTING_TYPES.has(s_type):
				errors.append("setting '%s' has invalid type '%s' (allowed: %s)" % [s_ref, s_type, str(SETTING_TYPES)])
			if s_type == "enum":
				var opts: Variant = sd.get("options", null)
				if not (opts is Array) or (opts as Array).is_empty():
					errors.append("enum setting '%s' requires a non-empty 'options' array" % s_ref)

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

	# Skills (DCR 019df57b — plugin-shipped skills).
	# Lax parse: collect Dictionary entries; structural and prefix validation
	# happens in validate().  Non-Dictionary entries are skipped silently here
	# so a single malformed entry doesn't drop the whole skills array on parse.
	for skill_entry in data.get("skills", []):
		if skill_entry is Dictionary:
			def.skills.append(skill_entry.duplicate(true))

	# Settings (declarative preferences shown in the host Preferences UI).
	# Lax parse; structural validation happens in validate().
	for setting_entry in data.get("settings", []):
		if setting_entry is Dictionary:
			def.settings.append(setting_entry.duplicate(true))
	def.settings_title = str(data.get("settings_title", ""))

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

	# Capabilities (top-level, optional).  Reject unknown values at parse time so
	# install fails loudly rather than silently treating a typo'd capability as a
	# no-op.  See validate_capabilities() for per-capability requirements.
	var caps_raw: Variant = data.get("capabilities", null)
	if caps_raw != null:
		if not (caps_raw is Array):
			push_error("[PluginDefinition] 'capabilities' must be an Array of Strings")
			return null
		for cap_raw in (caps_raw as Array):
			var cap: String = str(cap_raw)
			if not CAPABILITIES.has(cap):
				push_error(
					("[PluginDefinition] unknown capability '%s' (allowed: %s)") %
					[cap, str(CAPABILITIES)]
				)
				return null
			if not def.capabilities.has(cap):
				def.capabilities.append(cap)

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
	# Valid values: "host_owned" | "plugin_owned" | "none"
	# "host_owned": Minerva calls _on_panel_save_request(), serialises result, writes file.
	# "plugin_owned": Minerva dispatches capability:editor.request_save; plugin writes the file.
	# "none": panel has nothing to persist (smoke tests, dashboards, status views).
	#         Save action is a no-op; the panel does not contribute to project save state.
	var save_mode_raw: Variant = panel.get("save_mode", null)
	if save_mode_raw == null:
		result["save_mode"] = "host_owned"
	else:
		var save_mode: String = str(save_mode_raw)
		if save_mode != "host_owned" and save_mode != "plugin_owned" and save_mode != "none":
			return {
				"error": "panel_save_mode_invalid",
				"detail": {"name": panel_name, "save_mode": save_mode,
					"allowed": ["host_owned", "plugin_owned", "none"]},
			}
		result["save_mode"] = save_mode

	# --- chrome (optional) — Editor-tab chrome contract for PLUGIN_SCENE ---
	# Schema: {"suppress": [<action>, ...]} where each action is one of
	#   "save_all" | "save" | "create_note" | "inject_toggle".
	# Unknown action names → parse error so authors can't silently mistype.
	# Default (chrome key absent or chrome.suppress absent): all chrome controls
	# visible (subject to save_mode == "none" hiding the save buttons).
	const CHROME_ACTIONS := ["save_all", "save", "create_note", "inject_toggle"]
	var chrome_suppress: Array[String] = []
	var chrome_raw: Variant = panel.get("chrome", null)
	if chrome_raw != null:
		if not (chrome_raw is Dictionary):
			return {
				"error": "panel_chrome_not_dict",
				"detail": {"name": panel_name},
			}
		var chrome_dict: Dictionary = chrome_raw as Dictionary
		var suppress_raw: Variant = chrome_dict.get("suppress", null)
		if suppress_raw != null:
			if not (suppress_raw is Array):
				return {
					"error": "panel_chrome_suppress_not_array",
					"detail": {"name": panel_name},
				}
			for action_raw in (suppress_raw as Array):
				var action_name: String = str(action_raw)
				if not CHROME_ACTIONS.has(action_name):
					return {
						"error": "panel_chrome_suppress_unknown_action",
						"detail": {"name": panel_name, "action": action_name,
							"allowed": CHROME_ACTIONS},
					}
				if not chrome_suppress.has(action_name):
					chrome_suppress.append(action_name)
	result["chrome_suppress"] = chrome_suppress

	# --- fullscreen_capable (optional, default false) ---
	result["fullscreen_capable"] = bool(panel.get("fullscreen_capable", false))

	# --- multi_window (optional, default false) ---
	result["multi_window"] = bool(panel.get("multi_window", false))

	# --- render_mode (optional, default "single") — DCR 019dfa66 §T5 ---
	# "single":     panel is self-contained; opens alone (legacy behaviour).
	# "paired_dsl": panel renders a DSL buffer; host opens it next to a text
	#               editor attached to the same DocumentBuffer. Plugin receives
	#               attach_buffer / text_changed IPC from the broker.
	var render_mode_raw: Variant = panel.get("render_mode", null)
	if render_mode_raw == null:
		result["render_mode"] = "single"
	else:
		var render_mode: String = str(render_mode_raw)
		if render_mode != "single" and render_mode != "paired_dsl":
			return {
				"error": "panel_render_mode_invalid",
				"detail": {"name": panel_name, "render_mode": render_mode,
					"allowed": ["single", "paired_dsl"]},
			}
		result["render_mode"] = render_mode

	# --- layout_hint (optional, default "tabs") — DCR 019dfa66 §T5 ---
	# Suggests how the host should arrange the paired editor + render panel.
	# "tabs":         existing tabbed layout (default; host may ignore for paired_dsl).
	# "side_by_side": split the editor pane horizontally (text editor left, render right).
	var layout_hint_raw: Variant = panel.get("layout_hint", null)
	if layout_hint_raw == null:
		result["layout_hint"] = "tabs"
	else:
		var layout_hint: String = str(layout_hint_raw)
		if layout_hint != "tabs" and layout_hint != "side_by_side":
			return {
				"error": "panel_layout_hint_invalid",
				"detail": {"name": panel_name, "layout_hint": layout_hint,
					"allowed": ["tabs", "side_by_side"]},
			}
		result["layout_hint"] = layout_hint

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


## Scan a .gd source file for a top-level `func <method_name>(` declaration.
## Returns true if the declaration appears at the start of any non-blank line
## (indentation tolerated for nested classes, but typical panel scripts declare
## hooks at indentation 0).
##
## We use a regex over the source rather than loading the script and calling
## `script.has_method()` because (a) plugin scripts may have unresolved
## class_name references at install time before they enter the global registry,
## and (b) Script.has_method() returns built-in Object methods too, which would
## false-positive for `_init`, `set`, `get`, etc.
##
## abs_path: absolute filesystem path to the .gd file.
## method_name: bare name without parens, e.g. "_on_panel_save_request".
static func _script_declares_method(abs_path: String, method_name: String) -> bool:
	if abs_path.is_empty() or not FileAccess.file_exists(abs_path):
		return false
	var file := FileAccess.open(abs_path, FileAccess.READ)
	if not file:
		return false
	var text: String = file.get_as_text()
	var rx := RegEx.new()
	# Multiline mode: ^ matches at line starts.  Tolerate tabs/spaces before func.
	if rx.compile("(?m)^[\\t ]*func[\\t ]+%s[\\t ]*\\(" % method_name) != OK:
		return false
	return rx.search(text) != null


## Return true if any script declared by any panel in this plugin defines
## `method_name`.  Resolves script paths the same way scan_class_names() does.
func _any_panel_script_declares(method_name: String) -> bool:
	for panel in ui_panels:
		if not (panel is Dictionary):
			continue
		for rel_path in panel.get("scripts", []):
			var abs_path: String = data_directory.path_join(str(rel_path)).simplify_path()
			if _script_declares_method(abs_path, method_name):
				return true
	return false


## Validate this plugin's host_capabilities array against the allow-list and
## namespace rules.  Returns one error string per unknown or malformed entry.
##
## Match rules (in priority order):
##   1. Empty string           → error
##   2. Exact match in ALLOWED_HOST_CAPABILITIES → ok
##   3. Begins with a prefix in ALLOWED_HOST_CAPABILITY_NAMESPACES AND has at
##      least one char after the prefix → ok
##   4. Otherwise              → error
##
## Cross-check (T5): if any host.files.* capability is declared, the manifest
## must also set permissions.filesystem.mode = "scoped_paths" with at least
## one entry in permissions.filesystem.paths. Surface here so install fails
## loudly rather than runtime returning capability_not_granted on every call.
func validate_host_capabilities() -> Array[String]:
	var errors: Array[String] = []
	var declares_files_cap := false
	for hcap in host_capabilities:
		var cap: String = str(hcap)
		if cap.is_empty():
			errors.append("host_capability entry must not be empty")
			continue
		if cap.begins_with("host.files."):
			declares_files_cap = true
		if ALLOWED_HOST_CAPABILITIES.has(cap):
			continue
		var matched_ns := false
		for ns_prefix in ALLOWED_HOST_CAPABILITY_NAMESPACES:
			if cap.begins_with(ns_prefix) and cap.length() > ns_prefix.length():
				matched_ns = true
				break
		if not matched_ns:
			errors.append(
				"unknown host_capability '%s' (allowed: %s or namespaces: %s)" %
				[cap, str(ALLOWED_HOST_CAPABILITIES), str(ALLOWED_HOST_CAPABILITY_NAMESPACES)]
			)

	# Cross-check: declaring host.files.* requires the manifest to enable
	# scoped filesystem access. Otherwise the broker would have nothing to
	# validate paths against and every read/write would deny — better to
	# surface the gap at install time.
	if declares_files_cap:
		if filesystem_mode != "scoped_paths" and filesystem_mode != "unrestricted":
			errors.append(
				"host.files.* declared but permissions.filesystem.mode is '%s' (must be 'scoped_paths' or 'unrestricted')" %
				filesystem_mode
			)
		elif filesystem_mode == "scoped_paths" and filesystem_paths.is_empty():
			errors.append(
				"host.files.* declared with filesystem.mode = 'scoped_paths' but permissions.filesystem.paths is empty"
			)

	return errors


## Validate this plugin's declared capabilities against required hooks/manifest.
##
## Each declared capability has a contract — the platform will route certain
## flows to the plugin (panel hooks, server channels) only if the corresponding
## artefacts exist.  This validator catches silent participation gaps at install
## time rather than letting them surface as runtime state-loss bugs.
##
## Per-capability requirements:
##   "project_state":
##     - some panel script defines `_on_panel_save_request`
##     - some panel script defines `_on_panel_load_request`
##     - manifest declares non-empty project_file.serialize_channel and
##       project_file.deserialize_channel
##   "host_owned_save":
##     - some panel script defines `_on_panel_save_request`
##     - some panel script defines `_on_panel_load_request`
##     - at least one panel declares non-empty file_extensions
##     - at least one godot_scene panel has save_mode == "host_owned"
##   "project_export":
##     - manifest declares non-empty project_export.collect_channel and
##       project_export.apply_channel
##
## Returns {} on success.
## Returns {"error": String, "detail": Dictionary} on first failure.
##
## Note: server-side MCP tools/list verification is deferred to plugin start,
## not install — install-time can't talk to the server process yet.
func validate_capabilities() -> Dictionary:
	for cap in capabilities:
		match cap:
			"project_state":
				if project_file_serialize_channel.is_empty() or project_file_deserialize_channel.is_empty():
					return {
						"error": "capability_missing_channels",
						"detail": {
							"capability": cap,
							"missing": "project_file.serialize_channel and/or deserialize_channel",
						},
					}
				if not _any_panel_script_declares("_on_panel_save_request"):
					return {
						"error": "capability_missing_hook",
						"detail": {
							"capability": cap,
							"missing_hook": "_on_panel_save_request",
						},
					}
				if not _any_panel_script_declares("_on_panel_load_request"):
					return {
						"error": "capability_missing_hook",
						"detail": {
							"capability": cap,
							"missing_hook": "_on_panel_load_request",
						},
					}

			"host_owned_save":
				if not _any_panel_script_declares("_on_panel_save_request"):
					return {
						"error": "capability_missing_hook",
						"detail": {
							"capability": cap,
							"missing_hook": "_on_panel_save_request",
						},
					}
				if not _any_panel_script_declares("_on_panel_load_request"):
					return {
						"error": "capability_missing_hook",
						"detail": {
							"capability": cap,
							"missing_hook": "_on_panel_load_request",
						},
					}
				var has_extensions: bool = false
				var has_host_owned_panel: bool = false
				for panel in ui_panels:
					if not (panel is Dictionary):
						continue
					var exts: Array = panel.get("file_extensions", [])
					if exts is Array and not exts.is_empty():
						has_extensions = true
					if panel.get("kind", "") == "godot_scene" and panel.get("save_mode", "") == "host_owned":
						has_host_owned_panel = true
				if not has_extensions:
					return {
						"error": "capability_missing_file_extensions",
						"detail": {"capability": cap},
					}
				if not has_host_owned_panel:
					return {
						"error": "capability_no_host_owned_panel",
						"detail": {"capability": cap},
					}

			"project_export":
				if project_export_collect_channel.is_empty() or project_export_apply_channel.is_empty():
					return {
						"error": "capability_missing_channels",
						"detail": {
							"capability": cap,
							"missing": "project_export.collect_channel and/or apply_channel",
						},
					}

			_:
				# Unknown values are rejected at parse time; this branch is unreachable
				# in normal flow but included for defensive completeness.
				return {
					"error": "capability_unknown",
					"detail": {"capability": cap},
				}

	return {}


## Check that an id string is safe: starts with a lowercase letter, followed by
## lowercase letters, digits, or underscores.  Per-char String.is_valid_identifier()
## was incorrect because single digit chars ("2") are NOT valid identifier *starts*,
## but digits in middle positions are fine — switched to a whole-string regex.
static func _is_valid_id(value: String) -> bool:
	if value.is_empty():
		return false
	var rx := RegEx.new()
	if rx.compile("^[a-z][a-z0-9_]*$") != OK:
		return false
	return rx.search(value) != null
