class_name TextEditorAnnotationHost
extends AnnotationHost

const _CommentThreadScript = preload("res://Scripts/Services/Annotations/AnnotationCommentThread.gd")
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

signal annotations_changed()

const _ANN_ID_PREFIX := "ann_"
const _SCHEMA := preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
const _SidecarIOScript := preload("res://Scripts/Services/Annotations/AnnotationSidecarIO.gd")
const _LifecycleScript := preload("res://Scripts/Services/Annotations/AnnotationLifecycle.gd")
const _AnnotationTextCommentScript = preload("res://Scripts/Services/Annotations/kinds/AnnotationTextComment.gd")
const _TextAnchorHistoryScript = preload("res://Scripts/Services/Annotations/TextAnchorHistory.gd")

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

## Next stable user-facing number. Numbers are persisted per annotation and are
## never compacted, so chat references like "comment #2" survive resolve/reopen.
var _display_index_counter: int = 0

var _document_path: String = ""

## Per-host kind registry (built-in kinds registered eagerly).
var _registry: AnnotationRegistry = null
var _anchor_history: RefCounted = _TextAnchorHistoryScript.new()
var _anchor_generations: Dictionary = {}
var _tracked_text := ""

# ── Init ──────────────────────────────────────────────────────────────────────

func _init() -> void:
	super._init()
	register_anchor_resolver("core/text.range", Callable(self, "_resolve_text_range"))
	_registry = AnnotationRegistry.new()
	BuiltinKinds.register_all(_registry)
	_registry.register_annotation_kind(_AnnotationTextCommentScript.new())


## Return this host's kind registry. Required by MCP tools that resolve
## kind metadata (e.g. minerva_annotations_list).
func get_registry() -> AnnotationRegistry:
	return _registry


func get_capabilities() -> Dictionary:
	return {
		"kinds": ["text_comment"],
		"tools": ["select"],
		"anchor_types": ["core/text.range"],
		"lifecycle": {
			"resolve": true,
			"reopen": true,
			"delete": true,
			"repair": true,
			"apply": false,
		},
		"authoring": {
			"add": true,
			"domain_pickers": true,
		},
		"panes": false,
		"body_views": true,
		"filters": ["open", "resolved", "all"],
	}


func get_document_identity() -> Dictionary:
	return {
		"kind": "text",
		"path": _document_path,
		"display_name": _document_path.get_file() if not _document_path.is_empty() else "Text",
		"save_policy": "sidecar",
	}


# ── Public: code-edit binding ─────────────────────────────────────────────────

## Bind this host to an EditorCodeEdit node.  After binding, resolve_anchor()
## validates ranges against the live text.
func set_code_edit(code_edit: Object) -> void:
	_code_edit = code_edit
	_tracked_text = _get_text()
	_anchor_history.reset(_tracked_text, _code_edit_version(), _anchor_records())


func set_document_path(path: String) -> void:
	if path != _document_path and not _document_path.is_empty():
		_tracked_text = _get_text()
		_anchor_history.reset(_tracked_text, _code_edit_version(), _anchor_records())
	_document_path = path


## Set the text directly (used by headless tests via set_text()).
func set_text(text: String) -> void:
	_fallback_text = text
	if _code_edit == null:
		_tracked_text = text
		_anchor_history.reset(text, 0, _anchor_records())
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
	var stored := envelope.duplicate(true)
	var ann_id: String = str(stored.get("id", ""))
	if ann_id.is_empty():
		_id_counter += 1
		ann_id = "%s%04x" % [_ANN_ID_PREFIX, _id_counter]
		stored["id"] = ann_id
	_ensure_display_index(stored)
	# Stamp a project-scoped citeable ref ("C<n>") for chat citation (DCR
	# 019e9f602391 P2). No-op when no live project identity (headless tests).
	var _pi := ProjectIdentity.current()
	if _pi != null:
		_pi.stamp(stored)
	var schema = _SCHEMA.new()
	var result = schema.validate_with_registry(stored, _registry)
	if result.has_errors():
		push_warning("[TextEditorAnnotationHost] add_annotation_v2: validation errors: %s" % str(result.to_error_dicts()))
		return ""
	_annotations.append(stored)
	_bump_anchor_generation(ann_id)
	_anchor_history.record_anchor_state(_get_text(), _code_edit_version(), _anchor_records())
	annotations_changed.emit()
	return ann_id


## Override AnnotationHost.add_annotation() so callers using the base API work.
func add_annotation(annotation: Dictionary) -> String:
	return add_annotation_v2(annotation)


## Build and store a v2 envelope from (start, end, text). Used by Editor.add_comment
## (UI path) and the minerva_text_editor_add_comment MCP tool.
## Returns the assigned annotation id, or "" on failure.
func add_comment_at(start: int, end: int, text: String, target_scope: String = "range", author_kind: String = "human") -> String:
	if start < 0 or end < start:
		push_warning("[TextEditorAnnotationHost] add_comment_at: invalid range %d..%d" % [start, end])
		return ""
	if target_scope != "line":
		target_scope = "range"
	if author_kind != "ai":
		author_kind = "human"
	var src := _get_text()
	var snapshot_text := ""
	if end <= src.length():
		snapshot_text = src.substr(start, end - start)
	var line_col := _offset_to_line_col(start)
	var doc_revision: int = get_revision()
	var now := int(Time.get_unix_time_from_system())
	var envelope := {
		"id": "",
		"kind": "text_comment",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": start, "end": end},
			"snapshot": {
				"position": [float(line_col[0]), float(line_col[1])],
				"text": snapshot_text,
				"document_revision": doc_revision,
				"target_scope": target_scope,
			},
		},
		"kind_payload": {"text": text, "target_scope": target_scope},
		"lifecycle": "open",
		"author": {"kind": author_kind},
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


## Store-adapter alias used by MCPAnnotationsTools.
func get_all() -> Array:
	return get_all_annotations()


## Store-adapter lookup used by MCPAnnotationsTools.
func get_by_id(annotation_id: String) -> Dictionary:
	for ann in _annotations:
		if ann is Dictionary and str((ann as Dictionary).get("id", "")) == annotation_id:
			return (ann as Dictionary).duplicate(true)
	return {}


## Override AnnotationHost.get_annotations().
func get_annotations() -> Array:
	return _annotations


## Replace an annotation by id.  Returns true on success.
func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
	for i in range(_annotations.size()):
		if _annotations[i].get("id", "") == annotation_id:
			var updated := new_annotation.duplicate(true)
			updated["id"] = annotation_id
			if (_annotations[i] as Dictionary).get("anchor", {}) != updated.get("anchor", {}):
				_bump_anchor_generation(annotation_id)
			_annotations[i] = updated
			_anchor_history.record_anchor_state(_get_text(), _code_edit_version(), _anchor_records())
			annotations_changed.emit()
			return true
	return false


## Store-adapter update used by MCPAnnotationsTools.
func update(annotation: Dictionary) -> void:
	var annotation_id := str(annotation.get("id", ""))
	if not annotation_id.is_empty():
		update_annotation(annotation_id, annotation)


## Remove an annotation by id.  Returns true if found and removed.
func remove_annotation(annotation_id: String) -> bool:
	for i in range(_annotations.size()):
		if _annotations[i].get("id", "") == annotation_id:
			_annotations.remove_at(i)
			_anchor_history.record_anchor_state(_get_text(), _code_edit_version(), _anchor_records())
			# Base contract: removing the selected annotation clears selection.
			if get_selected_annotation_id() == annotation_id:
				set_selected_annotation_id("")
			annotations_changed.emit()
			return true
	return false


func add_comment_reply(annotation_id: String, text: String, author: Dictionary,
		parent_id: String = "") -> Dictionary:
	var current := get_by_id(annotation_id)
	if current.is_empty():
		return {"ok": false, "error": "annotation not found: %s" % annotation_id}
	var result: Dictionary = _CommentThreadScript.add_reply(current, text, author, parent_id)
	if bool(result.get("ok", false)) and not update_annotation(annotation_id, result.get("annotation", {})):
		return {"ok": false, "error": "annotation could not be updated"}
	return result


func edit_comment_reply(annotation_id: String, reply_id: String, text: String) -> Dictionary:
	var current := get_by_id(annotation_id)
	if current.is_empty():
		return {"ok": false, "error": "annotation not found: %s" % annotation_id}
	var result: Dictionary = _CommentThreadScript.edit_reply(current, reply_id, text)
	if bool(result.get("ok", false)) and not update_annotation(annotation_id, result.get("annotation", {})):
		return {"ok": false, "error": "annotation could not be updated"}
	return result


func delete_comment_reply(annotation_id: String, reply_id: String) -> Dictionary:
	var current := get_by_id(annotation_id)
	if current.is_empty():
		return {"ok": false, "error": "annotation not found: %s" % annotation_id}
	var result: Dictionary = _CommentThreadScript.delete_reply(current, reply_id)
	if bool(result.get("ok", false)) and not update_annotation(annotation_id, result.get("annotation", {})):
		return {"ok": false, "error": "annotation could not be updated"}
	return result


## Round 5b.ii: re-anchor a stale annotation to a new [start, end) range in the
## live document. Refreshes anchor.id + snapshot.text + snapshot.position from
## the current document, sets lifecycle back to "open", bumps the host revision
## so canvas + sidebar refresh. Returns true on success.
func retarget_annotation(annotation_id: String, start: int, end: int) -> bool:
	if start < 0 or end < start:
		return false
	for i in range(_annotations.size()):
		var ann_v: Variant = _annotations[i]
		if not ann_v is Dictionary:
			continue
		var ann: Dictionary = ann_v as Dictionary
		if str(ann.get("id", "")) != annotation_id:
			continue
		var src := _get_text()
		if end > src.length():
			return false
		var snapshot_text: String = src.substr(start, end - start)
		var line_col := _offset_to_line_col(start)
		var anchor: Dictionary = (ann.get("anchor", {}) as Dictionary).duplicate(true)
		anchor["id"] = {"start": start, "end": end}
		var snap: Dictionary = (anchor.get("snapshot", {}) as Dictionary).duplicate(true)
		snap.erase("tracking_state")
		snap["position"] = [float(line_col[0]), float(line_col[1])]
		snap["text"] = snapshot_text
		snap["document_revision"] = get_revision()
		anchor["snapshot"] = snap
		ann["anchor"] = anchor
		_bump_anchor_generation(annotation_id)
		ann["lifecycle"] = "open"
		ann["updated_at"] = int(Time.get_unix_time_from_system())
		_ensure_display_index(ann)
		_annotations[i] = ann
		_anchor_history.record_anchor_state(_get_text(), _code_edit_version(), _anchor_records())
		bump_revision()
		annotations_changed.emit()
		return true
	return false


## Smoke-test contract alias.
func repair_annotation(annotation_id: String, start: int, end: int) -> bool:
	return retarget_annotation(annotation_id, start, end)


## Load a serialized array of v2 envelopes into this host (replaces current list).
func load_annotations(raw_array: Array) -> void:
	var io = _SidecarIOScript.new()
	var result := io.process_annotations(raw_array)
	_annotations = result.get("annotations", [])
	_anchor_generations.clear()
	# JSON.parse_string returns Variant::FLOAT for all numerics; coerce
	# integer-valued anchor fields back to int so resolve_anchor's `is int`
	# guards behave the same on reload as on first author.
	for ann in _annotations:
		if ann is Dictionary:
			_migrate_text_to_text_comment(ann as Dictionary)
			_coerce_envelope_ints(ann as Dictionary)
			_ensure_display_index(ann as Dictionary)
			_bump_anchor_generation(str((ann as Dictionary).get("id", "")))
	# Bump _id_counter past any loaded "ann_XXXX" id so newly-generated ids
	# don't collide with persisted ones.
	for ann in _annotations:
		if ann is Dictionary:
			var ann_id := str((ann as Dictionary).get("id", ""))
			if ann_id.begins_with(_ANN_ID_PREFIX):
				var hex_part := ann_id.substr(_ANN_ID_PREFIX.length())
				if hex_part.is_valid_hex_number():
					var n: int = hex_part.hex_to_int()
					if n > _id_counter:
						_id_counter = n
			var display_index := int((ann as Dictionary).get("display_index", 0))
			if display_index > _display_index_counter:
				_display_index_counter = display_index
	# Reconcile the project-scoped ref counter against refs already minted in this
	# file so a number is never reused after a crash between saves (DCR
	# 019e9f602391 P2). Only refs minted by THIS project count.
	var _pi := ProjectIdentity.current()
	if _pi != null:
		var highest := AnnotationRef.highest_seq_in_list(_annotations, _pi.project_id)
		if highest > 0:
			_pi.reconcile_floor(highest)
	_tracked_text = _get_text()
	_anchor_history.reset(_tracked_text, _code_edit_version(), _anchor_records())
	annotations_changed.emit()


func update_annotation_lifecycle(annotation_id: String, lifecycle: String, patch: Dictionary = {}) -> Dictionary:
	if annotation_id.strip_edges().is_empty():
		return {"ok": false, "error": "annotation_id is required"}
	if not _LifecycleScript.is_valid_state(lifecycle):
		return {"ok": false, "error": "invalid lifecycle: %s" % lifecycle}
	for i in range(_annotations.size()):
		var ann_v: Variant = _annotations[i]
		if not ann_v is Dictionary:
			continue
		var ann: Dictionary = (ann_v as Dictionary).duplicate(true)
		if str(ann.get("id", "")) != annotation_id:
			continue
		var current := str(ann.get("lifecycle", "open"))
		if not _LifecycleScript.can_transition(current, lifecycle):
			return {"ok": false, "error": "illegal lifecycle transition: %s -> %s" % [current, lifecycle]}
		for key in patch.keys():
			ann[key] = patch[key]
		ann["lifecycle"] = lifecycle
		ann["updated_at"] = int(Time.get_unix_time_from_system())
		_ensure_display_index(ann)
		_annotations[i] = ann
		annotations_changed.emit()
		return {"ok": true, "annotation": ann.duplicate(true)}
	return {"ok": false, "error": "annotation not found: %s" % annotation_id}


func get_annotation_display_index(annotation: Dictionary) -> int:
	return int(annotation.get("display_index", 0))


## In-place coercion: walk a freshly-deserialised envelope and turn any
## numeric field that should be an int back into one. Idempotent on already-int
## inputs.
func _coerce_envelope_ints(envelope: Dictionary) -> void:
	if envelope.get("schema_version", null) is float:
		envelope["schema_version"] = int(envelope["schema_version"])
	if envelope.get("display_index", null) is float:
		envelope["display_index"] = int(envelope["display_index"])
	for key in ["created_at", "updated_at"]:
		if envelope.get(key, null) is float:
			envelope[key] = int(envelope[key])
	var anchor: Variant = envelope.get("anchor", null)
	if anchor is Dictionary:
		var anchor_id: Variant = (anchor as Dictionary).get("id", null)
		if anchor_id is Dictionary:
			for k in (anchor_id as Dictionary).keys():
				if (anchor_id as Dictionary)[k] is float:
					(anchor_id as Dictionary)[k] = int((anchor_id as Dictionary)[k])
		var snap: Variant = (anchor as Dictionary).get("snapshot", null)
		if snap is Dictionary and (snap as Dictionary).get("document_revision", null) is float:
			(snap as Dictionary)["document_revision"] = int((snap as Dictionary)["document_revision"])


func _ensure_display_index(annotation: Dictionary) -> void:
	var existing := int(annotation.get("display_index", 0))
	if existing > 0:
		if existing > _display_index_counter:
			_display_index_counter = existing
		return
	_display_index_counter += 1
	annotation["display_index"] = _display_index_counter


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
	_anchor_generations.clear()
	for annotation in _annotations:
		if annotation is Dictionary:
			_bump_anchor_generation(str((annotation as Dictionary).get("id", "")))
	_tracked_text = _get_text()
	_anchor_history.reset(_tracked_text, _code_edit_version(), _anchor_records())
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
	var tracking_state := str(snapshot.get("tracking_state", ""))
	if not tracking_state.is_empty():
		return {"position": snap_pos, "bounds": Rect2(snap_pos, Vector2.ZERO), "stale": true,
			"view_metadata": {"reason": "Text removed" if tracking_state == "text_removed" else "Anchor needs repair"}}

	# If id is not a valid {start, end} dict, mark stale.
	if not id is Dictionary:
		return {"position": snap_pos, "bounds": Rect2(snap_pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	var id_dict: Dictionary = id as Dictionary
	var start: Variant = id_dict.get("start", -1)
	var end: Variant = id_dict.get("end", -1)
	if not start is int or not end is int:
		return {"position": snap_pos, "bounds": Rect2(snap_pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	var src_text := _get_text()
	var text_len := src_text.length()
	if (start as int) < 0 or (end as int) > text_len or (start as int) > (end as int):
		return {"position": snap_pos, "bounds": Rect2(snap_pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	# Snapshot text follows ordinary edits through track_text_change(). A mismatch
	# here therefore means an untracked/external reset or an older sidecar that
	# could not be reconciled, and safely enters the repair flow.
	var snap_text: String = str(snapshot.get("text", ""))
	if not snap_text.is_empty():
		var live: String = src_text.substr(start as int, (end as int) - (start as int))
		if live != snap_text:
			return {"position": snap_pos, "bounds": Rect2(snap_pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	var line_col := _offset_to_line_col(start as int)
	var pos := Vector2(float(line_col[0]), float(line_col[1]))
	return {"position": pos, "bounds": Rect2(pos, Vector2.ZERO), "stale": false, "view_metadata": {}}


# ── Public helpers used by Editor.gd ─────────────────────────────────────────

## Return the current document text.  Public version for Editor.gd.
func get_text_content() -> String:
	return _get_text()


## Called from Editor's text_changed boundary after CodeEdit has recorded the
## operation. CodeEdit's version identifies undo/redo states; buffer revisions
## do not, because they only increase.
func track_text_change(text: String, code_edit_version: int) -> void:
	if text == _tracked_text:
		return
	var moved: Dictionary = _anchor_history.transition(
		_tracked_text, text, code_edit_version, _anchor_records())
	_tracked_text = text
	bump_revision()
	var changed := false
	for i in range(_annotations.size()):
		var annotation: Dictionary = _annotations[i]
		var annotation_id := str(annotation.get("id", ""))
		if not moved.has(annotation_id):
			continue
		var record: Dictionary = moved[annotation_id]
		var anchor_v: Variant = annotation.get("anchor", {})
		if not anchor_v is Dictionary:
			continue
		var anchor: Dictionary = (anchor_v as Dictionary).duplicate(true)
		anchor["id"] = {"start": int(record.get("start", 0)), "end": int(record.get("end", 0))}
		var snapshot_v: Variant = anchor.get("snapshot", {})
		var snapshot: Dictionary = (snapshot_v as Dictionary).duplicate(true) if snapshot_v is Dictionary else {}
		var record_state := str(record.get("tracking_state", ""))
		if not record_state.is_empty():
			snapshot["tracking_state"] = record_state
		else:
			snapshot.erase("tracking_state")
			var start := int(record.get("start", 0))
			var end := int(record.get("end", start))
			snapshot["text"] = text.substr(start, end - start)
			var line_col := _offset_to_line_col_for(text, start)
			snapshot["position"] = [float(line_col[0]), float(line_col[1])]
		snapshot["document_revision"] = get_revision()
		anchor["snapshot"] = snapshot
		if annotation.get("anchor", {}) != anchor:
			annotation["anchor"] = anchor
			_annotations[i] = annotation
			changed = true
	_anchor_history.record_anchor_state(text, code_edit_version, _anchor_records())
	if changed:
		annotations_changed.emit()


## Convert a flat char offset to [line, col].  Public version for Editor.gd.
func offset_to_line_col(offset: int) -> Array:
	return _offset_to_line_col(offset)


# ── Internal helpers ──────────────────────────────────────────────────────────

func _get_text() -> String:
	if _code_edit != null and "text" in _code_edit:
		return str(_code_edit.get("text"))
	return _fallback_text


func _code_edit_version() -> int:
	if _code_edit != null and _code_edit.has_method("get_version"):
		return int(_code_edit.call("get_version"))
	return 0


func _bump_anchor_generation(annotation_id: String) -> void:
	if annotation_id.is_empty():
		return
	_anchor_generations[annotation_id] = int(_anchor_generations.get(annotation_id, 0)) + 1


func _anchor_records() -> Dictionary:
	var records := {}
	for annotation_v in _annotations:
		if not annotation_v is Dictionary:
			continue
		var annotation: Dictionary = annotation_v
		var annotation_id := str(annotation.get("id", ""))
		var anchor_v: Variant = annotation.get("anchor", {})
		if annotation_id.is_empty() or not anchor_v is Dictionary:
			continue
		var id_v: Variant = (anchor_v as Dictionary).get("id", {})
		if not id_v is Dictionary:
			continue
		var snapshot_v: Variant = (anchor_v as Dictionary).get("snapshot", {})
		var snapshot: Dictionary = snapshot_v as Dictionary if snapshot_v is Dictionary else {}
		var record_state := str(snapshot.get("tracking_state", ""))
		var start := int((id_v as Dictionary).get("start", 0))
		var end := int((id_v as Dictionary).get("end", 0))
		if record_state.is_empty():
			var expected := str(snapshot.get("text", ""))
			if start < 0 or end < start or end > _tracked_text.length() \
					or (not expected.is_empty() and _tracked_text.substr(start, end - start) != expected):
				continue
		records[annotation_id] = {
			"generation": int(_anchor_generations.get(annotation_id, 1)),
			"start": start,
			"end": end,
			"tracking_state": record_state,
		}
	return records


func _offset_to_line_col(offset: int) -> Array:
	return _offset_to_line_col_for(_get_text(), offset)


static func _offset_to_line_col_for(text: String, offset: int) -> Array:
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


## Migrate older sidecar entries: kind=="text" with kind_payload.target_scope in
## ["range","line"] are comments authored before the text_comment kind existed.
## Read-side only — disk is not touched until next user write.
func _migrate_text_to_text_comment(envelope: Dictionary) -> void:
	if str(envelope.get("kind", "")) != "text":
		return
	var payload: Variant = envelope.get("kind_payload", null)
	if not payload is Dictionary:
		return
	var scope := str((payload as Dictionary).get("target_scope", ""))
	if scope == "range" or scope == "line":
		envelope["kind"] = "text_comment"
