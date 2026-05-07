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
		+ "Returns {editor_name, plugin_id, panel_name, panel_kind}. "
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

	# Resolve panel kind from ui_panels (godot_scene vs html).
	var panel_kind: String = "html"
	for pd in def.ui_panels:
		if pd is Dictionary and pd.get("name", "") == panel_name:
			panel_kind = str(pd.get("kind", "html"))
			break

	var editor_pane = SingletonObject.editor_pane
	if editor_pane == null:
		return MCPToolUtils.error("editor_pane_not_available")

	# Anonymous create currently only supports godot_scene panels — html panels
	# expect an HTML payload at construction time. Filing this gap as a
	# follow-up since no current plugin uses html-anonymous.
	if panel_kind != "godot_scene":
		return MCPToolUtils.error("html_panel_anonymous_create_unsupported: kind=%s" % panel_kind)

	var editor = editor_pane.add_plugin_scene_editor(plugin_id, panel_name, null, tab_title)
	if editor == null:
		return MCPToolUtils.error("editor_creation_failed")

	return MCPToolUtils.success({
		"editor_name": str(editor.tab_title),
		"plugin_id": plugin_id,
		"panel_name": panel_name,
		"panel_kind": panel_kind,
	})
