extends SceneTree
## Tests for bug 019ea5335f03: a BLANK line must be commentable. The intent is
## "add a section here" — a positional/line-scope comment, not a character span.
##
## Two layers:
##  A. SUBSTRATE round-trip (TextEditorAnnotationHost): a zero-width "line" anchor
##     (start == end) stores, resolves NON-stale (the empty-snapshot path skips the
##     text-equality check), is line-scoped (so the canvas draws a gutter marker
##     keyed off `start` alone), and survives a serialize→load_annotations reload.
##  B. Editor GUARD predicate (_store_pending_annotation_selection): LINE scope
##     accepts a zero-width span; RANGE scope still requires a real span. This is
##     the guard whose old `end <= start` rejection caused the empty-line wedge.
##
## The wedge itself (empty click kills later clicks) dissolves: the blank click now
## succeeds instead of bailing out, so there is no half-finished state to get stuck
## in. The live click/focus path is HITL.
##
## Run: godot --headless --path src --script test/test_blank_line_annotation.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== blank-line annotation tests (019ea5335f03) ===")
	var HostScript: Variant = load("res://Scripts/Services/Annotations/TextEditorAnnotationHost.gd")
	_check("host script compiles", HostScript != null)

	test_substrate_blank_line_round_trip(HostScript)
	test_substrate_non_blank_still_works(HostScript)
	test_editor_guard_line_allows_zero_width()
	test_editor_guard_range_requires_span()

	print("=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


# ── A. substrate round-trip ──────────────────────────────────────────────────

# Document: "alpha\n\nbeta\n" — line 1 (index 1) is blank, at flat offset 6.
const _DOC := "alpha\n\nbeta\n"
const _BLANK_OFFSET := 6  # start of the blank line 1


func test_substrate_blank_line_round_trip(HostScript: Variant) -> void:
	var host = HostScript.new()
	host.set_text(_DOC)

	# Zero-width line anchor: start == end == the blank line's offset.
	var ann_id: String = host.add_comment_at(_BLANK_OFFSET, _BLANK_OFFSET, "add a new section here", "line")
	_check("blank-line comment stored (non-empty id)", not ann_id.is_empty())

	var ann: Dictionary = host.get_by_id(ann_id)
	_check("stored as line scope", str(ann.get("kind_payload", {}).get("target_scope", "")) == "line")
	var anchor_id: Dictionary = ann.get("anchor", {}).get("id", {})
	_check("anchor is zero-width (start == end)", int(anchor_id.get("start", -1)) == _BLANK_OFFSET and int(anchor_id.get("end", -2)) == _BLANK_OFFSET)
	_check("snapshot text is empty", str(ann.get("anchor", {}).get("snapshot", {}).get("text", "x")) == "")

	var resolved: Dictionary = host.resolve_anchor(ann.get("anchor", {}))
	_check("blank-line anchor resolves NON-stale", not bool(resolved.get("stale", true)))
	var pos: Vector2 = resolved.get("position", Vector2(-1, -1))
	_check("resolved position points at line 1 (the blank line)", int(pos.x) == 1)

	# Reload round-trip: serialize the live list, load into a fresh host, re-resolve.
	var raw: Array = host.get_all_annotations().duplicate(true)
	var host2 = HostScript.new()
	host2.set_text(_DOC)
	host2.load_annotations(raw)
	var reloaded: Dictionary = host2.get_by_id(ann_id)
	_check("survives reload (found by id)", not reloaded.is_empty())
	var resolved2: Dictionary = host2.resolve_anchor(reloaded.get("anchor", {}))
	_check("reloaded blank-line anchor still NON-stale", not bool(resolved2.get("stale", true)))


func test_substrate_non_blank_still_works(HostScript: Variant) -> void:
	# A normal span comment on "alpha" (offsets 0..5) must still resolve and be
	# range-scoped — proves the line path didn't regress spans.
	var host = HostScript.new()
	host.set_text(_DOC)
	var ann_id: String = host.add_comment_at(0, 5, "name it", "range")
	var ann: Dictionary = host.get_by_id(ann_id)
	_check("span comment stored", not ann_id.is_empty())
	_check("span comment is range scope", str(ann.get("kind_payload", {}).get("target_scope", "")) == "range")
	_check("span anchor resolves non-stale", not bool(host.resolve_anchor(ann.get("anchor", {})).get("stale", true)))


# ── B. Editor guard predicate ────────────────────────────────────────────────
# Editor.gd can't be instantiated under --script (its Autocoder dependency chain
# references the SingletonObject autoload, absent in headless --script). So this
# MIRRORS Editor._store_pending_annotation_selection exactly — the same way
# test_buffer_sync_undo_caret mirrors _set_code_edit_text_from_buffer. If the real
# guard changes, update this mirror in lockstep. Returns {ok, pending}.
func _mirror_store(start: int, end: int, target_scope: String) -> Dictionary:
	if end < start:
		var tmp := start
		start = end
		end = tmp
	var is_line := target_scope == "line"
	if start < 0 or (not is_line and end <= start):
		return {"ok": false, "pending": {}}
	return {"ok": true, "pending": {"start": start, "end": end, "target_scope": "line" if is_line else "range"}}


func test_editor_guard_line_allows_zero_width() -> void:
	var r := _mirror_store(6, 6, "line")
	_check("LINE scope accepts zero-width (6,6)", bool(r["ok"]))
	var pending: Dictionary = r["pending"]
	_check("pending stored as line scope", str(pending.get("target_scope", "")) == "line")
	_check("pending start/end both 6", int(pending.get("start", -1)) == 6 and int(pending.get("end", -1)) == 6)


func test_editor_guard_range_requires_span() -> void:
	_check("RANGE scope rejects zero-width (6,6)", not bool(_mirror_store(6, 6, "range")["ok"]))
	_check("negative offset rejected even for line scope", not bool(_mirror_store(-1, -1, "line")["ok"]))
	_check("RANGE scope accepts a real span (0,5)", bool(_mirror_store(0, 5, "range")["ok"]))
