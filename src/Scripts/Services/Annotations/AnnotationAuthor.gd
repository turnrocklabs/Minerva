class_name AnnotationAuthor
extends RefCounted
## Validator for the v2 annotation author object.
##
## Author shape:
##   {
##     "kind":       "human" | "ai",   # required
##     "id":         String | null,     # optional
##     "model":      String | null,     # optional (AI only, but not enforced)
##     "session_id": String | null,     # optional
##   }
##
## Usage:
##   var errors := AnnotationAuthor.validate(author_dict)
##   if errors.size() > 0: # has errors

const KIND_HUMAN := "human"
const KIND_AI    := "ai"
const VALID_KINDS: PackedStringArray = ["human", "ai"]


## Canonical author-kind extractor. Accepts a v2 {kind: ...} dict or a v1
## plain "human"/"ai" string and returns the kind string ("" when absent).
## Every consumer that branches on author kind should use this instead of
## comparing annotation.author directly — v1 and v2 shapes coexist in the wild.
static func kind_of(author: Variant) -> String:
	if author is Dictionary:
		return str((author as Dictionary).get("kind", ""))
	return str(author)

## Optional string-or-null fields allowed alongside "kind".
const OPTIONAL_STRING_FIELDS: PackedStringArray = ["id", "model", "session_id"]


## Validates an author dictionary.
## Returns an Array of error dictionaries: [{field_path, message, code}].
## Returns an empty array when the author is valid.
static func validate(author: Variant) -> Array:
	var errors: Array = []

	if not author is Dictionary:
		errors.append({
			"field_path": "author",
			"message": "'author' must be a Dictionary",
			"code": "bad_type"
		})
		return errors

	var d: Dictionary = author

	# kind: required, must be "human" or "ai"
	if not d.has("kind"):
		errors.append({
			"field_path": "author.kind",
			"message": "'author.kind' is required",
			"code": "required"
		})
	elif d["kind"] not in VALID_KINDS:
		errors.append({
			"field_path": "author.kind",
			"message": "'author.kind' must be 'human' or 'ai', got: %s" % str(d["kind"]),
			"code": "bad_enum"
		})

	# Optional fields: must be String or null when present
	for field in OPTIONAL_STRING_FIELDS:
		if d.has(field):
			var val = d[field]
			if val != null and not val is String:
				errors.append({
					"field_path": "author.%s" % field,
					"message": "'author.%s' must be a String or null when present, got: %s" % [field, str(val)],
					"code": "bad_type"
				})

	return errors
