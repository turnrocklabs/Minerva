class_name MCPSnapshotTools
extends MCPToolModule
## One snapshot contract for visible editor surfaces and opt-in panel slots.
var _context_provider: Callable
var _image_capture: Callable

func _init(mcp_server = null, context_provider: Callable = Callable(),
		image_capture: Callable = Callable()) -> void:
	super(mcp_server)
	_context_provider = context_provider if context_provider.is_valid() else PanelServices.context
	_image_capture = image_capture if image_capture.is_valid() else PanelServices.capture


func get_tool_names() -> Array[String]:
	return ["minerva_snapshot"]


func register_tools() -> void:
	server._register_tool("minerva_snapshot",
		"Capture an open editor's visible content, or a named plugin viewport. "
		+ "Returns a PNG path, dimensions and view; base64 only when requested. "
		+ "Unknown editors/views report available choices.",
		{"type": "object", "properties": {
			"editor_name": {"type": "string", "description": "Exact editor tab name or live view handle"},
			"view": {"type": "string", "default": "active", "description": "Visible surface, or a panel's named slot"},
			"max_edge": {"type": "integer", "minimum": 1, "maximum": 4096, "default": 1024},
			"return_base64": {"type": "boolean", "default": false}
		}, "required": ["editor_name"]}, "editor")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	if not can_handle(tool_name):
		return _error("Unknown tool '%s'" % tool_name)
	var editor_name := str(arguments.get("editor_name", "")).strip_edges()
	if editor_name.is_empty():
		return _error("editor_name is required")
	var view := str(arguments.get("view", "active")).strip_edges()
	if view.is_empty():
		view = "active"
	var max_edge := int(arguments.get("max_edge", 1024))
	if max_edge < 1 or max_edge > 4096:
		return _error("max_edge must be between 1 and 4096")
	var ctx: Dictionary = _context_provider.call()
	var resolved := PanelServices.resolve(editor_name, ctx.get("broker"), ctx.get("editors", []))
	if not resolved.ok:
		var error := _error(str(resolved.error), resolved.get("views", ["active"]))
		error["available_editors"] = resolved.get("known", [])
		return error
	var target := PanelServices.capture_target(resolved, view)
	if not target.ok:
		return _error(str(target.error), target.views)
	var available := PanelServices.views(resolved.panel)
	var image: Image = await _image_capture.call(target)
	if image == null or image.is_empty():
		return _error("View '%s' did not produce an image" % view, available)
	var raw_panel: Variant = resolved.get("panel")
	if not is_instance_valid(raw_panel) and typeof(raw_panel) != TYPE_NIL:
		return _error("Panel closed during capture", available)
	var panel: Object = raw_panel
	var extras: Variant = {}
	if panel != null and panel.has_method("snapshot_extra"):
		extras = panel.snapshot_extra(view)
	if not extras is Dictionary:
		return _error("snapshot_extra must return a Dictionary", available)
	var long_edge := maxi(image.get_width(), image.get_height())
	if long_edge > max_edge:
		var scale := float(max_edge) / long_edge
		image.resize(maxi(1, roundi(image.get_width() * scale)),
			maxi(1, roundi(image.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
	var path := "user://snapshots/%s_%s.png" % [editor_name.validate_filename().left(80),
		Crypto.new().generate_random_bytes(8).hex_encode()]
	var directory_error := DirAccess.make_dir_recursive_absolute("user://snapshots")
	if directory_error != OK:
		return _error("Cannot create snapshot directory (error %d)" % directory_error, available)
	var save_error := image.save_png(path)
	if save_error != OK:
		return _error("Cannot save snapshot (error %d)" % save_error, available)
	var reply := {"success": true, "path": path, "width": image.get_width(),
		"height": image.get_height(), "view": view}
	# Extras are metadata, never a second authority for response or wire fields.
	for key in extras:
		if key not in ["success", "path", "width", "height", "view", "base64", "image_base64",
				"isError", "error", "error_message", "content", "structuredContent"]:
			reply[key] = extras[key]
	if bool(arguments.get("return_base64", false)):
		reply["image_base64"] = Marshalls.raw_to_base64(image.save_png_to_buffer())
	return reply


static func _error(message: String, available: Array = ["active"]) -> Dictionary:
	var result := MCPToolUtils.error(message)
	result["available_views"] = available
	return result
