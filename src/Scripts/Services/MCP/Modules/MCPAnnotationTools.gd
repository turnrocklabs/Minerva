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
		"List all annotations attached to a document. Returns the raw annotation array "
		+ "from the sidecar. Annotations with unregistered kinds are returned verbatim — "
		+ "they are preserved on disk even when their plugin is not installed.",
		{
			"type": "object",
			"properties": {
				"document_path": {
					"type": "string",
					"description": "Absolute path to the document file (e.g. /home/user/boards/board.minpcb). "
					+ "The sidecar is looked up at <document_path>.annotations.json.",
				},
			},
			"required": ["document_path"],
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
		"Render annotations to a transparent PNG overlay. If include_document is true, "
		+ "composites the document render underneath (requires a registered editor renderer — "
		+ "falls back to transparent background with a warning if not available). "
		+ "include_kinds filters to only those annotation kinds; empty = all. "
		+ "Returns {image_png: '<base64>'} on success.",
		{
			"type": "object",
			"properties": {
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
					"description": "If true, composite the document render underneath the overlay. "
					+ "Requires a registered editor render callback. Default: false.",
				},
				"include_kinds": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Filter to only these annotation kinds. Empty array = all kinds. Default: [].",
				},
			},
			"required": ["document_path", "view"],
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
	var missing: String = _require_args(args, ["document_path"])
	if not missing.is_empty():
		return _err(missing)

	var doc_path: String = args["document_path"]
	var sidecar: Dictionary = AnnotationSidecar.read_sidecar(doc_path)
	if sidecar.is_empty():
		# No sidecar = no annotations (not an error; §7.5 zero-annotation rule).
		return _ok({"annotations": []})

	var annotations: Array = sidecar.get("annotations", [])
	return _ok({"annotations": annotations})


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
	var missing: String = _require_args(args, ["document_path", "view"])
	if not missing.is_empty():
		return _err(missing)

	var doc_path: String = args["document_path"]
	var view: String = str(args.get("view", ""))
	var width: int = _coerce_int(args.get("width", 1024), 1024)
	var height: int = _coerce_int(args.get("height", 768), 768)
	var include_document: bool = _coerce_bool(args.get("include_document", false))
	var include_kinds: Array = []
	if args.has("include_kinds") and args["include_kinds"] is Array:
		include_kinds = args["include_kinds"]

	# Clamp to sane bounds.
	width = clampi(width, 1, 4096)
	height = clampi(height, 1, 4096)

	# Load annotations from sidecar.
	var sidecar: Dictionary = AnnotationSidecar.read_sidecar(doc_path)
	var all_annotations: Array = []
	if not sidecar.is_empty():
		all_annotations = sidecar.get("annotations", [])

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

	# Create an RGBA image for the overlay.
	var img: Image = Image.create(width, height, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))  # transparent

	# If include_document: stub — PluginEditorRegistry not yet implemented.
	# Per task spec: stub with a warning, fall back to transparent background.
	if include_document:
		push_warning(
			"[MCPAnnotationTools] render_overlay: include_document=true requested but "
			+ "PluginEditorRegistry is not yet implemented. Document compositing is not available. "
			+ "Returning overlay-only PNG. (Separate implementation task required.)"
		)
		# TODO(render_overlay): When PluginEditorRegistry is available, look up
		# the editor's render_document(view, w, h) callback here and composite under.

	# Render each annotation's bounding box as a placeholder rectangle.
	# Full per-kind rendering requires a live CanvasItem/RenderingServer and
	# is deferred to the rendering task. This stub proves the PNG plumbing works
	# and gives callers a spatial overview.
	var registry: AnnotationRegistry = _get_registry()
	for ann in filtered:
		_render_annotation_placeholder(img, ann, registry)

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


## Returns the global AnnotationRegistry if the singleton exposes one,
## or null if the registry is not available in this execution context.
## In headless tests there is no autoloaded singleton, so null is safe —
## kind validation is skipped (structural schema validation still runs).
func _get_registry() -> AnnotationRegistry:
	# Try the standard Godot autoload path first.
	if Engine.has_singleton("AnnotationRegistry"):
		return Engine.get_singleton("AnnotationRegistry") as AnnotationRegistry
	# Some project configs register it under "MinervaAnnotationRegistry".
	if Engine.has_singleton("MinervaAnnotationRegistry"):
		return Engine.get_singleton("MinervaAnnotationRegistry") as AnnotationRegistry
	# Fall back to SingletonObject if it exposes annotation_registry.
	if Engine.has_singleton("SingletonObject"):
		var so: Object = Engine.get_singleton("SingletonObject")
		if so != null and so.get("annotation_registry") is AnnotationRegistry:
			return so.annotation_registry as AnnotationRegistry
	return null


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
func _render_annotation_placeholder(
	img: Image,
	ann: Dictionary,
	registry: AnnotationRegistry  # may be null
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

	for y in range(iy0, iy1):
		for x in range(ix0, ix1):
			img.set_pixel(x, y, fill_color)
