class_name JsonPatch
extends RefCounted
## RFC 6902 JSON Patch implementation.
##
## Applies a sequence of patch operations to a JSON-compatible Variant tree
## (nested Dictionary / Array). No autoload required — all methods are static.
##
## Atomicity guarantee: a deep duplicate of the document is created before any
## ops are applied. If any op fails the original document is returned unchanged.
## On success the mutated duplicate is returned as `doc`.
##
## Depends on JsonPointer for path resolution.
##
## Usage:
##   var result := JsonPatch.apply(doc, patch_ops)
##   if result.success:
##       var new_doc = result.doc
##   else:
##       print(result.error.code, result.error.message)

# Use preload so this file compiles correctly in headless --script mode where
# class_name cross-references from sibling scripts are not guaranteed to be
# registered in the project UID cache.
const _JP := preload("res://Scripts/Services/Plugins/JsonPointer.gd")


# ---------------------------------------------------------------------------
# Error code constants (reviewers: every error path must use one of these)
# ---------------------------------------------------------------------------

## Referenced path doesn't exist for an op that requires it (remove/replace/test).
const ERR_PATH_MISSING = "path_missing"

## Reserved for future use (e.g. strict-mode add to an existing key).
## Currently unused but defined so callers can enumerate all codes at compile time.
const ERR_PATH_ALREADY_EXISTS = "path_already_exists"

## move/copy source path is absent.
const ERR_FROM_MISSING = "from_missing"

## move target path is a proper descendant of the from path.
const ERR_MOVE_INTO_SELF = "move_into_self"

## test op value mismatch.
const ERR_TEST_FAILED = "test_failed"

## Pointer didn't start with '/' and wasn't empty.
const ERR_MALFORMED_POINTER = "malformed_pointer"

## Op is present but missing a required key (e.g. add without value).
const ERR_MALFORMED_PATCH = "malformed_patch"

## Op string is not one of the six RFC 6902 operations.
const ERR_UNKNOWN_OP = "unknown_op"


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Apply a JSON Patch (Array of op Dictionaries) to a document.
##
## Returns:
##   {
##     success : bool,
##     doc     : Variant,        # mutated doc on success; original on failure
##     error   : {               # only present on failure
##       code     : String,
##       message  : String,
##       op_index : int,
##     }
##   }
##
## The caller passes a duplicate if they want immutability — this function
## applies ops to an internal deep-duplicate and only exposes it on success.
static func apply(doc: Variant, patch: Array) -> Dictionary:
	# Work on a deep copy so we can roll back on failure.
	var working: Variant = _deep_dup(doc)

	for i in range(patch.size()):
		var op_dict = patch[i]
		if not op_dict is Dictionary:
			return _fail("", ERR_MALFORMED_PATCH,
					"Patch op at index %d is not a Dictionary" % i, i, doc)

		var op: String = op_dict.get("op", "")
		var result: Dictionary

		match op:
			"add":
				result = _op_add(working, op_dict, i)
			"remove":
				result = _op_remove(working, op_dict, i)
			"replace":
				result = _op_replace(working, op_dict, i)
			"move":
				result = _op_move(working, op_dict, i)
			"copy":
				result = _op_copy(working, op_dict, i)
			"test":
				result = _op_test(working, op_dict, i)
			"":
				return _fail("", ERR_MALFORMED_PATCH,
						"Patch op at index %d missing 'op' key" % i, i, doc)
			_:
				return _fail(op, ERR_UNKNOWN_OP,
						"Unknown patch op '%s' at index %d" % [op, i], i, doc)

		if not result.success:
			# Propagate failure; return original doc untouched.
			return {
				"success": false,
				"doc": doc,
				"error": result.error,
			}

		# Some ops (add to root, replace root) need to rebind working.
		if result.has("new_root"):
			working = result.new_root

	return {"success": true, "doc": working}


# ---------------------------------------------------------------------------
# Op implementations
# ---------------------------------------------------------------------------

static func _op_add(doc: Variant, op: Dictionary, idx: int) -> Dictionary:
	if not op.has("path"):
		return _op_fail("add", ERR_MALFORMED_PATCH, "add op missing 'path'", idx)
	if not op.has("value"):
		return _op_fail("add", ERR_MALFORMED_PATCH, "add op missing 'value'", idx)

	var path: String = op["path"]
	var value: Variant = op["value"]

	# Edge case: add to root replaces the entire document.
	if path == "":
		return {"success": true, "new_root": _deep_dup(value)}

	var r := _JP.resolve(doc, path)

	# Malformed pointer
	if r.reason == "malformed_pointer":
		return _op_fail("add", ERR_MALFORMED_POINTER,
				"add: malformed pointer '%s': %s" % [path, r.get("_message", "")], idx)

	# "-" end-of-array append
	if r.reason == "end_of_array":
		(r.parent as Array).append(_deep_dup(value))
		return {"success": true}

	if r.found:
		# RFC 6902 §4.1: if target exists in an object → replace value.
		# If target is an array element → insert before that index (shift).
		if r.parent is Array:
			(r.parent as Array).insert(r.key, _deep_dup(value))
		else:
			r.parent[r.key] = _deep_dup(value)
		return {"success": true}

	# path_missing — check if the parent level resolves to add a new key
	# RFC: adding a new member to an object is valid; adding to a missing
	# intermediate path is NOT (no auto-vivification).
	# We need to resolve the parent path to see if it exists.
	var slash_idx: int = path.rfind("/")
	if slash_idx < 0:
		return _op_fail("add", ERR_PATH_MISSING,
				"add: cannot resolve path '%s'" % path, idx)

	var parent_path: String = path.left(slash_idx)
	var token: String = path.substr(slash_idx + 1)

	var pr := _JP.resolve(doc, parent_path)
	if not pr.found:
		return _op_fail("add", ERR_PATH_MISSING,
				"add: parent path '%s' not found" % parent_path, idx)

	var parent_node: Variant = pr.value
	if parent_node is Dictionary:
		# Unescape the final token (JsonPointer._unescape is private; inline it)
		var real_key: String = token.replace("~1", "/").replace("~0", "~")
		parent_node[real_key] = _deep_dup(value)
		return {"success": true}
	elif parent_node is Array:
		# Non-existent numeric index into existing array — out of bounds
		return _op_fail("add", ERR_PATH_MISSING,
				"add: array index out of bounds at '%s'" % path, idx)
	else:
		return _op_fail("add", ERR_PATH_MISSING,
				"add: cannot add to scalar at '%s'" % parent_path, idx)


static func _op_remove(doc: Variant, op: Dictionary, idx: int) -> Dictionary:
	if not op.has("path"):
		return _op_fail("remove", ERR_MALFORMED_PATCH, "remove op missing 'path'", idx)

	var path: String = op["path"]

	if path == "":
		# Removing root is not a legal op (nothing to assign back to)
		return _op_fail("remove", ERR_PATH_MISSING,
				"remove: cannot remove root document", idx)

	var r := _JP.resolve(doc, path)

	if r.reason == "malformed_pointer":
		return _op_fail("remove", ERR_MALFORMED_POINTER,
				"remove: malformed pointer '%s'" % path, idx)

	if not r.found:
		return _op_fail("remove", ERR_PATH_MISSING,
				"remove: path '%s' not found" % path, idx)

	if r.parent is Array:
		(r.parent as Array).remove_at(r.key)
	elif r.parent is Dictionary:
		(r.parent as Dictionary).erase(r.key)
	else:
		return _op_fail("remove", ERR_PATH_MISSING,
				"remove: no parent container at path '%s'" % path, idx)

	return {"success": true}


static func _op_replace(doc: Variant, op: Dictionary, idx: int) -> Dictionary:
	if not op.has("path"):
		return _op_fail("replace", ERR_MALFORMED_PATCH, "replace op missing 'path'", idx)
	if not op.has("value"):
		return _op_fail("replace", ERR_MALFORMED_PATCH, "replace op missing 'value'", idx)

	var path: String = op["path"]
	var value: Variant = op["value"]

	if path == "":
		# Replace root
		return {"success": true, "new_root": _deep_dup(value)}

	var r := _JP.resolve(doc, path)

	if r.reason == "malformed_pointer":
		return _op_fail("replace", ERR_MALFORMED_POINTER,
				"replace: malformed pointer '%s'" % path, idx)

	if not r.found:
		return _op_fail("replace", ERR_PATH_MISSING,
				"replace: path '%s' not found" % path, idx)

	r.parent[r.key] = _deep_dup(value)
	return {"success": true}


static func _op_move(doc: Variant, op: Dictionary, idx: int) -> Dictionary:
	if not op.has("from"):
		return _op_fail("move", ERR_MALFORMED_PATCH, "move op missing 'from'", idx)
	if not op.has("path"):
		return _op_fail("move", ERR_MALFORMED_PATCH, "move op missing 'path'", idx)

	var from_path: String = op["from"]
	var to_path: String = op["path"]

	# RFC 6902 §4.4: if path is a proper prefix of from → error
	if _is_proper_prefix(from_path, to_path):
		return _op_fail("move", ERR_MOVE_INTO_SELF,
				"move: target path '%s' is a descendant of from '%s'" % [to_path, from_path], idx)

	# If from == to, it's a no-op per RFC (move to itself succeeds trivially)
	if from_path == to_path:
		return {"success": true}

	var fr := _JP.resolve(doc, from_path)

	if fr.reason == "malformed_pointer":
		return _op_fail("move", ERR_MALFORMED_POINTER,
				"move: malformed from pointer '%s'" % from_path, idx)

	if not fr.found:
		return _op_fail("move", ERR_FROM_MISSING,
				"move: from path '%s' not found" % from_path, idx)

	var moved_value: Variant = _deep_dup(fr.value)

	# Remove from source
	var remove_result := _op_remove(doc, {"path": from_path}, idx)
	if not remove_result.success:
		return remove_result

	# Add to target
	var add_result := _op_add(doc, {"path": to_path, "value": moved_value}, idx)
	if not add_result.success:
		return add_result

	if add_result.has("new_root"):
		return add_result
	return {"success": true}


static func _op_copy(doc: Variant, op: Dictionary, idx: int) -> Dictionary:
	if not op.has("from"):
		return _op_fail("copy", ERR_MALFORMED_PATCH, "copy op missing 'from'", idx)
	if not op.has("path"):
		return _op_fail("copy", ERR_MALFORMED_PATCH, "copy op missing 'path'", idx)

	var from_path: String = op["from"]
	var to_path: String = op["path"]

	var fr := _JP.resolve(doc, from_path)

	if fr.reason == "malformed_pointer":
		return _op_fail("copy", ERR_MALFORMED_POINTER,
				"copy: malformed from pointer '%s'" % from_path, idx)

	if not fr.found:
		return _op_fail("copy", ERR_FROM_MISSING,
				"copy: from path '%s' not found" % from_path, idx)

	var copied_value: Variant = _deep_dup(fr.value)
	return _op_add(doc, {"path": to_path, "value": copied_value}, idx)


static func _op_test(doc: Variant, op: Dictionary, idx: int) -> Dictionary:
	if not op.has("path"):
		return _op_fail("test", ERR_MALFORMED_PATCH, "test op missing 'path'", idx)
	if not op.has("value"):
		return _op_fail("test", ERR_MALFORMED_PATCH, "test op missing 'value'", idx)

	var path: String = op["path"]
	var expected: Variant = op["value"]

	var r := _JP.resolve(doc, path)

	if r.reason == "malformed_pointer":
		return _op_fail("test", ERR_MALFORMED_POINTER,
				"test: malformed pointer '%s'" % path, idx)

	if not r.found:
		return _op_fail("test", ERR_PATH_MISSING,
				"test: path '%s' not found" % path, idx)

	if not _deep_equal(r.value, expected):
		return _op_fail("test", ERR_TEST_FAILED,
				"test: value at '%s' does not equal expected" % path, idx)

	return {"success": true}


# ---------------------------------------------------------------------------
# Deep equality (RFC 6902 §4.6 — values must be identical)
# ---------------------------------------------------------------------------

static func _deep_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		# Allow int/float equivalence for whole numbers (GDScript JSON round-trip)
		var a_num: bool = (typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT)
		var b_num: bool = (typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT)
		if a_num and b_num:
			return float(a) == float(b)
		return false

	if a is Dictionary:
		var ad: Dictionary = a
		var bd: Dictionary = b
		if ad.size() != bd.size():
			return false
		for k in ad:
			if not bd.has(k):
				return false
			if not _deep_equal(ad[k], bd[k]):
				return false
		return true

	if a is Array:
		var aa: Array = a
		var ba: Array = b
		if aa.size() != ba.size():
			return false
		for i in range(aa.size()):
			if not _deep_equal(aa[i], ba[i]):
				return false
		return true

	return a == b


# ---------------------------------------------------------------------------
# Deep duplicate
# ---------------------------------------------------------------------------

## Create a deep copy of any JSON-compatible Variant.
static func _deep_dup(v: Variant) -> Variant:
	if v is Dictionary:
		var d: Dictionary = {}
		for k in v:
			d[k] = _deep_dup(v[k])
		return d
	if v is Array:
		var a: Array = []
		for item in v:
			a.append(_deep_dup(item))
		return a
	# Scalars (int, float, String, bool, null) are value types — no copy needed.
	return v


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Returns true if candidate_path starts with base_path followed by '/',
## meaning candidate is a proper descendant of base (not equal).
static func _is_proper_prefix(base: String, candidate: String) -> bool:
	if base == "":
		# Empty base means root — every non-empty path is a descendant of root
		return candidate != ""
	return candidate.begins_with(base + "/")


## op is included in the error response when non-empty so callers can
## distinguish which patch operation failed. Top-level patch validation
## passes "" for op (no specific operation context yet).
static func _fail(op: String, code: String, message: String, op_index: int, original_doc: Variant) -> Dictionary:
	var err: Dictionary = {
		"code": code,
		"message": message,
		"op_index": op_index,
	}
	if not op.is_empty():
		err["op"] = op
	return {
		"success": false,
		"doc": original_doc,
		"error": err,
	}


## op identifies the failing operation type (e.g. "add", "remove") and is
## always recorded in the error dict — per-op failure path is always invoked
## with a concrete op name (see callers).
static func _op_fail(op: String, code: String, message: String, op_index: int) -> Dictionary:
	return {
		"success": false,
		"error": {
			"code": code,
			"message": message,
			"op_index": op_index,
			"op": op,
		},
	}
