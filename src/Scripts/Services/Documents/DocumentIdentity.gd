class_name DocumentIdentity extends RefCounted
## Handles identify live objects, not mutable titles or persisted files.
## Re-enumerate after close/reopen or session restore; paths remain durable locators.
static var _session: String = Crypto.new().generate_random_bytes(16).hex_encode()

static func handle(object: Object, kind: String) -> String:
	return "%s:%s:%d" % [kind, _session, object.get_instance_id()]

static func buffer_for(editor: Object, broker: Object = null) -> DocumentBuffer:
	if editor.has_method("get_document_buffer"):
		var buffer: DocumentBuffer = editor.get_document_buffer()
		if buffer != null:
			return buffer
	if broker != null and "plugin_id" in editor and "plugin_panel_key" in editor:
		return broker.get_attached_buffer(str(editor.plugin_id), str(editor.plugin_panel_key))
	return null

static func describe(editor: Object, broker: Object = null) -> Dictionary:
	var buffer := buffer_for(editor, broker)
	return {"view_id": handle(editor, "view"),
		"document_id": buffer.document_id if buffer != null else handle(editor, "document"),
		"identity_lifetime": "live_document"}

## Explicit handles never fall back to titles. A document can have several
## views; only the operation's plugin filter or an explicit view can select one.
static func resolve(args: Dictionary, editors: Array, broker: Object = null,
		plugin_id: String = "") -> Dictionary:
	var document_id := str(args.get("document_id", ""))
	var view_id := str(args.get("view_id", ""))
	if document_id.is_empty() and view_id.is_empty():
		return {"ok": false, "error": "document_id or view_id is required"}
	var matches: Array[Dictionary] = []
	for editor: Object in editors:
		if not is_instance_valid(editor):
			continue
		if not plugin_id.is_empty() and (not "plugin_id" in editor or str(editor.plugin_id) != plugin_id):
			continue
		var identity := describe(editor, broker)
		if not document_id.is_empty() and identity.document_id != document_id:
			continue
		if not view_id.is_empty() and identity.view_id != view_id:
			continue
		matches.append({"editor": editor, "identity": identity})
	if matches.size() == 1:
		return {"ok": true, "editor": matches[0].editor, "identity": matches[0].identity}
	var candidates: Array = []
	for candidate in matches:
		candidates.append(candidate.identity)
	return {"ok": false, "error": "ambiguous_document_view" if matches.size() > 1 else "document_view_not_found",
		"candidates": candidates}

## Panel tools keep their existing locator while gaining generic handles.
static func panel_schema(schema: Dictionary) -> Dictionary:
	var result := schema.duplicate(true)
	var properties: Dictionary = result.get("properties", {})
	properties["document_id"] = {"type": "string", "description": "Live document handle from minerva_list_editors. Selects this plugin's unique view."}
	properties["view_id"] = {"type": "string", "description": "Live view handle from minerva_list_editors; stable through tab rename."}
	result["properties"] = properties
	var required: Array = result.get("required", [])
	if required.has("editor_name"):
		required.erase("editor_name")
		result["required"] = required
		var clauses: Array = result.get("allOf", [])
		clauses.append({"anyOf": [{"required": ["editor_name"]}, {"required": ["document_id"]}, {"required": ["view_id"]}]})
		result["allOf"] = clauses
	return result
