class_name PluginEditorRegistry
extends RefCounted
## Registry that maps plugin-contributed file extensions and editor kinds to
## (plugin_id, panel_name) pairs.  Single source of truth for:
##   - File-dialog filter population (list_extensions)
##   - open-file routing in EditorContainer.open_file()
##   - "File → New" submenu population (list_editor_kinds)
##
## Design §7.2.
##
## Ownership: constructed by SingletonObject as `plugin_editor_registry`.
## Wired into installed DB changes via SingletonObject.initialize_plugins() —
## see NOTE at bottom of this file.
##
## Extension collision rules (design §7.3):
##   - Core extensions (.md, .py, .gd, .minkb, etc.) always win;
##     a plugin that declares a core extension gets a warning and the
##     extension is silently skipped (panel still usable via "New →").
##   - Required providers take precedence over optional providers. Equal-rank
##     conflicts refuse the later registration, naming both providers.
## Claims belong to installed definitions, including stopped providers.
##
## NOTE: PluginEditorRegistry is NOT registered as a Godot autoload.
## SingletonObject constructs it as a plain property:
##   var plugin_editor_registry: PluginEditorRegistry = PluginEditorRegistry.new()
## Registrations are reconciled in place so refused updates preserve prior claims.


## Core file extensions that plugin registrations must never override.
## Derived from SingletonObject.supported_text_formats plus the typed-editor formats.
## Keep in sync with open_file() in vboxEditor.gd and the FileDialog filters in Editor._ready().
const CORE_EXTENSIONS: PackedStringArray = [
	# Graphics
	".png", ".jpg", ".jpeg",
	# Typed editors
	".minkb",
	# Text / code (from supported_text_formats)
	".txt", ".rs", ".toml", ".md", ".json", ".xml", ".log",
	".py", ".cs", ".minproj", ".gd", ".tscn", ".godot", ".go", ".java",
	".html",
]


const SPREADSHEET_EXTENSIONS: PackedStringArray = [".minsheet", ".csv", ".tsv", ".xlsx"]
const SPREADSHEET_SAVE_EXTENSIONS: PackedStringArray = [".minsheet", ".csv"]
var _required_ids: Array[String] = []
var _registration_errors: Dictionary[String, String] = {}


func _init(required_ids: Array[String] = []) -> void:
	_required_ids = required_ids.duplicate()


## Required claims reconcile first; each rank preserves persisted install order.
func reconciliation_order(definitions: Array[PluginDefinition]) -> Array[PluginDefinition]:
	var required: Array[PluginDefinition] = []
	var optional: Array[PluginDefinition] = []
	for definition: PluginDefinition in definitions:
		if definition.id in _required_ids:
			required.append(definition)
		else:
			optional.append(definition)
	return required + optional


static func is_spreadsheet_extension(extension: String) -> bool:
	return extension.to_lower() in SPREADSHEET_EXTENSIONS


func resolve_file(extension: String) -> Dictionary:
	var key := extension.strip_edges().to_lower()
	if not key.begins_with("."):
		key = "." + key
	var claimed := resolve_extension(key)
	if not claimed.is_empty():
		return claimed
	return {"plugin_id": "sheets", "panel_name": "sheets_panel", "file_actions": ["open", "import", "create"]} if is_spreadsheet_extension(key) else {}


## extension (lowercased, leading '.') -> { plugin_id: String, panel_name: String }
var _ext_to_panel: Dictionary = {}

## editor_item_id -> { plugin_id: String, panel_name: String, default_filename: String,
##                     item_name: String }
## The insertion order is preserved (GDScript Dictionary is ordered) and is used
## by list_editor_kinds() to return items in registration order.
var _kind_to_panel: Dictionary = {}

## plugin_id -> Array[String] of extensions registered by this plugin.
## Removed only when its installed definition is removed or replaced.
var _plugin_extensions: Dictionary = {}

## plugin_id -> Array[String] of editor_item ids registered by this plugin.
## Removed only when its installed definition is removed or replaced.
var _plugin_kinds: Dictionary = {}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Register all godot_scene panel extensions and editor_items from a PluginDefinition.
## `def` must have .id, .ui_panels (Array[Dictionary]), and .editor_items (Array[Dictionary]).
##
## Returns an Array[String] of warning messages (empty means clean registration).
## A conflicting provider claim refuses the complete registration atomically.
## Core reservations remain warnings and skip only that extension.
func register_plugin(def) -> Array[String]:
	var warnings: Array[String] = []
	if def == null:
		warnings.append("PluginEditorRegistry.register_plugin: def is null")
		return warnings

	var plugin_id: String = str(def.id) if "id" in def else ""
	if plugin_id.is_empty():
		warnings.append("PluginEditorRegistry.register_plugin: def.id is empty")
		return warnings

	var registered_exts: Array[String] = []
	var registered_kinds: Array[String] = []
	var staged_extensions: Dictionary = {}
	var staged_kinds: Dictionary = {}

	# --- 1. File extensions from godot_scene panels ---
	var ui_panels: Array = def.ui_panels if "ui_panels" in def else []
	for panel_dict in ui_panels:
		if not panel_dict is Dictionary:
			continue
		var kind: String = panel_dict.get("kind", "html")
		if kind != "godot_scene":
			continue
		var panel_name: String = panel_dict.get("name", "")
		if panel_name.is_empty():
			continue
		var file_exts: Array = panel_dict.get("file_extensions", [])
		for ext_raw in file_exts:
			var ext: String = str(ext_raw).strip_edges().to_lower()
			if ext.is_empty():
				continue
			if not ext.begins_with("."):
				ext = "." + ext

			# Core-extension collision check.
			if ext in CORE_EXTENSIONS:
				var w: String = (
					("PluginEditorRegistry: plugin '%s' declares extension '%s' " +
					"which is a core extension — extension skipped (use 'New →' instead)") %
					[plugin_id, ext]
				)
				warnings.append(w)
				continue

			if staged_extensions.has(ext) and staged_extensions[ext].panel_name != panel_name:
				return _refused(plugin_id, "PluginEditorRegistry: plugin '%s' declares '%s' for two panels" % [plugin_id, ext])
			var previous: Dictionary = _ext_to_panel.get(ext, {})
			if _skip_required_claim(plugin_id, previous):
				warnings.append("PluginEditorRegistry: optional '%s' skips '%s', owned by required '%s'" % [plugin_id, ext, previous.plugin_id])
				continue
			var conflict := _conflict(ext, plugin_id, previous)
			if not conflict.is_empty():
				return _refused(plugin_id, conflict)

			if not previous.is_empty() and previous.get("plugin_id") != plugin_id:
				warnings.append("PluginEditorRegistry: optional '%s' skips '%s', owned by required '%s'" % [previous.plugin_id, ext, plugin_id])
			staged_extensions[ext] = {
				"plugin_id":   plugin_id,
				"panel_name":  panel_name,
				"render_mode": panel_dict.get("render_mode", "single"),
				"layout_hint": panel_dict.get("layout_hint", "tabs"),
				"file_actions": panel_dict.get("file_actions", ["open", "create"]),
			}
			registered_exts.append(ext)

	# --- 2. Editor kinds from editor_items ---
	var editor_items: Array = def.editor_items if "editor_items" in def else []
	for ei in editor_items:
		if not ei is Dictionary:
			continue
		var item_id: String = ei.get("id", "")
		var item_name: String = ei.get("name", "")
		var panel_name: String = ei.get("panel", "")
		var default_filename: String = ei.get("default_filename", "untitled")
		if item_id.is_empty() or panel_name.is_empty():
			continue

		# Verify the referenced panel is a godot_scene panel.
		var panel_is_scene := false
		for panel_dict in ui_panels:
			if panel_dict is Dictionary \
					and panel_dict.get("name", "") == panel_name \
					and panel_dict.get("kind", "html") == "godot_scene":
				panel_is_scene = true
				break
		if not panel_is_scene:
			# html-kind panels are registered via the existing CreatableItemRegistry path.
			continue

		var previous_kind: Dictionary = _kind_to_panel.get(item_id, {})
		if _skip_required_claim(plugin_id, previous_kind):
			warnings.append("PluginEditorRegistry: optional '%s' skips editor kind '%s', owned by required '%s'" % [plugin_id, item_id, previous_kind.plugin_id])
			continue
		var kind_conflict := _conflict(item_id, plugin_id, previous_kind)
		if not kind_conflict.is_empty():
			return _refused(plugin_id, kind_conflict)
		if not previous_kind.is_empty() and previous_kind.get("plugin_id") != plugin_id:
			warnings.append("PluginEditorRegistry: optional '%s' skips editor kind '%s', owned by required '%s'" % [previous_kind.plugin_id, item_id, plugin_id])
		var actions: Array[String] = ["open", "create"]
		for panel_value: Variant in ui_panels:
			if not panel_value is Dictionary:
				continue
			var panel: Dictionary = panel_value
			if panel.get("name") == panel_name:
				var action_values: Array = panel.get("file_actions", actions)
				actions.assign(action_values)
		staged_kinds[item_id] = {
			"plugin_id":        plugin_id,
			"panel_name":       panel_name,
			"default_filename": default_filename,
			"item_name":        item_name,
			"file_actions":     actions,
		}
		registered_kinds.append(item_id)

	unregister_plugin(plugin_id)
	_ext_to_panel.merge(staged_extensions, true)
	_kind_to_panel.merge(staged_kinds, true)
	_plugin_extensions[plugin_id] = registered_exts
	_plugin_kinds[plugin_id] = registered_kinds

	return warnings


func _skip_required_claim(plugin_id: String, existing: Dictionary) -> bool:
	return plugin_id not in _required_ids and existing.get("plugin_id", "") in _required_ids


func _conflict(claim: String, plugin_id: String, existing: Dictionary) -> String:
	var owner := str(existing.get("plugin_id", ""))
	if owner.is_empty() or owner == plugin_id:
		return ""
	if plugin_id in _required_ids and owner not in _required_ids:
		return ""
	return "PluginEditorRegistry: '%s' claimed by '%s'; plugin '%s' registration refused" % [claim, owner, plugin_id]

## Remove all extensions and editor kinds contributed by `plugin_id`.
func unregister_plugin(plugin_id: String) -> void:
	_registration_errors.erase(plugin_id)
	# Remove extensions.
	var exts: Array = _plugin_extensions.get(plugin_id, [])
	for ext in exts:
		var owner: Dictionary = _ext_to_panel.get(ext, {})
		if owner.get("plugin_id") == plugin_id:
			_ext_to_panel.erase(ext)
	_plugin_extensions.erase(plugin_id)

	# Remove editor kinds.
	var kinds: Array = _plugin_kinds.get(plugin_id, [])
	for kind_id in kinds:
		var owner: Dictionary = _kind_to_panel.get(kind_id, {})
		if owner.get("plugin_id") == plugin_id:
			_kind_to_panel.erase(kind_id)
	_plugin_kinds.erase(plugin_id)


## Resolve a file extension to its owning panel info.
## `ext` should be lowercased with a leading dot (e.g. ".mcad").
## Returns {} on miss.
func resolve_extension(ext: String) -> Dictionary:
	var key: String = ext.strip_edges().to_lower()
	if not key.begins_with("."):
		key = "." + key
	return _ext_to_panel.get(key, {}).duplicate()


## Resolve an editor_item id to its panel info.
## Returns {} on miss.
func resolve_editor_kind(kind_id: String) -> Dictionary:
	return _kind_to_panel.get(kind_id, {}).duplicate()


## Return all registered plugin extensions (lowercased, leading dot).
## Used by Editor._ready() to build FileDialog filter strings.
func list_extensions() -> Array[String]:
	var result: Array[String] = []
	for ext in _ext_to_panel:
		result.append(ext)
	return result


## Return all registered editor kinds in insertion order.
## Each entry: { id, item_name, plugin_id, panel_name, default_filename }
## Used by menuMain._rebuild_new_submenu() to append plugin "New →" items.
func list_editor_kinds() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for kind_id in _kind_to_panel:
		var entry: Dictionary = _kind_to_panel[kind_id].duplicate()
		entry["id"] = kind_id
		result.append(entry)
	return result


func registered_plugin_ids() -> Array[String]:
	var ids: Array[String] = []
	for id: String in _plugin_extensions:
		ids.append(id)
	for id: String in _registration_errors:
		if id not in ids:
			ids.append(id)
	return ids


func registration_error(plugin_id: String) -> String:
	return _registration_errors.get(plugin_id, "")


func _refused(plugin_id: String, message: String) -> Array[String]:
	_registration_errors[plugin_id] = message
	return [message]
