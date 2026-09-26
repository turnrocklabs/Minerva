extends RefCounted
class_name JSONLParser
## Reads a .dct.jsonl file and produces structured in-memory dictionaries.
## Implements the Docket JSONL Format Specification v1.0.0.

# Known _type values; anything else is skipped with a warning.
const KNOWN_TYPES := [
	"meta", "item", "event", "comment", "link",
	"attachment", "secret", "secret_version", "saved_query"
]


# -- Public API ---------------------------------------------------------------

static func parse_file(path: String) -> Dictionary:
	## Read a .dct.jsonl file and return structured data.
	## Returns a dict with keys: meta, items, events, comments, links,
	## attachments, secrets, secret_versions, saved_queries, unknown_types.
	## meta is a Dictionary; all others are Arrays of Dictionaries.
	var empty := _empty_result()

	if not FileAccess.file_exists(path):
		push_warning("JSONLParser: file not found: %s" % path)
		return empty

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("JSONLParser: cannot open file: %s" % path)
		return empty

	var result := _empty_result()
	var line_number := 0

	while not file.eof_reached():
		var raw_line: String = file.get_line()
		line_number += 1
		var line: String = raw_line.strip_edges()
		if line.is_empty():
			continue

		var parsed = _parse_json_line(line, line_number)
		if parsed == null:
			continue  # warning already emitted in _parse_json_line

		if not parsed is Dictionary:
			push_warning("JSONLParser: line %d is not a JSON object, skipping" % line_number)
			continue

		var type_val = parsed.get("_type")
		if type_val == null:
			push_warning("JSONLParser: line %d missing _type field, skipping" % line_number)
			continue

		var line_type: String = str(type_val)
		if line_type not in KNOWN_TYPES:
			push_warning("JSONLParser: line %d unknown _type '%s', skipping" % [line_number, line_type])
			if line_type not in result["unknown_types"]:
				result["unknown_types"].append(line_type)
			continue

		var record := _parse_record(line_type, parsed)
		if record.is_empty():
			continue
		_note_unknown_keys(line_type, parsed, record, result["unknown_keys"])
		match line_type:
			"meta":
				result["meta"] = record
			"item":
				result["items"].append(record)
			"event":
				result["events"].append(record)
			"comment":
				result["comments"].append(record)
			"link":
				result["links"].append(record)
			"attachment":
				result["attachments"].append(record)
			"secret":
				result["secrets"].append(record)
			"secret_version":
				result["secret_versions"].append(record)
			"saved_query":
				result["saved_queries"].append(record)

	file.close()
	return result


static func parse_line(json_text: String) -> Dictionary:
	## Parse a single JSONL line. Returns the parsed dict with _type included,
	## or an empty dict on any error.
	var line: String = json_text.strip_edges()
	if line.is_empty():
		return {}

	var parsed = _parse_json_line(line, -1)
	if parsed == null or not parsed is Dictionary:
		return {}

	var type_val = parsed.get("_type")
	if type_val == null:
		push_warning("JSONLParser.parse_line: missing _type field")
		return {}

	var line_type: String = str(type_val)
	if line_type not in KNOWN_TYPES:
		push_warning("JSONLParser.parse_line: unknown _type '%s'" % line_type)
		return {}

	return _parse_record(line_type, parsed)


static func _parse_record(line_type: String, parsed: Dictionary) -> Dictionary:
	## The parsed record for a known _type, or {} when required fields are missing.
	match line_type:
		"meta":
			return _parse_meta(parsed)
		"item":
			return _parse_item(parsed)
		"event":
			return _parse_event(parsed)
		"comment":
			return _parse_comment(parsed)
		"link":
			return _parse_link(parsed)
		"attachment":
			return _parse_attachment(parsed)
		"secret":
			return _parse_secret(parsed)
		"secret_version":
			return _parse_secret_version(parsed)
		"saved_query":
			return _parse_saved_query(parsed)
	return {}


static func validate_meta(meta: Dictionary) -> bool:
	## Check that required meta fields are present.
	## Required: _type, version, counter, id_prefix.
	if meta.get("_type") != "meta":
		return false
	if not meta.has("version") or str(meta["version"]).is_empty():
		return false
	if not meta.has("counter"):
		return false
	if not meta.has("id_prefix") or str(meta["id_prefix"]).is_empty():
		return false
	return true


# -- Line-type parsers --------------------------------------------------------

static func _parse_meta(d: Dictionary) -> Dictionary:
	var out := {"_type": "meta"}
	out["version"] = _str_field(d, "version", "")
	out["counter"] = _int_field(d, "counter", 0)
	out["id_prefix"] = _str_field(d, "id_prefix", "")
	# Optional fields
	_copy_str_opt(d, out, "project")
	_copy_str_opt(d, out, "vault_salt")
	_copy_str_opt(d, out, "vault_verify")
	# Preserve any extra fields for extensibility (ignore _type itself)
	for key in d:
		if key == "_type":
			continue
		if key in ["version", "counter", "id_prefix", "project", "vault_salt", "vault_verify"]:
			continue
		out[key] = d[key]
	return out


static func _parse_item(d: Dictionary) -> Dictionary:
	# Required fields
	if not _has_required(d, ["id", "type", "status", "title", "created_at", "updated_at"]):
		return {}
	var out := {"_type": "item"}
	out["id"] = _str_field(d, "id", "")
	out["type"] = _str_field(d, "type", "")
	out["status"] = _str_field(d, "status", "")
	out["title"] = _str_field(d, "title", "")
	out["created_at"] = _str_field(d, "created_at", "")
	out["updated_at"] = _str_field(d, "updated_at", "")
	# Optional string fields
	for key in ["description", "created_by", "assigned_to", "directed_to",
				"resolution", "environment", "repro_steps",
				"assumed", "corrected", "findings", "answer",
				"occurred_at", "detected_at", "reported_at",
				"why_chain", "significant_events", "contributing_factors",
				"value", "component", "key", "topic", "subtopic",
				"confidence", "surprise", "surfaced_from",
				"blocked_by", "parent",
				"test_setup", "test_steps", "expected_result",
				"last_reviewed",
				"command", "usage", "prompt_text", "preconditions",
				"summary", "article", "parameters",
				"steps", "outcome",
				"source", "pristine_hash", "target"]:
		_copy_str_opt(d, out, key)
	# Optional integer fields (omitted when 0)
	_copy_int_opt(d, out, "priority")
	_copy_int_opt(d, out, "severity")
	_copy_int_opt(d, out, "retrieval_count")
	_copy_int_opt(d, out, "research_cost")
	_copy_int_opt(d, out, "quality")
	_copy_int_opt(d, out, "customised")
	_copy_int_opt(d, out, "deprecated")
	# Array fields
	if d.has("tags") and d["tags"] is Array:
		out["tags"] = d["tags"].duplicate()
	if d.has("tool_deps") and d["tool_deps"] is Array:
		out["tool_deps"] = d["tool_deps"].duplicate()
	if d.has("unsatisfied_deps") and d["unsatisfied_deps"] is Array:
		out["unsatisfied_deps"] = d["unsatisfied_deps"].duplicate()
	# Object fields
	if d.has("pristine_content") and d["pristine_content"] is Dictionary:
		out["pristine_content"] = d["pristine_content"].duplicate(true)
	if d.has("optimization") and d["optimization"] is Dictionary:
		out["optimization"] = d["optimization"].duplicate(true)
	return out


static func _parse_event(d: Dictionary) -> Dictionary:
	# Required fields
	if not _has_required(d, ["item_id", "seq", "event_type", "timestamp"]):
		return {}
	var out := {"_type": "event"}
	out["item_id"] = _str_field(d, "item_id", "")
	out["seq"] = _int_field(d, "seq", 0)
	out["event_type"] = _str_field(d, "event_type", "")
	out["timestamp"] = _str_field(d, "timestamp", "")
	_copy_str_opt(d, out, "actor")
	_copy_str_opt(d, out, "note")
	return out


static func _parse_comment(d: Dictionary) -> Dictionary:
	# Required: id, item_id, created_at
	if not _has_required(d, ["id", "item_id", "created_at"]):
		return {}
	var out := {"_type": "comment"}
	out["id"] = _int_field(d, "id", 0)
	out["item_id"] = _str_field(d, "item_id", "")
	out["created_at"] = _str_field(d, "created_at", "")
	_copy_str_opt(d, out, "author")
	_copy_str_opt(d, out, "text")
	# status: omitted in JSONL when "open", but we keep it if present
	_copy_str_opt(d, out, "status")
	# parent_id: omitted when 0
	if d.has("parent_id"):
		out["parent_id"] = _int_field(d, "parent_id", 0)
	_copy_str_opt(d, out, "resolved_at")
	_copy_str_opt(d, out, "resolved_by")
	return out


static func _parse_link(d: Dictionary) -> Dictionary:
	# Required: from_id, to_id, relation
	if not _has_required(d, ["from_id", "to_id", "relation"]):
		return {}
	var out := {"_type": "link"}
	out["from_id"] = _str_field(d, "from_id", "")
	out["to_id"] = _str_field(d, "to_id", "")
	out["relation"] = _str_field(d, "relation", "")
	return out


static func _parse_attachment(d: Dictionary) -> Dictionary:
	# Required: id, item_id, filename, data, created_at
	if not _has_required(d, ["id", "item_id", "filename", "data", "created_at"]):
		return {}
	var out := {"_type": "attachment"}
	out["id"] = _int_field(d, "id", 0)
	out["item_id"] = _str_field(d, "item_id", "")
	out["filename"] = _str_field(d, "filename", "")
	out["created_at"] = _str_field(d, "created_at", "")
	# Decode base64 data to PackedByteArray
	var b64_str: String = _str_field(d, "data", "")
	out["data"] = _decode_base64(b64_str)
	out["data_b64"] = b64_str  # keep raw b64 for roundtrip
	# Optional
	_copy_str_opt(d, out, "mime_type")
	_copy_int_opt(d, out, "size_bytes")
	_copy_str_opt(d, out, "description")
	_copy_str_opt(d, out, "encoding")
	return out


static func _parse_secret(d: Dictionary) -> Dictionary:
	# Required: handle, ciphertext, iv, mac, created_at, updated_at
	if not _has_required(d, ["handle", "ciphertext", "iv", "mac", "created_at", "updated_at"]):
		return {}
	var out := {"_type": "secret"}
	out["handle"] = _str_field(d, "handle", "")
	out["created_at"] = _str_field(d, "created_at", "")
	out["updated_at"] = _str_field(d, "updated_at", "")
	# Decode binary fields
	out["ciphertext"] = _decode_base64(_str_field(d, "ciphertext", ""))
	out["iv"] = _decode_base64(_str_field(d, "iv", ""))
	out["mac"] = _decode_base64(_str_field(d, "mac", ""))
	# Keep raw b64 strings for roundtrip / inspection
	out["ciphertext_b64"] = _str_field(d, "ciphertext", "")
	out["iv_b64"] = _str_field(d, "iv", "")
	out["mac_b64"] = _str_field(d, "mac", "")
	# Optional
	if d.has("requires_2fa"):
		out["requires_2fa"] = bool(d["requires_2fa"])
	else:
		out["requires_2fa"] = false
	return out


static func _parse_secret_version(d: Dictionary) -> Dictionary:
	# Required: handle, version, ciphertext, iv, mac, created_at
	if not _has_required(d, ["handle", "version", "ciphertext", "iv", "mac", "created_at"]):
		return {}
	var out := {"_type": "secret_version"}
	out["handle"] = _str_field(d, "handle", "")
	out["version"] = _int_field(d, "version", 0)
	out["created_at"] = _str_field(d, "created_at", "")
	out["ciphertext"] = _decode_base64(_str_field(d, "ciphertext", ""))
	out["iv"] = _decode_base64(_str_field(d, "iv", ""))
	out["mac"] = _decode_base64(_str_field(d, "mac", ""))
	out["ciphertext_b64"] = _str_field(d, "ciphertext", "")
	out["iv_b64"] = _str_field(d, "iv", "")
	out["mac_b64"] = _str_field(d, "mac", "")
	_copy_str_opt(d, out, "rotated_by")
	return out


static func _parse_saved_query(d: Dictionary) -> Dictionary:
	# Required: name, query
	if not _has_required(d, ["name", "query"]):
		return {}
	var out := {"_type": "saved_query"}
	out["name"] = _str_field(d, "name", "")
	# query is an embedded JSON object (Dictionary), not a string
	var query_val = d.get("query")
	if query_val is Dictionary:
		out["query"] = query_val.duplicate(true)
	else:
		out["query"] = {}
	return out


# -- Internal helpers ---------------------------------------------------------

static func _empty_result() -> Dictionary:
	return {
		"meta": {},
		"items": [],
		"events": [],
		"comments": [],
		"links": [],
		"attachments": [],
		"secrets": [],
		"secret_versions": [],
		"saved_queries": [],
		"unknown_types": [],  # _type values skipped because this parser cannot read them
		"unknown_keys": [],  # "<type>.<key>" fields of known records the writer would drop
	}


# Meta keys JSONLSerializer writes back (jsonl_version is the cache's own copy
# of `version`), and the only meta version it writes.
const _WRITTEN_META_KEYS := ["_type", "version", "counter", "id_prefix", "project",
	"vault_salt", "vault_verify", "jsonl_version"]


static func _note_unknown_keys(line_type: String, raw: Dictionary, record: Dictionary, found: Array) -> void:
	## Appends "<type>.<key>" to `found` for each non-empty field of `raw` that
	## `record` does not carry, so a rewrite from the cache would drop it. Meta
	## extras are kept in the cache but never serialized, so meta is checked
	## against the written key set and version instead.
	var lost: Array = []
	if line_type == "meta":
		if str(raw.get("version", "")) != JSONLSerializer.JSONL_VERSION:
			lost.append("version")
		for key: String in raw:
			if key not in _WRITTEN_META_KEYS:
				lost.append(key)
	else:
		for key: String in raw:
			var val: Variant = raw[key]
			var empty: bool = val == null or (val is String and val == "") or (val is float and val == 0.0) or (val is bool and not val) \
				or (val is Array and val.is_empty()) or (val is Dictionary and val.is_empty())
			if not record.has(key) and not empty:
				lost.append(key)
	for key: String in lost:
		var tag := "%s.%s" % [line_type, key]
		if tag not in found:
			found.append(tag)


static func _parse_json_line(line: String, line_number: int) -> Variant:
	## Parse a JSON string. Returns the parsed value or null on error.
	var result = JSON.parse_string(line)
	if result == null:
		if line_number >= 0:
			push_warning("JSONLParser: line %d is not valid JSON, skipping: %s" % [line_number, line.substr(0, 80)])
		else:
			push_warning("JSONLParser: invalid JSON: %s" % line.substr(0, 80))
		return null
	return result


static func _has_required(d: Dictionary, keys: Array) -> bool:
	for key in keys:
		if not d.has(key):
			push_warning("JSONLParser: missing required field '%s' in %s line" % [key, str(d.get("_type", "?"))])
			return false
	return true


static func _str_field(d: Dictionary, key: String, default_val: String) -> String:
	var val = d.get(key)
	if val == null:
		return default_val
	return str(val)


static func _int_field(d: Dictionary, key: String, default_val: int) -> int:
	var val = d.get(key)
	if val == null:
		return default_val
	if val is int:
		return val
	if val is float:
		return int(val)
	return int(str(val))


static func _copy_str_opt(src: Dictionary, dst: Dictionary, key: String) -> void:
	## Copy a string field from src to dst only if it is present and non-empty.
	if src.has(key):
		var val = src[key]
		if val != null and str(val) != "":
			dst[key] = str(val)


static func _copy_int_opt(src: Dictionary, dst: Dictionary, key: String) -> void:
	## Copy an integer field from src to dst only if it is present and non-zero.
	if src.has(key):
		var val = src[key]
		var ival: int
		if val is int:
			ival = val
		elif val is float:
			ival = int(val)
		else:
			ival = int(str(val))
		if ival != 0:
			dst[key] = ival


static func _decode_base64(b64: String) -> PackedByteArray:
	## Decode a standard base64 string to a PackedByteArray.
	## Returns empty array on empty input or decode failure.
	if b64.is_empty():
		return PackedByteArray()
	var result := Marshalls.base64_to_raw(b64)
	return result
