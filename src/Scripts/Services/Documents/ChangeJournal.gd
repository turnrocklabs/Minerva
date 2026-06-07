class_name ChangeJournal
extends RefCounted
## In-memory, per-session edit journal (work item 019ea01719a2). Backs the code
## review diff from Minerva's ACTUAL edits — agent AND human — instead of git.
##
## Every buffered edit funnels through DocumentBuffer.apply_edit() -> text_changed
## (the human editor routes there too via Editor._on_editor_changed). The journal
## subscribes to each buffer and keeps, per path: a BASELINE (text at the start of
## the current changeset) + CURRENT text. mark() starts a new changeset
## (re-baselines). The review diff for a file = TextLineDiff(baseline, current).
##
## Attribution (ai vs human) is one-shot per edit via attribute_next_edit_to():
## MCP doc tools tag their edit "ai" right before apply_edit; human typing is the
## default. v1 is in-memory (rubric: reliability+cost over data-durability, owner
## decision); persistence per project_id is a later drop-in.

var project_id: String = ""

var _baselines: Dictionary = {}   # path -> String (text at changeset start)
var _current: Dictionary = {}     # path -> String (latest text)
var _meta: Dictionary = {}        # path -> {edits:int, source:String, version:int, ts:int}
var _connected: Dictionary = {}   # path -> true (avoid double-connecting a buffer)
var _changeset: Dictionary = {"label": "session", "source": "", "ts": 0, "seq": 0}
var _next_source: String = ""     # one-shot attribution for the next edit


func _init(p_project_id: String = "") -> void:
	project_id = p_project_id


## Subscribe to a buffer's edits and seed its baseline. Idempotent per path, so
## DocumentRegistry can call it on every get_or_create_buffer.
func track_buffer(path: String, buffer: Object) -> void:
	if path.is_empty() or buffer == null:
		return
	var initial := str(buffer.get("text")) if buffer.get("text") != null else ""
	if not _baselines.has(path):
		_baselines[path] = initial
	if not _current.has(path):
		_current[path] = initial
	if not _connected.has(path) and buffer.has_signal("text_changed"):
		buffer.text_changed.connect(_on_text_changed.bind(path))
		_connected[path] = true


## One-shot: attribute the NEXT edit (the next text_changed) to `source` (e.g.
## "ai"). Consumed once, then reverts to the "human" default.
func attribute_next_edit_to(source: String) -> void:
	_next_source = source


func _on_text_changed(text: String, version: int, path: String) -> void:
	_current[path] = text
	var source := _next_source if not _next_source.is_empty() else "human"
	_next_source = ""
	var m: Dictionary = _meta.get(path, {"edits": 0, "source": "", "version": 0, "ts": 0})
	m["edits"] = int(m["edits"]) + 1
	m["source"] = source
	m["version"] = version
	m["ts"] = int(Time.get_unix_time_from_system())
	_meta[path] = m


## Start a new changeset: re-baseline every tracked path to its current text and
## reset per-file metadata. Callers emit markers (turn-start, save, commit).
func mark(label: String, source: String = "") -> void:
	for path in _current.keys():
		_baselines[path] = _current[path]
	_meta.clear()
	_changeset = {
		"label": label,
		"source": source,
		"ts": int(Time.get_unix_time_from_system()),
		"seq": int(_changeset.get("seq", 0)) + 1,
	}


## Paths changed in the current changeset (current != baseline).
func changed_paths() -> Array:
	var out: Array = []
	for path in _current.keys():
		if str(_current[path]) != str(_baselines.get(path, "")):
			out.append(path)
	return out


## Structured diff for one path: TextLineDiff(baseline, current) + attribution.
func diff_for(path: String) -> Dictionary:
	var before := str(_baselines.get(path, ""))
	var after := str(_current.get(path, ""))
	var d := TextLineDiff.diff(before, after)
	var m: Dictionary = _meta.get(path, {})
	d["path"] = path
	d["source"] = str(m.get("source", ""))
	d["edits"] = int(m.get("edits", 0))
	return d


## Aligned left/right rows (baseline vs current) for the side-by-side review
## widget (TextLineDiff.aligned_rows). Empty when the file isn't changed/tracked.
func aligned_rows_for(path: String) -> Array:
	if not _current.has(path):
		return []
	return TextLineDiff.aligned_rows(str(_baselines.get(path, "")), str(_current[path]))


## Overview of the current changeset for a review launcher.
func changeset_summary() -> Dictionary:
	var files: Array = []
	for path in changed_paths():
		var d := diff_for(path)
		files.append({"path": path, "adds": d["adds"], "dels": d["dels"], "source": d["source"]})
	return {
		"label": str(_changeset.get("label", "")),
		"source": str(_changeset.get("source", "")),
		"seq": int(_changeset.get("seq", 0)),
		"files": files,
	}
