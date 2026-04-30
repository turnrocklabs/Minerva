class_name AnnotationV2Schema
extends RefCounted
## V2 annotation envelope schema: validation, serialization, and deserialization.
##
## The v2 envelope adds typed anchors, lifecycle states, author identity, and a
## required human/LLM-readable summary. V1 helpers remain in AnnotationSchema.gd
## for migration (task #9).
##
## Canonical v2 envelope shape — see task body 019ddb7593467eef for the full spec.
##
## Usage:
##   var schema := AnnotationV2Schema.new()
##   var result := schema.validate(envelope_dict)
##   if result.has_errors(): ...
##
## Serialization (strips computed fields):
##   var clean := schema.serialize(envelope_dict)
##   var restored := schema.deserialize(clean)

# ── Constants ─────────────────────────────────────────────────────────────────

const SCHEMA_VERSION := 2

## Required top-level string fields
const _REQUIRED_STRINGS: PackedStringArray = [
	"id", "kind", "view_context"
]

## Required top-level fields (any type — validated individually)
const _REQUIRED_FIELDS: PackedStringArray = [
	"id", "kind", "schema_version", "anchor", "kind_payload",
	"lifecycle", "author", "view_context", "visible_in_views", "summary"
]

const _VALID_LIFECYCLES: PackedStringArray = ["open", "applied", "resolved", "stale"]
const _GENERIC_KIND_ANCHORS := {
	"text": ["core/*"],
	"arrow": ["core/*"],
	"region": ["core/*"],
	"polyline": ["core/*"],
	"highlight": ["core/*"],
	"measure_distance": ["core/*"],
	"measure_angle": ["core/*"],
	"measure_radius": ["core/*"],
	"2d_text": ["core/*"],
	"2d_arrow": ["core/*"],
	"2d_region": ["core/*"],
	"2d_polyline": ["core/*"],
	"2d_highlight": ["core/*"],
	"2d_measure_distance": ["core/*"],
	"2d_measure_angle": ["core/*"],
	"2d_measure_radius": ["core/*"],
}


# ── Structured validation result (mirrors AnnotationSchema pattern) ───────────

class ValidationResult extends RefCounted:
	var errors: Array = []  # Array of {field_path, message, code}

	func has_errors() -> bool:
		return errors.size() > 0

	func add_error(field_path: String, message: String, code: String) -> void:
		errors.append({"field_path": field_path, "message": message, "code": code})

	func to_error_dicts() -> Array:
		return errors.duplicate()


# ── Public API ─────────────────────────────────────────────────────────────────

## Validates a complete v2 annotation envelope dictionary.
## Returns a ValidationResult. Check result.has_errors() for failures.
func validate(envelope: Dictionary) -> ValidationResult:
	var result := ValidationResult.new()

	# ── schema_version: required, must be 2 ───────────────────────────────────
	if not envelope.has("schema_version"):
		result.add_error("schema_version", "'schema_version' is required", "required")
	elif envelope["schema_version"] != SCHEMA_VERSION:
		result.add_error(
			"schema_version",
			"'schema_version' must be %d, got: %s" % [SCHEMA_VERSION, str(envelope["schema_version"])],
			"bad_enum"
		)

	# ── id: required non-empty string ─────────────────────────────────────────
	if not envelope.has("id"):
		result.add_error("id", "'id' is required", "required")
	elif not envelope["id"] is String or (envelope["id"] as String).is_empty():
		result.add_error("id", "'id' must be a non-empty String", "bad_type")

	# ── kind: required non-empty string ───────────────────────────────────────
	if not envelope.has("kind"):
		result.add_error("kind", "'kind' is required", "required")
	elif not envelope["kind"] is String or (envelope["kind"] as String).is_empty():
		result.add_error("kind", "'kind' must be a non-empty String", "bad_type")

	# ── anchor: required dictionary ───────────────────────────────────────────
	if not envelope.has("anchor"):
		result.add_error("anchor", "'anchor' is required", "required")
	elif not envelope["anchor"] is Dictionary:
		result.add_error("anchor", "'anchor' must be a Dictionary", "bad_type")
	else:
		_validate_anchor(result, envelope["anchor"])

	# ── kind_payload: required dictionary ─────────────────────────────────────
	if not envelope.has("kind_payload"):
		result.add_error("kind_payload", "'kind_payload' is required", "required")
	elif not envelope["kind_payload"] is Dictionary:
		result.add_error("kind_payload", "'kind_payload' must be a Dictionary", "bad_type")

	# ── lifecycle: required, closed enum ──────────────────────────────────────
	if not envelope.has("lifecycle"):
		result.add_error("lifecycle", "'lifecycle' is required", "required")
	elif not envelope["lifecycle"] is String or \
			envelope["lifecycle"] not in _VALID_LIFECYCLES:
		result.add_error(
			"lifecycle",
			"'lifecycle' must be one of %s, got: %s" % [str(_VALID_LIFECYCLES), str(envelope.get("lifecycle"))],
			"bad_enum"
		)

	# ── author: required dictionary ───────────────────────────────────────────
	if not envelope.has("author"):
		result.add_error("author", "'author' is required", "required")
	elif not envelope["author"] is Dictionary:
		result.add_error("author", "'author' must be a Dictionary", "bad_type")
	else:
		var author_errors := AnnotationAuthor.validate(envelope["author"])
		for e in author_errors:
			result.add_error(e["field_path"], e["message"], e["code"])

	# ── view_context: required non-empty string ────────────────────────────────
	if not envelope.has("view_context"):
		result.add_error("view_context", "'view_context' is required", "required")
	elif not envelope["view_context"] is String or (envelope["view_context"] as String).is_empty():
		result.add_error("view_context", "'view_context' must be a non-empty String", "bad_type")

	# ── visible_in_views: required array ──────────────────────────────────────
	if not envelope.has("visible_in_views"):
		result.add_error("visible_in_views", "'visible_in_views' is required", "required")
	elif not envelope["visible_in_views"] is Array:
		result.add_error("visible_in_views", "'visible_in_views' must be an Array", "bad_type")

	# ── summary: required non-empty string ────────────────────────────────────
	if not envelope.has("summary"):
		result.add_error("summary", "'summary' is required", "required")
	elif not envelope["summary"] is String or (envelope["summary"] as String).is_empty():
		result.add_error("summary", "'summary' must be a non-empty String", "bad_type")

	if not result.has_errors():
		_validate_kind_anchor_compat(result, envelope, null)

	return result


func validate_with_registry(envelope: Dictionary, registry: Object) -> ValidationResult:
	var result := validate(envelope)
	if result.has_errors():
		var only_compat := true
		for error in result.errors:
			if str(error.get("code", "")) != "kind_anchor_incompatible":
				only_compat = false
				break
		if not only_compat:
			return result
	result.errors = result.errors.filter(func(error): return str(error.get("code", "")) != "kind_anchor_incompatible")
	_validate_kind_anchor_compat(result, envelope, registry)
	return result


func anchor_type_matches_pattern(anchor_type: String, pattern: String) -> bool:
	if pattern.ends_with("/*"):
		return anchor_type.begins_with(pattern.substr(0, pattern.length() - 1))
	return anchor_type == pattern


## Validates an update: checks immutability of view_context.
## Returns an Array of error dicts (empty = no violations).
func validate_update(old_envelope: Dictionary, new_envelope: Dictionary) -> Array:
	return check_view_context_immutable(old_envelope, new_envelope)


## Checks that view_context has not changed between old and new envelopes.
## Returns an Array of error dicts; empty means no immutability violation.
func check_view_context_immutable(old_envelope: Dictionary, new_envelope: Dictionary) -> Array:
	var errors: Array = []
	var old_vc = old_envelope.get("view_context", null)
	var new_vc = new_envelope.get("view_context", null)
	if old_vc != new_vc:
		errors.append({
			"field_path": "view_context",
			"message": "'view_context' is immutable post-creation; old='%s', new='%s'" % [str(old_vc), str(new_vc)],
			"code": "immutable"
		})
	return errors


## Serialize an envelope to a storable Dictionary.
## Strips the computed 'anchored_to' field — it will be re-derived on deserialize.
func serialize(envelope: Dictionary) -> Dictionary:
	var out: Dictionary = envelope.duplicate(true)
	out.erase("anchored_to")
	return out


## Deserialize a stored Dictionary back into a live envelope.
## Re-derives the computed 'anchored_to' field from anchor.plugin/type/id.
func deserialize(dict: Dictionary) -> Dictionary:
	var out: Dictionary = dict.duplicate(true)
	if out.has("anchor") and out["anchor"] is Dictionary:
		out["anchored_to"] = derive_anchored_to(out)
	return out


## Derives the 'anchored_to' string from the envelope's anchor fields.
## Format: "{anchor.plugin}.{anchor.type}:{anchor.id}"
## Returns "" if the anchor or its required fields are missing.
static func derive_anchored_to(envelope: Dictionary) -> String:
	if not envelope.has("anchor") or not envelope["anchor"] is Dictionary:
		return ""
	var anchor: Dictionary = envelope["anchor"]
	var plugin = anchor.get("plugin", null)
	var atype  = anchor.get("type", null)
	var aid    = anchor.get("id", null)
	if plugin == null or atype == null or aid == null:
		return ""
	return "%s.%s:%s" % [str(plugin), str(atype), str(aid)]


# ── Internal helpers ───────────────────────────────────────────────────────────

func _validate_anchor(result: ValidationResult, anchor: Dictionary) -> void:
	# plugin: required non-empty string
	if not anchor.has("plugin"):
		result.add_error("anchor.plugin", "'anchor.plugin' is required", "required")
	elif not anchor["plugin"] is String or (anchor["plugin"] as String).is_empty():
		result.add_error("anchor.plugin", "'anchor.plugin' must be a non-empty String", "bad_type")

	# type: required non-empty string
	if not anchor.has("type"):
		result.add_error("anchor.type", "'anchor.type' is required", "required")
	elif not anchor["type"] is String or (anchor["type"] as String).is_empty():
		result.add_error("anchor.type", "'anchor.type' must be a non-empty String", "bad_type")

	# id: required, Variant (int / string / array / dict for multi-element) — must be present
	if not anchor.has("id"):
		result.add_error("anchor.id", "'anchor.id' is required", "required")
	# id may be null explicitly in the envelope but the field must exist.
	# We accept null as a valid sentinel per the spec (Variant).

	# stable_key: optional, must be String or null if present
	if anchor.has("stable_key"):
		var sk = anchor["stable_key"]
		if sk != null and not sk is String:
			result.add_error("anchor.stable_key", "'anchor.stable_key' must be a String or null", "bad_type")

	# snapshot: required dictionary with at minimum a "position" key
	if not anchor.has("snapshot"):
		result.add_error("anchor.snapshot", "'anchor.snapshot' is required", "required")
	elif not anchor["snapshot"] is Dictionary:
		result.add_error("anchor.snapshot", "'anchor.snapshot' must be a Dictionary", "bad_type")
	else:
		var snap: Dictionary = anchor["snapshot"]
		if not snap.has("position"):
			result.add_error(
				"anchor.snapshot.position",
				"'anchor.snapshot.position' is required (at minimum {position: ...})",
				"required"
			)


func _validate_kind_anchor_compat(result: ValidationResult, envelope: Dictionary, registry: Object) -> void:
	var kind_name := str(envelope.get("kind", ""))
	var anchor: Dictionary = envelope.get("anchor", {})
	var anchor_type := "%s/%s" % [str(anchor.get("plugin", "")), str(anchor.get("type", ""))]
	var accepted := _accepted_anchor_types_for_kind(kind_name, registry)
	if accepted.is_empty():
		result.add_error("kind", "annotation kind '%s' accepts no anchors" % kind_name, "kind_anchor_incompatible")
		return
	for pattern in accepted:
		if anchor_type_matches_pattern(anchor_type, str(pattern)):
			return
	result.add_error(
		"anchor",
		"annotation kind '%s' does not accept anchor '%s'" % [kind_name, anchor_type],
		"kind_anchor_incompatible"
	)


func _accepted_anchor_types_for_kind(kind_name: String, registry: Object) -> Array:
	if registry != null and registry.has_method("get_annotation_kind"):
		var kind: Variant = registry.get_annotation_kind(StringName(kind_name))
		if kind != null and kind.has_method("accepted_anchor_types"):
			var accepted: Variant = kind.accepted_anchor_types()
			if accepted is Array:
				return accepted
	if _GENERIC_KIND_ANCHORS.has(kind_name):
		return _GENERIC_KIND_ANCHORS[kind_name]
	return []
