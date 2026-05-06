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
## Wired into plugin start/stop via SingletonObject.initialize_plugins() —
## see NOTE at bottom of this file.
##
## Extension collision rules (design §7.3):
##   - Core extensions (.md, .py, .gd, .minpcb, etc.) always win;
##     a plugin that declares a core extension gets a warning and the
##     extension is silently skipped (panel still usable via "New →").
##   - Two plugins with the same non-core extension: first-installed wins;
##     second plugin's declaration is skipped with a warning.
##
## NOTE: PluginEditorRegistry is NOT registered as a Godot autoload.
## SingletonObject constructs it as a plain property:
##   var plugin_editor_registry: PluginEditorRegistry = PluginEditorRegistry.new()
## Call register_plugin() / unregister_plugin() from the plugin_started /
## plugin_stopped / plugin_crashed signal handlers in SingletonObject.initialize_plugins().


## Core file extensions that plugin registrations must never override.
## Derived from SingletonObject.supported_text_formats plus the typed-editor formats.
## Keep in sync with open_file() in vboxEditor.gd and the FileDialog filters in Editor._ready().
const CORE_EXTENSIONS: PackedStringArray = [
	# Graphics
	".png", ".jpg", ".jpeg",
	# Typed editors
	".minpcb", ".minkb", ".minsheet",
	# Text / code (from supported_text_formats)
	".txt", ".rs", ".toml", ".md", ".json", ".xml", ".csv", ".log",
	".py", ".cs", ".minproj", ".gd", ".tscn", ".godot", ".go", ".java",
	".html",
]


## extension (lowercased, leading '.') -> { plugin_id: String, panel_name: String }
var _ext_to_panel: Dictionary = {}

## editor_item_id -> { plugin_id: String, panel_name: String, default_filename: String,
##                     item_name: String }
## The insertion order is preserved (GDScript Dictionary is ordered) and is used
## by list_editor_kinds() to return items in registration order.
var _kind_to_panel: Dictionary = {}

## plugin_id -> Array[String] of extensions registered by this plugin.
## Used to cleanly unregister on stop.
var _plugin_extensions: Dictionary = {}

## plugin_id -> Array[String] of editor_item ids registered by this plugin.
## Used to cleanly unregister on stop.
var _plugin_kinds: Dictionary = {}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Register all godot_scene panel extensions and editor_items from a PluginDefinition.
## `def` must have .id, .ui_panels (Array[Dictionary]), and .editor_items (Array[Dictionary]).
##
## Returns an Array[String] of warning messages (empty means clean registration).
## Warnings are issued for extension collisions; they do NOT prevent the plugin
## from being usable via "New →".
func register_plugin(def) -> Array[String]:
	var warnings: Array[String] = []
	if def == null:
		warnings.append("PluginEditorRegistry.register_plugin: def is null")
		return warnings

	var plugin_id: String = str(def.id) if "id" in def else ""
	if plugin_id.is_empty():
		warnings.append("PluginEditorRegistry.register_plugin: def.id is empty")
		return warnings

	# Guard double-registration.
	if _plugin_extensions.has(plugin_id):
		unregister_plugin(plugin_id)

	var registered_exts: Array[String] = []
	var registered_kinds: Array[String] = []

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
				push_warning(w)
				warnings.append(w)
				continue

			# Cross-plugin collision check.
			if _ext_to_panel.has(ext):
				var existing_plugin: String = _ext_to_panel[ext].get("plugin_id", "?")
				var w: String = (
					("PluginEditorRegistry: plugin '%s' declares extension '%s' " +
					"already claimed by plugin '%s' — extension skipped") %
					[plugin_id, ext, existing_plugin]
				)
				push_warning(w)
				warnings.append(w)
				continue

			_ext_to_panel[ext] = {
				"plugin_id":   plugin_id,
				"panel_name":  panel_name,
				"render_mode": panel_dict.get("render_mode", "single"),
				"layout_hint": panel_dict.get("layout_hint", "tabs"),
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

		_kind_to_panel[item_id] = {
			"plugin_id":        plugin_id,
			"panel_name":       panel_name,
			"default_filename": default_filename,
			"item_name":        item_name,
		}
		registered_kinds.append(item_id)

	_plugin_extensions[plugin_id] = registered_exts
	_plugin_kinds[plugin_id] = registered_kinds

	return warnings


## Remove all extensions and editor kinds contributed by `plugin_id`.
func unregister_plugin(plugin_id: String) -> void:
	# Remove extensions.
	var exts: Array = _plugin_extensions.get(plugin_id, [])
	for ext in exts:
		_ext_to_panel.erase(ext)
	_plugin_extensions.erase(plugin_id)

	# Remove editor kinds.
	var kinds: Array = _plugin_kinds.get(plugin_id, [])
	for kind_id in kinds:
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
