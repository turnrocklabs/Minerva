class_name AnnotationSidecarIO
extends RefCounted

const AnnotationSchemaScript = preload("res://Scripts/Services/Annotations/AnnotationSchema.gd")


func process_annotations(sidecar_data: Array) -> Dictionary:
	var schema := AnnotationSchemaScript.new()
	var annotations: Array = []
	var dropped: Array = []
	var failed: Array = []

	for item in sidecar_data:
		if not item is Dictionary:
			failed.append({"annotation": item, "reason": "annotation must be a dictionary"})
			continue
		var annotation := item as Dictionary
		if schema.is_v1_envelope(annotation):
			var migrated: Variant = schema.migrate_v1_to_v2(annotation, null)
			if migrated is String and migrated == "drop":
				dropped.append({"id": annotation.get("id", ""), "kind": annotation.get("kind", "")})
			elif migrated is Dictionary:
				annotations.append(migrated)
			else:
				failed.append({"id": annotation.get("id", ""), "kind": annotation.get("kind", ""), "reason": "migration failed"})
		else:
			annotations.append(annotation.duplicate(true))

	return {
		"annotations": annotations,
		"v1_dropped": dropped,
		"v1_failed": failed,
		"summary": _summary(annotations.size(), dropped.size(), failed.size()),
	}


func load_sidecar(sidecar_data: Array) -> Dictionary:
	return process_annotations(sidecar_data)


func save_sidecar_v2(_document_path: String, _annotations: Array) -> Dictionary:
	return {"ok": true}


func _summary(loaded: int, dropped: int, failed: int) -> String:
	return "%d loaded, %d dropped, %d migration failed" % [loaded, dropped, failed]
