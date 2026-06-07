class_name AnnotationRefResolver
extends RefCounted
## Chat bridge for citeable annotation refs (DCR 019e9f602391 P4).
##
## When a user cites a ref like "C7" in a chat message, this resolves it to the
## annotation's CURRENT (re-anchored) code + intent + lifecycle/staleness and
## returns it as plain-text reference notes. Those notes are injected via
## ChatHistoryItem.InjectedNotes, which every provider already folds into a
## "Reference Information" section (each entry must be a String — NOT a
## ContextBlock dict, which providers silently drop).
##
## Resolution scans live editor hosts (open buffers) so the cited code reflects
## edits made since the comment was written. Refs are scoped to the project_id so
## a "C7" from another project doesn't leak in.

const _REF_PATTERN := "\\bC[0-9]+\\b"


## Extract unique refs cited in `text`, in first-appearance order: ["C7","C12"].
static func parse_refs(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var re := RegEx.new()
	if re.compile(_REF_PATTERN) != OK:
		return out
	for m in re.search_all(text):
		var r := m.get_string()
		if not out.has(r):
			out.append(r)
	return out


## Resolve every ref cited in `text` to a plain-text reference note for the LLM.
## Returns an Array of Strings ready to merge into ChatHistoryItem.InjectedNotes.
## Unresolvable refs (not open in any live host, or another project's) are skipped.
static func resolve_for_chat(text: String, project_id: String) -> Array:
	var notes: Array = []
	for ref in parse_refs(text):
		var found := _find(ref, project_id)
		if found.is_empty():
			continue
		notes.append(_format_ref_note(ref, found))
	return notes


## Find a ref in the live editor hosts. Returns {host, editor_name, annotation}
## or {} if not found. project_id (when non-empty) scopes to one project.
static func _find(ref: String, project_id: String) -> Dictionary:
	for editor_name in AnnotationHostRegistry.list_editor_names():
		var host: AnnotationHost = AnnotationHostRegistry.get_host(str(editor_name))
		if host == null:
			continue
		for ann in _host_annotations(host):
			if not ann is Dictionary:
				continue
			var d := ann as Dictionary
			if str(d.get("ref", "")) != ref:
				continue
			if not project_id.is_empty() and str(d.get("ref_project", "")) != project_id:
				continue
			return {"host": host, "editor_name": str(editor_name), "annotation": d}
	return {}


## Build the plain-text note for one resolved ref: header (ref, status, location,
## intent) + the CURRENT code at the anchor when available.
static func _format_ref_note(ref: String, found: Dictionary) -> String:
	var ann: Dictionary = found.get("annotation", {})
	var host: AnnotationHost = found.get("host", null)
	var loc := str(found.get("editor_name", ""))

	var intent := str(ann.get("summary", "")).strip_edges()
	if intent.is_empty() and ann.get("kind_payload", {}) is Dictionary:
		intent = str((ann.get("kind_payload", {}) as Dictionary).get("text", "")).strip_edges()
	if intent.is_empty():
		intent = "(no intent recorded)"

	var stale := false
	var current_code := ""
	if host != null and ann.get("anchor", {}) is Dictionary:
		var anchor: Dictionary = ann.get("anchor", {})
		var resolved: Variant = host.resolve_anchor(anchor)
		if resolved is Dictionary:
			stale = bool((resolved as Dictionary).get("stale", false))
		current_code = _current_code_at(host, anchor)

	var status := str(ann.get("lifecycle", "open"))
	if stale:
		status += " / STALE (code at the anchor changed since this comment)"

	var lines: Array = []
	lines.append("Cited annotation %s [%s]%s" % [ref, status, ("" if loc.is_empty() else " @ " + loc)])
	lines.append("Intent: %s" % intent)
	if not current_code.is_empty():
		lines.append("Current code at the anchor:\n%s" % current_code)
	return "\n".join(lines)


## Current text at a text.range anchor from the live buffer, or "" if not a
## text.range / out of bounds / host has no text accessor.
static func _current_code_at(host: AnnotationHost, anchor: Dictionary) -> String:
	if not host.has_method("get_text_content"):
		return ""
	var aid: Variant = anchor.get("id", {})
	if not aid is Dictionary or not (aid as Dictionary).has("start") or not (aid as Dictionary).has("end"):
		return ""
	var src := str(host.get_text_content())
	var s := int((aid as Dictionary)["start"])
	var e := int((aid as Dictionary)["end"])
	if s < 0 or e > src.length() or s > e:
		return ""
	return src.substr(s, e - s)


static func _host_annotations(host: AnnotationHost) -> Array:
	if host.has_method("get_all_annotations"):
		return host.get_all_annotations()
	if host.has_method("get_annotations"):
		return host.get_annotations()
	return []
