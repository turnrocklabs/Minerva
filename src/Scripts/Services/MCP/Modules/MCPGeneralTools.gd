class_name MCPGeneralTools
extends MCPToolModule
## MCP tool module for host-level general tools that don't fit a domain module.
##
## Tools:
##   minerva_open_file — open an absolute file path in the appropriate editor.
##
## Implements the MCPToolModule duck-typed interface (get_tool_names, can_handle,
## register_tools, handle).  Calls SingletonObject.open_file_at_path() which
## contains all type-resolution logic — this module is a thin shim.


const _TOOL_SET := "general"


func get_tool_names() -> Array[String]:
	return [
		"minerva_open_file",
		"minerva_create_plugin_editor",
	]


func register_tools() -> void:
	server._register_tool(
		"minerva_open_file",
		"Open a file at an absolute path in the appropriate Minerva editor tab. "
		+ "Resolves the editor type automatically from the file extension using the "
		+ "same dispatch logic as File → Open in the UI. Idempotent: if the file is "
		+ "already open, returns the existing tab's name without creating a duplicate. "
		+ "Returns {ok, editor_kind, editor_name, plugin_id, panel_name} on success, "
		+ "or {ok: false, errors: [string]} on failure. "
		+ "Possible errors: file_not_found, not_a_file, plugin_not_running:<id>, "
		+ "no_handler_for_extension:<ext>.",
		{
			"type": "object",
			"properties": {
				"path": {
					"type": "string",
					"description": "Absolute filesystem path to the file to open (e.g. /home/user/work/foo.txt). "
					+ "Relative paths are resolved via ProjectSettings.globalize_path but an absolute "
					+ "path is strongly preferred.",
				},
			},
			"required": ["path"],
		},
		_TOOL_SET
	)

	server._register_tool(
		"minerva_create_plugin_editor",
		"Create a new ANONYMOUS (unsaved, no file path) editor backed by a plugin's editor_item — the MCP equivalent of File → New → <plugin item> in the UI. The buffer lives only in memory until the user (or a later minerva_doc_save with `path`) Save-As's it. Use the returned `editor_name` to drive content via minerva_doc_read / minerva_doc_write / minerva_doc_save (the unified-key API). "
		+ "For paired_dsl panels (e.g. cad), TWO tabs are spawned (render + text source) sharing one DocumentBuffer; minerva_doc_* calls on EITHER editor_name resolve to the shared buffer, and the render panel re-evaluates automatically as the buffer changes. "
		+ "Returns {editor_name, plugin_id, panel_name, panel_kind, render_mode, [text_editor_name, buffer_path] (paired_dsl only)}. "
		+ "Possible errors: plugin_not_found:<id>, editor_item_not_found:<id>, "
		+ "editor_pane_not_available, html_panel_anonymous_create_unsupported.",
		{
			"type": "object",
			"properties": {
				"plugin_id": {
					"type": "string",
					"description": "Plugin id (e.g. 'cad', from the plugin's manifest.json).",
				},
				"editor_item_id": {
					"type": "string",
					"description": "id of the editor_items[] entry in the plugin manifest (e.g. 'new_mcad' for the cad plugin).",
				},
				"tab_title": {
					"type": "string",
					"description": "Optional tab title for the new editor. Defaults to the editor_items entry's `name`. The returned editor_name reflects the title actually used.",
				},
			},
			"required": ["plugin_id", "editor_item_id"],
		},
		_TOOL_SET
	)


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_open_file":
			return _open_file(arguments)
		"minerva_create_plugin_editor":
			return _create_plugin_editor(arguments)
	return MCPToolUtils.error("Unknown general tool: %s" % tool_name)


# ── Tool implementation ───────────────────────────────────────────────────────

func _open_file(args: Dictionary) -> Dictionary:
	var err: Variant = MCPToolUtils.check_required(args, ["path"])
	if err != null:
		return err

	var path: String = str(args["path"]).strip_edges()
	if path.is_empty():
		return MCPToolUtils.error("path is required")

	var result: Dictionary = SingletonObject.open_file_at_path(path)

	# open_file_at_path already returns {ok, editor_kind, editor_name, ...} or
	# {ok: false, errors: [...]}.  Surface the result directly; callers read ok.
	if result.get("ok", false):
		# Normalise to match MCPToolUtils.success envelope (adds success:true).
		var data: Dictionary = result.duplicate()
		data.erase("ok")
		return MCPToolUtils.success(data)
	else:
		# Flatten errors array into a single message for the MCP error field.
		var errors: Array = result.get("errors", ["unknown error"])
		return {"success": false, "ok": false, "errors": errors,
				"error": ", ".join(errors)}


func _create_plugin_editor(args: Dictionary) -> Dictionary:
	var plugin_id: String = str(args.get("plugin_id", "")).strip_edges()
	var editor_item_id: String = str(args.get("editor_item_id", "")).strip_edges()
	var tab_title: String = str(args.get("tab_title", "")).strip_edges()
	if plugin_id.is_empty() or editor_item_id.is_empty():
		return MCPToolUtils.error("plugin_id and editor_item_id are required")

	var pm = SingletonObject.plugin_manager
	if pm == null:
		return MCPToolUtils.error("plugin_manager_not_available")
	var def = pm.get_db().get_by_id(plugin_id)
	if def == null:
		return MCPToolUtils.error("plugin_not_found: %s" % plugin_id)

	# Look up the editor_items entry by its declared id.
	var editor_item: Dictionary = {}
	for ei in def.editor_items:
		if ei is Dictionary and str(ei.get("id", "")) == editor_item_id:
			editor_item = ei
			break
	if editor_item.is_empty():
		return MCPToolUtils.error("editor_item_not_found: %s" % editor_item_id)

	var panel_name: String = str(editor_item.get("panel", ""))
	if panel_name.is_empty():
		return MCPToolUtils.error("editor_item_missing_panel: %s" % editor_item_id)

	# Default tab_title to the editor_items entry's name field if the caller
	# didn't supply one.
	if tab_title.is_empty():
		tab_title = str(editor_item.get("name", editor_item_id))

	# Resolve panel kind + render_mode from ui_panels.
	var panel_kind: String = "html"
	var render_mode: String = "single"
	for pd in def.ui_panels:
		if pd is Dictionary and pd.get("name", "") == panel_name:
			panel_kind = str(pd.get("kind", "html"))
			render_mode = str(pd.get("render_mode", "single"))
			break

	var editor_pane = SingletonObject.editor_pane
	if editor_pane == null:
		return MCPToolUtils.error("editor_pane_not_available")

	# Anonymous create currently only supports godot_scene panels — html panels
	# expect an HTML payload at construction time. Filing this gap as a
	# follow-up since no current plugin uses html-anonymous.
	if panel_kind != "godot_scene":
		return MCPToolUtils.error("html_panel_anonymous_create_unsupported: kind=%s" % panel_kind)

	# paired_dsl panels (e.g. cad) expect a sibling TEXT editor sharing a
	# DocumentBuffer with the render panel. The file-open path
	# (SingletonObject._open_paired_dsl) handles this for path-bound .mcad —
	# the anonymous-create path mirrors that shape using an unbacked buffer
	# (DocumentRegistry mints a synthetic identity that survives Save-As).
	if render_mode == "paired_dsl":
		var unbacked_r := DocumentRegistry.get_instance().create_unbacked_buffer()
		if not unbacked_r.ok:
			return MCPToolUtils.error("unbacked_buffer_creation_failed: %s" % unbacked_r.get("error", "?"))
		var unbacked_buf: DocumentBuffer = unbacked_r.buffer
		var unbacked_path: String = unbacked_buf.file_path

		# Text editor: anonymous (no `file`), bind to unbacked buffer manually.
		# Distinct title from the render tab — when both share the same name,
		# find_editor_by_name returns whichever is first in the list, breaking
		# minerva_doc_write's resolver: it picks the TEXT editor and skips the
		# PLUGIN_SCENE branch where invoke_apply_sync lives, so doc_write reply
		# arrives without last_eval. F2's buffer routing keeps both tabs in sync
		# via the shared DocumentBuffer regardless of which name the agent uses.
		var text_tab: String = "%s (source)" % tab_title
		var text_editor: Editor = editor_pane.add(Editor.Type.TEXT, null, text_tab)
		if text_editor == null:
			return MCPToolUtils.error("text_editor_creation_failed")
		text_editor.bind_to_buffer_path(unbacked_path)

		# Render editor: anonymous plugin scene, broker attaches the unbacked
		# buffer so text_changed signals from the TEXT editor flow to the panel
		# via the substrate-reserved attach_buffer / text_changed channels.
		var render_editor: Editor = editor_pane.add_plugin_scene_editor(plugin_id, panel_name, null, tab_title)
		if render_editor == null:
			return MCPToolUtils.error("render_editor_creation_failed")
		var broker = SingletonObject.plugin_scene_panel_broker
		if broker != null:
			broker.attach_buffer_to_panel(plugin_id, panel_name, unbacked_buf)
		else:
			push_warning("[minerva_create_plugin_editor] plugin_scene_panel_broker missing; text_changed will not flow to render panel")

		return MCPToolUtils.success({
			"editor_name": str(render_editor.tab_title),
			"text_editor_name": str(text_editor.tab_title),
			"plugin_id": plugin_id,
			"panel_name": panel_name,
			"panel_kind": panel_kind,
			"render_mode": render_mode,
			"buffer_path": unbacked_path,
		})

	# Non-paired_dsl (single-render) anonymous panel: same as before.
	var editor = editor_pane.add_plugin_scene_editor(plugin_id, panel_name, null, tab_title)
	if editor == null:
		return MCPToolUtils.error("editor_creation_failed")

	return MCPToolUtils.success({
		"editor_name": str(editor.tab_title),
		"plugin_id": plugin_id,
		"panel_name": panel_name,
		"panel_kind": panel_kind,
		"render_mode": render_mode,
	})
