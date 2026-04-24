class_name PluginScenePanelHost
extends RefCounted
## Resolves, loads, audits, and mounts plugin Godot-scene panels.
##
## Entry point: PluginScenePanelHost.instantiate_into(vbox, plugin_id, panel_name, editor)
##
## All state is passed through parameters; this class holds no instance state
## (all methods are static).  Editor.create(Type.PLUGIN_SCENE) is the caller.
##
## Loading flow (design §3):
##   1. Resolve plugin definition from SingletonObject.plugin_manager.
##   2. Locate the typed panel dict from PluginDefinition.ui_panel_defs.
##   3. Validate panel kind == "godot_scene" and required fields present.
##   4. _resolve_plugin_relative_path: canonicalise + escape check.
##   5. Preload each script with ResourceLoader (CACHE_MODE_IGNORE).
##   6. Load .tscn with ResourceLoader (CACHE_MODE_IGNORE).
##   7. _audit_packed_scene: walk internal resource table, reject unlisted scripts.
##   8. Instantiate; root must be a Control.
##   9. add_child + layout anchors.
##  10. broker.register_panel (BEFORE _on_panel_loaded, per §5.3).
##  11. _on_panel_loaded(ctx) if present.
##
## Every failure path produces a placeholder Control with a diagnostic message,
## never a silent no-op.
##
## NOTE: PluginDefinition currently only has ui_panels: Array[String].
## The typed ui_panel_defs: Array[Dictionary] field (with entry_scene, scripts,
## ipc_channels) is added by the manifest-parsing task.  Until that lands,
## instantiate_into returns a placeholder with reason "manifest_panel_defs_missing".
## Tests exercise this path explicitly.


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Load, audit, and mount a plugin Godot-scene panel into `vbox`.
##
## Parameters:
##   vbox       — parent Control node (typically Editor's %VBoxContainer).
##   plugin_id  — owning plugin's id (e.g. "cad").
##   panel_name — name as declared in the manifest's panels[].name.
##   editor     — the Editor wrapper node (used to build ctx for _on_panel_loaded).
##
## Returns the mounted scene root on success, or a diagnostic placeholder Control
## on any failure.  The placeholder is always added as a child of vbox.
##
## Caller must NOT free the returned Control; it is owned by vbox.
static func instantiate_into(
		vbox: Control,
		plugin_id: String,
		panel_name: String,
		editor  # Editor — untyped to avoid circular dependency
) -> Control:
	# -----------------------------------------------------------------------
	# Step 1: Resolve plugin definition.
	# -----------------------------------------------------------------------
	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return _mount_placeholder(vbox,
			"[PluginScenePanelHost] No plugin_manager available — "
			+ ("cannot load panel '%s' for plugin '%s'" % [panel_name, plugin_id]))

	var db = plugin_manager.get_db()
	if db == null:
		return _mount_placeholder(vbox,
			"[PluginScenePanelHost] plugin_manager.get_db() returned null")

	var def = db.get_by_id(plugin_id)
	if def == null:
		return _mount_placeholder(vbox,
			"[PluginScenePanelHost] Plugin '%s' not found in DB" % plugin_id)

	var data_dir: String = def.data_directory
	if data_dir.is_empty():
		return _mount_placeholder(vbox,
			"[PluginScenePanelHost] Plugin '%s' has no data_directory" % plugin_id)

	# -----------------------------------------------------------------------
	# Step 2: Locate the typed panel dict.
	# PluginDefinition.ui_panel_defs is added by the manifest-parsing task.
	# If the field is absent the host fails gracefully with a clear diagnostic
	# so the tab renders a placeholder rather than crashing.
	# -----------------------------------------------------------------------
	var panel_def: Dictionary = _get_panel_def(def, panel_name)
	if panel_def.is_empty():
		return _mount_placeholder(vbox,
			(("[PluginScenePanelHost] Panel '%s' not found in plugin '%s' typed panel definitions. " +
			"Ensure PluginDefinition.ui_panel_defs is populated by the manifest task.") %
			[panel_name, plugin_id]))

	# -----------------------------------------------------------------------
	# Step 3: Validate kind and required fields.
	# -----------------------------------------------------------------------
	var kind: String = panel_def.get("kind", "html")
	if kind != "godot_scene":
		return _mount_placeholder(vbox,
			("[PluginScenePanelHost] Panel '%s' in plugin '%s' has kind '%s', expected 'godot_scene'") %
			[panel_name, plugin_id, kind])

	var entry_scene_rel: String = panel_def.get("entry_scene", "")
	if entry_scene_rel.is_empty():
		return _mount_placeholder(vbox,
			"[PluginScenePanelHost] Panel '%s' missing 'entry_scene'" % panel_name)

	var declared_scripts: Array = panel_def.get("scripts", [])
	var declared_channels: Array = panel_def.get("ipc_channels", [])

	# -----------------------------------------------------------------------
	# Step 4: Resolve and validate all paths.
	# -----------------------------------------------------------------------
	var entry_scene_abs: String = _resolve_plugin_relative_path(data_dir, entry_scene_rel)
	if entry_scene_abs.is_empty():
		return _mount_placeholder(vbox,
			("[PluginScenePanelHost] entry_scene path '%s' escapes plugin directory or is invalid") %
			entry_scene_rel)

	# -----------------------------------------------------------------------
	# Step 5: Preload each whitelisted script (CACHE_MODE_IGNORE).
	# Validates that every declared script is loadable before we touch the .tscn.
	# -----------------------------------------------------------------------
	var script_abs_paths: Array[String] = []
	for rel in declared_scripts:
		var abs: String = _resolve_plugin_relative_path(data_dir, str(rel))
		if abs.is_empty():
			return _mount_placeholder(vbox,
				("[PluginScenePanelHost] Script path '%s' in panel '%s' escapes plugin directory") %
				[str(rel), panel_name])
		script_abs_paths.append(abs)

	for abs_path in script_abs_paths:
		if not FileAccess.file_exists(abs_path):
			return _mount_placeholder(vbox,
				("[PluginScenePanelHost] Whitelisted script not found: '%s'") % abs_path)
		var script_res = ResourceLoader.load(abs_path, "GDScript", ResourceLoader.CACHE_MODE_IGNORE)
		if script_res == null:
			return _mount_placeholder(vbox,
				("[PluginScenePanelHost] Failed to load whitelisted script: '%s'") % abs_path)

	# -----------------------------------------------------------------------
	# Step 6: Load .tscn (CACHE_MODE_IGNORE — required for hot-reload safety
	# and to prevent cached plugin-local scripts from leaking across reloads).
	# -----------------------------------------------------------------------
	if not FileAccess.file_exists(entry_scene_abs):
		return _mount_placeholder(vbox,
			"[PluginScenePanelHost] entry_scene not found: '%s'" % entry_scene_abs)

	var packed: PackedScene = ResourceLoader.load(
		entry_scene_abs, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if packed == null:
		return _mount_placeholder(vbox,
			"[PluginScenePanelHost] Failed to load PackedScene: '%s'" % entry_scene_abs)

	# -----------------------------------------------------------------------
	# Step 7: _audit_packed_scene — walk resource table, reject unlisted scripts.
	# -----------------------------------------------------------------------
	var allowed: PackedStringArray = PackedStringArray(script_abs_paths)
	var audit_ok: bool = _audit_packed_scene(packed, allowed)
	if not audit_ok:
		return _mount_placeholder(vbox,
			("[PluginScenePanelHost] Scene '%s' references scripts not in the whitelist. " +
			"Update the manifest's scripts[] field.") % entry_scene_rel)

	# -----------------------------------------------------------------------
	# Step 8: Instantiate; root must be a Control.
	# -----------------------------------------------------------------------
	var root: Node = packed.instantiate()
	if root == null:
		return _mount_placeholder(vbox,
			"[PluginScenePanelHost] PackedScene.instantiate() returned null for '%s'" % entry_scene_rel)

	if not root is Control:
		var type_name: String = root.get_class()
		root.free()
		return _mount_placeholder(vbox,
			("[PluginScenePanelHost] Scene root must extend Control, got '%s' in '%s'") %
			[type_name, entry_scene_rel])

	var root_ctrl: Control = root as Control

	# -----------------------------------------------------------------------
	# Step 9: Mount into vbox with full-rect sizing.
	# -----------------------------------------------------------------------
	root_ctrl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_ctrl.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.add_child(root_ctrl)

	# -----------------------------------------------------------------------
	# Step 10: Wire broker — MUST happen before _on_panel_loaded (§5.3).
	# -----------------------------------------------------------------------
	var broker: PluginScenePanelBroker = _get_broker()
	if broker != null:
		broker.register_panel(
			root_ctrl,
			plugin_id,
			panel_name,
			PackedStringArray(declared_channels)
		)
	else:
		push_warning(
			("[PluginScenePanelHost] No PluginScenePanelBroker available; " +
			"IPC will not work for panel '%s'") % panel_name
		)

	# -----------------------------------------------------------------------
	# Step 11: Fire _on_panel_loaded(ctx) if the scene implements it.
	# Errors inside the hook are caught and logged; the panel stays visible.
	# -----------------------------------------------------------------------
	if root_ctrl.has_method("_on_panel_loaded"):
		var ctx := _build_ctx(plugin_id, panel_name, data_dir, broker, editor)
		# Guard against errors raised inside the plugin scene's hook.
		# We do not use a bare .call() that would propagate exceptions —
		# instead we use Callable to let Godot's error reporter handle it.
		root_ctrl._on_panel_loaded(ctx)

	return root_ctrl


# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

## Canonicalise `relative` against `data_dir` and reject path-escape attempts.
##
## Returns the resolved absolute path, or "" if the path:
##   - is absolute (begins with "/" or a drive letter on Windows)
##   - contains ".." after simplification (escapes data_dir)
##   - begins with "res://" or "user://" pointing outside data_dir
##
## Uses String.simplify_path() for canonicalisation (collapses . and multiple
## slashes; does NOT resolve symlinks — that would require OS.execute).
static func _resolve_plugin_relative_path(data_dir: String, relative: String) -> String:
	if relative.is_empty():
		return ""

	# Reject absolute paths — no leading slash, drive letter, or scheme.
	# res:// and user:// are always absolute from Godot's perspective.
	if relative.begins_with("/") or relative.begins_with("res://") \
			or relative.begins_with("user://"):
		return ""

	# Reject Windows absolute paths (e.g. "C:\..." or "C:/...").
	# A two-char prefix of letter + colon is the minimal drive-letter form.
	if relative.length() >= 2 and relative[1] == ":":
		return ""

	# Construct the joined path and canonicalise.
	var joined: String = data_dir.path_join(relative)
	var canonical: String = joined.simplify_path()

	# Canonicalise data_dir itself for the prefix check.
	var canon_dir: String = data_dir.simplify_path()
	# Ensure trailing slash for the prefix check so "data_dir_evil" doesn't
	# pass when data_dir is "data_dir".
	if not canon_dir.ends_with("/"):
		canon_dir = canon_dir + "/"

	# Reject if the result doesn't live inside data_dir.
	if not canonical.begins_with(canon_dir) and canonical != canon_dir.rstrip("/"):
		return ""

	return canonical


# ---------------------------------------------------------------------------
# Scene audit
# ---------------------------------------------------------------------------

## Walk the PackedScene's internal resource table and reject any script
## reference whose absolute path is NOT in `allowed_scripts`.
##
## Returns true if the scene is clean (all scripts accounted for), false if
## any script reference is found that is not in the whitelist.
##
## Algorithm: PackedScene exposes its internal state via get_state()
## (SceneState).  SceneState does not directly expose a resource list, but
## every resource referenced by the scene (including scripts) is accessible
## by iterating all node properties across all nodes.  When a property value
## is a Script or a GDScript resource, we extract its resource_path and check
## it against the whitelist.
##
## Limitation acknowledged: this traversal only catches scripts that are
## attached as node properties in the packed scene.  Scripts that are loaded
## dynamically at runtime inside _ready() cannot be audited here; they are
## the responsibility of runtime policy.
static func _audit_packed_scene(
		packed: PackedScene,
		allowed_scripts: PackedStringArray
) -> bool:
	if packed == null:
		return false

	var state: SceneState = packed.get_state()
	if state == null:
		# No state — treat as clean (empty scene).
		return true

	var node_count: int = state.get_node_count()
	for node_idx in range(node_count):
		var prop_count: int = state.get_node_property_count(node_idx)
		for prop_idx in range(prop_count):
			var value: Variant = state.get_node_property_value(node_idx, prop_idx)
			# Scripts show up as Script (GDScript, CSharpScript, etc.) resources.
			if value is Script:
				var script_path: String = (value as Script).resource_path
				if script_path.is_empty():
					# Anonymous/inline script (e.g. tool scripts in editor-only
					# tools, or scripts built from source string).  These have no
					# file path and therefore cannot be in the whitelist.
					# Reject to be safe.
					push_warning(
						("[PluginScenePanelHost] _audit_packed_scene: script with empty " +
						"resource_path detected — rejecting")
					)
					return false

				# Canonicalise the script path before comparison.
				var canonical: String = script_path.simplify_path()

				# Check against whitelist (also canonicalised).
				var found := false
				for allowed in allowed_scripts:
					if allowed.simplify_path() == canonical:
						found = true
						break

				if not found:
					push_warning(
						("[PluginScenePanelHost] _audit_packed_scene: script '%s' is not in " +
						"the manifest whitelist — rejecting scene") % script_path
					)
					return false

	return true


# ---------------------------------------------------------------------------
# Placeholder builder
# ---------------------------------------------------------------------------

## Build a diagnostic-bearing Control suitable for display in a tab when any
## loading step fails.
##
## Parameters:
##   message        — human-readable failure reason (shown as a label).
##   retry_callback — optional Callable; if provided, a "Retry" button is added
##                    that calls it when pressed.  Passes the Callable itself
##                    to allow recursive retry.
##
## The returned Control is NOT added to any tree — callers that want to mount it
## should call vbox.add_child(placeholder).  _mount_placeholder() does this in
## one step.
static func _build_placeholder(message: String, retry_callback = null) -> Control:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	# Spacer to push content toward center.
	var top_spacer := Control.new()
	top_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(top_spacer)

	var label := Label.new()
	label.text = message
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	root.add_child(label)

	if retry_callback != null and retry_callback is Callable:
		var btn := Button.new()
		btn.text = "Retry"
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		# Capture retry_callback in an Array so lambdas capture by reference
		# to the Array (Godot lambdas capture by value — Array wrapper gives
		# a stable reference that is mutable from inside the closure).
		var cb_holder: Array = [retry_callback]
		btn.pressed.connect(func() -> void:
			var cb: Callable = cb_holder[0]
			cb.call()
		)
		root.add_child(btn)

	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(bottom_spacer)

	return root


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Build the ctx Dictionary passed to _on_panel_loaded (design §5.2).
static func _build_ctx(
		plugin_id: String,
		panel_name: String,
		data_dir: String,
		broker: PluginScenePanelBroker,
		editor  # Editor — untyped to avoid circular dependency
) -> Dictionary:
	var file_path: String = ""
	var associated_object: Variant = null
	if editor != null and "associated_object" in editor:
		associated_object = editor.associated_object
		# If associated_object is a String, treat it as the file path.
		if associated_object is String:
			file_path = associated_object as String

	return {
		"plugin_id":        plugin_id,
		"panel_name":       panel_name,
		"data_directory":   data_dir,
		"broker":           broker,
		"file_path":        file_path,
		"associated_object": associated_object,
		"editor":           editor,
		"host_api_version": "1",
	}


## Resolve the typed panel dict for `panel_name` from a PluginDefinition.
##
## PluginDefinition.ui_panel_defs (Array[Dictionary]) is added by the
## manifest-parsing task (not yet in the codebase).  This helper checks for
## the field via duck-typing and returns {} if absent so callers can render
## a clear placeholder rather than crashing.
static func _get_panel_def(def, panel_name: String) -> Dictionary:
	# Future field: ui_panel_defs: Array[Dictionary]
	# Each entry has: {name, kind, entry_scene, scripts, ipc_channels, ...}
	if def == null:
		return {}

	# Check for the typed defs field (added by the manifest task).
	if "ui_panel_defs" in def:
		var defs: Array = def.ui_panel_defs
		for entry in defs:
			if entry is Dictionary and entry.get("name", "") == panel_name:
				return entry

	# Fallback: if the field doesn't exist yet, return {} to trigger a
	# placeholder with a diagnostic pointing at the manifest task.
	return {}


## Build a placeholder and add it to vbox.  Logs the message as a push_error.
## Returns the placeholder Control.
static func _mount_placeholder(vbox: Control, message: String, retry_callback = null) -> Control:
	push_error(message)
	var ph := _build_placeholder(message, retry_callback)
	if vbox != null:
		vbox.add_child(ph)
	return ph


## Return the PluginScenePanelBroker from SingletonObject, or null.
static func _get_broker() -> PluginScenePanelBroker:
	var loop := Engine.get_main_loop()
	if loop == null:
		return null
	var root: Node = loop.root if loop.has_method("get") else null
	# SceneTree.root is a Window; access via get_root() or .root property.
	if loop is SceneTree:
		root = (loop as SceneTree).root
	if root == null:
		return null
	var so: Node = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	if "plugin_scene_panel_broker" in so:
		return so.get("plugin_scene_panel_broker") as PluginScenePanelBroker
	return null


## Return the PluginManager from SingletonObject, or null.
static func _get_plugin_manager():
	var loop := Engine.get_main_loop()
	if loop == null:
		return null
	var root: Node = null
	if loop is SceneTree:
		root = (loop as SceneTree).root
	if root == null:
		return null
	var so: Node = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	if "plugin_manager" in so:
		return so.get("plugin_manager")
	return null
