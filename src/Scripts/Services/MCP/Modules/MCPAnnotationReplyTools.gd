class_name MCPAnnotationReplyTools
extends RefCounted
## Focused MCP surface for stable text-comment reply mutations. Source lookup
## and sidecar/live-host writes remain centralized in MCPAnnotationTools.

const TOOL_NAMES: Array[String] = [
	"minerva_annotations_add_reply",
	"minerva_annotations_edit_reply",
	"minerva_annotations_delete_reply",
]

var _server_ref: WeakRef = null
var server:
	get:
		return _server_ref.get_ref() if _server_ref != null else null
	set(value):
		_server_ref = weakref(value) if value != null else null
var _annotations: RefCounted


func _init(mcp_server, annotations: RefCounted) -> void:
	server = mcp_server
	_annotations = annotations


func get_tool_names() -> Array[String]:
	return TOOL_NAMES


func can_handle(tool_name: String) -> bool:
	return tool_name in TOOL_NAMES


func register_tools() -> void:
	_register("minerva_annotations_add_reply",
		"Append an AI-authored reply to a text-comment thread. Replying to a resolved thread reopens it.",
		{"text": {"type": "string"}, "parent_id": {"type": "string"}}, ["annotation_id", "text"])
	_register("minerva_annotations_edit_reply",
		"Edit one reply in a text-comment thread by stable reply id.",
		{"reply_id": {"type": "string"}, "text": {"type": "string"}}, ["annotation_id", "reply_id", "text"])
	_register("minerva_annotations_delete_reply",
		"Delete one reply by stable id. Delete the root comment with minerva_annotations_delete.",
		{"reply_id": {"type": "string"}}, ["annotation_id", "reply_id"])


func _register(tool_name: String, description: String, extra: Dictionary, required: Array) -> void:
	var properties := {
		"annotation_id": {"type": "string"},
		"editor_name": {"type": "string", "description": "Live editor scope."},
		"document_path": {"type": "string", "description": "Saved sidecar scope."},
	}
	properties.merge(extra, true)
	server._register_tool(tool_name, description + " Scope with editor_name or document_path.",
		{"type": "object", "properties": properties, "required": required}, "annotations")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_annotations_add_reply":
			return _annotations.call("mutate_comment_reply", arguments, "add")
		"minerva_annotations_edit_reply":
			return _annotations.call("mutate_comment_reply", arguments, "edit")
		"minerva_annotations_delete_reply":
			return _annotations.call("mutate_comment_reply", arguments, "delete")
	return {"ok": false, "success": false, "error": "Unknown annotation reply tool: %s" % tool_name}
