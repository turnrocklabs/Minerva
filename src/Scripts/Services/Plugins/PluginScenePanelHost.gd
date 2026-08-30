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
##   2. Locate the typed panel dict from PluginDefinition.ui_panels (typed entries).
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
## The typed ui_panels (typed entries): Array[Dictionary] field (with entry_scene, scripts,
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
	# PluginDefinition.ui_panels (typed entries) is added by the manifest-parsing task.
	# If the field is absent the host fails gracefully with a clear diagnostic
	# so the tab renders a placeholder rather than crashing.
	# -----------------------------------------------------------------------
	var panel_def: Dictionary = _get_panel_def(def, panel_name)
	if panel_def.is_empty():
		return _mount_placeholder(vbox,
			(("[PluginScenePanelHost] Panel '%s' not found in plugin '%s' typed panel definitions. " +
			"Ensure PluginDefinition.ui_panels (typed entries) is populated by the manifest task.") %
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
		var abs_path: String = _resolve_plugin_relative_path(data_dir, str(rel))
		if abs_path.is_empty():
			return _mount_placeholder(vbox,
				("[PluginScenePanelHost] Script path '%s' in panel '%s' escapes plugin directory") %
				[str(rel), panel_name])
		script_abs_paths.append(abs_path)

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
	# The Editor wrapper is constructed before it is added to the live tree,
	# so plugin scene _ready() may not have run yet. Wait for ready in that
	# case so scene scripts can safely use child-node refs initialised there.
	# -----------------------------------------------------------------------
	if root_ctrl.has_method("_on_panel_loaded"):
		var ctx := _build_ctx(plugin_id, panel_name, data_dir, broker, editor)
		if root_ctrl.is_node_ready():
			root_ctrl._on_panel_loaded(ctx)
		else:
			root_ctrl.ready.connect(func() -> void:
				if is_instance_valid(root_ctrl):
					root_ctrl._on_panel_loaded(ctx)
			, CONNECT_ONE_SHOT)

	return root_ctrl


# ---------------------------------------------------------------------------
# Save / load / unload dispatch helpers (design §5.1, §7.5)
# ---------------------------------------------------------------------------

## Call `_on_panel_save_request()` on `panel_root` if the method exists.
##
## Returns the Dictionary returned by the hook on success.
## Returns null and logs a push_warning if the scene does not implement the
## hook (per §7.5: scenes without the hook cannot participate in host_owned
## saves).
##
## Note on error semantics: GDScript 4 has no try/catch. This helper relies
## on `push_error`/`push_warning` being non-fatal in Godot — they log but do
## not abort. A genuine runtime error inside the hook (null-deref, type
## mismatch, infinite recursion, wrong return type) WILL still propagate /
## abort; the helper cannot shield against those. For misbehaving plugins,
## `has_method` is the only practical guard available before the call.
static func invoke_save(panel_root: Node, _ctx: Dictionary) -> Variant:
	if panel_root == null:
		push_warning("[PluginScenePanelHost] invoke_save: panel_root is null")
		return null
	if not panel_root.has_method("_on_panel_save_request"):
		push_warning(
			("[PluginScenePanelHost] invoke_save: scene '%s' does not implement " +
			"_on_panel_save_request — cannot host_owned save") % panel_root.name
		)
		return null
	# Defensive call: errors inside the hook are surfaced via Godot's error
	# reporter but do not propagate as GDScript exceptions here.
	var result: Variant = null
	result = panel_root._on_panel_save_request()
	return result


## Call `_on_panel_apply_sync(document)` on `panel_root` and await its result.
##
## Synchronous variant of invoke_load: applies the document AND awaits the
## plugin's per-apply work (e.g. cad's evaluate→worker round-trip) before
## returning. Lets MCP write tools surface eval status / errors in their
## reply rather than forcing the agent to poll.
##
## The hook contract: returns a Dictionary with at least `{ok: bool}` —
## additional plugin-specific fields (e.g. cad's `last_eval`) are passed
## through verbatim. Returns null when the panel does NOT implement the
## hook — callers should fall back to invoke_load + buffer-only behavior.
##
## Same error-semantics caveat as invoke_save: GDScript has no try/catch.
static func invoke_apply_sync(panel_root: Node, document: Variant) -> Variant:
	if panel_root == null:
		push_warning("[PluginScenePanelHost] invoke_apply_sync: panel_root is null")
		return null
	if not panel_root.has_method("_on_panel_apply_sync"):
		# Not implemented is normal — caller falls back.
		return null
	var result: Variant = await panel_root._on_panel_apply_sync(document)
	return result


## Call `_on_panel_load_request(document)` on `panel_root` if the method exists.
##
## Returns true on successful dispatch (method exists and was called).
## Returns false and logs a push_warning if the scene does not implement the
## hook.
##
## Same error-semantics caveat as invoke_save: GDScript has no try/catch;
## `push_error` is non-fatal but a real runtime error inside the hook will
## still propagate.
static func invoke_load(panel_root: Node, document: Variant) -> bool:
	if panel_root == null:
		push_warning("[PluginScenePanelHost] invoke_load: panel_root is null")
		return false
	if not panel_root.has_method("_on_panel_load_request"):
		push_warning(
			("[PluginScenePanelHost] invoke_load: scene '%s' does not implement " +
			"_on_panel_load_request") % panel_root.name
		)
		return false
	panel_root._on_panel_load_request(document)
	return true


## Call `_on_panel_create_note_request(ctx)` on `panel_root` if the method exists.
##
## Returns the Variant returned by the hook on success (expected to be a
## Dictionary describing the note — see Editor.gd PLUGIN_SCENE create-note
## branch).  Returns null and logs a push_warning if the scene does not
## implement the hook — callers are expected to fall back to the platform
## default (screenshot-to-image-note).
##
## The hook may be a coroutine (a panel that renders its preview off-screen
## has to yield a frame), so the call is awaited; awaiting a plain return
## value yields it unchanged, so a synchronous hook costs nothing. Callers
## must await this function.
##
## Same error-semantics caveat as invoke_save: GDScript has no try/catch.
static func invoke_create_note(panel_root: Node, ctx: Dictionary) -> Variant:
	if panel_root == null:
		push_warning("[PluginScenePanelHost] invoke_create_note: panel_root is null")
		return null
	if not panel_root.has_method("_on_panel_create_note_request"):
		# Not an error — the platform falls back to screenshot-to-image-note.
		return null
	return await panel_root._on_panel_create_note_request(ctx)


## Call `_on_panel_restore_from_note(payload)` on `panel_root` if the method
## exists. The hook is the inverse of `_on_panel_create_note_request`: when a
## plugin_data note is opened, the host invokes this hook so the plugin can
## restore its scene from the saved JSON payload.
##
## Returns the bool returned by the hook (true = restore succeeded; false =
## payload unrecognised / wrong version → host should display a toast and
## leave the panel blank). Returns false and logs a push_warning when the
## panel doesn't implement the hook — callers should treat that as
## "unsupported" and degrade to preview-image-only display.
##
## Same error-semantics caveat as invoke_save.
static func invoke_restore_from_note(panel_root: Node, payload: Dictionary) -> bool:
	if panel_root == null:
		push_warning("[PluginScenePanelHost] invoke_restore_from_note: panel_root is null")
		return false
	if not panel_root.has_method("_on_panel_restore_from_note"):
		push_warning(
			("[PluginScenePanelHost] invoke_restore_from_note: scene '%s' does not " +
			"implement _on_panel_restore_from_note — cannot reopen plugin_data note") %
			panel_root.name
		)
		return false
	var result: Variant = panel_root._on_panel_restore_from_note(payload)
	# Tolerate non-bool returns: anything truthy is success.
	return bool(result)


## Call `_on_panel_render_for_llm(ctx)` on `panel_root` if the method exists.
##
## Returns the canonical MultimodalPayload — an Array of content parts where
## each part is either:
##   {"type": "text",  "text": String}
##   {"type": "image", "image": Image, "alt": String}
##
## Provider adapters (see DCR work item 019df4ebf896) translate this canonical
## shape into per-provider wire formats. Plugins that don't implement the hook
## fall back to a single text+image pair built from the note's preview_image
## and preview_alt_text — this helper returns an empty Array in that case so
## the caller can detect "no plugin-side rendering".
##
## Same error-semantics caveat as invoke_save.
static func invoke_render_for_llm(panel_root: Node, ctx: Dictionary) -> Array:
	if panel_root == null:
		push_warning("[PluginScenePanelHost] invoke_render_for_llm: panel_root is null")
		return []
	if not panel_root.has_method("_on_panel_render_for_llm"):
		# Not a warning — falling back to preview_image is the documented default.
		return []
	var result: Variant = panel_root._on_panel_render_for_llm(ctx)
	if result is Array:
		return result as Array
	push_warning(
		("[PluginScenePanelHost] invoke_render_for_llm: scene '%s' returned %s, " +
		"expected Array of {type, ...} content parts — falling back to preview.") %
		[panel_root.name, typeof(result)]
	)
	return []


## Call `_on_panel_inject_toggle_changed(enabled)` on `panel_root` if the
## method exists.  Fire-and-forget: no return value is consumed.
##
## The toggle state change is non-blocking — Minerva's chat-injection
## bookkeeping happens on the host side regardless of whether the panel
## reacts to the signal.
static func invoke_inject_toggle(panel_root: Node, enabled: bool) -> void:
	if panel_root == null:
		return
	if not panel_root.has_method("_on_panel_inject_toggle_changed"):
		return
	panel_root._on_panel_inject_toggle_changed(enabled)


## True when `panel_root` declares the undo hook pair. The editor ribbon hides
## its Undo/Redo buttons for panels that return false here, so a panel that
## has no history never shows live-looking buttons that do nothing.
## Both hooks are required together: a panel that can undo can redo.
static func supports_undo(panel_root: Node) -> bool:
	if panel_root == null:
		return false
	return panel_root.has_method("_on_panel_undo_request") \
		and panel_root.has_method("_on_panel_redo_request")


## Call `_on_panel_undo_request()` on `panel_root`. Returns the hook's bool
## (true = a step was reverted). Returns false when the panel is null or does
## not declare the hook pair — the ribbon should never reach this path for
## such panels because supports_undo() gates the buttons, but the guard keeps
## a stray call harmless.
static func invoke_undo(panel_root: Node) -> bool:
	if not supports_undo(panel_root):
		return false
	return bool(panel_root._on_panel_undo_request())


## Call `_on_panel_redo_request()` on `panel_root`. Mirror of invoke_undo:
## returns the hook's bool (true = a step was re-applied), false when absent.
static func invoke_redo(panel_root: Node) -> bool:
	if not supports_undo(panel_root):
		return false
	return bool(panel_root._on_panel_redo_request())


## Call `_on_panel_unload()` on `panel_root` if the method exists.
##
## Named wrapper for the inline pattern already used in instantiate_into —
## extracted here for consistency and testability (design §5.1).
##
## Same error-semantics caveat as invoke_save: GDScript has no try/catch;
## `push_error` is non-fatal but real runtime errors propagate.  Per §5.3:
## IPC from inside _on_panel_unload is rejected by the broker (panel_unloading)
## — the scene must not initiate new IPC calls here.
static func invoke_unload(panel_root: Node) -> void:
	if panel_root == null:
		return
	if not panel_root.has_method("_on_panel_unload"):
		return
	panel_root._on_panel_unload()


## Drop the broker registration made by instantiate_into — the other half of
## a mount, called when the owning editor leaves the tree. A panel the broker
## no longer lists under this plugin (its plugin was stopped, which already
## unregistered it) is left alone rather than warned about.
static func unregister_from_broker(plugin_id: String, panel_name: String) -> void:
	var broker: PluginScenePanelBroker = _get_broker()
	if broker == null or broker.get_panel_owner(panel_name) != plugin_id:
		return
	broker.unregister_panel(plugin_id, panel_name)


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

				# Core Minerva scripts (anything under res://) are implicitly
				# trusted — they ship with the binary and cannot be modified
				# by a plugin.  This lets plugin scenes attach core widgets
				# (e.g. AnnotationToolbar) without each plugin having to
				# whitelist the platform's own files.
				if script_path.begins_with("res://"):
					continue

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
## Per design §2.2 the manifest-parsing task upgrades `PluginDefinition.ui_panels`
## from `Array[String]` (legacy) IN-PLACE to `Array[Dictionary]` (typed).  Until
## that task lands, ui_panels still holds bare strings — every godot_scene panel
## open will render a placeholder with the "manifest_panel_defs_missing"
## diagnostic.  Once the task lands, each Dictionary entry has the shape
## {name, kind, entry_scene, scripts, ipc_channels, file_extensions, ...}.
static func _get_panel_def(def, panel_name: String) -> Dictionary:
	if def == null:
		return {}
	if not ("ui_panels" in def):
		return {}

	var panels: Array = def.ui_panels
	for entry in panels:
		# Pre-manifest-task entries are bare strings — skip; will trigger
		# placeholder with "manifest_panel_defs_missing".
		if entry is String:
			continue
		# Post-manifest-task entries are Dictionaries with at least a `name` key.
		if entry is Dictionary and entry.get("name", "") == panel_name:
			return entry

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
		var broker = so.get("plugin_scene_panel_broker")
		if broker == null:
			broker = PluginScenePanelBroker.new(
				so.get("plugin_manager"),
				so.get("plugin_policy"),
				so.get("plugin_capability_broker"),
				so.get("plugin_audit_log")
			)
			so.set("plugin_scene_panel_broker", broker)
		return broker as PluginScenePanelBroker
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
