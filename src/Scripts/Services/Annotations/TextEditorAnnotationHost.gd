class_name TextEditorAnnotationHost
extends AnnotationHost
## Annotation host for the built-in code / text editor (Design §11.2, Round 5a).
##
## Owns a list of v2 annotation envelopes anchored to char-offset ranges in the
## editor text.  Wired to an EditorCodeEdit (or any object that exposes a `text`
## property) via set_code_edit() so resolve_anchor() can validate ranges against
## the live document.
##
## Anchor type handled: core/text.range
##   anchor.id  = {start: int, end: int}  (flat character offsets)
##   anchor.snapshot.position = [line_float, col_float]
##   anchor.snapshot.text     = selected substring at author time
##   anchor.snapshot.document_revision = int
##
## Sidecar file:  <file_path>.annotations.json

const _ANN_ID_PREFIX := "ann_"
const _SCHEMA := preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")

# ── Back-reference to the live text source ────────────────────────────────────

## The EditorCodeEdit (or anything with a `.text: String` property) that owns
## the document being annotated.  May be null when running in headless tests.
var _code_edit: Object = null

## Fallback text used when _code_edit is null (e.g. headless unit tests).
var _fallback_text: String = ""

## Annotation storage: Array of v2 envelope Dictionaries.
var _annotations: Array = []

## Next numeric suffix for generated IDs.
var _id_counter: int = 0

# ── Init ──────────────────────────────────────────────────────────────────────

func _init() -> void:
	super._init()
	register_anchor_resolver("core/text.range", Callable(self, "_resolve_text_range"))


# ── Public: code-edit binding ─────────────────────────────────────────────────

## Bind this host to an EditorCodeEdit node.  After binding, resolve_anchor()
## validates ranges against the live text.
func set_code_edit(code_edit: Object) -> void:
	_code_edit = code_edit


## Set the text directly (used by headless tests via set_text()).
func set_text(text: String) -> void:
	_fallback_text = text
	if _code_edit == null:
		bump_revision()


# ── Public: sidecar path ──────────────────────────────────────────────────────

## Return the path for the annotation sidecar file for a given source file.
## e.g. "res://Scripts/MyScript.gd" → "res://Scripts/MyScript.gd.annotations.json"
func get_sidecar_path(file_path: String) -> String:
	return file_path + ".annotations.json"


# ── Public: annotation storage ────────────────────────────────────────────────

## Add a v2 envelope.  Assigns a stable ID if one is not already present.
## Returns the assigned ID.
func add_annotation_v2(envelope: Dictionary) -> String:
	var schema = _SCHEMA.new()
	var result = schema.validate(envelope)
	if result.has_errors():
		push_warning("[TextEditorAnnotationHost] add_annotation_v2: validation errors: %s" % str(result.to_error_dicts()))
		return ""
	_id_counter += 1
	var ann_id: String = envelope.get("id", "")
	if ann_id.is_empty():
		ann_id = "%s%04x" % [_ANN_ID_PREFIX, _id_counter]
	var stored := envelope.duplicate(true)
	stored["id"] = ann_id
	_annotations.append(stored)
	return ann_id


## Override AnnotationHost.add_annotation() so callers using the base API work.
func add_annotation(annotation: Dictionary) -> String:
	return add_annotation_v2(annotation)


## Build and store a v2 envelope from (start, end, text). Used by Editor.add_comment
## (UI path) and the minerva_text_editor_add_comment MCP tool.
## Returns the assigned annotation id, or "" on failure.
func add_comment_at(start: int, end: int, text: String) -> String:
	if start < 0 or end < start:
		push_warning("[TextEditorAnnotationHost] add_comment_at: invalid range %d..%d" % [start, end])
		return ""
	var src := _get_text()
	var snapshot_text := ""
	if end <= src.length():
		snapshot_text = src.substr(start, end - start)
	var line_col := _offset_to_line_col(start)
	var doc_revision: int = get_revision()
	var now := int(Time.get_unix_time_from_system())
	var envelope := {
		"id": "",
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": start, "end": end},
			"snapshot": {
				"position": [float(line_col[0]), float(line_col[1])],
				"text": snapshot_text,
				"document_revision": doc_revision,
			},
		},
		"kind_payload": {"text": text},
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "text",
		"visible_in_views": ["all"],
		"summary": text if not text.is_empty() else "(empty comment)",
		"created_at": now,
		"updated_at": now,
	}
	return add_annotation_v2(envelope)


## Return all stored annotations (live array — do not mutate directly).
func get_all_annotations() -> Array:
	return _annotations


## Override AnnotationHost.get_annotations().
func get_annotations() -> Array:
	return _annotations


## Replace an annotation by id.  Returns true on success.
func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
	for i in range(_annotations.size()):
		if _annotations[i].get("id", "") == annotation_id:
			var updated := new_annotation.duplicate(true)
			updated["id"] = annotation_id
			_annotations[i] = updated
			return true
	return false


## Remove an annotation by id.  Returns true if found and removed.
func remove_annotation(annotation_id: String) -> bool:
	for i in range(_annotations.size()):
		if _annotations[i].get("id", "") == annotation_id:
			_annotations.remove_at(i)
			return true
	return false


## Load a serialized array of v2 envelopes into this host (replaces current list).
func load_annotations(raw_array: Array) -> void:
	var io := AnnotationSidecarIO.new()
	var result := io.process_annotations(raw_array)
	_annotations = result.get("annotations", [])


# ── Snapshot / restore (for round-trip; 5b/5c will flesh these out) ───────────

func capture_state_snapshot() -> Variant:
	return {
		"text": _get_text(),
		"annotations": _annotations.duplicate(true),
	}


func restore_state_snapshot(snapshot: Variant) -> bool:
	if not snapshot is Dictionary:
		return false
	var d: Dictionary = snapshot as Dictionary
	if d.has("text"):
		_fallback_text = str(d["text"])
	if d.has("annotations") and d["annotations"] is Array:
		_annotations = (d["annotations"] as Array).duplicate(true)
	return true


# ── View context ──────────────────────────────────────────────────────────────

func get_view_context() -> String:
	return "text"


# ── Core/text.range anchor resolver ──────────────────────────────────────────

func _resolve_text_range(anchor: Dictionary) -> Dictionary:
	var id: Variant = anchor.get("id", null)
	var snapshot: Dictionary = anchor.get("snapshot", {})
	var pos_array: Variant = snapshot.get("position", [0.0, 0.0])
	var snap_pos := Vector2.ZERO
	if pos_array is Array and (pos_array as Array).size() >= 2:
		snap_pos = Vector2(float((pos_array as Array)[0]), float((pos_array as Array)[1]))
	elif pos_array is Vector2:
		snap_pos = pos_array

	# If id is not a valid {start, end} dict, mark stale.
	if not id is Dictionary:
		return {"position": snap_pos, "bounds": Rect2(snap_pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	var id_dict: Dictionary = id as Dictionary
	var start: Variant = id_dict.get("start", -1)
	var end: Variant = id_dict.get("end", -1)
	if not start is int or not end is int:
		return {"position": snap_pos, "bounds": Rect2(snap_pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	var text_len := _get_text().length()
	if (start as int) < 0 or (end as int) > text_len or (start as int) > (end as int):
		return {"position": snap_pos, "bounds": Rect2(snap_pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	# Valid range — compute a rough line/col for position feedback.
	var line_col := _offset_to_line_col(start as int)
	var pos := Vector2(float(line_col[0]), float(line_col[1]))
	return {"position": pos, "bounds": Rect2(pos, Vector2.ZERO), "stale": false, "view_metadata": {}}


# ── Public helpers used by Editor.gd ─────────────────────────────────────────

## Return the current document text.  Public version for Editor.gd.
func get_text_content() -> String:
	return _get_text()


## Convert a flat char offset to [line, col].  Public version for Editor.gd.
func offset_to_line_col(offset: int) -> Array:
	return _offset_to_line_col(offset)


# ── Internal helpers ──────────────────────────────────────────────────────────

func _get_text() -> String:
	if _code_edit != null and "text" in _code_edit:
		return str(_code_edit.get("text"))
	return _fallback_text


func _offset_to_line_col(offset: int) -> Array:
	var text := _get_text()
	var line := 0
	var col := 0
	var i := 0
	while i < offset and i < text.length():
		if text[i] == "\n":
			line += 1
			col = 0
		else:
			col += 1
		i += 1
	return [line, col]
