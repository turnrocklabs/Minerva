extends RefCounted
## Adapter for the legacy host CAD tools. The plugin owns evaluation policy;
## the host only resolves document/view handles and preserves its result context.

static func schema(input: Dictionary) -> Dictionary:
	var out := DocumentIdentity.panel_schema(input)
	var props: Dictionary = out.get("properties", {})
	props["accept_last_completed"] = {"type": "boolean", "description": "Allow the last completed model while edits are pending; replies retain stale provenance."}
	props["require_source_version"] = {"type": "integer", "description": "Require this completed buffer revision."}
	props["require_source_digest"] = {"type": "string", "description": "Require this SHA-256 of evaluated DSL source."}
	# Export may collect with job_id alone, or start with any supported locator.
	if props.has("job_id"):
		out["anyOf"] = [{"required": ["job_id"]},
			{"required": ["editor_name", "format", "path"]},
			{"required": ["document_id", "format", "path"]},
			{"required": ["view_id", "format", "path"]}]
	return out

static func locate(args: Dictionary) -> Dictionary:
	if not args.has("document_id") and not args.has("view_id"):
		return {"success": true}
	var pane = SingletonObject.editor_pane
	if pane == null:
		return {"success": false, "error": "No editor pane is available"}
	var resolved := DocumentIdentity.resolve(args, pane.get_open_editors(),
		SingletonObject.plugin_scene_panel_broker, "cad")
	if not resolved.ok:
		return {"success": false, "error": resolved.error, "candidates": resolved.get("candidates", [])}
	var editor: Object = resolved.editor
	args["editor_name"] = DocumentIdentity.handle(editor, "view")
	if "plugin_scene_root" in editor and editor.plugin_scene_root != null:
		var root: Node = editor.plugin_scene_root
		if root.has_method("get_annotation_host"):
			args["_cad_host"] = root.get_annotation_host()
	return {"success": true}

static func begin(host: Object, args: Dictionary, require_current: bool) -> Dictionary:
	if host == null or not host.has_method("get_panel"):
		return {"success": true}
	var panel: Node = host.get_panel()
	if panel == null or not panel.has_method("begin_evaluation_read"):
		if args.has("require_source_version") or args.has("require_source_digest") or args.get("accept_last_completed", false):
			return {"success": false, "error": "This CAD plugin cannot enforce evaluation requirements; update it first."}
		return {"success": true}
	var context: Dictionary = panel.begin_evaluation_read(args, require_current)
	if context.has("freshness"):
		context["panel"] = weakref(panel)
	return context

static func finish(reply: Dictionary, context: Dictionary) -> Dictionary:
	if not context.has("panel"):
		return reply
	var panel: Node = context.panel.get_ref()
	if panel == null:
		reply["stale"] = true
		reply["result_valid"] = false
		return reply
	return panel.finish_evaluation_read(reply, context.freshness)

static func export_document_args(args: Dictionary) -> Dictionary:
	var fmt := str(args.get("format", "")).strip_edges().to_lower()
	if fmt not in ["stl", "step", "stp", "3mf", "glb"]:
		return {"success": false, "error": "unsupported export format: " + fmt}
	var path := str(args.get("path", "")).strip_edges()
	if path.is_empty():
		return {"success": false, "error": "path is required"}
	var document: Dictionary = args.get("_evaluated_document", {})
	var source := str(document.get("source", ""))
	var version := int(document.get("source_version", -1))
	if document.is_empty():
		var editor = MCPToolUtils.find_editor_by_name(str(args.get("editor_name", "")))
		if editor == null:
			return {"success": false, "error": "editor_not_found"}
		var buffer := DocumentIdentity.buffer_for(editor, SingletonObject.plugin_scene_panel_broker)
		if buffer != null:
			source = buffer.text
			version = buffer.version
	if source.is_empty():
		return {"success": false, "error": "No source is available to export"}
	if args.has("require_source_version") and int(args.require_source_version) != version:
		return {"success": false, "error": "Export source does not match require_source_version"}
	if args.has("require_source_digest") and str(args.require_source_digest) != source.sha256_text():
		return {"success": false, "error": "Export source does not match require_source_digest"}
	return {"source": source, "source_version": version,
		"document_id": document.get("document_id", ""),
		"evaluation_provenance": document.get("provenance", {}), "part": args.get("part", ""),
		"selection": args.get("selection", args.get("part", document.get("model", {}).get("selection", ""))),
		"configuration": args.get("configuration", document.get("model", {}).get("configuration", "")),
		"format": fmt, "path": path}
