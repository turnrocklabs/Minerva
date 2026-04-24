class_name AnnotationSchema
extends RefCounted
## Annotation data schema: validation, primitive sub-schemas, and structured error reporting.
##
## This class is the authoritative definition of the annotation envelope and all
## built-in 2D primitive sub-schemas (arrow, text, region, polyline, highlight,
## measure_distance, measure_angle, measure_radius, ink_stroke).
##
## Sidecar filename convention: foo.ext.annotations.json (§7.1)
## Author field: "ai" for MCP-originated writes, "human" for UI writes (§8.1)
##
## Usage:
##   var result := AnnotationSchema.validate_annotation(annotation_dict)
##   if result.has_errors():
##       for err in result.errors: print(err.field_path, err.message)

# ── Constants ──────────────────────────────────────────────────────────────────

## Valid author values (closed enum per design §2.1)
const AUTHOR_HUMAN := "human"
const AUTHOR_AI    := "ai"

## Substrate-assigned ID prefix (ann_ + 6 hex chars)
const ID_PREFIX := "ann_"

## All recognized built-in 2D primitive kinds (design §2.2 + plan-decision §2)
const PRIMITIVE_KINDS: PackedStringArray = [
	"arrow",
	"text",
	"region",
	"polyline",
	"highlight",
	"measure_distance",
	"measure_angle",
	"measure_radius",
	"ink_stroke",
]

## Primitive kinds that are out-of-scope for this task (post-MVP)
## Included in PRIMITIVE_KINDS above for schema recognition; logic is in a separate task.
const PRIMITIVE_KINDS_POST_MVP: PackedStringArray = [
	"ink_stroke",
]

## Built-in annotation kinds shipped by core (2d_* prefix reserved for core).
## 2d_polyline added per plan-decision comment (enables lossless PCB migration).
const BUILTIN_ANNOTATION_KINDS: PackedStringArray = [
	"2d_arrow",
	"2d_text",
	"2d_region",
	"2d_polyline",
	"2d_highlight",
	"2d_measure_distance",
	"2d_measure_angle",
	"2d_measure_radius",
	# 2d_ink_stroke is post-MVP — separate task 019dc0ebf9d5797a82af41edd4c8c180
]


# ── Structured validation error ────────────────────────────────────────────────

class ValidationError extends RefCounted:
	## A single structured validation failure.
	## MCP layer returns arrays of these; never plain strings (design §8.1).

	var field_path: String  ## e.g. "primitives[0].from"
	var message: String     ## human-readable description
	var code: String        ## machine tag: "required", "type", "enum", "format", "range"

	func _init(p_field_path: String, p_message: String, p_code: String) -> void:
		field_path = p_field_path
		message    = p_message
		code       = p_code

	func to_dict() -> Dictionary:
		return {
			"field_path": field_path,
			"message":    message,
			"code":       code,
		}


# ── Validation result ──────────────────────────────────────────────────────────

class ValidationResult extends RefCounted:
	## Result of a validation call. Holds zero or more structured errors.

	var errors: Array[ValidationError] = []

	func has_errors() -> bool:
		return errors.size() > 0

	func add_error(field_path: String, message: String, code: String) -> void:
		errors.append(ValidationError.new(field_path, message, code))

	## Returns errors as an array of dicts (for MCP serialisation).
	func to_error_dicts() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for e in errors:
			out.append(e.to_dict())
		return out


# ── Public API ─────────────────────────────────────────────────────────────────

## Validates a complete annotation envelope dict.
## Checks required fields, author enum, and every primitive in primitives[].
## For kinds with primitives_optional:true the caller must pass that flag.
## Returns a ValidationResult (check has_errors()).
static func validate_annotation(
	annotation: Dictionary,
	primitives_optional: bool = false
) -> ValidationResult:
	var result := ValidationResult.new()

	# ── Required top-level fields ──────────────────────────────────────────────
	_require_string(result, annotation, "id",           "required")
	_require_string(result, annotation, "kind",         "required")
	_require_string(result, annotation, "view_context", "required")
	_require_string(result, annotation, "created_at",   "required")

	# author: required, closed enum
	if not annotation.has("author"):
		result.add_error("author", "Field 'author' is required", "required")
	elif annotation["author"] not in [AUTHOR_HUMAN, AUTHOR_AI]:
		result.add_error(
			"author",
			"'author' must be 'human' or 'ai', got: %s" % str(annotation.get("author")),
			"enum"
		)

	# primitives: required array unless primitives_optional is true for this kind
	if not annotation.has("primitives"):
		if not primitives_optional:
			result.add_error("primitives", "Field 'primitives' is required", "required")
	elif not annotation["primitives"] is Array:
		result.add_error("primitives", "Field 'primitives' must be an array", "type")
	else:
		# Validate each primitive
		var prims: Array = annotation["primitives"]
		for i in prims.size():
			_validate_primitive(result, prims[i], "primitives[%d]" % i)

	# id format check: must start with ann_ and have at least 1 char after
	var ann_id = annotation.get("id", "")
	if ann_id is String and ann_id.length() > 0:
		if not ann_id.begins_with(ID_PREFIX):
			result.add_error(
				"id",
				"'id' must start with '%s', got: %s" % [ID_PREFIX, ann_id],
				"format"
			)

	# created_at: basic RFC3339 shape check (YYYY-MM-DDTHH:MM:SS)
	var created = annotation.get("created_at", "")
	if created is String and created.length() > 0:
		if not _looks_like_rfc3339(created):
			result.add_error(
				"created_at",
				"'created_at' must be an RFC3339 string, got: %s" % created,
				"format"
			)

	# updated_at: optional, but if present must be RFC3339
	if annotation.has("updated_at"):
		var updated = annotation["updated_at"]
		if not updated is String or not _looks_like_rfc3339(updated):
			result.add_error(
				"updated_at",
				"'updated_at' must be an RFC3339 string when present",
				"format"
			)

	return result


## Validates a single primitive dict at a given field path prefix.
## Returns a ValidationResult for just this primitive.
static func validate_primitive(primitive: Dictionary, path_prefix: String = "primitive") -> ValidationResult:
	var result := ValidationResult.new()
	_validate_primitive(result, primitive, path_prefix)
	return result


## Generates a substrate-style annotation ID using a random 6-hex suffix.
static func generate_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%s%06x" % [ID_PREFIX, rng.randi() % 0x1000000]


## Returns true if the given kind name is in the core 2d_* reserved namespace.
static func is_core_kind(kind_name: StringName) -> bool:
	return str(kind_name).begins_with("2d_")


## Returns true if the given plugin kind name is valid (no 2d_ prefix).
static func is_valid_plugin_kind_name(kind_name: StringName) -> bool:
	return not str(kind_name).begins_with("2d_") and str(kind_name).length() > 0


# ── Internal helpers ───────────────────────────────────────────────────────────

static func _require_string(
	result: ValidationResult,
	d: Dictionary,
	field: String,
	code: String
) -> void:
	if not d.has(field):
		result.add_error(field, "Field '%s' is required" % field, code)
	elif not d[field] is String or (d[field] as String).is_empty():
		result.add_error(field, "Field '%s' must be a non-empty string" % field, "type")


static func _validate_primitive(
	result: ValidationResult,
	prim: Variant,
	path: String
) -> void:
	if not prim is Dictionary:
		result.add_error(path, "Primitive must be a dictionary object", "type")
		return

	var p: Dictionary = prim
	if not p.has("kind"):
		result.add_error("%s.kind" % path, "Primitive 'kind' is required", "required")
		return

	var kind = p["kind"]
	if not kind is String or (kind as String).is_empty():
		result.add_error("%s.kind" % path, "Primitive 'kind' must be a non-empty string", "type")
		return

	match kind:
		"arrow":          _validate_prim_arrow(result, p, path)
		"text":           _validate_prim_text(result, p, path)
		"region":         _validate_prim_region(result, p, path)
		"polyline":       _validate_prim_polyline(result, p, path)
		"highlight":      _validate_prim_highlight(result, p, path)
		"measure_distance": _validate_prim_measure_distance(result, p, path)
		"measure_angle":  _validate_prim_measure_angle(result, p, path)
		"measure_radius": _validate_prim_measure_radius(result, p, path)
		"ink_stroke":     _validate_prim_ink_stroke(result, p, path)
		_:
			# Unknown primitive kind — not rejected; logged as informational.
			# The substrate preserves unknown primitives verbatim (§10).
			pass


static func _validate_prim_arrow(result: ValidationResult, p: Dictionary, path: String) -> void:
	_require_point2(result, p, "from", path)
	_require_point2(result, p, "to",   path)
	if p.has("head_size"):
		_require_positive_number(result, p["head_size"], "%s.head_size" % path)


static func _validate_prim_text(result: ValidationResult, p: Dictionary, path: String) -> void:
	_require_point2(result, p, "at", path)
	if not p.has("content"):
		result.add_error("%s.content" % path, "text primitive requires 'content'", "required")
	elif not p["content"] is String:
		result.add_error("%s.content" % path, "'content' must be a string", "type")
	if p.has("size"):
		_require_positive_number(result, p["size"], "%s.size" % path)


static func _validate_prim_region(result: ValidationResult, p: Dictionary, path: String) -> void:
	_require_points_array(result, p, "points", path, 3)


static func _validate_prim_polyline(result: ValidationResult, p: Dictionary, path: String) -> void:
	_require_points_array(result, p, "points", path, 2)


static func _validate_prim_highlight(result: ValidationResult, p: Dictionary, path: String) -> void:
	if not p.has("rect"):
		result.add_error("%s.rect" % path, "highlight primitive requires 'rect'", "required")
		return
	var rect = p["rect"]
	if not rect is Array or (rect as Array).size() != 4:
		result.add_error("%s.rect" % path, "'rect' must be [x, y, w, h] (4-element array)", "type")
		return
	for i in 4:
		if not (rect[i] is float or rect[i] is int):
			result.add_error(
				"%s.rect[%d]" % [path, i],
				"'rect' element must be a number",
				"type"
			)


static func _validate_prim_measure_distance(
	result: ValidationResult, p: Dictionary, path: String
) -> void:
	_require_point2(result, p, "from", path)
	_require_point2(result, p, "to",   path)


static func _validate_prim_measure_angle(
	result: ValidationResult, p: Dictionary, path: String
) -> void:
	_require_point2(result, p, "a", path)
	_require_point2(result, p, "b", path)
	_require_point2(result, p, "c", path)


static func _validate_prim_measure_radius(
	result: ValidationResult, p: Dictionary, path: String
) -> void:
	_require_point2(result, p, "center", path)
	_require_point2(result, p, "edge",   path)


static func _validate_prim_ink_stroke(result: ValidationResult, p: Dictionary, path: String) -> void:
	## ink_stroke is post-MVP (task 019dc0ebf9d5797a82af41edd4c8c180).
	## Schema accepted and preserved; detailed point validation deferred.
	if not p.has("points"):
		result.add_error("%s.points" % path, "ink_stroke primitive requires 'points'", "required")
		return
	if not p["points"] is Array:
		result.add_error("%s.points" % path, "'points' must be an array", "type")


# ── Point / array helpers ──────────────────────────────────────────────────────

static func _require_point2(
	result: ValidationResult,
	p: Dictionary,
	field: String,
	path: String
) -> void:
	var key := "%s.%s" % [path, field]
	if not p.has(field):
		result.add_error(key, "Field '%s' is required" % field, "required")
		return
	var v = p[field]
	if not v is Array or (v as Array).size() != 2:
		result.add_error(key, "'%s' must be a 2-element [x, y] array" % field, "type")
		return
	for i in 2:
		if not (v[i] is float or v[i] is int):
			result.add_error(
				"%s[%d]" % [key, i],
				"'%s' element must be a number" % field,
				"type"
			)


static func _require_points_array(
	result: ValidationResult,
	p: Dictionary,
	field: String,
	path: String,
	min_points: int
) -> void:
	var key := "%s.%s" % [path, field]
	if not p.has(field):
		result.add_error(key, "Field '%s' is required" % field, "required")
		return
	var arr = p[field]
	if not arr is Array:
		result.add_error(key, "'%s' must be an array of [x, y] points" % field, "type")
		return
	if (arr as Array).size() < min_points:
		result.add_error(
			key,
			"'%s' requires at least %d points, got %d" % [field, min_points, (arr as Array).size()],
			"range"
		)
		return
	for i in (arr as Array).size():
		var pt = arr[i]
		if not pt is Array or (pt as Array).size() != 2:
			result.add_error(
				"%s[%d]" % [key, i],
				"Each point must be a 2-element [x, y] array",
				"type"
			)
		else:
			for j in 2:
				if not (pt[j] is float or pt[j] is int):
					result.add_error(
						"%s[%d][%d]" % [key, i, j],
						"Point coordinate must be a number",
						"type"
					)


static func _require_positive_number(
	result: ValidationResult,
	value: Variant,
	path: String
) -> void:
	if not (value is float or value is int):
		result.add_error(path, "Must be a number", "type")
	elif float(value) <= 0.0:
		result.add_error(path, "Must be a positive number, got %s" % str(value), "range")


## Minimal RFC3339 shape: YYYY-MM-DDTHH:MM:SS (optionally followed by Z or offset)
static func _looks_like_rfc3339(s: String) -> bool:
	if s.length() < 19:
		return false
	# Check basic structural positions
	return (
		s[4] == "-" and s[7] == "-" and
		(s[10] == "T" or s[10] == "t") and
		s[13] == ":" and s[16] == ":"
	)
