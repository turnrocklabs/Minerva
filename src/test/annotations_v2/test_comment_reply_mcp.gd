extends SceneTree
## Reply tools exercise the same store mutation path used by live hosts while
## keeping transport/registration out of this focused contract test.

const _AnnotationsScript = preload("res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd")
const _ReplyToolsScript = preload("res://Scripts/Services/MCP/Modules/MCPAnnotationReplyTools.gd")
const _SidecarScript = preload("res://Scripts/Services/Annotations/AnnotationSidecar.gd")

var _passed := 0
var _failed := 0


func _initialize() -> void:
	var store := _Store.new()
	store.values = [{
		"id": "ann_thread", "kind": "text_comment", "schema_version": 2,
		"kind_payload": {"text": "Root"}, "lifecycle": "open",
		"author": {"kind": "human"},
	}]
	var annotations = _AnnotationsScript.new(null)
	annotations.set_annotation_store(store)
	var tools = _ReplyToolsScript.new(null, annotations)

	var added: Dictionary = tools.handle("minerva_annotations_add_reply",
		{"annotation_id": "ann_thread", "text": "Agent reply"})
	var reply_id := str(added.get("reply", {}).get("id", ""))
	check("MCP add stamps stable AI reply metadata", bool(added.get("ok", false))
		and not reply_id.is_empty() and added.get("reply", {}).get("author", {}).get("kind") == "ai")

	var edited: Dictionary = tools.handle("minerva_annotations_edit_reply",
		{"annotation_id": "ann_thread", "reply_id": reply_id, "text": "Revised"})
	check("MCP edit updates the addressed reply without replacing root", bool(edited.get("ok", false))
		and edited.get("annotation", {}).get("kind_payload", {}).get("text") == "Root"
		and edited.get("annotation", {}).get("kind_payload", {}).get("replies", [])[0].get("text") == "Revised")

	var deleted: Dictionary = tools.handle("minerva_annotations_delete_reply",
		{"annotation_id": "ann_thread", "reply_id": reply_id})
	check("MCP delete removes only the addressed reply", bool(deleted.get("ok", false))
		and not deleted.get("annotation", {}).get("kind_payload", {}).has("replies"))
	var missing: Dictionary = tools.handle("minerva_annotations_edit_reply",
		{"annotation_id": "ann_thread", "reply_id": reply_id, "text": "Late"})
	check("MCP edit reports a missing stable reply", not bool(missing.get("ok", false))
		and str(missing.get("error", "")).contains("reply not found"))
	_test_sidecar_roundtrip_and_write_failure(tools)

	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _test_sidecar_roundtrip_and_write_failure(tools: RefCounted) -> void:
	var doc_path := "user://comment-reply-mcp.txt"
	var annotation := {
		"id": "ann_sidecar", "kind": "text_comment", "schema_version": 2,
		"kind_payload": {"text": "Root"}, "lifecycle": "open", "author": {"kind": "human"},
	}
	var err: Error = _SidecarScript.write_sidecar(doc_path, {
		"document": {"path": doc_path, "kind": "text"}, "annotations": [annotation],
		"unknown_kinds": [],
	})
	check("sidecar fixture is writable", err == OK)
	var added: Dictionary = tools.handle("minerva_annotations_add_reply", {
		"document_path": doc_path, "annotation_id": "ann_sidecar", "text": "Persisted",
	})
	var loaded: Dictionary = _SidecarScript.read_sidecar(doc_path)
	check("MCP reply round-trips through the real sidecar", bool(added.get("ok", false))
		and loaded.get("annotations", [])[0].get("kind_payload", {}).get("replies", [])[0].get("text") == "Persisted")
	var tmp_path: String = _SidecarScript.sidecar_path_for(doc_path) + ".tmp"
	DirAccess.remove_absolute(tmp_path)
	DirAccess.make_dir_absolute(tmp_path)
	var failed: Dictionary = tools.handle("minerva_annotations_add_reply", {
		"document_path": doc_path, "annotation_id": "ann_sidecar", "text": "No write",
	})
	var after_failure: Dictionary = _SidecarScript.read_sidecar(doc_path)
	check("sidecar write failure is returned instead of reporting a persisted reply",
		not bool(failed.get("ok", false)) and str(failed.get("error", "")).contains("sidecar")
		and (after_failure.get("annotations", [])[0].get("kind_payload", {}).get("replies", []) as Array).size() == 1)
	DirAccess.remove_absolute(tmp_path)
	DirAccess.remove_absolute(_SidecarScript.sidecar_path_for(doc_path))


func check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("  PASS: %s" % label)
	else:
		_failed += 1
		printerr("  FAIL: %s" % label)


class _Store extends RefCounted:
	var values: Array = []

	func get_all() -> Array:
		return values.duplicate(true)

	func update(annotation: Dictionary) -> void:
		for i in range(values.size()):
			if str((values[i] as Dictionary).get("id", "")) == str(annotation.get("id", "")):
				values[i] = annotation.duplicate(true)
