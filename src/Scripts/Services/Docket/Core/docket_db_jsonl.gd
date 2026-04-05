extends DocketDB
class_name DocketDBJsonl
## DocketDB subclass that writes through to both SQLite (cache) and JSONL (canonical).
##
## JSONL is the source of truth; SQLite is a fast query cache.
## Every mutation first delegates to the parent DocketDB method (SQLite),
## then rewrites the entire JSONL file atomically.
##
## Opening flow:
##   1. If JSONL exists and cache is fresh → open cache via DocketDB.open()
##   2. If cache is stale or missing → rebuild from JSONL via JSONLCache
##   3. If neither exists → create new (fresh JSONL + SQLite cache)

var _jsonl_path: String
var _flush_depth: int = 0  # Reentrance guard to avoid redundant JSONL writes


# -- Lifecycle ----------------------------------------------------------------

static func open_jsonl(path: String) -> DocketDBJsonl:
	## Open a JSONL-backed docket. `path` is the .dct.jsonl file.
	## Returns an open DocketDBJsonl, or null on failure.
	var wrapper := DocketDBJsonl.new()
	wrapper._jsonl_path = path

	var cache_path := path + ".cache"

	if not FileAccess.file_exists(path):
		push_error("DocketDBJsonl: JSONL file not found: %s" % path)
		return null

	# Rebuild or reuse cache
	var cache_db: DocketDB
	if JSONLCache.is_cache_valid(path, cache_path):
		# Open cache directly — faster than rebuilding
		var temp_db := DocketDB.new()
		if temp_db.open(cache_path):
			cache_db = temp_db
		else:
			push_warning("DocketDBJsonl: stale cache, rebuilding from %s" % path)
			cache_db = JSONLCache.rebuild_cache(path, cache_path)
	else:
		cache_db = JSONLCache.rebuild_cache(path, cache_path)

	if cache_db == null:
		push_error("DocketDBJsonl: failed to open or rebuild cache for %s" % path)
		return null

	# Transfer the opened SQLite connection to our wrapper (which IS a DocketDB)
	wrapper._db = cache_db._db
	wrapper._path = cache_db._path
	wrapper._is_open = true

	# Detach the temp DocketDB so it doesn't close our connection
	cache_db._db = null
	cache_db._is_open = false

	return wrapper


static func create_new_jsonl(path: String) -> DocketDBJsonl:
	## Create a brand-new JSONL-backed docket. `path` is the .dct.jsonl file.
	## Writes an initial JSONL file (meta line only) and creates the SQLite cache.
	var wrapper := DocketDBJsonl.new()
	wrapper._jsonl_path = path

	var cache_path := path + ".cache"

	# Create the SQLite cache via parent's create_new
	var cache_db := DocketDB.create_new(cache_path)
	if cache_db == null:
		push_error("DocketDBJsonl: failed to create cache at %s" % cache_path)
		return null

	# Transfer ownership
	wrapper._db = cache_db._db
	wrapper._path = cache_db._path
	wrapper._is_open = true
	cache_db._db = null
	cache_db._is_open = false

	# Write initial JSONL
	wrapper._flush_jsonl()

	return wrapper


func get_jsonl_path() -> String:
	return _jsonl_path


func get_path() -> String:
	## Override: return the JSONL path (canonical), not the cache path.
	return _jsonl_path


func close() -> void:
	# Flush JSONL one last time before closing
	if _is_open and not _jsonl_path.is_empty():
		_flush_jsonl()
	super.close()


# -- JSONL write-through ------------------------------------------------------

func _flush_jsonl() -> void:
	## Serialize current DB state to JSONL and write atomically.
	## Uses _flush_depth to coalesce nested mutations (e.g. add_comment → add_event).
	## Acquires a .lock file before writing to prevent concurrent corruption.
	if _jsonl_path.is_empty():
		return
	if _flush_depth > 0:
		return  # We're inside a compound mutation — will flush when outermost returns

	var jsonl_text := JSONLSerializer.serialize_all(self)
	if jsonl_text.is_empty():
		push_warning("DocketDBJsonl: serializer produced empty output, skipping flush")
		return

	# Acquire advisory lock — tight scope around the file write only.
	# If we can't get the lock we log a warning but proceed: the SQLite
	# mutation already succeeded and losing the JSONL write would be worse
	# than a potential race on a very loaded system.
	var lock := FileLock.acquire(_jsonl_path)
	if lock == null:
		push_warning("DocketDBJsonl: could not acquire .lock for %s — writing anyway" % _jsonl_path)

	_atomic_write(_jsonl_path, jsonl_text)

	if lock != null:
		lock.release()

	# Update cache fingerprint so it stays valid
	var fingerprint := _file_fingerprint(_jsonl_path)
	if not fingerprint.is_empty():
		# Use super to avoid triggering another flush
		super.set_meta_value("jsonl_hash", fingerprint)


static func _file_fingerprint(path: String) -> String:
	## Lightweight freshness token: "size:mtime".
	if not FileAccess.file_exists(path):
		return ""
	var size := FileAccess.get_file_as_bytes(path).size()
	var mtime := FileAccess.get_modified_time(path)
	return "%d:%d" % [size, mtime]


static func _atomic_write(path: String, content: String) -> void:
	## Write content to a file atomically: write to .tmp, then rename.
	var tmp_path := path + ".tmp.%d" % OS.get_process_id()

	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_error("DocketDBJsonl: cannot open temp file %s for writing" % tmp_path)
		return
	f.store_string(content)
	f.flush()
	f.close()

	# Atomic rename
	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		push_error("DocketDBJsonl: rename %s → %s failed (error %d)" % [tmp_path, path, err])
		# Clean up temp file on failure
		DirAccess.remove_absolute(tmp_path)


# -- Overridden mutating methods ----------------------------------------------

# Each override: call super (SQLite), then flush JSONL.


func insert_item(id: String, item: Dictionary) -> String:
	var result := super.insert_item(id, item)
	if result.is_empty():  # success
		_flush_jsonl()
	return result


func update_item_fields(id: String, changes: Dictionary) -> void:
	super.update_item_fields(id, changes)
	_flush_jsonl()


func set_item_field(id: String, field: String, val) -> void:
	super.set_item_field(id, field, val)
	_flush_jsonl()


func delete_item(id: String) -> void:
	# delete_item internally calls delete_secret (which we override).
	_flush_depth += 1
	super.delete_item(id)
	_flush_depth -= 1
	_flush_jsonl()


func import_item_full(new_id: String, exported: Dictionary) -> void:
	super.import_item_full(new_id, exported)
	_flush_jsonl()


func rewrite_refs(old_qualified: String, new_qualified: String, old_bare_id: String, new_qualified_for_bare: String) -> int:
	var count := super.rewrite_refs(old_qualified, new_qualified, old_bare_id, new_qualified_for_bare)
	if count > 0:
		_flush_jsonl()
	return count


# -- ID generation (mutates counter) -----------------------------------------

func next_id() -> String:
	var result := super.next_id()
	_flush_jsonl()
	return result


# next_uuid7_id() does NOT mutate the counter — it's stateless. No override needed.


# -- Meta mutations -----------------------------------------------------------

func set_meta_value(meta_key: String, val: String) -> void:
	super.set_meta_value(meta_key, val)
	# Avoid infinite recursion: _flush_jsonl calls set_meta_value("jsonl_hash", ...)
	if meta_key == "jsonl_hash":
		return
	_flush_jsonl()


func set_id_prefix(prefix: String) -> void:
	# set_id_prefix calls set_meta_value internally.
	_flush_depth += 1
	super.set_id_prefix(prefix)
	_flush_depth -= 1
	_flush_jsonl()


func set_project_name(name: String) -> void:
	# set_project_name calls set_meta_value internally.
	_flush_depth += 1
	super.set_project_name(name)
	_flush_depth -= 1
	_flush_jsonl()


func set_counter(val: int) -> void:
	super.set_counter(val)
	_flush_jsonl()


# -- Events -------------------------------------------------------------------

func add_event(item_id: String, event_type: String, actor: String, note: String = "") -> void:
	super.add_event(item_id, event_type, actor, note)
	_flush_jsonl()


# -- Links --------------------------------------------------------------------

func add_link(from_id: String, to_id: String, relation: String) -> void:
	super.add_link(from_id, to_id, relation)
	_flush_jsonl()


# -- Attachments --------------------------------------------------------------

func attach_file(item_id: String, filename: String, data: PackedByteArray, mime: String = "application/octet-stream", desc: String = "") -> Dictionary:
	var result := super.attach_file(item_id, filename, data, mime, desc)
	if not result.has("error"):
		_flush_jsonl()
	return result


func detach_file(att_id: int) -> void:
	super.detach_file(att_id)
	_flush_jsonl()


# -- Comments -----------------------------------------------------------------

func add_comment(item_id: String, author: String, text: String, parent_id: int = 0) -> Dictionary:
	# add_comment internally calls add_event (which triggers our override + flush).
	# Use depth guard to coalesce into a single flush.
	_flush_depth += 1
	var result := super.add_comment(item_id, author, text, parent_id)
	_flush_depth -= 1
	_flush_jsonl()
	return result


func resolve_comment(comment_id: int, resolution: String, resolved_by: String) -> Dictionary:
	# resolve_comment internally calls add_event.
	_flush_depth += 1
	var result := super.resolve_comment(comment_id, resolution, resolved_by)
	_flush_depth -= 1
	_flush_jsonl()
	return result


# -- Saved queries ------------------------------------------------------------

func save_query(name: String, query_dict: Dictionary) -> void:
	super.save_query(name, query_dict)
	_flush_jsonl()


# -- Secrets ------------------------------------------------------------------

func init_vault(key: PackedByteArray, salt: PackedByteArray) -> void:
	# init_vault calls set_meta_value twice internally.
	_flush_depth += 1
	super.init_vault(key, salt)
	_flush_depth -= 1
	_flush_jsonl()


func set_secret(handle: String, ciphertext: PackedByteArray, iv: PackedByteArray, mac: PackedByteArray, requires_2fa: bool = false) -> void:
	super.set_secret(handle, ciphertext, iv, mac, requires_2fa)
	_flush_jsonl()


func delete_secret(handle: String) -> bool:
	var result := super.delete_secret(handle)
	if result:
		_flush_jsonl()
	return result


func rotate_secret(handle: String, new_ct: PackedByteArray, new_iv: PackedByteArray, new_mac: PackedByteArray, rotated_by: String = "", requires_2fa: bool = false) -> void:
	# rotate_secret internally calls set_secret (which we override).
	_flush_depth += 1
	super.rotate_secret(handle, new_ct, new_iv, new_mac, rotated_by, requires_2fa)
	_flush_depth -= 1
	_flush_jsonl()


func set_secret_2fa(handle: String, requires: bool) -> void:
	super.set_secret_2fa(handle, requires)
	_flush_jsonl()


# -- Retrieval bump -----------------------------------------------------------

func bump_retrieval(id: String) -> void:
	super.bump_retrieval(id)
	_flush_jsonl()


# -- Transition/error logs (NOT serialized to JSONL per spec) -----------------
# log_transition() and log_mcp_error() are intentionally NOT overridden.
# Per the JSONL format spec section 7, transition_log and mcp_error_log are
# ephemeral diagnostic data local to the SQLite cache.
