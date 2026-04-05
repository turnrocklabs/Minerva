extends RefCounted
class_name DocketDB
## SQLite-backed storage replacing FileManager + QueryEngine + IdGenerator.
## Returns Dictionaries in the same format as the old in-memory dicts.

var _db: SQLite
var _path: String
var _is_open: bool = false


# -- Lifecycle ----------------------------------------------------------------

func open(path: String) -> bool:
	_path = path
	_db = SQLite.new()
	_db.path = path
	_db.verbosity_level = SQLite.QUIET
	if not _db.open_db():
		push_error("DocketDB: failed to open %s" % path)
		return false
	_exec("PRAGMA journal_mode=WAL;")
	_exec("PRAGMA foreign_keys=ON;")
	_exec("PRAGMA busy_timeout=15000;")
	_is_open = true
	DocketDBSchema.migrate_schema(self)

	# Auto-derive project name and ID prefix from filename if still defaults
	var basename := path.get_file().get_basename()
	if get_project_name().is_empty() and not basename.is_empty():
		set_project_name(basename)
	if get_id_prefix() == "DKT" and not basename.is_empty() and basename != "docket":
		set_id_prefix(_derive_prefix(basename))

	return true


func close() -> void:
	if _db:
		_exec("PRAGMA wal_checkpoint(TRUNCATE);")
		_db.close_db()
	_is_open = false


func checkpoint() -> void:
	## Flush WAL to main database file so other processes can see all data.
	if _db and _is_open:
		_exec("PRAGMA wal_checkpoint(PASSIVE);")


func is_open() -> bool:
	return _is_open


static func create_new(path: String) -> DocketDB:
	var db := DocketDB.new()
	db._path = path
	db._db = SQLite.new()
	db._db.path = path
	db._db.verbosity_level = SQLite.QUIET
	if not db._db.open_db():
		push_error("DocketDB: failed to create %s" % path)
		return null
	db._exec("PRAGMA journal_mode=WAL;")
	db._exec("PRAGMA foreign_keys=ON;")
	db._exec("PRAGMA busy_timeout=15000;")
	db._init_schema()
	db._is_open = true

	# Default project name and ID prefix from filename
	var basename := path.get_file().get_basename()
	if db.get_project_name().is_empty() and not basename.is_empty():
		db.set_project_name(basename)
	if db.get_id_prefix() == "DKT" and not basename.is_empty():
		db.set_id_prefix(_derive_prefix(basename))

	return db


func get_path() -> String:
	return _path


# -- Schema creation ----------------------------------------------------------

func _init_schema() -> void:
	DocketDBSchema.init_schema(self)

# -- ID generation ------------------------------------------------------------

func next_id() -> String:
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key='counter';")
	var counter: int = int(rows[0].value) if rows.size() > 0 else 0
	counter += 1
	_exec("UPDATE docket_meta SET value=? WHERE key='counter';", [str(counter)])
	var prefix := get_id_prefix()
	if counter <= 9999:
		return "%s-%04d" % [prefix, counter]
	else:
		return "%s-%d" % [prefix, counter]


func get_id_prefix() -> String:
	return get_meta_value("id_prefix", "DKT")


func set_id_prefix(prefix: String) -> void:
	set_meta_value("id_prefix", prefix)


static func _derive_prefix(name: String) -> String:
	## Derive a 3-letter uppercase prefix from a project name.
	## Prefers consonant-leading characters, falls back to first 3 chars.
	if name.is_empty():
		return "DKT"
	var upper := name.to_upper()
	var consonants := "BCDFGHJKLMNPQRSTVWXYZ"
	var result := ""
	# First pass: take consonant-leading chars
	for c in upper:
		if consonants.contains(c):
			result += c
			if result.length() >= 3:
				return result
	# Fallback: take first 3 alphanumeric chars
	result = ""
	for c in upper:
		if c >= "A" and c <= "Z":
			result += c
			if result.length() >= 3:
				return result
	# Ultra-fallback: pad with X
	while result.length() < 3:
		result += "X"
	return result


func get_counter() -> int:
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key='counter';")
	return int(rows[0].value) if rows.size() > 0 else 0


func set_counter(val: int) -> void:
	_exec("UPDATE docket_meta SET value=? WHERE key='counter';", [str(val)])


# -- UUID7 generation ---------------------------------------------------------

static func generate_uuid7() -> String:
	## Build a UUID v7: 6 bytes ms-timestamp (big-endian), 10 random bytes,
	## version nibble 0x7 in byte 6, variant bits 0b10 in byte 8.
	## Returns 32-char lowercase hex (no dashes).
	var ms: int = int(Time.get_unix_time_from_system() * 1000.0)
	var buf := PackedByteArray()
	buf.resize(16)
	# 6 bytes big-endian millisecond timestamp
	buf[0] = (ms >> 40) & 0xFF
	buf[1] = (ms >> 32) & 0xFF
	buf[2] = (ms >> 24) & 0xFF
	buf[3] = (ms >> 16) & 0xFF
	buf[4] = (ms >> 8) & 0xFF
	buf[5] = ms & 0xFF
	# 10 random bytes
	var rand_bytes := Crypto.new().generate_random_bytes(10)
	for i in 10:
		buf[6 + i] = rand_bytes[i]
	# Stamp version 7 in byte 6 high nibble
	buf[6] = (buf[6] & 0x0F) | 0x70
	# Stamp variant 0b10 in byte 8 high 2 bits
	buf[8] = (buf[8] & 0x3F) | 0x80
	return buf.hex_encode()


func next_uuid7_id() -> String:
	## Generate a new UUID7 ID for this DB instance.
	return generate_uuid7()


func resolve_short_id(prefix: String) -> String:
	## Resolve a short hex prefix (min 4 chars) to a full UUID7 ID.
	## Returns "" if ambiguous or not found.
	if prefix.length() < 4:
		return ""
	# Exact match first
	if has_item(prefix):
		return prefix
	# Prefix match via LIKE
	var rows := _exec_select("SELECT id FROM items WHERE id LIKE ? LIMIT 2;", [prefix + "%"])
	if rows.size() == 1:
		return str(rows[0].id)
	return ""


func short_id(full_id: String) -> String:
	## Return the shortest unique prefix for display (min 7 chars for UUID7).
	## Legacy IDs are returned as-is.
	if not _is_uuid7(full_id):
		return full_id
	for length in range(7, full_id.length() + 1):
		var candidate := full_id.substr(0, length)
		var rows := _exec_select("SELECT COUNT(*) AS cnt FROM items WHERE id LIKE ? ;", [candidate + "%"])
		var cnt: int = int(rows[0].cnt) if rows.size() > 0 else 0
		if cnt <= 1:
			return candidate
	return full_id


static func _is_uuid7(id: String) -> bool:
	## Check if an ID looks like a UUID7 (32 lowercase hex chars).
	return id.length() == 32 and id.is_valid_hex_number(false)


# -- Meta helpers -------------------------------------------------------------

func get_meta_value(meta_key: String, default: String = "") -> String:
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key=?;", [meta_key])
	return str(rows[0].value) if rows.size() > 0 else default


func set_meta_value(meta_key: String, val: String) -> void:
	_exec("INSERT OR REPLACE INTO docket_meta (key, value) VALUES (?, ?);", [meta_key, val])


func get_project_name() -> String:
	return get_meta_value("project", "")


func set_project_name(name: String) -> void:
	set_meta_value("project", name)


func get_project_meta() -> Dictionary:
	## Return all project lifecycle metadata as a dict.
	var d := {}
	var stage := get_meta_value("project_stage", "")
	if not stage.is_empty():
		d["stage"] = stage
	var hyp := get_meta_value("project_hypothesis", "")
	if not hyp.is_empty():
		d["hypothesis"] = hyp
	var sc := get_meta_value("project_success_criteria", "")
	if not sc.is_empty():
		d["success_criteria"] = sc
	var pt := get_meta_value("project_promoted_to", "")
	if not pt.is_empty():
		d["promoted_to"] = pt
	return d


func set_project_meta(meta: Dictionary) -> void:
	## Update project lifecycle metadata. Only writes non-empty values.
	if meta.has("stage"):
		set_meta_value("project_stage", str(meta["stage"]))
	if meta.has("hypothesis"):
		set_meta_value("project_hypothesis", str(meta["hypothesis"]))
	if meta.has("success_criteria"):
		set_meta_value("project_success_criteria", str(meta["success_criteria"]))
	if meta.has("promoted_to"):
		set_meta_value("project_promoted_to", str(meta["promoted_to"]))


# -- Qualified reference helpers ----------------------------------------------

static func parse_qualified_ref(ref: String) -> Dictionary:
	## Parse "project:ID" into {"project": "...", "id": "..."}. Bare IDs return empty project.
	var colon_pos := ref.find(":")
	if colon_pos > 0:
		return {"project": ref.substr(0, colon_pos), "id": ref.substr(colon_pos + 1)}
	return {"project": "", "id": ref}


# -- Text normalization -------------------------------------------------------

## Replace literal \n and \t escape sequences with real characters.
## Defends against MCP clients that pass escaped text instead of actual newlines.
static func _normalize_text(val) -> Variant:
	if val is String:
		var s: String = val
		s = s.replace("\\n", "\n")
		s = s.replace("\\t", "\t")
		return s
	return val


# -- Item CRUD ----------------------------------------------------------------

## Column names for the items table (excluding id which is PRIMARY KEY).
const _ITEM_COLS: Array = [
	"type", "status", "title", "description",
	"created_at", "updated_at", "created_by", "assigned_to", "directed_to",
	"priority", "severity",
	"resolution", "environment", "repro_steps",
	"assumed", "corrected", "findings", "answer",
	"occurred_at", "detected_at", "reported_at",
	"why_chain", "significant_events", "contributing_factors",
	"value", "component", "key",
	"topic", "subtopic", "confidence",
	"surprise", "surfaced_from",
	"retrieval_count", "research_cost",
	"blocked_by", "parent",
	"test_setup", "test_steps", "expected_result",
	"quality", "last_reviewed",
	"command", "usage", "prompt_text", "preconditions",
	"summary", "article", "parameters",
	"steps", "outcome",
]


func insert_item(id: String, item: Dictionary) -> String:
	## Inserts an item into the database. Returns "" on success, error message on failure.
	# Insert main row
	var cols := PackedStringArray(["id"])
	var placeholders := PackedStringArray(["?"])
	var bindings: Array = [id]
	for col in _ITEM_COLS:
		if item.has(col):
			cols.append(col)
			placeholders.append("?")
			bindings.append(_normalize_text(item[col]))
	var sql := "INSERT INTO items (%s) VALUES (%s);" % [",".join(cols), ",".join(placeholders)]
	var err := _exec_checked(sql, bindings)
	if not err.is_empty():
		return err

	# Tags — ensure it's an Array
	var tags_raw = item.get("tags", [])
	var tags: Array = tags_raw if tags_raw is Array else []
	for tag in tags:
		_exec("INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [id, str(tag)])

	# Events
	var events: Array = item.get("events", [])
	for ev in events:
		_exec("INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
			[id, str(ev.get("event_type", "")), str(ev.get("actor", "")),
			 str(ev.get("timestamp", "")), str(ev.get("note", ""))])

	# Links
	var links: Array = item.get("links", [])
	for link in links:
		var to_id: String = str(link.get("to", ""))
		var relation: String = str(link.get("relation", ""))
		if not to_id.is_empty() and not relation.is_empty():
			_exec("INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
				[id, to_id, relation])

	return ""


func get_item(id: String) -> Dictionary:
	var rows := _exec_select("SELECT * FROM items WHERE id=?;", [id])
	if rows.is_empty():
		return {}
	return _build_item_dict(rows[0])


func has_item(id: String) -> bool:
	var rows := _exec_select("SELECT 1 FROM items WHERE id=? LIMIT 1;", [id])
	return rows.size() > 0


func update_item_fields(id: String, changes: Dictionary) -> void:
	if changes.is_empty():
		return
	var sets := PackedStringArray()
	var bindings: Array = []
	for col in changes:
		if col in ["tags", "events", "links", "id"]:
			continue
		sets.append("%s=?" % col)
		bindings.append(_normalize_text(changes[col]))
	if sets.size() > 0:
		bindings.append(id)
		_exec("UPDATE items SET %s WHERE id=?;" % ",".join(sets), bindings)

	# Handle tags replacement
	if changes.has("tags"):
		_exec("DELETE FROM item_tags WHERE item_id=?;", [id])
		var tags: Array = changes["tags"]
		for tag in tags:
			_exec("INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [id, str(tag)])


func set_item_field(id: String, field: String, val) -> void:
	if field == "tags":
		update_item_fields(id, {"tags": val})
	else:
		_exec("UPDATE items SET %s=? WHERE id=?;" % field, [_normalize_text(val), id])


# -- Full item export/import/delete (for cross-project moves) -----------------

func export_item_full(id: String) -> Dictionary:
	## Export an item with all related data (tags, events, links, comments, attachments).
	var rows := _exec_select("SELECT * FROM items WHERE id=?;", [id])
	if rows.is_empty():
		return {}
	var row: Dictionary = rows[0]

	# Scalar fields
	var exported := {}
	exported["item"] = {}
	for col in _ITEM_COLS:
		var val = row.get(col)
		exported["item"][col] = val if val != null else ""
	exported["item"]["title"] = str(row.get("title", ""))

	# Tags
	var tag_rows := _exec_select("SELECT tag FROM item_tags WHERE item_id=?;", [id])
	var tags: Array = []
	for tag_row in tag_rows:
		tags.append(str(tag_row.tag))
	exported["tags"] = tags

	# Events
	var event_rows := _exec_select("SELECT event_type, actor, timestamp, note FROM item_events WHERE item_id=? ORDER BY id ASC;", [id])
	var events: Array = []
	for er in event_rows:
		events.append({
			"event_type": str(er.get("event_type", "")),
			"actor": str(er.get("actor", "")),
			"timestamp": str(er.get("timestamp", "")),
			"note": str(er.get("note", "")),
		})
	exported["events"] = events

	# Links
	var link_rows := _exec_select("SELECT to_id, relation FROM item_links WHERE from_id=?;", [id])
	var links: Array = []
	for lr in link_rows:
		links.append({
			"to": str(lr.get("to_id", "")),
			"relation": str(lr.get("relation", "")),
		})
	exported["links"] = links

	# Comments
	var comment_rows := _exec_select("SELECT * FROM comments WHERE item_id=? ORDER BY id ASC;", [id])
	var comments: Array = []
	for cr in comment_rows:
		comments.append({
			"parent_id": int(cr.get("parent_id", 0)),
			"author": str(cr.get("author", "")),
			"text": str(cr.get("text", "")),
			"status": str(cr.get("status", "open")),
			"created_at": str(cr.get("created_at", "")),
			"resolved_at": str(cr.get("resolved_at", "")),
			"resolved_by": str(cr.get("resolved_by", "")),
		})
	exported["comments"] = comments

	# Attachments (with binary data)
	_db.query_with_bindings("SELECT * FROM attachments WHERE item_id=?;", [id])
	var att_rows: Array = _db.query_result if _db.query_result else []
	var attachments: Array = []
	for ar in att_rows:
		attachments.append({
			"filename": str(ar.get("filename", "")),
			"mime_type": str(ar.get("mime_type", "")),
			"data": ar.get("data", PackedByteArray()),
			"created_at": str(ar.get("created_at", "")),
			"description": str(ar.get("description", "")),
		})
	exported["attachments"] = attachments

	return exported


func import_item_full(new_id: String, exported: Dictionary) -> void:
	## Import a full item export under a new ID. Adds a "moved" event.
	var item_data: Dictionary = exported.get("item", {})
	item_data["id"] = new_id

	# Insert main item
	var cols := PackedStringArray(["id"])
	var placeholders := PackedStringArray(["?"])
	var bindings: Array = [new_id]
	for col in _ITEM_COLS:
		if item_data.has(col):
			cols.append(col)
			placeholders.append("?")
			bindings.append(item_data[col])
	var title: String = str(item_data.get("title", ""))
	if not item_data.has("title"):
		cols.append("title")
		placeholders.append("?")
		bindings.append(title)
	var sql := "INSERT INTO items (%s) VALUES (%s);" % [",".join(cols), ",".join(placeholders)]
	_exec(sql, bindings)

	# Tags
	var tags: Array = exported.get("tags", [])
	for tag in tags:
		_exec("INSERT OR IGNORE INTO item_tags (item_id, tag) VALUES (?, ?);", [new_id, str(tag)])

	# Events (preserve existing + add moved event)
	var events: Array = exported.get("events", [])
	for ev in events:
		_exec("INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
			[new_id, str(ev.get("event_type", "")), str(ev.get("actor", "")),
			 str(ev.get("timestamp", "")), str(ev.get("note", ""))])
	# Add "moved" event
	var ts := Time.get_datetime_string_from_system(true)
	_exec("INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
		[new_id, "moved", "", ts, "Moved to this project as %s" % new_id])

	# Links
	var links: Array = exported.get("links", [])
	for link in links:
		var to_id: String = str(link.get("to", ""))
		var relation: String = str(link.get("relation", ""))
		if not to_id.is_empty() and not relation.is_empty():
			_exec("INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
				[new_id, to_id, relation])

	# Comments
	var comments: Array = exported.get("comments", [])
	for c in comments:
		_exec("INSERT INTO comments (item_id, parent_id, author, text, status, created_at, resolved_at, resolved_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
			[new_id, int(c.get("parent_id", 0)), str(c.get("author", "")),
			 str(c.get("text", "")), str(c.get("status", "open")),
			 str(c.get("created_at", "")), str(c.get("resolved_at", "")),
			 str(c.get("resolved_by", ""))])

	# Attachments
	var attachments: Array = exported.get("attachments", [])
	for att in attachments:
		var att_data = att.get("data", PackedByteArray())
		var size_bytes: int = att_data.size() if att_data is PackedByteArray else 0
		_db.query_with_bindings(
			"INSERT INTO attachments (item_id, filename, mime_type, size_bytes, data, created_at, description) VALUES (?, ?, ?, ?, ?, ?, ?);",
			[new_id, str(att.get("filename", "")), str(att.get("mime_type", "")),
			 size_bytes, att_data, str(att.get("created_at", "")),
			 str(att.get("description", ""))])

	# Update timestamp
	_exec("UPDATE items SET updated_at=? WHERE id=?;", [ts, new_id])


func delete_item(id: String) -> void:
	## Cascading delete of an item and all related data (tags, events, links, comments, attachments, secrets).
	## Foreign keys with ON DELETE CASCADE handle most of this, but we do it explicitly for safety.
	_exec("DELETE FROM item_tags WHERE item_id=?;", [id])
	_exec("DELETE FROM item_events WHERE item_id=?;", [id])
	_exec("DELETE FROM item_links WHERE from_id=? OR to_id=?;", [id, id])
	_exec("DELETE FROM comments WHERE item_id=?;", [id])
	_exec("DELETE FROM attachments WHERE item_id=?;", [id])
	# Clean up vault entries (secret value + encrypted notes + versions)
	delete_secret(id)
	delete_secret(id + ":notes")
	_exec("DELETE FROM docket_secret_versions WHERE handle=?;", [id])
	_exec("DELETE FROM docket_secret_versions WHERE handle=?;", [id + ":notes"])
	_exec("DELETE FROM items WHERE id=?;", [id])


func rewrite_refs(old_qualified: String, new_qualified: String, old_bare_id: String, new_qualified_for_bare: String) -> int:
	## Rewrite parent and blocked_by references from old to new.
	## Returns the total number of rows updated.
	var count := 0

	# Rewrite qualified parent refs
	_exec("UPDATE items SET parent=? WHERE parent=?;", [new_qualified, old_qualified])
	count += _get_changes_count()

	# Rewrite bare parent refs (backwards compat)
	_exec("UPDATE items SET parent=? WHERE parent=?;", [new_qualified_for_bare, old_bare_id])
	count += _get_changes_count()

	# Rewrite qualified blocked_by refs
	_exec("UPDATE items SET blocked_by=? WHERE blocked_by=?;", [new_qualified, old_qualified])
	count += _get_changes_count()

	# Rewrite bare blocked_by refs
	_exec("UPDATE items SET blocked_by=? WHERE blocked_by=?;", [new_qualified_for_bare, old_bare_id])
	count += _get_changes_count()

	return count


func _get_changes_count() -> int:
	## Get the number of rows modified by the last UPDATE/INSERT/DELETE.
	var rows := _exec_select("SELECT changes() as cnt;")
	return int(rows[0].cnt) if rows.size() > 0 else 0


# -- Events -------------------------------------------------------------------

func add_event(item_id: String, event_type: String, actor: String, note: String = "") -> void:
	var ts := Time.get_datetime_string_from_system(true)
	_exec("INSERT INTO item_events (item_id, event_type, actor, timestamp, note) VALUES (?, ?, ?, ?, ?);",
		[item_id, event_type, actor, ts, note])
	_exec("UPDATE items SET updated_at=? WHERE id=?;", [ts, item_id])


func get_events(item_id: String) -> Array:
	var rows := _exec_select("SELECT event_type, actor, timestamp, note FROM item_events WHERE item_id=? ORDER BY id ASC;", [item_id])
	var result: Array = []
	for row in rows:
		result.append({
			"event_type": str(row.get("event_type", "")),
			"actor": str(row.get("actor", "")),
			"timestamp": str(row.get("timestamp", "")),
			"note": str(row.get("note", "")),
		})
	return result


# -- Transition log -----------------------------------------------------------

func log_transition(item_type: String, from_state: String, attempted_to: String, succeeded: bool, valid_transitions: Array = []) -> void:
	var ts := Time.get_datetime_string_from_system(true)
	_exec("INSERT INTO transition_log (timestamp, item_type, from_state, attempted_to, succeeded, valid_transitions) VALUES (?, ?, ?, ?, ?, ?);",
		[ts, item_type, from_state, attempted_to, 1 if succeeded else 0, ",".join(valid_transitions)])


func get_transition_report() -> Array:
	## Returns failed transition attempts grouped by (item_type, from_state, attempted_to), sorted by frequency.
	var rows := _exec_select("""
		SELECT item_type, from_state, attempted_to, valid_transitions, COUNT(*) as count
		FROM transition_log WHERE succeeded = 0
		GROUP BY item_type, from_state, attempted_to
		ORDER BY count DESC;
	""")
	var result: Array = []
	for row in rows:
		result.append({
			"item_type": str(row.get("item_type", "")),
			"from_state": str(row.get("from_state", "")),
			"attempted_to": str(row.get("attempted_to", "")),
			"valid_transitions": str(row.get("valid_transitions", "")),
			"count": int(row.get("count", 0)),
		})
	return result


# -- MCP error log ------------------------------------------------------------

func log_mcp_error(tool_name: String, error_message: String, arg_keys: String = "") -> void:
	var ts := Time.get_datetime_string_from_system(true)
	_exec("INSERT INTO mcp_error_log (timestamp, tool_name, error_message, arg_keys) VALUES (?, ?, ?, ?);",
		[ts, tool_name, error_message, arg_keys])


func get_error_report() -> Array:
	## Returns MCP errors grouped by (tool_name, error_message), sorted by frequency.
	var rows := _exec_select("""
		SELECT tool_name, error_message, COUNT(*) as count
		FROM mcp_error_log
		GROUP BY tool_name, error_message
		ORDER BY count DESC;
	""")
	var result: Array = []
	for row in rows:
		result.append({
			"tool_name": str(row.get("tool_name", "")),
			"error_message": str(row.get("error_message", "")),
			"count": int(row.get("count", 0)),
		})
	return result


# -- Links --------------------------------------------------------------------

func add_link(from_id: String, to_id: String, relation: String) -> void:
	_exec("INSERT INTO item_links (from_id, to_id, relation) VALUES (?, ?, ?);",
		[from_id, to_id, relation])


func get_links(item_id: String) -> Array:
	var rows := _exec_select("SELECT to_id, relation FROM item_links WHERE from_id=?;", [item_id])
	var result: Array = []
	for row in rows:
		result.append({
			"to": str(row.get("to_id", "")),
			"relation": str(row.get("relation", "")),
		})
	return result


# -- Query execution ----------------------------------------------------------

func execute_query(query: Dictionary, detail: String = "full") -> Array:
	var filter = query.get("filter", {})
	var sort_spec: Array = query.get("sort", [])
	var limit: int = int(query.get("limit", 0))

	var translated: Dictionary
	if filter is Dictionary and filter.has("conditions"):
		translated = DocketDBFilter.translate_conditions(filter.conditions)
	elif filter is Dictionary and (filter.has("$or") or filter.has("$and")):
		translated = DocketDBFilter.translate_tree(filter)
	else:
		translated = DocketDBFilter.translate_filter(filter if filter is Dictionary else {})
	var where_clause: String = translated.where
	var bindings: Array = translated.bindings

	var sql := "SELECT * FROM items"
	if not where_clause.is_empty():
		sql += " WHERE " + where_clause

	# Sort — validate field names against the items table columns
	const SORTABLE_FIELDS := [
		"id", "type", "status", "title", "description",
		"created_at", "updated_at", "created_by", "assigned_to", "directed_to",
		"priority", "severity", "resolution", "environment", "repro_steps",
		"assumed", "corrected", "findings", "answer",
		"occurred_at", "detected_at", "reported_at",
		"why_chain", "significant_events", "contributing_factors",
		"value", "component", "key", "topic", "subtopic", "confidence",
		"surprise", "surfaced_from", "retrieval_count", "research_cost",
		"blocked_by", "parent",
		"test_setup", "test_steps", "expected_result",
		"quality", "last_reviewed",
		"command", "usage", "prompt_text", "preconditions",
		"summary", "article", "parameters",
		"steps", "outcome",
	]
	if sort_spec.size() > 0:
		var order_parts := PackedStringArray()
		for spec in sort_spec:
			var field: String = str(spec.get("field", ""))
			var dir: String = str(spec.get("dir", "asc")).to_upper()
			if dir != "DESC":
				dir = "ASC"
			if field.is_empty():
				continue
			if field not in SORTABLE_FIELDS:
				return [{"_error": "Invalid sort field: '%s'. Valid fields: %s" % [field, ", ".join(SORTABLE_FIELDS)]}]
			order_parts.append("%s %s" % [field, dir])
		if order_parts.size() > 0:
			sql += " ORDER BY " + ",".join(order_parts)

	# Limit
	if limit > 0:
		sql += " LIMIT %d" % limit

	sql += ";"
	var rows := _exec_select(sql, bindings)

	# Propagate validation errors from sort check
	if rows.size() == 1 and rows[0] is Dictionary and rows[0].has("_error"):
		return rows

	if detail == "lean":
		return _build_lean_rows(rows)

	var results: Array = []
	for row in rows:
		var item := _build_item_dict(row)
		if detail == "full_stripped":
			item = _strip_empty(item)
		results.append(item)
	return results


# -- Hint helpers -------------------------------------------------------------

func find_hint(component: String, key_val: String) -> Dictionary:
	var rows := _exec_select(
		"SELECT * FROM items WHERE type='hint' AND component=? AND key=? LIMIT 1;",
		[component, key_val])
	if rows.is_empty():
		return {}
	return _build_item_dict(rows[0])


func query_hints(args: Dictionary, detail: String = "full") -> Array:
	var hints_only: bool = args.get("_hints_only", false)
	var conditions := PackedStringArray()
	if hints_only:
		conditions.append("type='hint'")
	else:
		conditions.append("type IN ('hint','insight')")
	var bindings: Array = []

	if args.has("component") and not str(args.component).is_empty():
		conditions.append("component=?")
		bindings.append(str(args.component))
	if args.has("key") and not str(args.key).is_empty():
		conditions.append("key=?")
		bindings.append(str(args.key))
	if args.get("promoted_only", false):
		conditions.append("status='promoted'")
	if args.has("min_retrievals"):
		conditions.append("retrieval_count>=?")
		bindings.append(int(args.min_retrievals))
	if args.has("min_research_cost"):
		conditions.append("research_cost>=?")
		bindings.append(int(args.min_research_cost))

	# Tag filtering (all tags must match)
	var tag_filter: Array = args.get("tags", [])
	for tag in tag_filter:
		conditions.append("EXISTS (SELECT 1 FROM item_tags WHERE item_tags.item_id=items.id AND item_tags.tag=?)")
		bindings.append(str(tag))

	var sql := "SELECT * FROM items WHERE " + " AND ".join(conditions)
	var limit: int = int(args.get("limit", 0))
	if limit > 0:
		sql += " LIMIT %d" % limit
	sql += ";"

	var rows := _exec_select(sql, bindings)

	if detail == "lean":
		return _build_lean_hint_rows(rows)

	var results: Array = []
	for row in rows:
		var item := _build_item_dict(row)
		if detail == "full_stripped":
			item = _strip_empty(item)
		results.append(item)
	return results


func bump_retrieval(id: String) -> void:
	var ts := Time.get_datetime_string_from_system(true)
	_exec("UPDATE items SET retrieval_count=retrieval_count+1, updated_at=? WHERE id=?;", [ts, id])


# -- Context ------------------------------------------------------------------

func query_context(tags: Array, include_types: Array = [], detail: String = "full") -> Array:
	if tags.is_empty():
		return []

	# Items that have ANY of the requested tags
	var tag_placeholders := PackedStringArray()
	var bindings: Array = []
	for tag in tags:
		tag_placeholders.append("?")
		bindings.append(str(tag))

	var sql := "SELECT DISTINCT items.* FROM items INNER JOIN item_tags ON item_tags.item_id=items.id WHERE item_tags.tag IN (%s)" % ",".join(tag_placeholders)

	if include_types.size() > 0:
		var type_placeholders := PackedStringArray()
		for t in include_types:
			type_placeholders.append("?")
			bindings.append(str(t))
		sql += " AND items.type IN (%s)" % ",".join(type_placeholders)

	sql += ";"
	var rows := _exec_select(sql, bindings)

	if detail == "lean":
		return _build_lean_rows(rows)

	var results: Array = []
	for row in rows:
		var item := _build_item_dict(row)
		if detail == "full_stripped":
			item = _strip_empty(item)
		results.append(item)
	return results


# -- Saved queries ------------------------------------------------------------

func save_query(name: String, query_dict: Dictionary) -> void:
	var json_str := JSON.stringify(query_dict)
	_exec("INSERT OR REPLACE INTO saved_queries (name, query_json) VALUES (?, ?);", [name, json_str])


func load_query(name: String) -> Dictionary:
	var rows := _exec_select("SELECT query_json FROM saved_queries WHERE name=?;", [name])
	if rows.is_empty():
		return {}
	var parsed = JSON.parse_string(str(rows[0].query_json))
	if parsed == null:
		return {}
	return parsed


func list_queries() -> Array:
	var rows := _exec_select("SELECT name, query_json FROM saved_queries;")
	var result: Array = []
	for row in rows:
		var parsed = JSON.parse_string(str(row.query_json))
		if parsed:
			result.append({"name": str(row.name), "query": parsed})
		else:
			result.append({"name": str(row.name), "query": {}})
	return result


# -- Attachments --------------------------------------------------------------

const MAX_ATTACHMENT_BYTES: int = 5 * 1024 * 1024  # 5 MB

func attach_file(item_id: String, filename: String, data: PackedByteArray, mime: String = "application/octet-stream", desc: String = "") -> Dictionary:
	var size_bytes: int = data.size()
	if size_bytes > MAX_ATTACHMENT_BYTES:
		push_error("DocketDB: attachment too large: %d bytes (max %d)" % [size_bytes, MAX_ATTACHMENT_BYTES])
		return {"error": "File too large: %d bytes (max 5 MB)" % size_bytes}
	var ts := Time.get_datetime_string_from_system(true)

	# Use raw query_with_bindings for BLOB support
	_db.query_with_bindings(
		"INSERT INTO attachments (item_id, filename, mime_type, size_bytes, data, created_at, description) VALUES (?, ?, ?, ?, ?, ?, ?);",
		[item_id, filename, mime, size_bytes, data, ts, desc])

	# Get the inserted row id
	var rows := _exec_select("SELECT last_insert_rowid() as lid;")
	var att_id: int = int(rows[0].lid) if rows.size() > 0 else 0

	return {
		"id": att_id,
		"item_id": item_id,
		"filename": filename,
		"mime_type": mime,
		"size_bytes": size_bytes,
		"created_at": ts,
		"description": desc,
	}


func get_attachment(att_id: int) -> Dictionary:
	_db.query_with_bindings("SELECT * FROM attachments WHERE id=?;", [att_id])
	var rows: Array = _db.query_result
	if rows.is_empty():
		return {}
	var row: Dictionary = rows[0]
	return {
		"id": int(row.get("id", 0)),
		"item_id": str(row.get("item_id", "")),
		"filename": str(row.get("filename", "")),
		"mime_type": str(row.get("mime_type", "")),
		"size_bytes": int(row.get("size_bytes", 0)),
		"data": row.get("data", PackedByteArray()),
		"created_at": str(row.get("created_at", "")),
		"description": str(row.get("description", "")),
	}


func list_attachments(item_id: String) -> Array:
	var rows := _exec_select(
		"SELECT id, item_id, filename, mime_type, size_bytes, created_at, description FROM attachments WHERE item_id=?;",
		[item_id])
	var result: Array = []
	for row in rows:
		result.append({
			"id": int(row.get("id", 0)),
			"item_id": str(row.get("item_id", "")),
			"filename": str(row.get("filename", "")),
			"mime_type": str(row.get("mime_type", "")),
			"size_bytes": int(row.get("size_bytes", 0)),
			"created_at": str(row.get("created_at", "")),
			"description": str(row.get("description", "")),
		})
	return result


func detach_file(att_id: int) -> void:
	_exec("DELETE FROM attachments WHERE id=?;", [att_id])


# -- Comments -----------------------------------------------------------------

func add_comment(item_id: String, author: String, text: String, parent_id: int = 0) -> Dictionary:
	var ts := Time.get_datetime_string_from_system(true)
	var clean_text: String = _normalize_text(text)
	_exec("INSERT INTO comments (item_id, parent_id, author, text, status, created_at) VALUES (?, ?, ?, ?, 'open', ?);",
		[item_id, parent_id, author, clean_text, ts])
	var rows := _exec_select("SELECT last_insert_rowid() as lid;")
	var cid: int = int(rows[0].lid) if rows.size() > 0 else 0
	if parent_id > 0:
		add_event(item_id, "comment_reply", author, text.substr(0, 80))
	else:
		add_event(item_id, "comment_added", author, text.substr(0, 80))
	return {"id": cid, "item_id": item_id, "parent_id": parent_id, "author": author, "text": text, "status": "open", "created_at": ts}


func list_comments(item_id: String) -> Array:
	var rows := _exec_select("SELECT * FROM comments WHERE item_id=? ORDER BY id ASC;", [item_id])
	var result: Array = []
	for row in rows:
		result.append(_build_comment_dict(row))
	return result


func resolve_comment(comment_id: int, resolution: String, resolved_by: String) -> Dictionary:
	if resolution not in ["accepted", "rejected"]:
		return {"error": "Resolution must be 'accepted' or 'rejected'"}
	var ts := Time.get_datetime_string_from_system(true)
	_exec("UPDATE comments SET status=?, resolved_at=?, resolved_by=? WHERE id=?;",
		[resolution, ts, resolved_by, comment_id])
	var rows := _exec_select("SELECT * FROM comments WHERE id=?;", [comment_id])
	if rows.is_empty():
		return {"error": "Comment not found"}
	var row: Dictionary = rows[0]
	var item_id: String = str(row.get("item_id", ""))
	add_event(item_id, "comment_" + resolution, resolved_by, str(row.get("text", "")).substr(0, 80))
	return _build_comment_dict(row)


func get_comment(comment_id: int) -> Dictionary:
	var rows := _exec_select("SELECT * FROM comments WHERE id=?;", [comment_id])
	if rows.is_empty():
		return {}
	return _build_comment_dict(rows[0])


func _build_comment_dict(row: Dictionary) -> Dictionary:
	return {
		"id": int(row.get("id", 0)),
		"item_id": str(row.get("item_id", "")),
		"parent_id": int(row.get("parent_id", 0)),
		"author": str(row.get("author", "")),
		"text": str(row.get("text", "")),
		"status": str(row.get("status", "open")),
		"created_at": str(row.get("created_at", "")),
		"resolved_at": str(row.get("resolved_at", "")),
		"resolved_by": str(row.get("resolved_by", "")),
	}


# -- Vault / Secret storage ---------------------------------------------------

func has_vault() -> bool:
	## True if this docket has a vault salt (i.e. secrets have been initialized).
	var rows := _exec_select("SELECT value FROM docket_meta WHERE key='vault_salt';")
	return rows.size() > 0 and not str(rows[0].value).is_empty()


func init_vault(key: PackedByteArray, salt: PackedByteArray) -> void:
	## Store vault salt and verification hash. Call once when creating first secret.
	set_meta_value("vault_salt", Marshalls.raw_to_base64(salt))
	set_meta_value("vault_verify", Marshalls.raw_to_base64(VaultCrypto.compute_verify_hash(key)))


func get_vault_salt() -> PackedByteArray:
	var b64 := get_meta_value("vault_salt", "")
	if b64.is_empty():
		return PackedByteArray()
	return Marshalls.base64_to_raw(b64)


func verify_vault(key: PackedByteArray) -> bool:
	## Check if the given derived key matches the stored verification hash.
	var stored_b64 := get_meta_value("vault_verify", "")
	if stored_b64.is_empty():
		return false
	var stored := Marshalls.base64_to_raw(stored_b64)
	var computed := VaultCrypto.compute_verify_hash(key)
	return stored == computed


func set_secret(handle: String, ciphertext: PackedByteArray, iv: PackedByteArray, mac: PackedByteArray, requires_2fa: bool = false) -> void:
	## Insert or update an encrypted secret.
	var now := Time.get_datetime_string_from_system(true)
	var flag := 1 if requires_2fa else 0
	var existing := _exec_select("SELECT handle FROM docket_secrets WHERE handle=?;", [handle])
	if existing.size() > 0:
		_exec("UPDATE docket_secrets SET ciphertext=?, iv=?, mac=?, updated_at=?, requires_2fa=? WHERE handle=?;",
			[ciphertext, iv, mac, now, flag, handle])
	else:
		_exec("INSERT INTO docket_secrets (handle, ciphertext, iv, mac, created_at, updated_at, requires_2fa) VALUES (?, ?, ?, ?, ?, ?, ?);",
			[handle, ciphertext, iv, mac, now, now, flag])


func get_secret_raw(handle: String) -> Dictionary:
	## Returns {ciphertext, iv, mac, requires_2fa} or empty dict if not found.
	var rows := _exec_select("SELECT ciphertext, iv, mac, requires_2fa FROM docket_secrets WHERE handle=?;", [handle])
	if rows.is_empty():
		return {}
	var row: Dictionary = rows[0]
	return {
		"ciphertext": row.ciphertext as PackedByteArray,
		"iv": row.iv as PackedByteArray,
		"mac": row.mac as PackedByteArray,
		"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
	}


func list_secrets() -> Array:
	## Returns [{handle, created_at, updated_at}] — no decryption.
	var rows := _exec_select("SELECT handle, created_at, updated_at FROM docket_secrets ORDER BY handle;")
	var result: Array = []
	for row in rows:
		result.append({
			"handle": str(row.handle),
			"created_at": str(row.created_at),
			"updated_at": str(row.updated_at),
		})
	return result


func delete_secret(handle: String) -> bool:
	var rows := _exec_select("SELECT handle FROM docket_secrets WHERE handle=?;", [handle])
	if rows.is_empty():
		return false
	_exec("DELETE FROM docket_secrets WHERE handle=?;", [handle])
	return true


func get_all_secrets_raw() -> Array:
	## Returns all secrets with raw encrypted data — for re-encryption on password change.
	var rows := _exec_select("SELECT handle, ciphertext, iv, mac, requires_2fa FROM docket_secrets;")
	var result: Array = []
	for row in rows:
		result.append({
			"handle": str(row.handle),
			"ciphertext": row.ciphertext as PackedByteArray,
			"iv": row.iv as PackedByteArray,
			"mac": row.mac as PackedByteArray,
			"requires_2fa": int(row.get("requires_2fa", 0)) == 1,
		})
	return result


func rotate_secret(handle: String, new_ct: PackedByteArray, new_iv: PackedByteArray, new_mac: PackedByteArray, rotated_by: String = "", requires_2fa: bool = false) -> void:
	## Archive current secret value into versions table, then store new value.
	var now := Time.get_datetime_string_from_system(true)
	# Get current value to archive
	var current := get_secret_raw(handle)
	if not current.is_empty():
		# Determine next version number
		var ver_rows := _exec_select("SELECT COALESCE(MAX(version), 0) AS max_ver FROM docket_secret_versions WHERE handle=?;", [handle])
		var next_ver: int = int(ver_rows[0].get("max_ver", 0)) + 1 if ver_rows.size() > 0 else 1
		_exec("INSERT INTO docket_secret_versions (handle, version, ciphertext, iv, mac, created_at, rotated_by) VALUES (?, ?, ?, ?, ?, ?, ?);",
			[handle, next_ver, current.ciphertext, current.iv, current.mac, now, rotated_by])
	# Store new value
	set_secret(handle, new_ct, new_iv, new_mac, requires_2fa)


func get_secret_versions(handle: String) -> Array:
	## Returns [{version, ciphertext, iv, mac, created_at, rotated_by}] ordered by version desc.
	var rows := _exec_select("SELECT version, ciphertext, iv, mac, created_at, rotated_by FROM docket_secret_versions WHERE handle=? ORDER BY version DESC;", [handle])
	var result: Array = []
	for row in rows:
		result.append({
			"version": int(row.version),
			"ciphertext": row.ciphertext as PackedByteArray,
			"iv": row.iv as PackedByteArray,
			"mac": row.mac as PackedByteArray,
			"created_at": str(row.created_at),
			"rotated_by": str(row.get("rotated_by", "")),
		})
	return result


func set_secret_2fa(handle: String, requires: bool) -> void:
	## Set the requires_2fa flag on a secret.
	_exec("UPDATE docket_secrets SET requires_2fa=? WHERE handle=?;", [1 if requires else 0, handle])


static func _has_column(col_rows: Array, col_name: String) -> bool:
	for cr in col_rows:
		if str(cr.get("name", "")) == col_name:
			return true
	return false


# -- Internal SQL helpers -----------------------------------------------------

func _exec(sql: String, bindings: Array = []) -> void:
	if bindings.is_empty():
		_db.query(sql)
	else:
		_db.query_with_bindings(sql, bindings)


func _exec_checked(sql: String, bindings: Array = []) -> String:
	## Like _exec but returns "" on success, error message on failure.
	var ok: bool
	if bindings.is_empty():
		ok = _db.query(sql)
	else:
		ok = _db.query_with_bindings(sql, bindings)
	if not ok:
		var msg: String = _db.error_message if _db.error_message else "SQL execution failed"
		push_error("DocketDB: %s — %s" % [msg, sql.left(120)])
		return msg
	return ""


func _exec_select(sql: String, bindings: Array = []) -> Array:
	var ok: bool
	if bindings.is_empty():
		ok = _db.query(sql)
	else:
		ok = _db.query_with_bindings(sql, bindings)
	if not ok:
		var msg: String = _db.error_message if _db.error_message else "SQL query failed"
		push_error("DocketDB: %s — %s" % [msg, sql.left(120)])
		return []
	return _db.query_result if _db.query_result else []


func _begin() -> void:
	_exec("BEGIN TRANSACTION;")


func _commit() -> void:
	_exec("COMMIT;")


static func _strip_empty(item: Dictionary) -> Dictionary:
	## Remove empty-string, zero, null, and empty-array values from an item dict.
	## Always keeps: id, type, status, title, created_at, updated_at.
	const KEEP_KEYS := ["id", "type", "status", "title", "created_at", "updated_at"]
	var result := {}
	for key in item:
		var val = item[key]
		if key in KEEP_KEYS:
			result[key] = val
			continue
		if val == null:
			continue
		if val is String and val.is_empty():
			continue
		if val is int and val == 0:
			continue
		if val is Array and val.is_empty():
			continue
		result[key] = val
	return result


static func _build_lean_rows(rows: Array) -> Array:
	## Return [{id, title}, ...] from raw SQL rows. Zero extra queries.
	var result: Array = []
	for row in rows:
		result.append({
			"id": str(row.get("id", "")),
			"title": str(row.get("title", "")),
		})
	return result


static func _build_lean_hint_rows(rows: Array) -> Array:
	## Return [{id, title, component, key, value}, ...] for hints. Zero extra queries.
	var result: Array = []
	for row in rows:
		result.append({
			"id": str(row.get("id", "")),
			"title": str(row.get("title", "")),
			"component": str(row.get("component", "")),
			"key": str(row.get("key", "")),
			"value": str(row.get("value", "")),
		})
	return result


func _build_item_dict(row: Dictionary) -> Dictionary:
	## Convert a raw SQLite row into the same Dictionary format as old JSON items.
	var item := {}
	var id: String = str(row.get("id", ""))

	# Copy all scalar fields
	item["id"] = id
	item["type"] = str(row.get("type", ""))
	item["status"] = str(row.get("status", ""))
	item["title"] = str(row.get("title", ""))
	item["description"] = str(row.get("description", ""))
	item["created_at"] = str(row.get("created_at", ""))
	item["updated_at"] = str(row.get("updated_at", ""))
	item["created_by"] = str(row.get("created_by", ""))
	item["assigned_to"] = str(row.get("assigned_to", ""))
	item["directed_to"] = str(row.get("directed_to", ""))
	item["priority"] = int(row.get("priority", 0))
	item["severity"] = int(row.get("severity", 0))
	item["retrieval_count"] = int(row.get("retrieval_count", 0))
	item["research_cost"] = int(row.get("research_cost", 0))
	item["quality"] = int(row.get("quality", 0))

	# Nullable type-specific text fields
	for col in ["resolution", "environment", "repro_steps", "assumed", "corrected",
				 "findings", "answer", "occurred_at", "detected_at", "reported_at",
				 "why_chain", "significant_events", "contributing_factors",
				 "value", "component", "key", "topic", "subtopic", "confidence",
				 "surprise", "surfaced_from", "blocked_by", "parent",
				 "test_setup", "test_steps", "expected_result", "last_reviewed",
				 "command", "usage", "prompt_text", "preconditions",
				 "summary", "article", "parameters",
				 "steps", "outcome"]:
		var val = row.get(col)
		if val != null:
			item[col] = str(val)
		else:
			item[col] = ""

	# Fetch tags
	var tag_rows := _exec_select("SELECT tag FROM item_tags WHERE item_id=?;", [id])
	var tags: Array = []
	for tag_row in tag_rows:
		tags.append(str(tag_row.tag))
	item["tags"] = tags

	# Fetch events
	item["events"] = get_events(id)

	# Fetch links
	item["links"] = get_links(id)

	return item
