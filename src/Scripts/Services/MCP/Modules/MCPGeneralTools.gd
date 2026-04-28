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
	return ["minerva_open_file"]


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


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_open_file":
			return _open_file(arguments)
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
