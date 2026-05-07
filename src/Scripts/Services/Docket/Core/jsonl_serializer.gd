extends RefCounted
class_name JSONLSerializer
## Serializes DocketDB state to JSONL format per the docket JSONL format spec v1.0.0.
##
## Each serialize_* method returns a String (possibly empty).
## serialize_all() returns the complete JSONL file content (ends with \n).

const JSONL_VERSION := "1.0.0"


# -- Public API ---------------------------------------------------------------

static func serialize_all(db: DocketDB) -> String:
	## Full JSONL file from DB state. Lines in spec order, file ends with \n.
	var parts: PackedStringArray = []

	var meta_line := serialize_meta(db)
	if not meta_line.is_empty():
		parts.append(meta_line)

	var items_lines := serialize_items(db)
	if not items_lines.is_empty():
		parts.append(items_lines)

	var events_lines := serialize_events(db)
	if not events_lines.is_empty():
		parts.append(events_lines)

	var comments_lines := serialize_comments(db)
	if not comments_lines.is_empty():
		parts.append(comments_lines)

	var links_lines := serialize_links(db)
	if not links_lines.is_empty():
		parts.append(links_lines)

	var attachments_lines := serialize_attachments(db)
	if not attachments_lines.is_empty():
		parts.append(attachments_lines)

	var secrets_lines := serialize_secrets(db)
	if not secrets_lines.is_empty():
		parts.append(secrets_lines)

	var queries_lines := serialize_saved_queries(db)
	if not queries_lines.is_empty():
		parts.append(queries_lines)

	if parts.is_empty():
		return ""
	return "\n".join(parts) + "\n"


static func serialize_meta(db: DocketDB) -> String:
	## Serialize the meta line. Always exactly one line.
	var d := {}

	# Required fields first (in schema order)
	d["_type"] = "meta"
	d["version"] = JSONL_VERSION
	d["counter"] = db.get_counter()
	d["id_prefix"] = db.get_id_prefix()

	# Optional fields
	var project := db.get_project_name()
	if not project.is_empty():
		d["project"] = project

	var vault_salt := db.get_meta_value("vault_salt", "")
	if not vault_salt.is_empty():
		d["vault_salt"] = vault_salt

	var vault_verify := db.get_meta_value("vault_verify", "")
	if not vault_verify.is_empty():
		d["vault_verify"] = vault_verify

	# Note: we only serialize the known meta keys above. DocketDB doesn't expose
	# a list_meta_keys() method, so any custom meta values live only in the cache.

	return _to_ordered_json(d)


static func serialize_items(db: DocketDB) -> String:
	## All item lines sorted by id ascending.
	var rows := db._exec_select("SELECT * FROM items ORDER BY id ASC;")
	if rows.is_empty():
		return ""

	var lines: PackedStringArray = []
	for row in rows:
		var line := _serialize_item_row(db, row)
		lines.append(line)

	return "\n".join(lines)


static func serialize_events(db: DocketDB) -> String:
	## All event lines sorted by (item_id, seq) where seq is 1-based per-item.
	## We read events ordered by (item_id, id ASC) and compute seq within each item.
	var rows := db._exec_select(
		"SELECT item_id, event_type, actor, timestamp, note FROM item_events ORDER BY item_id ASC, id ASC;"
	)
	if rows.is_empty():
		return ""

	var lines: PackedStringArray = []
	var current_item_id := ""
	var seq := 0

	for row in rows:
		var item_id := str(row.get("item_id", ""))
		if item_id != current_item_id:
			current_item_id = item_id
			seq = 0
		seq += 1

		var d := {}
		d["_type"] = "event"
		d["item_id"] = item_id
		d["seq"] = seq
		d["event_type"] = str(row.get("event_type", ""))
		# actor: omit if empty
		var actor := str(row.get("actor", ""))
		if not actor.is_empty():
			d["actor"] = actor
		d["timestamp"] = str(row.get("timestamp", ""))
		# note: omit if empty
		var note := str(row.get("note", ""))
		if not note.is_empty():
			d["note"] = note

		lines.append(_to_ordered_json(d))

	return "\n".join(lines)


static func serialize_comments(db: DocketDB) -> String:
	## All comment lines sorted by (item_id ASC, id ASC).
	var rows := db._exec_select(
		"SELECT * FROM comments ORDER BY item_id ASC, id ASC;"
	)
	if rows.is_empty():
		return ""

	var lines: PackedStringArray = []
	for row in rows:
		var d := {}
		d["_type"] = "comment"
		d["id"] = int(row.get("id", 0))
		d["item_id"] = str(row.get("item_id", ""))

		# author: optional
		var author := str(row.get("author", ""))
		if not author.is_empty():
			d["author"] = author

		# text: optional
		var text := str(row.get("text", ""))
		if not text.is_empty():
			d["text"] = text

		# status: omit if "open" (the default)
		var status := str(row.get("status", "open"))
		if status != "open":
			d["status"] = status

		d["created_at"] = str(row.get("created_at", ""))

		# parent_id: omit if 0
		var parent_id := int(row.get("parent_id", 0))
		if parent_id != 0:
			d["parent_id"] = parent_id

		# resolved_at: optional
		var resolved_at := str(row.get("resolved_at", ""))
		if not resolved_at.is_empty():
			d["resolved_at"] = resolved_at

		# resolved_by: optional
		var resolved_by := str(row.get("resolved_by", ""))
		if not resolved_by.is_empty():
			d["resolved_by"] = resolved_by

		lines.append(_to_ordered_json(d))

	return "\n".join(lines)


static func serialize_links(db: DocketDB) -> String:
	## All link lines sorted by (from_id ASC, to_id ASC, relation ASC).
	var rows := db._exec_select(
		"SELECT from_id, to_id, relation FROM item_links ORDER BY from_id ASC, to_id ASC, relation ASC;"
	)
	if rows.is_empty():
		return ""

	var lines: PackedStringArray = []
	for row in rows:
		var d := {}
		d["_type"] = "link"
		d["from_id"] = str(row.get("from_id", ""))
		d["to_id"] = str(row.get("to_id", ""))
		d["relation"] = str(row.get("relation", ""))
		lines.append(_to_ordered_json(d))

	return "\n".join(lines)


static func serialize_attachments(db: DocketDB) -> String:
	## All attachment lines sorted by (item_id ASC, id ASC).
	## Uses raw query_with_bindings to retrieve BLOB data.
	db._db.query("SELECT * FROM attachments ORDER BY item_id ASC, id ASC;")
	var rows: Array = db._db.query_result if db._db.query_result else []
	if rows.is_empty():
		return ""

	var lines: PackedStringArray = []
	for row in rows:
		var d := {}
		d["_type"] = "attachment"
		d["id"] = int(row.get("id", 0))
		d["item_id"] = str(row.get("item_id", ""))
		d["filename"] = str(row.get("filename", ""))

		# mime_type: omit if "application/octet-stream"
		var mime := str(row.get("mime_type", "application/octet-stream"))
		if mime != "application/octet-stream" and not mime.is_empty():
			d["mime_type"] = mime

		# size_bytes: omit if 0
		var size_bytes := int(row.get("size_bytes", 0))
		if size_bytes != 0:
			d["size_bytes"] = size_bytes

		# data: base64-encode the BLOB
		var raw_data = row.get("data", PackedByteArray())
		if raw_data is PackedByteArray:
			d["data"] = Marshalls.raw_to_base64(raw_data)
		else:
			d["data"] = ""

		d["created_at"] = str(row.get("created_at", ""))

		# description: optional
		var desc := str(row.get("description", ""))
		if not desc.is_empty():
			d["description"] = desc

		lines.append(_to_ordered_json(d))

	return "\n".join(lines)


static func serialize_secrets(db: DocketDB) -> String:
	## secret lines sorted by handle ASC, then secret_version lines sorted by (handle, version).
	var secret_rows := db._exec_select(
		"SELECT handle, ciphertext, iv, mac, created_at, updated_at, requires_2fa FROM docket_secrets ORDER BY handle ASC;"
	)
	var version_rows := db._exec_select(
		"SELECT handle, version, ciphertext, iv, mac, created_at, rotated_by FROM docket_secret_versions ORDER BY handle ASC, version ASC;"
	)

	if secret_rows.is_empty() and version_rows.is_empty():
		return ""

	var lines: PackedStringArray = []

	for row in secret_rows:
		var d := {}
		d["_type"] = "secret"
		d["handle"] = str(row.get("handle", ""))

		# Binary fields — may be PackedByteArray or String depending on SQLite driver
		d["ciphertext"] = _bytes_to_b64(row.get("ciphertext"))
		d["iv"] = _bytes_to_b64(row.get("iv"))
		d["mac"] = _bytes_to_b64(row.get("mac"))

		d["created_at"] = str(row.get("created_at", ""))
		d["updated_at"] = str(row.get("updated_at", ""))

		# requires_2fa: omit if false
		var requires_2fa := int(row.get("requires_2fa", 0)) == 1
		if requires_2fa:
			d["requires_2fa"] = true

		lines.append(_to_ordered_json(d))

	for row in version_rows:
		var d := {}
		d["_type"] = "secret_version"
		d["handle"] = str(row.get("handle", ""))
		d["version"] = int(row.get("version", 0))

		d["ciphertext"] = _bytes_to_b64(row.get("ciphertext"))
		d["iv"] = _bytes_to_b64(row.get("iv"))
		d["mac"] = _bytes_to_b64(row.get("mac"))

		d["created_at"] = str(row.get("created_at", ""))

		# rotated_by: optional
		var rotated_by := str(row.get("rotated_by", ""))
		if not rotated_by.is_empty():
			d["rotated_by"] = rotated_by

		lines.append(_to_ordered_json(d))

	return "\n".join(lines)


static func serialize_saved_queries(db: DocketDB) -> String:
	## Saved query lines sorted by name ASC.
	var rows := db._exec_select("SELECT name, query_json FROM saved_queries ORDER BY name ASC;")
	if rows.is_empty():
		return ""

	var lines: PackedStringArray = []
	for row in rows:
		var d := {}
		d["_type"] = "saved_query"
		d["name"] = str(row.get("name", ""))
		# query is an embedded JSON object, not a string
		var query_json := str(row.get("query_json", "{}"))
		var parsed = JSON.parse_string(query_json)
		if parsed == null:
			parsed = {}
		d["query"] = parsed
		lines.append(_to_ordered_json(d))

	return "\n".join(lines)


# -- Internal helpers ---------------------------------------------------------

static func _serialize_item_row(db: DocketDB, row: Dictionary) -> String:
	## Serialize a single item row (already fetched from DB) to a JSONL line.
	var id := str(row.get("id", ""))

	# Fetch tags for this item
	var tag_rows := db._exec_select("SELECT tag FROM item_tags WHERE item_id=? ORDER BY tag ASC;", [id])
	var tags: Array = []
	for tag_row in tag_rows:
		tags.append(str(tag_row.get("tag", "")))

	# Build dict in spec-defined field order (section 5.2), omitting empty/zero/null
	# Always-present: _type, id, type, status, title, created_at, updated_at
	var d := {}
	d["_type"] = "item"
	d["id"] = id
	d["type"] = str(row.get("type", ""))
	d["status"] = str(row.get("status", ""))
	d["title"] = str(row.get("title", ""))

	# Optional string fields
	_set_if_nonempty(d, "description", str(row.get("description", "")))
	d["created_at"] = str(row.get("created_at", ""))
	d["updated_at"] = str(row.get("updated_at", ""))
	_set_if_nonempty(d, "created_by", str(row.get("created_by", "")))
	_set_if_nonempty(d, "assigned_to", str(row.get("assigned_to", "")))
	_set_if_nonempty(d, "directed_to", str(row.get("directed_to", "")))

	# Integer fields: omit if 0
	var priority := int(row.get("priority", 0))
	if priority != 0:
		d["priority"] = priority
	var severity := int(row.get("severity", 0))
	if severity != 0:
		d["severity"] = severity

	# Tags array: omit if empty
	if not tags.is_empty():
		d["tags"] = tags

	# More optional fields in spec order
	_set_if_nonempty(d, "parent", str(row.get("parent", "")))
	_set_if_nonempty(d, "resolution", _nullable_str(row.get("resolution")))
	_set_if_nonempty(d, "environment", _nullable_str(row.get("environment")))
	_set_if_nonempty(d, "repro_steps", _nullable_str(row.get("repro_steps")))
	_set_if_nonempty(d, "assumed", _nullable_str(row.get("assumed")))
	_set_if_nonempty(d, "corrected", _nullable_str(row.get("corrected")))
	_set_if_nonempty(d, "findings", _nullable_str(row.get("findings")))
	_set_if_nonempty(d, "answer", _nullable_str(row.get("answer")))
	_set_if_nonempty(d, "occurred_at", _nullable_str(row.get("occurred_at")))
	_set_if_nonempty(d, "detected_at", _nullable_str(row.get("detected_at")))
	_set_if_nonempty(d, "reported_at", _nullable_str(row.get("reported_at")))
	_set_if_nonempty(d, "why_chain", _nullable_str(row.get("why_chain")))
	_set_if_nonempty(d, "significant_events", _nullable_str(row.get("significant_events")))
	_set_if_nonempty(d, "contributing_factors", _nullable_str(row.get("contributing_factors")))
	_set_if_nonempty(d, "value", _nullable_str(row.get("value")))
	_set_if_nonempty(d, "component", _nullable_str(row.get("component")))
	_set_if_nonempty(d, "key", _nullable_str(row.get("key")))
	_set_if_nonempty(d, "topic", _nullable_str(row.get("topic")))
	_set_if_nonempty(d, "subtopic", _nullable_str(row.get("subtopic")))
	_set_if_nonempty(d, "confidence", _nullable_str(row.get("confidence")))
	_set_if_nonempty(d, "surprise", _nullable_str(row.get("surprise")))
	_set_if_nonempty(d, "surfaced_from", _nullable_str(row.get("surfaced_from")))

	var retrieval_count := int(row.get("retrieval_count", 0))
	if retrieval_count != 0:
		d["retrieval_count"] = retrieval_count
	var research_cost := int(row.get("research_cost", 0))
	if research_cost != 0:
		d["research_cost"] = research_cost

	_set_if_nonempty(d, "blocked_by", _nullable_str(row.get("blocked_by")))
	_set_if_nonempty(d, "test_setup", _nullable_str(row.get("test_setup")))
	_set_if_nonempty(d, "test_steps", _nullable_str(row.get("test_steps")))
	_set_if_nonempty(d, "expected_result", _nullable_str(row.get("expected_result")))

	var quality := int(row.get("quality", 0))
	if quality != 0:
		d["quality"] = quality
	_set_if_nonempty(d, "last_reviewed", _nullable_str(row.get("last_reviewed")))

	_set_if_nonempty(d, "command", _nullable_str(row.get("command")))
	_set_if_nonempty(d, "usage", _nullable_str(row.get("usage")))
	_set_if_nonempty(d, "prompt_text", _nullable_str(row.get("prompt_text")))
	_set_if_nonempty(d, "preconditions", _nullable_str(row.get("preconditions")))
	_set_if_nonempty(d, "summary", _nullable_str(row.get("summary")))
	_set_if_nonempty(d, "article", _nullable_str(row.get("article")))
	_set_if_nonempty(d, "parameters", _nullable_str(row.get("parameters")))
	_set_if_nonempty(d, "steps", _nullable_str(row.get("steps")))
	_set_if_nonempty(d, "outcome", _nullable_str(row.get("outcome")))

	_set_if_nonempty(d, "target", _nullable_str(row.get("target")))

	# tool_deps: stored as JSON TEXT in SQLite, deserialized to Array by _build_item_dict
	var tool_deps = row.get("tool_deps")
	if tool_deps is String and not tool_deps.is_empty():
		var parsed_deps = JSON.parse_string(tool_deps)
		if parsed_deps is Array and not parsed_deps.is_empty():
			d["tool_deps"] = parsed_deps
	elif tool_deps is Array and not tool_deps.is_empty():
		d["tool_deps"] = tool_deps

	# optimization: stored as JSON TEXT in SQLite, deserialized to Dictionary by _build_item_dict
	var optimization = row.get("optimization")
	if optimization is String and not optimization.is_empty():
		var parsed_opt = JSON.parse_string(optimization)
		if parsed_opt is Dictionary and not parsed_opt.is_empty():
			d["optimization"] = parsed_opt
	elif optimization is Dictionary and not optimization.is_empty():
		d["optimization"] = optimization

	# Plugin-shipped skills metadata (DCR 019df57b).
	_set_if_nonempty(d, "source", _nullable_str(row.get("source")))
	_set_if_nonempty(d, "pristine_hash", _nullable_str(row.get("pristine_hash")))

	# customised + deprecated stored as INTEGER 0/1; emit only when non-zero.
	var customised := int(row.get("customised", 0))
	if customised != 0:
		d["customised"] = customised
	var deprecated := int(row.get("deprecated", 0))
	if deprecated != 0:
		d["deprecated"] = deprecated

	# pristine_content: same shape as optimization (JSON TEXT in SQLite,
	# Dictionary in JSONL).
	var pristine_content = row.get("pristine_content")
	if pristine_content is String and not pristine_content.is_empty():
		var parsed_pc = JSON.parse_string(pristine_content)
		if parsed_pc is Dictionary and not parsed_pc.is_empty():
			d["pristine_content"] = parsed_pc
	elif pristine_content is Dictionary and not pristine_content.is_empty():
		d["pristine_content"] = pristine_content

	# unsatisfied_deps: same shape as tool_deps (JSON Array in SQLite, Array in JSONL).
	var unsatisfied_deps = row.get("unsatisfied_deps")
	if unsatisfied_deps is String and not unsatisfied_deps.is_empty():
		var parsed_ud = JSON.parse_string(unsatisfied_deps)
		if parsed_ud is Array and not parsed_ud.is_empty():
			d["unsatisfied_deps"] = parsed_ud
	elif unsatisfied_deps is Array and not unsatisfied_deps.is_empty():
		d["unsatisfied_deps"] = unsatisfied_deps

	return _to_ordered_json(d)


static func _set_if_nonempty(d: Dictionary, key: String, val: String) -> void:
	## Add key to dict only if val is non-empty.
	if not val.is_empty():
		d[key] = val


static func _nullable_str(val) -> String:
	## Convert a possibly-null value to string, returning "" for null.
	if val == null:
		return ""
	return str(val)


static func _bytes_to_b64(val) -> String:
	## Convert PackedByteArray (or already-base64 String) to base64 string.
	if val is PackedByteArray:
		return Marshalls.raw_to_base64(val)
	if val is String:
		return val
	return ""


static func _to_ordered_json(d: Dictionary) -> String:
	## Serialize a dictionary to JSON with deterministic key order.
	## _type is always first; all other keys are in insertion order (as built by callers).
	## Values are serialized per JSON rules: strings quoted+escaped, ints as numbers,
	## bools as true/false, arrays recursively, dicts recursively.
	var parts: PackedStringArray = []
	# _type always comes first per the spec (section 6.5)
	if d.has("_type"):
		parts.append('"_type":%s' % _json_value(d["_type"]))
	for key in d:
		if key == "_type":
			continue
		var val = d[key]
		parts.append('"%s":%s' % [_json_escape(key), _json_value(val)])
	return "{%s}" % ",".join(parts)


static func _json_value(val) -> String:
	## Serialize a value to its JSON representation.
	if val == null:
		return "null"
	if val is bool:
		return "true" if val else "false"
	if val is int:
		return str(val)
	if val is float:
		# Avoid scientific notation for reasonable values
		if val == int(val):
			return str(int(val))
		return str(val)
	if val is String:
		return '"%s"' % _json_escape(val)
	if val is Array:
		var items: PackedStringArray = []
		for item in val:
			items.append(_json_value(item))
		return "[%s]" % ",".join(items)
	if val is Dictionary:
		var parts: PackedStringArray = []
		for key in val:
			parts.append('"%s":%s' % [_json_escape(str(key)), _json_value(val[key])])
		return "{%s}" % ",".join(parts)
	if val is PackedByteArray:
		return '"%s"' % Marshalls.raw_to_base64(val)
	# Fallback
	return '"%s"' % _json_escape(str(val))


static func _json_escape(s: String) -> String:
	## Escape a string for use inside JSON double-quotes.
	var result := ""
	for i in s.length():
		var c := s[i]
		match c:
			'"':
				result += '\\"'
			'\\':
				result += '\\\\'
			'\n':
				result += '\\n'
			'\r':
				result += '\\r'
			'\t':
				result += '\\t'
			_:
				var code := c.unicode_at(0)
				if code < 0x20:
					# Control character — use \uXXXX
					result += "\\u%04x" % code
				else:
					result += c
	return result
