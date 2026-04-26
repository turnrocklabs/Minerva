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
##
## Intentionally extends RefCounted (not MCPToolModule) to avoid a transitive
## compile-time dependency on MCPToolUtils, which references the SingletonObject
## autoload. Annotations do not need editor-lookup helpers. The MinervaMCPServer
## module array is duck-typed (Array, not Array[MCPToolModule]), so this is
## fully compatible at runtime.
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
		"Render annotations composited with the host's UI, return PNG. "
		+ "EXACTLY ONE of `editor_name` (live in-memory annotations from a running plugin panel) "
		+ "or `document_path` (saved sidecar) must be provided. EXPENSIVE — image tokens. "
		+ "include_document=true: composites the host's UI underneath when a renderer is registered "
		+ "(live editor) or falls back to transparent if not. "
		+ "include_kinds filters to only those annotation kinds; empty = all. "
		+ "Returns {image_png: '<base64>'} on success.",
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
			"required": ["view"],
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
			return _annotations_render_overlay(arguments)
	return _err("Unknown annotation tool: %s" % tool_name)


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
			return _ok({
				"source": "sidecar",
				"document_path": doc_path,
				"annotations": [],
				"count": 0,
				"author_filter": author_filter if not author_filter.is_empty() else null,
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

		# summary: use kind.summary() if kind is registered; fall back to display_name+count.
		var kind_obj: AnnotationKind = null
		if registry != null:
			kind_obj = registry.get_annotation_kind(StringName(str(ann.get("kind", ""))))
		if kind_obj != null:
			entry["summary"] = kind_obj.summary(ann)
		else:
			var prim_count: int = (ann.get("primitives", []) as Array).size()
			entry["summary"] = "%s (%d primitives)" % [str(ann.get("kind", "")), prim_count]

		# bounds: only include when kind is registered and bounds is non-zero.
		if kind_obj != null:
			var b: Rect2 = kind_obj.bounds(ann)
			entry["bounds"] = {"x": b.position.x, "y": b.position.y, "w": b.size.x, "h": b.size.y}

		result_annotations.append(entry)

	var resp: Dictionary = {
		"source": source_label,
		"annotations": result_annotations,
		"count": result_annotations.size(),
		"author_filter": author_filter if not author_filter.is_empty() else null,
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
	# Require view; source identifier resolved below.
	var view_missing: String = _require_args(args, ["view"])
	if not view_missing.is_empty():
		return _err(view_missing)

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
					"[MCPAnnotationTools] render_overlay: editor '%s' returned null from "
					+ "render_content_to_image(). Falling back to transparent background."
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

	# Render each annotation's bounding box as a placeholder rectangle.
	var registry: AnnotationRegistry = _get_registry()
	for ann in filtered:
		_render_annotation_placeholder(img, ann, registry, overlay_scale)

	# Encode to PNG and base64.
	var png_bytes: PackedByteArray = img.save_png_to_buffer()
	if png_bytes.is_empty():
		return _err("Failed to encode overlay image as PNG")

	var b64: String = Marshalls.raw_to_base64(png_bytes)
	return _ok({"image_png": b64})


# ── Internal helpers ──────────────────────────────────────────────────────────

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


## Render a single annotation as a placeholder rectangle on the image.
## Uses AnnotationKind.bounds_from_primitives() (substrate-side, no plugin required)
## to determine placement. Fills known-kind bounds with a semi-transparent color;
## unknown kinds get a grey placeholder (design §10).
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
