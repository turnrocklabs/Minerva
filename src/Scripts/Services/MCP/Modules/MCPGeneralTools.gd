class_name MCPGeneralTools
extends MCPToolModule
## MCP tool module for host-level general tools that don't fit a domain module.
##
## Tools:
##   minerva_open_file — open an absolute file path in the appropriate editor.
##   minerva_open_docket — open/focus the upstream Docket window.
##
## Implements the MCPToolModule duck-typed interface (get_tool_names, can_handle,
## register_tools, handle).  Calls SingletonObject.open_file_at_path() which
## contains all type-resolution logic — this module is a thin shim.


const _TOOL_SET := "general"


func get_tool_names() -> Array[String]:
	return [
		"minerva_open_file",
		"minerva_create_plugin_editor",
		"minerva_open_docket",
	]


func register_tools() -> void:
	server._register_tool("minerva_open_docket",
		"Open or focus the Docket plugin's upstream window. Optionally open a specific project docket (.dct) by path. "
		+ "Returns {success, message, pid}, or a visible plugin, project or window-opening error.",
		{
			"type": "object",
			"properties": {
				"dct_path": {"type": "string", "description": "Optional: absolute path to a .dct project file to open."},
			},
		},
		"docket")

	server._register_tool(
		"minerva_open_file",
		"Open or import a file at an absolute path through its owning Minerva editor. "
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
				"action": {"type": "string", "enum": ["open", "import"], "description": "Open or import through the owning editor (default open)."},
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
	return await handle_with_context(tool_name, arguments, MCPExecutionContext.create("module"))


# ── Tool implementation ───────────────────────────────────────────────────────

# The Docket plugin's window, on `dct_path` when given; its refusal is the
# tool's error.
func handle_with_context(tool_name: String, args: Dictionary, context: MCPExecutionContext) -> Dictionary:
	match tool_name:
		"minerva_open_file": return await _open_file(args, context)
		"minerva_create_plugin_editor": return await _create_plugin_editor(args, context)
		"minerva_open_docket": return await _open_docket(args, context)
	return MCPToolUtils.error("Unknown general tool: %s" % tool_name)

func _open_docket(args: Dictionary, context: MCPExecutionContext = null) -> Dictionary:
	var opened := await SingletonObject.open_docket_panel(str(args.get("dct_path", "")).strip_edges(), context)
	if not opened.ok:
		return MCPToolUtils.error(", ".join(PackedStringArray(opened.errors)))
	return {"success": true, "message": "Docket window opened.", "pid": opened.get("pid", 0)}


func _open_file(args: Dictionary, context: MCPExecutionContext = null) -> Dictionary:
	var err: Variant = MCPToolUtils.check_required(args, ["path"])
	if err != null:
		return err

	var path: String = str(args["path"]).strip_edges()
	if path.is_empty():
		return MCPToolUtils.error("path is required")

	var action: Variant = args.get("action", "open")
	if not action is String or action not in ["open", "import"]:
		return MCPToolUtils.error("action must be open or import")
	var action_name: String = action
	var result: Dictionary = await SingletonObject.open_file_when_ready(path, action_name, context)

	# open_file_at_path already returns {ok, editor_kind, editor_name, ...} or
	# {ok: false, errors: [...]}.  Surface the result directly; callers read ok.
	if result.get("ok", false):
		# Normalise to match MCPToolUtils.success envelope (adds success:true).
		var data: Dictionary = result.duplicate()
		data.erase("ok")
		if context != null and not str(data.get("editor_name", "")).is_empty():
			context.lifetime.recovery = {"tool": "minerva_open_file", "editor_name": data.editor_name}
		return MCPToolUtils.success(data)
	else:
		# Flatten errors array into a single message for the MCP error field.
		var errors: Array = result.get("errors", ["unknown error"])
		return {"success": false, "ok": false, "errors": errors,
				"error": ", ".join(errors)}


func _create_plugin_editor(args: Dictionary, context: MCPExecutionContext = null) -> Dictionary:
	var result: Dictionary = await SingletonObject.create_plugin_editor_when_ready(args, context)
	if context != null and result.get("success", false) and not str(result.get("editor_name", "")).is_empty():
		context.lifetime.recovery = {"tool": "minerva_create_plugin_editor", "editor_name": result.editor_name}
	return result
