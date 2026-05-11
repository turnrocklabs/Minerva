class_name JsonPointer
extends RefCounted
## RFC 6901 JSON Pointer implementation.
##
## Provides a single static entry point for navigating into a JSON-compatible
## Variant tree (nested Dictionary / Array). No autoload required — all methods
## are static.
##
## Escape rules (RFC 6901 §4):
##   ~1  →  /   (decoded first)
##   ~0  →  ~   (decoded second)
##
## Special token "-" on an Array means "one past the last element" (end-of-array).
## Used by RFC 6902 op:add to append. Resolving "-" returns found=false so that
## callers can distinguish "append target" from "element exists" while still
## having parent + key available.
##
## Usage:
##   var r := JsonPointer.resolve(doc, "/slides/0/title")
##   if r.found:
##       print(r.value)
##   else:
##       print("not found: ", r.reason)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Resolve a JSON Pointer against a document.
##
## Returns a Dictionary with the following keys:
##   found  : bool    — true iff the token path leads to an existing value
##                      (false for "-" end-of-array target and all errors)
##   value  : Variant — the resolved value when found=true; null otherwise
##   parent : Variant — the container (Dict or Array) holding the resolved key,
##                      or null for root pointer or on error
##   key    : Variant — String key (for Dict) or int index (for Array),
##                      or null for root / error; for "-" it is arr.size()
##   reason : String  — human-readable explanation when found=false
##
## Mutating parent[key] = new_value is safe and updates the document in-place.
static func resolve(doc: Variant, pointer: String) -> Dictionary:
	# Empty pointer → root
	if pointer == "":
		return {
			"found": true,
			"value": doc,
			"parent": null,
			"key": null,
			"reason": "",
		}

	# Must start with '/'
	if not pointer.begins_with("/"):
		return _not_found(null, null, "malformed_pointer",
				"JSON Pointer must be empty or start with '/'; got: '%s'" % pointer)

	# Split on '/' — first element is empty string before leading '/'
	var raw_tokens: PackedStringArray = pointer.split("/")
	# raw_tokens[0] is "" (before the leading slash); skip it
	var tokens: Array = []
	for i in range(1, raw_tokens.size()):
		tokens.append(_unescape(raw_tokens[i]))

	var current: Variant = doc
	var parent: Variant = null
	var last_key: Variant = null

	for ti in range(tokens.size()):
		var token: String = tokens[ti]
		var is_last: bool = (ti == tokens.size() - 1)

		if current is Dictionary:
			if not current.has(token):
				return _not_found(current if is_last else null,
						token if is_last else null,
						"path_missing",
						"Key '%s' not found in object at token index %d" % [token, ti])
			parent = current
			last_key = token
			current = current[token]

		elif current is Array:
			# Handle "-" end-of-array
			if token == "-":
				if is_last:
					return {
						"found": false,
						"value": null,
						"parent": current,
						"key": current.size(),
						"reason": "end_of_array",
					}
				else:
					# "-" is only legal as the final token for add
					return _not_found(null, null, "path_missing",
							"Token '-' used at non-terminal position (token index %d)" % ti)

			# Must be a non-negative integer
			if not _is_array_index(token):
				return _not_found(null, null, "malformed_pointer",
						"Array index token '%s' is not a non-negative integer (token index %d)" % [token, ti])

			var idx: int = int(token)
			if idx < 0 or idx >= current.size():
				return _not_found(current if is_last else null,
						idx if is_last else null,
						"path_missing",
						"Array index %d out of bounds (size %d) at token index %d" % [idx, current.size(), ti])
			parent = current
			last_key = idx
			current = current[idx]

		else:
			# Scalar — cannot navigate further
			return _not_found(null, null, "path_missing",
					"Cannot descend into scalar value at token index %d (token '%s')" % [ti, token])

	return {
		"found": true,
		"value": current,
		"parent": parent,
		"key": last_key,
		"reason": "",
	}


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Decode RFC 6901 escape sequences. ~1 first, then ~0 (per spec §4).
static func _unescape(token: String) -> String:
	# Replace ~1 → / before ~0 → ~ to avoid double-processing
	return token.replace("~1", "/").replace("~0", "~")


## Returns true iff s represents a valid non-negative integer with no leading
## zeros (except "0" itself) — RFC 6901 array index requirement.
static func _is_array_index(s: String) -> bool:
	if s.is_empty():
		return false
	if not s.is_valid_int():
		return false
	# No leading zeros (unless the token is literally "0")
	if s.length() > 1 and s[0] == "0":
		return false
	return int(s) >= 0


static func _not_found(parent: Variant, key: Variant, reason: String, message: String) -> Dictionary:
	return {
		"found": false,
		"value": null,
		"parent": parent,
		"key": key,
		"reason": reason,
		"_message": message,
	}
