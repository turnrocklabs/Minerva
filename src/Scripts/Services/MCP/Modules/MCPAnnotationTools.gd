class_name MCPAnnotationTools
extends RefCounted
## MCP tool module for annotation CRUD and overlay rendering.
##
## Implements five tools over the annotation substrate (design §8.1-8.2):
##   minerva_annotations_list         — list all annotations from sidecar
##   minerva_annotations_add          — validate + add annotation, force author=ai
##   minerva_annotations_update       — shallow patch top-level fields
##   minerva_annotations_delete       — delete by id (idempotent)
##   minerva_annotations_render_overlay — render annotations to PNG
##   minerva_annotations_query        — v2 lifecycle/chat-context query surface
##   minerva_annotations_update_status — transition v2 lifecycle state
##   minerva_annotations_repair_anchor — direct/admin anchor retarget surface
##
## Intentionally extends RefCounted (not MCPToolModule) to avoid a transitive
## compile-time dependency on MCPToolUtils, which references the SingletonObject
## autoload. Annotations do not need editor-lookup helpers. The MinervaMCPServer
## module array is duck-typed (Array, not Array[MCPToolModule]), so this is
## fully compatible at runtime.
##
## Render-via-kind implementation note (R6):
##   _render_annotation_via_kind() dispatches to kind.render() using an
##   _ImageRenderContext that overrides all draw helpers with pure-software
##   rasterizers that write directly to an Image. This works in both headless
##   test environments (no GPU, no SceneTree _draw callback) and in live usage.
##   The placeholder fill_rect is kept as a fallback for null (unknown) kinds.
##
## Scope constraints enforced here:
##   - Live-authoring (start_stroke / add_points / end_stroke) is task
##     019dc0ec06f77301858eed9cc22bb116 — NOT HERE.
##   - Project-export integration is task 019dc055dc727a42adde624933630511 — NOT HERE.
##   - PluginEditorRegistry not yet implemented; render_overlay stubs document
##     compositing with a warning and returns an overlay-only PNG.
##
## Author attribution rule (design §8.1, plan-decision item 5):
##   All MCP-originated writes set annotation.author = "ai" unconditionally.
##   "human" is reserved for direct-UI authoring on the Godot editor surface.
##
## Validation errors are always structured arrays of {field_path, message, code}
## dicts — never plain strings. LLMs need structured results to fix problems.
##
## Sidecar 250 ms debounce note (design §7.5):
##   The design calls for a 250 ms debounce on MCP mutations. This module performs
##   immediate writes for correctness and testability; a debounce wrapper can be
##   layered on top without changing the tool surface.

## Back-reference to MinervaMCPServer for tool registration.
## Null in unit tests (module still works — handle() has no server dependency).
var server

const _TOOL_SET := "annotations"
## Maximum edge length (pixels) for the output overlay image. Images wider or
## taller than this are downsampled before compositing to keep PNG encoding fast.
const _MAX_OUTPUT_EDGE: int = 1024
const _DEFAULT_QUERY_STATUSES: PackedStringArray = ["open", "applied"]


func _init(mcp_server = null) -> void:
	server = mcp_server


# ── MCPToolModule interface (duck-typed) ──────────────────────────────────────

func get_tool_names() -> Array[String]:
	return [
		"minerva_annotations_list",
		"minerva_annotations_add",
		"minerva_annotations_update",
		"minerva_annotations_delete",
		"minerva_annotations_render_overlay",
		"minerva_annotations_query",
		"minerva_annotations_update_status",
		"minerva_annotations_repair_anchor",
		"minerva_text_editor_add_comment",
	]


func can_handle(tool_name: String) -> bool:
	return tool_name in get_tool_names()


func register_tools() -> void:
	server._register_tool(
		"minerva_annotations_list",
		"List annotations in a document. Returns a flat array; each entry has id, kind, author, "
		+ "summary (one-line natural-language description), bounds ({x, y, w, h}), "
		+ "anchored_to (semantic anchor to a domain entity, often empty), plus the original "
		+ "primitives array. Optional author filter ('human' or 'ai') narrows the output. "
		+ "Use this for token-efficient annotation introspection; call render_overlay if you need vision. "
		+ "Provide EXACTLY ONE of: editor_name (live in-memory annotations from a running plugin "
		+ "panel — match the name returned by minerva_list_editors), or document_path (sidecar "
		+ "on disk at <document_path>.annotations.json). Prefer editor_name for unsaved work.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors). Queries the "
					+ "live in-memory AnnotationHost for that editor — needed when the user's just-drawn "
					+ "annotations haven't been saved to a sidecar yet.",
				},
				"document_path": {
					"type": "string",
					"description": "Absolute path to the document file (e.g. /home/user/boards/board.minpcb). "
					+ "The sidecar is looked up at <document_path>.annotations.json.",
				},
				"author": {
					"type": "string",
					"enum": ["human", "ai"],
					"description": "Optional. Filter to only annotations authored by 'human' or 'ai'. Omit for all.",
				},
			},
		},
		_TOOL_SET
	)

	server._register_tool(
		"minerva_annotations_add",
		"Add a new annotation to a document. The annotation is validated against the "
		+ "substrate schema and the registered kind. Structural errors return "
		+ "{ok: false, errors: [{field_path, message, code}, ...]}. "
		+ "author is always forced to 'ai' regardless of the input value. "
		+ "id and created_at are generated if absent.",
		{
			"type": "object",
			"properties": {
				"document_path": {
					"type": "string",
					"description": "Absolute path to the document file.",
				},
				"annotation": {
					"type": "object",
					"description": "Annotation envelope dict. Required fields: kind, view_context, primitives[]. "
					+ "Optional: id (generated if absent), created_at (stamped if absent), payload. "
					+ "author is overwritten to 'ai' by the server.",
				},
			},
			"required": ["document_path", "annotation"],
		},
		_TOOL_SET
	)

	server._register_tool(
		"minerva_annotations_update",
		"Shallow-patch top-level fields of an existing annotation. primitives[] is replaced "
		+ "wholesale if present in the patch. updated_at is always bumped. author cannot be "
		+ "changed (immutable post-creation). Returns {ok: false, error: 'not_found'} if "
		+ "the id does not exist in the sidecar.",
		{
			"type": "object",
			"properties": {
				"document_path": {
					"type": "string",
					"description": "Absolute path to the document file.",
				},
				"id": {
					"type": "string",
					"description": "Annotation id to update (e.g. ann_a1b2c3).",
				},
				"patch": {
					"type": "object",
					"description": "Dict of top-level fields to replace. Only provided keys are modified.",
				},
			},
			"required": ["document_path", "id", "patch"],
		},
		_TOOL_SET
	)

	server._register_tool(
		"minerva_annotations_delete",
		"Delete an annotation by id. Idempotent — if the id is not found, returns "
		+ "{ok: false, reason: 'not_found'} but does not raise an error.",
		{
			"type": "object",
			"properties": {
				"document_path": {
					"type": "string",
					"description": "Absolute path to the document file.",
				},
				"id": {
					"type": "string",
					"description": "Annotation id to delete.",
				},
			},
			"required": ["document_path", "id"],
		},
		_TOOL_SET
	)

	server._register_tool(
		"minerva_annotations_render_overlay",
		"Render annotations composited with the host's UI and write PNG to a caller-supplied "
		+ "absolute path. EXACTLY ONE of `editor_name` (live in-memory annotations from a running "
		+ "plugin panel) or `document_path` (saved sidecar) must be provided. EXPENSIVE — call "
		+ "sparingly and read the written file with your Read tool for vision. "
		+ "include_document=true: composites the host's UI underneath when a renderer is registered "
		+ "(live editor) or falls back to transparent if not. "
		+ "include_kinds filters to only those annotation kinds; empty = all. "
		+ "output_path must be an absolute filesystem path; the parent directory must already exist. "
		+ "Returns {output_path, width, height, annotations_drawn} on success.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors). Queries the "
					+ "live in-memory AnnotationHost for that editor — needed when the user's just-drawn "
					+ "annotations haven't been saved to a sidecar yet.",
				},
				"document_path": {
					"type": "string",
					"description": "Absolute path to the document file.",
				},
				"view": {
					"type": "string",
					"description": "view_context string (e.g. 'pcb', 'cad:top'). Annotations whose "
					+ "view_context does not match are excluded.",
				},
				"output_path": {
					"type": "string",
					"description": "Absolute filesystem path where the rendered PNG will be written. "
					+ "Parent directory must exist. If the file already exists, it is silently overwritten.",
				},
				"width": {
					"type": "integer",
					"description": "Output image width in pixels. Default: 1024.",
				},
				"height": {
					"type": "integer",
					"description": "Output image height in pixels. Default: 768.",
				},
				"include_document": {
					"type": "boolean",
					"description": "If true, composite the host's UI render underneath the overlay. "
					+ "Requires a live AnnotationHost with render_content_to_image() (editor_name path). "
					+ "Falls back to transparent background with a warning if not available. Default: false.",
				},
				"include_kinds": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Filter to only these annotation kinds. Empty array = all kinds. Default: [].",
				},
			},
			"required": ["view", "output_path"],
		},
		_TOOL_SET
	)

	server._register_tool(
		"minerva_annotations_query",
		"Query v2 annotations for LLM action flows. Prefer editor_name for live "
		+ "unsaved work; document_path queries the sidecar. Default status filter "
		+ "returns open + applied annotations. Pass capabilities to receive "
		+ "chat_context blocks for non-multimodal and multimodal models.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Live editor tab title."},
				"document_path": {"type": "string", "description": "Document path; sidecar is <path>.annotations.json."},
				"status": {"type": "string", "description": "open, applied, resolved, stale, or any. Omitted = open + applied."},
				"anchor_type": {"type": "string", "description": "Filter like core/text.range or cad/*."},
				"kind": {"type": "string", "description": "Annotation kind filter."},
				"text": {"type": "string", "description": "Case-insensitive text search over summary/payload."},
				"capabilities": {"type": "object", "description": "Capability schema for chat_context projection."},
			},
		},
		_TOOL_SET
	)

	server._register_tool(
		"minerva_annotations_update_status",
		"Transition a v2 annotation lifecycle state. Used by LLM apply flows to "
		+ "mark an open annotation applied with applied.links. Refuses substrate-only "
		+ "stale transitions and illegal lifecycle transitions.",
		{
			"type": "object",
			"properties": {
				"annotation_id": {"type": "string", "description": "Annotation id."},
				"id": {"type": "string", "description": "Alias for annotation_id."},
				"editor_name": {"type": "string", "description": "Optional live editor scope."},
				"document_path": {"type": "string", "description": "Optional sidecar scope."},
				"lifecycle": {"type": "string", "description": "Target lifecycle: applied, resolved, or open."},
				"status": {"type": "string", "description": "Alias for lifecycle."},
				"patch": {"type": "object", "description": "Fields to merge, e.g. applied/resolved objects."},
				"applied": {"type": "object", "description": "Shortcut for patch.applied."},
				"resolved": {"type": "object", "description": "Shortcut for patch.resolved."},
			},
		},
		_TOOL_SET
	)

	server._register_tool(
		"minerva_annotations_repair_anchor",
		"Retarget a v2 annotation anchor. For text editor admin/LLM repair, pass "
		+ "new_anchor={plugin:'core', type:'text.range', id:{start,end}, snapshot:{...}}. "
		+ "If new_anchor is omitted, returns needs_retarget=true unless the anchor registry "
		+ "can repair automatically.",
		{
			"type": "object",
			"properties": {
				"annotation_id": {"type": "string", "description": "Annotation id."},
				"id": {"type": "string", "description": "Alias for annotation_id."},
				"editor_name": {"type": "string", "description": "Optional live editor scope."},
				"document_path": {"type": "string", "description": "Optional sidecar scope."},
				"new_anchor": {"type": "object", "description": "Replacement anchor dictionary."},
			},
		},
		_TOOL_SET
	)

	server._register_tool(
		"minerva_text_editor_add_comment",
		"Add a v2 annotation (kind=text, anchor=core/text.range) to a built-in text "
		+ "editor tab, anchored to a flat character-offset range [start, end). The "
		+ "annotation appears immediately in the live AnnotationHost; persistence to "
		+ "the .annotations.json sidecar happens on the next minerva_save_editor or "
		+ "user Ctrl+S. Use minerva_list_editors first to find editor_name. "
		+ "Returns {ok, annotation_id, count}.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Editor tab title (as returned by minerva_list_editors).",
				},
				"start": {
					"type": "integer",
					"description": "Inclusive start character offset (0-based, flat across newlines).",
				},
				"end": {
					"type": "integer",
					"description": "Exclusive end character offset. Must be >= start.",
				},
				"text": {
					"type": "string",
					"description": "Comment text — becomes annotation.kind_payload.text and summary.",
				},
			},
			"required": ["editor_name", "start", "end", "text"],
		},
		_TOOL_SET
	)


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_annotations_list":
			return _annotations_list(arguments)
		"minerva_annotations_add":
			return _annotations_add(arguments)
		"minerva_annotations_update":
			return _annotations_update(arguments)
		"minerva_annotations_delete":
			return _annotations_delete(arguments)
		"minerva_annotations_render_overlay":
			return await _annotations_render_overlay(arguments)
		"minerva_annotations_query":
			return query(arguments)
		"minerva_annotations_update_status":
			return _handle_update_status(arguments)
		"minerva_annotations_repair_anchor":
			return _handle_repair_anchor(arguments)
		"minerva_text_editor_add_comment":
			return _text_editor_add_comment(arguments)
	return _err("Unknown annotation tool: %s" % tool_name)


# ── minerva_text_editor_add_comment ───────────────────────────────────────────

func _text_editor_add_comment(args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", ""))
	if editor_name.is_empty():
		return _err("'editor_name' is required")
	if not args.has("start") or not args.has("end"):
		return _err("'start' and 'end' are required")
	var start: int = int(args.get("start", -1))
	var end: int = int(args.get("end", -1))
	var text: String = str(args.get("text", ""))
	if start < 0 or end < start:
		return _err("invalid range: start=%d, end=%d (require start >= 0 and end >= start)" % [start, end])

	var host: AnnotationHost = AnnotationHostRegistry.get_host(editor_name)
	if host == null:
		var known: Array = AnnotationHostRegistry.list_editor_names()
		return _err("no annotation host registered for editor '%s'. Known: %s" % [editor_name, str(known)])
	if not host.has_method("add_comment_at"):
		return _err("editor '%s' is not a text editor (host lacks add_comment_at)" % editor_name)

	var ann_id: String = host.call("add_comment_at", start, end, text)
	if ann_id.is_empty():
		return _err("add_comment_at returned empty id (validation failed; check log)")
	var count: int = (host.get_annotations() as Array).size() if host.has_method("get_annotations") else -1
	return {"ok": true, "annotation_id": ann_id, "count": count}


# ── V2 MCP query / lifecycle / repair surface (Round 5c) ─────────────────────

func query(filters: Dictionary = {}) -> Dictionary:
	var source := _resolve_annotation_source(filters, false)
	if not bool(source.get("ok", false)):
		return _err(str(source.get("error", "annotation source not found")))

	var host: AnnotationHost = source.get("host", null) as AnnotationHost
	var registry: AnnotationRegistry = source.get("registry", null) as AnnotationRegistry
	if registry == null and host != null:
		registry = host.get_registry()
	if registry == null:
		registry = _get_registry()

	var projected: Array = []
	var raw_annotations: Array = source.get("annotations", [])
	for ann_v in raw_annotations:
		if not ann_v is Dictionary:
			continue
		var ann: Dictionary = (ann_v as Dictionary).duplicate(true)
		var stale := _compute_stale(ann, host)
		if not _matches_query_filters(ann, filters, stale):
			continue
		projected.append(_project_query_annotation(ann, filters, host, registry, stale))

	var total := projected.size()
	var truncated := total > 100
	if truncated:
		projected = projected.slice(0, 100)
	var result := {
		"success": true,
		"ok": true,
		"source": str(source.get("source", "")),
		"annotations": projected,
		"total": total,
		"count": projected.size(),
		"truncated": truncated,
	}
	if source.has("editor_name"):
		result["editor_name"] = source["editor_name"]
	if source.has("document_path"):
		result["document_path"] = source["document_path"]
	return result


func update_status(annotation_id: String, lifecycle: String, patch: Dictionary = {}) -> Dictionary:
	if annotation_id.strip_edges().is_empty():
		return {"ok": false, "success": false, "error": "annotation_id is required"}
	if lifecycle.strip_edges().is_empty():
		return {"ok": false, "success": false, "error": "lifecycle is required"}

	var source := _resolve_annotation_source(patch, true, annotation_id)
	if not bool(source.get("ok", false)):
		return {"ok": false, "success": false, "error": str(source.get("error", "annotation not found"))}
	var annotation: Dictionary = source.get("annotation", {})
	if annotation.is_empty():
		return {"ok": false, "success": false, "error": "annotation not found: %s" % annotation_id}

	var current := str(annotation.get("lifecycle", "open"))
	if lifecycle == "stale":
		return {"ok": false, "success": false, "error": "stale is substrate-only", "from": current, "to": lifecycle}
	if not AnnotationLifecycle.can_transition(current, lifecycle):
		return {
			"ok": false,
			"success": false,
			"error": "illegal lifecycle transition: %s -> %s" % [current, lifecycle],
			"from": current,
			"to": lifecycle,
		}

	var payload_error := _validate_status_payload(lifecycle, patch)
	if not payload_error.is_empty():
		return {"ok": false, "success": false, "error": payload_error, "from": current, "to": lifecycle}

	for key in patch.keys():
		if key in ["editor_name", "document_path", "annotation_id", "id", "lifecycle", "status"]:
			continue
		annotation[key] = patch[key]
	annotation["lifecycle"] = lifecycle
	annotation["updated_at"] = int(Time.get_unix_time_from_system())

	var update_result := _write_annotation_to_source(source, annotation)
	if not bool(update_result.get("ok", false)):
		return update_result

	var host: AnnotationHost = source.get("host", null) as AnnotationHost
	var registry: AnnotationRegistry = source.get("registry", null) as AnnotationRegistry
	var stale := _compute_stale(annotation, host)
	return {
		"ok": true,
		"success": true,
		"annotation": _project_query_annotation(annotation, {"status": "any"}, host, registry, stale),
	}


func repair_anchor(annotation_id: String, new_anchor: Variant = null, scope: Dictionary = {}) -> Dictionary:
	if annotation_id.strip_edges().is_empty():
		return {"ok": false, "success": false, "error": "annotation_id is required"}
	var source := _resolve_annotation_source(scope, true, annotation_id)
	if not bool(source.get("ok", false)):
		return {"ok": false, "success": false, "error": str(source.get("error", "annotation not found"))}
	var annotation: Dictionary = source.get("annotation", {})
	if annotation.is_empty():
		return {"ok": false, "success": false, "error": "annotation not found: %s" % annotation_id}

	var repaired: Variant = new_anchor
	if repaired == null:
		var host: AnnotationHost = source.get("host", null) as AnnotationHost
		if host != null and host.has_method("get_anchor_registry"):
			var anchor_registry: Variant = host.get_anchor_registry()
			if anchor_registry != null and anchor_registry.has_method("repair"):
				repaired = anchor_registry.repair(annotation.get("anchor", {}), host)
		if repaired == null:
			return {"ok": false, "success": false, "needs_retarget": true}
	if not repaired is Dictionary:
		return {"ok": false, "success": false, "error": "new_anchor must be a Dictionary", "needs_retarget": true}

	annotation["anchor"] = (repaired as Dictionary).duplicate(true)
	annotation["lifecycle"] = "open"
	annotation["updated_at"] = int(Time.get_unix_time_from_system())
	var update_result := _write_annotation_to_source(source, annotation)
	if not bool(update_result.get("ok", false)):
		return update_result
	var host2: AnnotationHost = source.get("host", null) as AnnotationHost
	var registry: AnnotationRegistry = source.get("registry", null) as AnnotationRegistry
	return {
		"ok": true,
		"success": true,
		"annotation": _project_query_annotation(annotation, {"status": "any"}, host2, registry, _compute_stale(annotation, host2)),
	}


func _handle_update_status(args: Dictionary) -> Dictionary:
	var annotation_id := str(args.get("annotation_id", args.get("id", "")))
	var lifecycle := str(args.get("lifecycle", args.get("status", "")))
	var raw_patch: Variant = args.get("patch", {})
	var patch: Dictionary = (raw_patch as Dictionary).duplicate(true) if raw_patch is Dictionary else {}
	for key in ["editor_name", "document_path"]:
		if args.has(key):
			patch[key] = args[key]
	if args.has("applied"):
		patch["applied"] = args["applied"]
	if args.has("resolved"):
		patch["resolved"] = args["resolved"]
	return update_status(annotation_id, lifecycle, patch)


func _handle_repair_anchor(args: Dictionary) -> Dictionary:
	var annotation_id := str(args.get("annotation_id", args.get("id", "")))
	var scope := {}
	for key in ["editor_name", "document_path"]:
		if args.has(key):
			scope[key] = args[key]
	var new_anchor: Variant = args.get("new_anchor", null)
	return repair_anchor(annotation_id, new_anchor, scope)


# ── Tool implementations ──────────────────────────────────────────────────────

func _annotations_list(args: Dictionary) -> Dictionary:
	# Caller must pick exactly one of the two source identifiers.
	# editor_name → live in-memory AnnotationHost (no save required).
	# document_path → on-disk sidecar (authoritative when saved).
	var doc_path: String = str(args.get("document_path", ""))
	var editor_name: String = str(args.get("editor_name", ""))
	if doc_path.is_empty() and editor_name.is_empty():
		return _err("either 'editor_name' or 'document_path' is required")
	if not doc_path.is_empty() and not editor_name.is_empty():
		return _err("provide only one of 'editor_name' or 'document_path', not both")

	# Optional author filter — validate if present.
	var author_filter: String = str(args.get("author", ""))
	if not author_filter.is_empty() and author_filter != AnnotationSchema.AUTHOR_HUMAN and author_filter != AnnotationSchema.AUTHOR_AI:
		return _err("author filter must be 'human' or 'ai', got: %s" % author_filter)

	var registry: AnnotationRegistry = _get_registry()
	var raw_annotations: Array = []
	var source_label: String = ""

	if not editor_name.is_empty():
		var host: AnnotationHost = AnnotationHostRegistry.get_host(editor_name)
		if host == null:
			var known: Array = AnnotationHostRegistry.list_editor_names()
			return _err("no live annotation host registered for editor '%s'. Known: %s"
				% [editor_name, str(known)])
		raw_annotations = host.get_annotations()
		source_label = "live"
		# Live hosts know their own kind registry; prefer it over the fallback
		# so plugin-contributed kinds resolve correctly.
		var host_reg: AnnotationRegistry = host.get_registry()
		if host_reg != null:
			registry = host_reg
	else:
		var sidecar: Dictionary = AnnotationSidecar.read_sidecar(doc_path)
		if sidecar.is_empty():
			# No sidecar = no annotations (not an error; §7.5 zero-annotation rule).
			var empty_filter_value: Variant = null
			if not author_filter.is_empty():
				empty_filter_value = author_filter
			return _ok({
				"source": "sidecar",
				"document_path": doc_path,
				"annotations": [],
				"count": 0,
				"author_filter": empty_filter_value,
			})
		raw_annotations = sidecar.get("annotations", [])
		source_label = "sidecar"

	var result_annotations: Array = []
	for ann in raw_annotations:
		if not ann is Dictionary:
			continue

		# Apply author filter.
		if not author_filter.is_empty() and str(ann.get("author", "")) != author_filter:
			continue

		# Build the enriched entry: start with full annotation (all original fields pass through),
		# then overlay the new computed fields so existing assertions remain unaffected.
		var entry: Dictionary = ann.duplicate(true)
		entry["anchored_to"] = AnnotationSchema.get_anchored_to(ann)

		# v2 envelopes already carry a real `summary` field — preserve it.
		# Only synthesise a placeholder for v1 annotations (which lack one).
		var is_v2 := int(ann.get("schema_version", 1)) >= 2
		var kind_obj: AnnotationKind = null
		if registry != null:
			kind_obj = registry.get_annotation_kind(StringName(str(ann.get("kind", ""))))
		if is_v2 and not str(ann.get("summary", "")).is_empty():
			entry["summary"] = str(ann.get("summary", ""))
		elif kind_obj != null:
			entry["summary"] = kind_obj.summary(ann)
		else:
			var prim_count: int = (ann.get("primitives", []) as Array).size()
			entry["summary"] = "%s (%d primitives)" % [str(ann.get("kind", "")), prim_count]

		# bounds: only include when kind is registered and bounds is non-zero.
		if kind_obj != null:
			var b: Rect2 = kind_obj.bounds(ann)
			entry["bounds"] = {"x": b.position.x, "y": b.position.y, "w": b.size.x, "h": b.size.y}

		result_annotations.append(entry)

	# Bind to a Variant so the ternary's String/null mix doesn't warn
	# INCOMPATIBLE_TERNARY (parser can't infer a single result type otherwise).
	var resp_filter_value: Variant = null
	if not author_filter.is_empty():
		resp_filter_value = author_filter
	var resp: Dictionary = {
		"source": source_label,
		"annotations": result_annotations,
		"count": result_annotations.size(),
		"author_filter": resp_filter_value,
	}
	if source_label == "live":
		resp["editor_name"] = editor_name
	else:
		resp["document_path"] = doc_path
	return _ok(resp)


func _annotations_add(args: Dictionary) -> Dictionary:
	var missing: String = _require_args(args, ["document_path", "annotation"])
	if not missing.is_empty():
		return _err(missing)

	var doc_path: String = args["document_path"]
	var raw_ann: Variant = args.get("annotation", {})
	var annotation: Dictionary = raw_ann if raw_ann is Dictionary else {}

	# Force author=ai for all MCP-originated writes (design §8.1, plan-decision item 5).
	annotation["author"] = AnnotationSchema.AUTHOR_AI

	# Generate id if missing.
	if not annotation.has("id") or (annotation["id"] is String and (annotation["id"] as String).is_empty()):
		annotation["id"] = AnnotationSchema.generate_id()

	# Stamp created_at if missing.
	if not annotation.has("created_at") or (annotation["created_at"] is String and (annotation["created_at"] as String).is_empty()):
		annotation["created_at"] = Time.get_datetime_string_from_system(true) + "Z"

	# Validate annotation kind against live registry BEFORE schema validation
	# (unknown kinds are rejected at MCP layer per design §8.0).
	var kind_str: String = str(annotation.get("kind", ""))
	if kind_str.is_empty():
		return {
			"ok": false,
			"errors": [{"field_path": "kind", "message": "Field 'kind' is required", "code": "required"}],
		}

	# Check if kind is registered — unknown kinds rejected at MCP, preserved on load.
	# When no registry is available (headless test context), kind check is skipped.
	var registry: AnnotationRegistry = _get_registry()
	if registry != null and not registry.has_kind(StringName(kind_str)):
		return {
			"ok": false,
			"errors": [{
				"field_path": "kind",
				"message": (("Annotation kind '%s' is not registered. Register via AnnotationRegistry "
					+ "before adding via MCP. Unknown-kind annotations on disk are preserved verbatim "
					+ "but new MCP writes require a registered kind.") % kind_str),
				"code": "enum",
			}],
		}

	# Schema validation (structural checks on envelope + primitives).
	# primitives_optional depends on the registered kind's flag.
	var primitives_optional: bool = false
	if registry != null:
		var kind_obj: AnnotationKind = registry.get_annotation_kind(StringName(kind_str))
		if kind_obj != null:
			primitives_optional = kind_obj.primitives_optional

	var schema_result: AnnotationSchema.ValidationResult = AnnotationSchema.validate_annotation(annotation, primitives_optional)
	if schema_result.has_errors():
		return {
			"ok": false,
			"errors": schema_result.to_error_dicts(),
		}

	# Kind-specific extra validation via registry.
	if registry != null:
		var kind_errors: Array = registry.dispatch_validate(annotation)
		if kind_errors.size() > 0:
			var error_dicts: Array[Dictionary] = []
			for e in kind_errors:
				if e is AnnotationSchema.ValidationError:
					error_dicts.append(e.to_dict())
				elif e is Dictionary:
					error_dicts.append(e)
				else:
					error_dicts.append({"field_path": "", "message": str(e), "code": "invalid"})
			return {"ok": false, "errors": error_dicts}

	# Read existing sidecar, append, write back.
	var sidecar: Dictionary = _load_or_init_sidecar(doc_path)
	var annotations: Array = sidecar["annotations"]
	annotations.append(annotation)
	sidecar["annotations"] = annotations

	var write_err: Error = AnnotationSidecar.write_sidecar(doc_path, sidecar)
	if write_err != OK:
		return _err("Failed to write sidecar (error %d)" % write_err)

	return _ok({"id": annotation["id"]})


func _annotations_update(args: Dictionary) -> Dictionary:
	var missing: String = _require_args(args, ["document_path", "id", "patch"])
	if not missing.is_empty():
		return _err(missing)

	var doc_path: String = args["document_path"]
	var target_id: String = str(args["id"])
	var raw_patch: Variant = args.get("patch", {})
	var patch: Dictionary = raw_patch if raw_patch is Dictionary else {}

	var sidecar: Dictionary = AnnotationSidecar.read_sidecar(doc_path)
	if sidecar.is_empty():
		return {"ok": false, "error": "not_found"}

	var annotations: Array = sidecar.get("annotations", [])
	var found_idx: int = -1
	for i in annotations.size():
		if annotations[i] is Dictionary and str(annotations[i].get("id", "")) == target_id:
			found_idx = i
			break

	if found_idx < 0:
		return {"ok": false, "error": "not_found"}

	var existing: Dictionary = annotations[found_idx].duplicate(true)

	# Shallow patch: merge provided fields over the top, except author (immutable).
	for key in patch.keys():
		if key == "author":
			# author is immutable post-creation (design §8.1).
			continue
		if key == "id":
			# id is immutable.
			continue
		existing[key] = patch[key]

	# Always bump updated_at.
	existing["updated_at"] = Time.get_datetime_string_from_system(true) + "Z"

	annotations[found_idx] = existing
	sidecar["annotations"] = annotations

	var write_err: Error = AnnotationSidecar.write_sidecar(doc_path, sidecar)
	if write_err != OK:
		return _err("Failed to write sidecar (error %d)" % write_err)

	return _ok({"ok": true})


func _annotations_delete(args: Dictionary) -> Dictionary:
	var missing: String = _require_args(args, ["document_path", "id"])
	if not missing.is_empty():
		return _err(missing)

	var doc_path: String = args["document_path"]
	var target_id: String = str(args["id"])

	var sidecar: Dictionary = AnnotationSidecar.read_sidecar(doc_path)
	if sidecar.is_empty():
		# No sidecar means the id definitely doesn't exist.
		return {"ok": false, "reason": "not_found"}

	var annotations: Array = sidecar.get("annotations", [])
	var found: bool = false
	var new_annotations: Array = []
	for ann in annotations:
		if ann is Dictionary and str(ann.get("id", "")) == target_id:
			found = true
		else:
			new_annotations.append(ann)

	if not found:
		return {"ok": false, "reason": "not_found"}

	sidecar["annotations"] = new_annotations

	# write_sidecar deletes the file when annotations is empty (§7.5 zero-annotation rule).
	var write_err: Error = AnnotationSidecar.write_sidecar(doc_path, sidecar)
	if write_err != OK:
		return _err("Failed to write sidecar (error %d)" % write_err)

	return _ok({"ok": true})


func _annotations_render_overlay(args: Dictionary) -> Dictionary:
	# Require view and output_path; source identifier resolved below.
	var view_missing: String = _require_args(args, ["view"])
	if not view_missing.is_empty():
		return _err(view_missing)

	# Validate output_path before doing any rendering work.
	var output_path: String = str(args.get("output_path", ""))
	if output_path.is_empty():
		return _err("output_path is required")
	if not output_path.is_absolute_path():
		return _err("output_path must be absolute (got: %s)" % output_path)
	var parent_dir: String = output_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent_dir):
		return _err("output_path parent directory does not exist: %s" % parent_dir)

	# Dual-path source resolution — mirrors _annotations_list.
	var doc_path: String = str(args.get("document_path", ""))
	var editor_name: String = str(args.get("editor_name", ""))
	if doc_path.is_empty() and editor_name.is_empty():
		return _err("either 'editor_name' or 'document_path' is required")
	if not doc_path.is_empty() and not editor_name.is_empty():
		return _err("provide only one of 'editor_name' or 'document_path', not both")

	var view: String = str(args.get("view", ""))
	var width: int = _coerce_int(args.get("width", 1024), 1024)
	var height: int = _coerce_int(args.get("height", 768), 768)
	var include_document: bool = _coerce_bool(args.get("include_document", false))
	var include_kinds: Array = []
	if args.has("include_kinds") and args["include_kinds"] is Array:
		include_kinds = args["include_kinds"]

	# Clamp to sane bounds — single-sourced from _MAX_OUTPUT_EDGE.
	width = clampi(width, 1, _MAX_OUTPUT_EDGE)
	height = clampi(height, 1, _MAX_OUTPUT_EDGE)

	# Resolve annotations and optional background image based on source path.
	var all_annotations: Array = []
	var bg_image: Image = null  # null = transparent background
	# Scale factor applied to bg_image (and therefore to annotation bounds).
	# Stays 1.0 when no downsampling is needed.
	var overlay_scale: float = 1.0

	if not editor_name.is_empty():
		# Live path: query the registered AnnotationHost directly.
		var host: AnnotationHost = AnnotationHostRegistry.get_host(editor_name)
		if host == null:
			var known: Array = AnnotationHostRegistry.list_editor_names()
			return _err("no live annotation host registered for editor '%s'. Known: %s"
				% [editor_name, str(known)])
		all_annotations = host.get_annotations()

		if include_document:
			# Ask the host to render its UI content. Returns null in headless / when
			# _ui_root is not wired — we fall back to transparent gracefully.
			var viewport_rect := Rect2()  # TODO: derive from host or args in a future version
			var rendered: Image = host.render_content_to_image(viewport_rect)
			if rendered == null:
				push_warning(
					("[MCPAnnotationTools] render_overlay: editor '%s' returned null from "
					+ "render_content_to_image(). Falling back to transparent background.")
					% editor_name
				)
				# bg_image stays null → transparent
			else:
				bg_image = rendered
				# Downsample if the captured image exceeds the output edge cap.
				var max_edge: int = maxi(bg_image.get_width(), bg_image.get_height())
				if max_edge > _MAX_OUTPUT_EDGE:
					overlay_scale = _MAX_OUTPUT_EDGE / float(max_edge)
					var new_w: int = int(bg_image.get_width() * overlay_scale)
					var new_h: int = int(bg_image.get_height() * overlay_scale)
					bg_image.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)
				# Match the output size to the (possibly resized) panel image.
				width = bg_image.get_width()
				height = bg_image.get_height()
	else:
		# Sidecar path: existing behavior — read from disk; no document underlay.
		var sidecar: Dictionary = AnnotationSidecar.read_sidecar(doc_path)
		if not sidecar.is_empty():
			all_annotations = sidecar.get("annotations", [])

		if include_document:
			# Sidecar path has no live renderer yet; warn and fall back.
			push_warning(
				"[MCPAnnotationTools] render_overlay: include_document=true requested for "
				+ "document_path path — no live renderer available for sidecar-only documents. "
				+ "Returning overlay-only PNG."
			)

	# Filter by view_context and include_kinds.
	var filtered: Array = []
	for ann in all_annotations:
		if not ann is Dictionary:
			continue
		if str(ann.get("view_context", "")) != view:
			continue
		if include_kinds.size() > 0:
			if not (ann.get("kind", "") in include_kinds):
				continue
		filtered.append(ann)

	# Create an RGBA image for the overlay (or composite onto the bg image).
	var img: Image
	if bg_image != null:
		# Start from the captured panel image so it forms the background.
		img = bg_image.duplicate()
	else:
		img = Image.create(width, height, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))  # transparent

	# Render each annotation via its kind's render() virtual.
	# Falls back to the placeholder fill for annotations whose kind is not
	# registered (unknown kinds: design §10).
	var registry: AnnotationRegistry = _get_registry()
	for ann in filtered:
		var kind_name: StringName = StringName(str(ann.get("kind", "")))
		var kind: AnnotationKind = null
		if registry != null:
			kind = registry.get_annotation_kind(kind_name)
		if kind != null:
			await _render_annotation_via_kind(img, ann, kind, overlay_scale)
		else:
			_render_annotation_placeholder(img, ann, registry, overlay_scale)

	# Write PNG to the caller-supplied path.
	var save_err: Error = img.save_png(output_path)
	if save_err != OK:
		return _err("failed to write PNG to %s: %d" % [output_path, save_err])

	return _ok({
		"output_path": output_path,
		"width": img.get_width(),
		"height": img.get_height(),
		"annotations_drawn": filtered.size(),
	})


# ── Internal helpers ──────────────────────────────────────────────────────────

func _resolve_annotation_source(filters: Dictionary, require_annotation: bool, annotation_id: String = "") -> Dictionary:
	var doc_path := str(filters.get("document_path", ""))
	var editor_name := str(filters.get("editor_name", ""))
	if not doc_path.is_empty() and not editor_name.is_empty():
		return {"ok": false, "error": "provide only one of 'editor_name' or 'document_path', not both"}

	if not editor_name.is_empty():
		var host: AnnotationHost = AnnotationHostRegistry.get_host(editor_name)
		if host == null:
			var known: Array = AnnotationHostRegistry.list_editor_names()
			return {
				"ok": false,
				"error": "no live annotation host registered for editor '%s'. Known: %s" % [editor_name, str(known)],
			}
		return _source_from_host(editor_name, host, require_annotation, annotation_id)

	if not doc_path.is_empty():
		var sidecar: Dictionary = AnnotationSidecar.read_sidecar(doc_path)
		var annotations: Array = sidecar.get("annotations", []) if not sidecar.is_empty() else []
		var source := {
			"ok": true,
			"source": "sidecar",
			"document_path": doc_path,
			"sidecar": sidecar,
			"annotations": annotations,
			"registry": _get_registry(),
		}
		return _attach_source_annotation(source, require_annotation, annotation_id)

	if require_annotation:
		return _resolve_annotation_by_id(annotation_id)

	return {"ok": false, "error": "either 'editor_name' or 'document_path' is required"}


func _source_from_host(editor_name: String, host: AnnotationHost, require_annotation: bool, annotation_id: String = "") -> Dictionary:
	var annotations: Array = host.get_annotations() if host.has_method("get_annotations") else []
	var source := {
		"ok": true,
		"source": "live",
		"editor_name": editor_name,
		"host": host,
		"annotations": annotations,
		"registry": host.get_registry() if host.has_method("get_registry") else _get_registry(),
	}
	return _attach_source_annotation(source, require_annotation, annotation_id)


func _resolve_annotation_by_id(annotation_id: String) -> Dictionary:
	var matches: Array = []
	for editor_name in AnnotationHostRegistry.list_editor_names():
		var host: AnnotationHost = AnnotationHostRegistry.get_host(str(editor_name))
		if host == null:
			continue
		var source := _source_from_host(str(editor_name), host, true, annotation_id)
		if bool(source.get("ok", false)):
			matches.append(source)
	if matches.size() == 1:
		return matches[0]
	if matches.size() > 1:
		var names: Array = []
		for source in matches:
			names.append(str(source.get("editor_name", "")))
		return {"ok": false, "error": "annotation id '%s' is ambiguous across live editors: %s" % [annotation_id, str(names)]}
	return {"ok": false, "error": "annotation not found: %s; provide editor_name or document_path for saved sidecar annotations" % annotation_id}


func _attach_source_annotation(source: Dictionary, require_annotation: bool, annotation_id: String) -> Dictionary:
	if not require_annotation:
		return source
	if annotation_id.strip_edges().is_empty():
		return {"ok": false, "error": "annotation_id is required"}
	var annotations: Array = source.get("annotations", [])
	for i in range(annotations.size()):
		var ann_v: Variant = annotations[i]
		if ann_v is Dictionary and str((ann_v as Dictionary).get("id", "")) == annotation_id:
			source["annotation"] = (ann_v as Dictionary).duplicate(true)
			source["index"] = i
			return source
	return {"ok": false, "error": "annotation not found: %s" % annotation_id}


func _compute_stale(annotation: Dictionary, host: AnnotationHost) -> bool:
	var stale := str(annotation.get("lifecycle", "")) == AnnotationLifecycle.STATE_STALE or bool(annotation.get("stale", false))
	if host != null and annotation.get("anchor", {}) is Dictionary:
		var resolved: Variant = host.resolve_anchor(annotation.get("anchor", {}))
		if resolved is Dictionary:
			stale = stale or bool((resolved as Dictionary).get("stale", false))
	return stale


func _matches_query_filters(annotation: Dictionary, filters: Dictionary, stale: bool) -> bool:
	var lifecycle := str(annotation.get("lifecycle", ""))
	var status := str(filters.get("status", ""))
	if status.is_empty():
		if not lifecycle in _DEFAULT_QUERY_STATUSES:
			return false
	elif status == "stale":
		if not stale:
			return false
	elif status != "any" and lifecycle != status:
		return false

	if filters.has("anchor_type") and not _anchor_type_matches(annotation, str(filters["anchor_type"])):
		return false
	if filters.has("kind") and str(annotation.get("kind", "")) != str(filters["kind"]):
		return false
	if filters.has("author") and _author_kind(annotation) != str(filters["author"]):
		return false
	if filters.has("author_kind") and _author_kind(annotation) != str(filters["author_kind"]):
		return false
	if filters.has("author_id") and _author_id(annotation) != str(filters["author_id"]):
		return false
	if filters.has("text"):
		var needle := str(filters["text"]).to_lower()
		var haystack := "%s %s" % [str(annotation.get("summary", "")), str(annotation.get("kind_payload", {}))]
		if not haystack.to_lower().contains(needle):
			return false

	var time_range: Variant = filters.get("time_range", {})
	if time_range is Dictionary:
		var range_dict: Dictionary = time_range
		if range_dict.has("after") and str(annotation.get("created_at", "")) <= str(range_dict["after"]):
			return false
		if range_dict.has("before") and str(annotation.get("created_at", "")) >= str(range_dict["before"]):
			return false
	return true


func _anchor_type_matches(annotation: Dictionary, expected: String) -> bool:
	var anchor: Dictionary = annotation.get("anchor", {}) if annotation.get("anchor", {}) is Dictionary else {}
	var actual := "%s/%s" % [str(anchor.get("plugin", "")), str(anchor.get("type", ""))]
	if expected.ends_with("/*"):
		return actual.begins_with(expected.substr(0, expected.length() - 1))
	return actual == expected


func _author_kind(annotation: Dictionary) -> String:
	var author: Variant = annotation.get("author", "")
	if author is Dictionary:
		return str((author as Dictionary).get("kind", ""))
	return str(author)


func _author_id(annotation: Dictionary) -> String:
	var author: Variant = annotation.get("author", {})
	if author is Dictionary:
		return str((author as Dictionary).get("id", ""))
	return ""


func _project_query_annotation(
	annotation: Dictionary,
	filters: Dictionary,
	host: AnnotationHost,
	registry: AnnotationRegistry,
	stale: bool
) -> Dictionary:
	var entry := annotation.duplicate(true)
	entry["stale"] = stale
	if stale and str(entry.get("lifecycle", "")) != AnnotationLifecycle.STATE_STALE:
		entry["lifecycle_effective"] = AnnotationLifecycle.STATE_STALE
	entry["anchored_to"] = AnnotationSchema.get_anchored_to(entry)

	var kind_obj: AnnotationKind = null
	if registry != null:
		kind_obj = registry.get_annotation_kind(StringName(str(entry.get("kind", ""))))
	if str(entry.get("summary", "")).is_empty():
		if kind_obj != null:
			entry["summary"] = kind_obj.summary(entry)
		else:
			entry["summary"] = str(entry.get("kind", "annotation"))
	if kind_obj != null:
		var bounds: Rect2 = kind_obj.bounds(entry)
		entry["bounds"] = {"x": bounds.position.x, "y": bounds.position.y, "w": bounds.size.x, "h": bounds.size.y}

	if host != null and entry.get("anchor", {}) is Dictionary:
		var resolved: Variant = host.resolve_anchor(entry.get("anchor", {}))
		if resolved is Dictionary:
			entry["resolved_anchor"] = _serialize_resolved_anchor(resolved as Dictionary)

	if filters.has("capabilities"):
		if kind_obj != null:
			entry["chat_context"] = kind_obj.to_chat_context(entry, filters.get("capabilities", {}))
		else:
			entry["chat_context"] = AnnotationKind.new().to_chat_context(entry, filters.get("capabilities", {}))
	return entry


func _serialize_resolved_anchor(resolved: Dictionary) -> Dictionary:
	var result := {"stale": bool(resolved.get("stale", false))}
	var pos: Variant = resolved.get("position", null)
	if pos is Vector2:
		result["position"] = [(pos as Vector2).x, (pos as Vector2).y]
	var bounds: Variant = resolved.get("bounds", null)
	if bounds is Rect2:
		var rect: Rect2 = bounds
		result["bounds"] = {"x": rect.position.x, "y": rect.position.y, "w": rect.size.x, "h": rect.size.y}
	var metadata: Variant = resolved.get("view_metadata", {})
	if metadata is Dictionary:
		result["view_metadata"] = metadata
	return result


func _validate_status_payload(lifecycle: String, patch: Dictionary) -> String:
	if lifecycle == AnnotationLifecycle.STATE_APPLIED:
		if not patch.has("applied") or not patch["applied"] is Dictionary:
			return "applied object is required"
		var applied: Dictionary = patch["applied"]
		if not applied.has("links") or not applied["links"] is Array:
			return "applied.links is required"
	if lifecycle == AnnotationLifecycle.STATE_RESOLVED:
		if not patch.has("resolved") or not patch["resolved"] is Dictionary:
			return "resolved object is required"
		var resolved: Dictionary = patch["resolved"]
		if not resolved.has("by") or not resolved["by"] is Dictionary:
			return "resolved.by is required"
	return ""


func _write_annotation_to_source(source: Dictionary, annotation: Dictionary) -> Dictionary:
	var annotation_id := str(annotation.get("id", ""))
	if annotation_id.is_empty():
		return {"ok": false, "success": false, "error": "annotation id is required"}
	if str(source.get("source", "")) == "live":
		var host: AnnotationHost = source.get("host", null) as AnnotationHost
		if host == null:
			return {"ok": false, "success": false, "error": "live annotation host is unavailable"}
		if not host.update_annotation(annotation_id, annotation):
			return {"ok": false, "success": false, "error": "annotation not found: %s" % annotation_id}
		return {"ok": true, "success": true}

	var doc_path := str(source.get("document_path", ""))
	if doc_path.is_empty():
		return {"ok": false, "success": false, "error": "document_path is required for sidecar update"}
	var sidecar: Dictionary = source.get("sidecar", {})
	if sidecar.is_empty():
		return {"ok": false, "success": false, "error": "annotation sidecar not found for %s" % doc_path}
	var annotations: Array = sidecar.get("annotations", [])
	var idx := int(source.get("index", -1))
	if idx < 0 or idx >= annotations.size():
		idx = -1
		for i in range(annotations.size()):
			if annotations[i] is Dictionary and str(annotations[i].get("id", "")) == annotation_id:
				idx = i
				break
	if idx < 0:
		return {"ok": false, "success": false, "error": "annotation not found: %s" % annotation_id}
	annotations[idx] = annotation
	sidecar["annotations"] = annotations
	var write_err: Error = AnnotationSidecar.write_sidecar(doc_path, sidecar)
	if write_err != OK:
		return {"ok": false, "success": false, "error": "failed to write sidecar (error %d)" % write_err}
	return {"ok": true, "success": true}

## Minimal success response builder (mirrors MCPToolUtils.success).
static func _ok(data: Dictionary = {}) -> Dictionary:
	var result: Dictionary = {"success": true}
	result.merge(data)
	return result


## Minimal error response builder (mirrors MCPToolUtils.error).
static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}


## Validate that required keys are present and non-empty in args.
## Returns empty string on success, or an error message on the first missing key.
static func _require_args(args: Dictionary, keys: Array) -> String:
	for key in keys:
		if not args.has(key) or (args[key] is String and (args[key] as String).is_empty()):
			return "%s is required" % key
	return ""


## Coerce a value to int with a fallback default.
static func _coerce_int(value: Variant, default_val: int = 0) -> int:
	if value == null:
		return default_val
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String and (value as String).is_valid_int():
		return (value as String).to_int()
	return default_val


## Coerce a value to bool with a fallback default.
static func _coerce_bool(value: Variant, default_val: bool = false) -> bool:
	if value == null:
		return default_val
	if value is bool:
		return value
	if value is String:
		return (value as String).to_lower() == "true"
	if value is int or value is float:
		return value != 0
	return default_val


## Cached fallback registry, lazily built from BuiltinKinds. Used when no
## global registry is available — gives live MCP calls (and headless tests
## that opt in via _use_fallback_registry) summary/bounds for built-in kinds
## even without an autoloaded host registry.
static var _fallback_registry: AnnotationRegistry = null

## Set by tests that want to skip the BuiltinKinds fallback (preserves the
## "kind unknown → bounds omitted" headless behavior). Live runs leave this
## false so MCP callers get summaries and bounds for built-in kinds.
static var _disable_fallback_registry: bool = false


## Returns an AnnotationRegistry — either a global one if any plugin
## registered it, or a lazy built-in fallback that knows the eight 2D kinds.
##
## Resolution order:
##   1. Engine singleton named "AnnotationRegistry" (if any plugin registers one)
##   2. Engine singleton named "MinervaAnnotationRegistry"
##   3. The SingletonObject autoload (via /root/SingletonObject) if it exposes
##      `annotation_registry`. Engine.has_singleton() does NOT return true for
##      GDScript autoloads — we use the tree path instead.
##   4. The lazy BuiltinKinds fallback (gives summaries + bounds for the eight
##      built-in 2D kinds even without a host registry).
##
## When `_disable_fallback_registry` is true (test-only), step 4 is skipped
## and null is returned, preserving the legacy "kind unknown" behavior.
func _get_registry() -> AnnotationRegistry:
	if Engine.has_singleton("AnnotationRegistry"):
		return Engine.get_singleton("AnnotationRegistry") as AnnotationRegistry
	if Engine.has_singleton("MinervaAnnotationRegistry"):
		return Engine.get_singleton("MinervaAnnotationRegistry") as AnnotationRegistry

	# GDScript autoload via tree path. Engine.has_singleton() doesn't see these.
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		var so := tree.root.get_node_or_null("SingletonObject")
		if so != null and so.get("annotation_registry") is AnnotationRegistry:
			return so.annotation_registry as AnnotationRegistry

	if _disable_fallback_registry:
		return null

	# Lazy BuiltinKinds fallback.
	if _fallback_registry == null:
		_fallback_registry = AnnotationRegistry.new()
		BuiltinKinds.register_all(_fallback_registry)
	return _fallback_registry


## Build the base sidecar dict for a document that has no sidecar yet.
func _load_or_init_sidecar(doc_path: String) -> Dictionary:
	var existing: Dictionary = AnnotationSidecar.read_sidecar(doc_path)
	if not existing.is_empty():
		return existing
	# Initialize a fresh sidecar envelope.
	return {
		"substrate_version": AnnotationSidecar.SUBSTRATE_VERSION,
		"document": {
			"path": doc_path.get_file(),
			"kind": doc_path.get_extension(),
		},
		"annotations": [],
		"unknown_kinds": [],
	}


## Render a single annotation via its kind's render() virtual into img.
##
## Builds an _ImageRenderContext whose draw helpers rasterize directly to img
## using pure-software pixel operations — no GPU, no SceneTree, no CanvasItem RID
## required. Works correctly in both headless test contexts and live usage.
##
## scale_factor: passed to the render context's transform so all coordinates are
## scaled to match a downsampled bg_image. At 1.0 (no downsampling), annotation
## coordinates map 1:1 to image pixels.
func _render_annotation_via_kind(
	img: Image,
	ann: Dictionary,
	kind: AnnotationKind,
	scale_factor: float = 1.0
) -> void:
	var ctx := _ImageRenderContext.new(img, scale_factor)
	kind.render(ctx, ann)
	# Text primitives are queued (Image has no font rasterizer); rasterize them
	# via an offscreen SubViewport + Label and blend into img. Async because we
	# wait for RenderingServer.frame_post_draw between Label submission and
	# texture capture.
	await ctx._flush_text_queue()


## Render a single annotation as a placeholder rectangle on the image.
## Used as a fallback when kind == null (unknown / unregistered kind).
##
## scale_factor: multiply annotation bounds by this before drawing. Pass < 1.0 when
## bg_image was downsampled so annotations stay aligned with the smaller image.
func _render_annotation_placeholder(
	img: Image,
	ann: Dictionary,
	registry: AnnotationRegistry,  # may be null
	scale_factor: float = 1.0
) -> void:
	var prims: Variant = ann.get("primitives", [])
	var bounds: Rect2
	if registry != null:
		bounds = registry.dispatch_bounds(ann)
	elif prims is Array:
		bounds = AnnotationKind.bounds_from_primitives(prims)
	else:
		return

	if bounds.size == Vector2.ZERO:
		return

	# Scale annotation bounds to match a downsampled bg_image.
	if scale_factor != 1.0:
		bounds = Rect2(bounds.position * scale_factor, bounds.size * scale_factor)

	# Choose fill color based on author (design §5 author colors).
	var author: String = str(ann.get("author", "ai"))
	var fill_color: Color
	if author == AnnotationSchema.AUTHOR_HUMAN:
		fill_color = Color(1.0, 0.0, 1.0, 0.3)  # light magenta, semi-transparent
	else:
		fill_color = Color(0.0, 1.0, 1.0, 0.3)  # cyan, semi-transparent

	# Convert bounds to image pixels (bounds are in view coords; we map them
	# directly at 1:1 for the headless stub — full coordinate transform requires
	# a live AnnotationRenderContext with editor zoom/transform).
	var ix0: int = clampi(int(bounds.position.x), 0, img.get_width() - 1)
	var iy0: int = clampi(int(bounds.position.y), 0, img.get_height() - 1)
	var ix1: int = clampi(int(bounds.position.x + bounds.size.x), 0, img.get_width())
	var iy1: int = clampi(int(bounds.position.y + bounds.size.y), 0, img.get_height())

	# Single native call — avoids the GDScript per-pixel loop overhead.
	img.fill_rect(Rect2i(ix0, iy0, ix1 - ix0, iy1 - iy0), fill_color)


# ── _ImageRenderContext ───────────────────────────────────────────────────────
## Software-rasterizing render context that writes directly to an Image.
##
## Overrides all draw helpers from AnnotationRenderContext. No GPU, no
## CanvasItem RID, no SceneTree required — usable in headless Godot.
##
## Coordinate model: annotation primitives are in view/document space.
## The context applies `scale_factor` as a uniform scale so that annotations
## drawn on top of a downsampled bg_image land at the correct pixel positions.
## At scale_factor=1.0, document coordinates map 1:1 to image pixels.
##
## Line width: Bresenham lines are 1px. Widths > 1 are approximated by
## drawing parallel offset lines (integer rounding keeps it fast).
##
## Text: GDScript's Image class has no font rasterizer, so draw_string /
## draw_string_rotated cannot rasterize directly. They enqueue (pos, text,
## color, size, rotation) tuples; the orchestrator flushes the queue after
## kind.render() returns by spinning up a transient SubViewport + Label per
## text entry, awaiting frame_post_draw, capturing the viewport texture, and
## blending into the target Image at the screen-space text anchor. See
## _flush_text_queue(). The live (canvas_item) render path in
## AnnotationRenderContext.draw_string uses Font.draw_string and produces the
## same visual; this path matches that pixel-for-pixel within rounding.
class _ImageRenderContext extends AnnotationRenderContext:
	var _img: Image
	## Deferred text draws: each entry is
	## { "pos": Vector2 (screen-space), "text": String, "color": Color,
	##   "size": int, "rotation": float (radians) }.
	## Populated by draw_string / draw_string_rotated, flushed by
	## _flush_text_queue() after the kind's synchronous render() returns.
	var _text_queue: Array = []

	func _init(img: Image, scale_factor: float = 1.0) -> void:
		_img        = img
		zoom        = scale_factor
		# Build a scale-only Transform2D so to_screen() applies scale_factor.
		# origin stays at (0,0) — annotation coords and image pixels share an origin.
		transform   = Transform2D(0.0, Vector2(scale_factor, scale_factor), 0.0, Vector2.ZERO)
		viewport_rect = Rect2(Vector2.ZERO, Vector2(img.get_width(), img.get_height()))

	# ── Draw helpers ─────────────────────────────────────────────────────────

	func draw_line(a: Vector2, b: Vector2, color: Color, width: float = 1.0) -> void:
		var sa := to_screen(a)
		var sb := to_screen(b)
		var passes: int = maxi(1, int(roundi(width)))
		for w in passes:
			_bresenham_line(sa, sb, color)
			# Offset perpendicular for wider strokes.
			if w + 1 < passes:
				var dir := (sb - sa).normalized()
				var perp := Vector2(-dir.y, dir.x)
				sa += perp
				sb += perp


	func draw_polyline(points: PackedVector2Array, color: Color, width: float = 1.0) -> void:
		for i in range(points.size() - 1):
			draw_line(points[i], points[i + 1], color, width)


	func draw_polygon(points: PackedVector2Array, colors: PackedColorArray) -> void:
		if points.size() < 3:
			return
		# Pick the first (or only) color. Polygon fills are typically uniform.
		var color: Color = colors[0] if colors.size() > 0 else Color.WHITE
		# Screen-transform all points.
		var screen_pts: PackedVector2Array = PackedVector2Array()
		screen_pts.resize(points.size())
		for i in points.size():
			screen_pts[i] = to_screen(points[i])
		# For triangle fans (arrowheads): rasterize each triangle as a filled
		# scan-line band. General polygons: fan from vertex 0.
		for i in range(1, screen_pts.size() - 1):
			_fill_triangle(screen_pts[0], screen_pts[i], screen_pts[i + 1], color)
		# Always draw the outline so even degenerate fills are visible.
		for i in screen_pts.size():
			var next: int = (i + 1) % screen_pts.size()
			_bresenham_line(screen_pts[i], screen_pts[next], color)


	## Enqueues a text draw to be rasterized after the synchronous kind.render()
	## pass. The actual GPU work happens in _flush_text_queue(), which awaits
	## RenderingServer.frame_post_draw — incompatible with the synchronous
	## kind.render() callback. `pos` is in document space; we convert to screen
	## space (which is image-pixel space for this context) once, here.
	func draw_string(
		_font: Font,
		pos: Vector2,
		text: String,
		color: Color,
		size: int = 16
	) -> void:
		if text.is_empty():
			return
		_text_queue.append({
			"pos": to_screen(pos),
			"text": text,
			"color": color,
			"size": size,
			"rotation": 0.0,
		})


	func draw_string_rotated(
		_font: Font,
		pos: Vector2,
		text: String,
		color: Color,
		size: int = 16,
		rotation_rad: float = 0.0
	) -> void:
		if text.is_empty():
			return
		_text_queue.append({
			"pos": to_screen(pos),
			"text": text,
			"color": color,
			"size": size,
			"rotation": rotation_rad,
		})


	## Drains _text_queue: for each pending text draw, render to an offscreen
	## SubViewport+Label, await one frame, capture, blend into _img.
	## Idempotent — safe to call when queue is empty.
	## Requires a live SceneTree (Engine.get_main_loop() must be a SceneTree).
	## In a true headless context with no SceneTree, falls back to a tiny
	## colored marker so the region still reads as non-empty.
	func _flush_text_queue() -> void:
		if _text_queue.is_empty():
			return
		var tree := Engine.get_main_loop() as SceneTree
		if tree == null or tree.root == null:
			# No SceneTree → can't host a SubViewport. Draw a 4×4 marker per
			# entry so the region is non-empty for diversity tests, then bail.
			for entry in _text_queue:
				var sp: Vector2 = entry["pos"]
				var col: Color = entry["color"]
				var x: int = clampi(int(sp.x), 0, _img.get_width() - 1)
				var y: int = clampi(int(sp.y), 0, _img.get_height() - 1)
				_img.fill_rect(Rect2i(x, y, mini(4, _img.get_width() - x), mini(4, _img.get_height() - y)), col)
			_text_queue.clear()
			return

		var font: Font = ThemeDB.fallback_font
		for entry in _text_queue:
			var text: String = entry["text"]
			var size: int = entry["size"]
			var color: Color = entry["color"]
			var sp: Vector2 = entry["pos"]
			var rotation: float = entry["rotation"]

			# Measure the text so the SubViewport is just large enough.
			# Add a small margin so descenders and AA edges aren't clipped.
			var measured: Vector2 = Vector2(text.length() * size, size * 1.5)
			if font != null:
				measured = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
			var pad: int = maxi(2, int(size * 0.3))
			var vp_w: int = maxi(4, int(ceil(measured.x)) + pad * 2)
			var vp_h: int = maxi(4, int(ceil(measured.y)) + pad * 2)

			var viewport := SubViewport.new()
			viewport.size = Vector2i(vp_w, vp_h)
			viewport.transparent_bg = true
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			viewport.disable_3d = true
			viewport.gui_disable_input = true

			var label := Label.new()
			label.text = text
			label.add_theme_color_override("font_color", color)
			label.add_theme_font_size_override("font_size", size)
			if font != null:
				label.add_theme_font_override("font", font)
			# Position the label so glyphs don't touch the viewport edge.
			label.position = Vector2(pad, pad)
			label.size = Vector2(vp_w - pad * 2, vp_h - pad * 2)

			viewport.add_child(label)
			tree.root.add_child(viewport)

			# Wait for the SubViewport to actually render this frame.
			await RenderingServer.frame_post_draw

			var rendered: Image = viewport.get_texture().get_image()

			# Blend the rendered text onto _img. Anchor is the baseline-ish
			# bottom-left in canvas-item draw_string semantics; SubViewport
			# renders the Label's top-left at (pad, pad). We compensate by
			# placing the viewport's text-bottom at sp.y, so the destination
			# top-left is sp.y - measured.y - pad.
			# rotation_rad is intentionally ignored (matches the prior
			# draw_string_rotated behaviour, which also drew axis-aligned).
			# Per-pixel rotation here would need a CPU-side resample and is
			# unnecessary for the label-style text annotation kinds emit.
			var _r := rotation
			var dst_x: int = int(sp.x) - pad
			var dst_y: int = int(sp.y) - int(ceil(measured.y)) - pad

			if rendered != null:
				_blend_image_clipped(rendered, dst_x, dst_y)

			# Clean up immediately to avoid leaks / orphan-node warnings.
			viewport.remove_child(label)
			label.queue_free()
			tree.root.remove_child(viewport)
			viewport.queue_free()
		_text_queue.clear()


	## Blends `src` onto _img at (dst_x, dst_y), clipping to _img bounds.
	## Uses Image.blend_rect so existing pixels compose with the text alpha.
	func _blend_image_clipped(src: Image, dst_x: int, dst_y: int) -> void:
		var src_w: int = src.get_width()
		var src_h: int = src.get_height()
		var img_w: int = _img.get_width()
		var img_h: int = _img.get_height()

		# Compute source rect after clipping the destination to _img bounds.
		var src_x0: int = 0
		var src_y0: int = 0
		var copy_w: int = src_w
		var copy_h: int = src_h
		if dst_x < 0:
			src_x0 = -dst_x
			copy_w -= src_x0
			dst_x = 0
		if dst_y < 0:
			src_y0 = -dst_y
			copy_h -= src_y0
			dst_y = 0
		if dst_x + copy_w > img_w:
			copy_w = img_w - dst_x
		if dst_y + copy_h > img_h:
			copy_h = img_h - dst_y
		if copy_w <= 0 or copy_h <= 0:
			return
		# Image.blend_rect requires matching formats.
		if src.get_format() != _img.get_format():
			src.convert(_img.get_format())
		_img.blend_rect(src, Rect2i(src_x0, src_y0, copy_w, copy_h), Vector2i(dst_x, dst_y))


	func draw_rect(rect: Rect2, color: Color, filled: bool, width: float = 1.0) -> void:
		var tl := to_screen(rect.position)
		var br := to_screen(rect.position + rect.size)
		if filled:
			var x0: int = clampi(int(tl.x), 0, _img.get_width() - 1)
			var y0: int = clampi(int(tl.y), 0, _img.get_height() - 1)
			var x1: int = clampi(int(br.x), 0, _img.get_width())
			var y1: int = clampi(int(br.y), 0, _img.get_height())
			_img.fill_rect(Rect2i(x0, y0, x1 - x0, y1 - y0), color)
		else:
			# _corner suffix because plain `tr` shadows Object.tr translation method.
			var tr_corner := to_screen(Vector2(rect.position.x + rect.size.x, rect.position.y))
			var bl_corner := to_screen(Vector2(rect.position.x, rect.position.y + rect.size.y))
			draw_line(tl, tr_corner, color, width)
			draw_line(tr_corner, br, color, width)
			draw_line(br, bl_corner, color, width)
			draw_line(bl_corner, tl, color, width)


	# to_screen / from_screen are inherited from AnnotationRenderContext and
	# use the Transform2D we set in _init — no override needed.

	# ── Software rasterization helpers ───────────────────────────────────────

	## Bresenham integer line-draw — writes one pixel per step.
	## Clips to image bounds per pixel so no out-of-range writes occur.
	func _bresenham_line(a: Vector2, b: Vector2, color: Color) -> void:
		var x0: int = roundi(a.x)
		var y0: int = roundi(a.y)
		var x1: int = roundi(b.x)
		var y1: int = roundi(b.y)
		var dx: int = absi(x1 - x0)
		var dy: int = absi(y1 - y0)
		var sx: int = 1 if x0 < x1 else -1
		var sy: int = 1 if y0 < y1 else -1
		var err: int = dx - dy
		var w: int = _img.get_width()
		var h: int = _img.get_height()
		while true:
			if x0 >= 0 and x0 < w and y0 >= 0 and y0 < h:
				_img.set_pixel(x0, y0, color)
			if x0 == x1 and y0 == y1:
				break
			var e2: int = err * 2
			if e2 > -dy:
				err -= dy
				x0  += sx
			if e2 < dx:
				err += dx
				y0  += sy


	## Scan-line fill for a single triangle (no clipping — we set_pixel only
	## when in-bounds). Vertices are already in image/screen space.
	func _fill_triangle(v0: Vector2, v1: Vector2, v2: Vector2, color: Color) -> void:
		# Sort vertices by y.
		var pts: Array = [v0, v1, v2]
		pts.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y < b.y)
		var pa: Vector2 = pts[0]
		var pb: Vector2 = pts[1]
		var pc: Vector2 = pts[2]

		var img_w: int = _img.get_width()
		var img_h: int = _img.get_height()

		var y_start: int = clampi(roundi(pa.y), 0, img_h - 1)
		var y_end:   int = clampi(roundi(pc.y), 0, img_h - 1)

		for y in range(y_start, y_end + 1):
			# Compute x range for this scanline using edge intersections.
			var t_ac: float = 0.0
			if pc.y - pa.y > 0.0001:
				t_ac = (y - pa.y) / (pc.y - pa.y)
			var x_ac: float = pa.x + t_ac * (pc.x - pa.x)

			var x_other: float
			if y <= pb.y:
				var t_ab: float = 0.0
				if pb.y - pa.y > 0.0001:
					t_ab = (y - pa.y) / (pb.y - pa.y)
				x_other = pa.x + t_ab * (pb.x - pa.x)
			else:
				var t_bc: float = 0.0
				if pc.y - pb.y > 0.0001:
					t_bc = (y - pb.y) / (pc.y - pb.y)
				x_other = pb.x + t_bc * (pc.x - pb.x)

			var x_left:  int = clampi(roundi(minf(x_ac, x_other)), 0, img_w - 1)
			var x_right: int = clampi(roundi(maxf(x_ac, x_other)), 0, img_w - 1)
			for x in range(x_left, x_right + 1):
				_img.set_pixel(x, y, color)
