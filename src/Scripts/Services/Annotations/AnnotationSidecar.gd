class_name AnnotationSidecar
extends RefCounted
## Sidecar file I/O for the annotation substrate.
##
## Each document may have a companion sidecar at <document_path>.annotations.json.
## This class owns all read, write, delete, and path-resolution logic for that file.
##
## Design references: Annotation-substrate-design.md §7
## Policy:           Plugin-platform-policy.md §Paths
##
## Key behaviours:
##   - Atomic writes (tmp → flush → rename) per §7.3.
##   - Corrupt files backed up to .annotations.json.corrupt-<unix> on parse failure.
##   - write_sidecar() with an empty annotations[] deletes the sidecar instead of
##     writing an empty file (zero-annotation documents leave no sidecar on disk, §7.5).
##   - Payload paths are sidecar-relative by convention; helpers resolve/make-relative
##     those paths so project-export rewrites compose cleanly (§7.4, §9).
##
## JSON int↔float coercion note (Godot gotcha documented in §5):
##   Godot's JSON parser may return integer JSON values as int or float depending on
##   whether they have a decimal point.  Callers that need stable numeric types must
##   apply explicit int()/float() at their own boundaries.  This class makes no
##   assumptions about numeric types inside annotations[] — it round-trips values
##   verbatim.

## Current on-disk schema version.  Bump only on breaking changes.
const SUBSTRATE_VERSION: int = 1


# ── Path helpers ──────────────────────────────────────────────────────────────

## Returns the sidecar path for the given document path.
## Example: "/home/user/boards/board.minpcb" → "/home/user/boards/board.minpcb.annotations.json"
## The suffix ".annotations.json" is appended to the FULL filename including extension (§7.1).
static func sidecar_path_for(document_path: String) -> String:
	return document_path + ".annotations.json"


## Resolves a relative path that lives inside a sidecar payload against the
## sidecar's directory.  Absolute paths are returned unchanged (§7.4).
##
## Example:
##   sidecar_doc_path  = "/home/user/boards/board.minpcb"
##   relative_inside   = "textures/label.png"
##   → "/home/user/boards/textures/label.png"
static func resolve_relative_path(sidecar_doc_path: String, relative_inside: String) -> String:
	if relative_inside.is_absolute_path():
		return relative_inside
	var sidecar_dir := sidecar_doc_path.get_base_dir()
	return sidecar_dir.path_join(relative_inside)


## Returns a path relative to the sidecar directory — the inverse of
## resolve_relative_path().  Used by project-export pack hooks to rewrite
## absolute paths to package-relative form (§7.4, §9).
## If the absolute path does not share a prefix with the sidecar directory,
## it is returned unchanged (cross-drive or unrelated paths).
static func make_relative(sidecar_doc_path: String, absolute: String) -> String:
	var sidecar_dir := sidecar_doc_path.get_base_dir()
	# Ensure sidecar_dir ends with "/" for clean prefix matching.
	if not sidecar_dir.ends_with("/"):
		sidecar_dir += "/"
	if absolute.begins_with(sidecar_dir):
		return absolute.substr(sidecar_dir.length())
	# Path is outside the sidecar directory — return as-is (cross-mount, etc.).
	return absolute


# ── Existence / delete ────────────────────────────────────────────────────────

## Returns true if the sidecar file exists on disk.
static func has_sidecar(document_path: String) -> bool:
	return FileAccess.file_exists(sidecar_path_for(document_path))


## Deletes the sidecar file.  Returns OK if deleted or if it did not exist.
static func delete_sidecar(document_path: String) -> Error:
	var sp := sidecar_path_for(document_path)
	if not FileAccess.file_exists(sp):
		return OK
	var err := DirAccess.remove_absolute(sp)
	if err != OK:
		push_error(
			("AnnotationSidecar: delete_sidecar failed for %s (error %d)") % [sp, err]
		)
	return err


# ── Read ──────────────────────────────────────────────────────────────────────

## Reads and returns the parsed sidecar for the given document path.
##
## Returns a Dictionary with keys:
##   substrate_version  int
##   document           {path, kind, hash?}
##   annotations        Array   (preserves author order)
##   unknown_kinds      Array   (summary only)
##
## Returns an empty Dictionary {} when:
##   - No sidecar file exists (normal — zero-annotation document).
##   - The sidecar exists but cannot be parsed (corrupt). In that case the bad
##     file is moved to <sidecar>.corrupt-<unix_timestamp> before returning {}.
static func read_sidecar(document_path: String) -> Dictionary:
	var sp := sidecar_path_for(document_path)
	if not FileAccess.file_exists(sp):
		return {}

	var f := FileAccess.open(sp, FileAccess.READ)
	if f == null:
		push_error(
			("AnnotationSidecar: cannot open sidecar for reading: %s (error %d)") % [sp, FileAccess.get_open_error()]
		)
		return {}

	var raw := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(raw)
	if not parsed is Dictionary:
		_backup_corrupt(sp)
		return {}

	var data: Dictionary = parsed as Dictionary

	# Basic structural sanity — if top-level keys are wrong, treat as corrupt.
	if not data.has("annotations") or not data["annotations"] is Array:
		_backup_corrupt(sp)
		return {}

	return data


# ── Write ─────────────────────────────────────────────────────────────────────

## Atomically writes the sidecar to disk using the tmp-then-rename protocol (§7.3):
##   1. Serialize data to JSON.
##   2. Write to <sidecar>.tmp
##   3. flush() + close()
##   4. DirAccess.rename_absolute(tmp → sidecar)
##
## If data["annotations"] is absent or empty, the sidecar is DELETED rather
## than written as an empty file (zero-annotation documents have no sidecar, §7.5).
##
## The caller is responsible for populating data correctly.  Minimum valid shape:
##   {
##     "substrate_version": 1,
##     "document": {"path": "board.minpcb", "kind": "minpcb"},
##     "annotations": [...],
##     "unknown_kinds": []
##   }
## substrate_version is injected/overwritten here to ensure it is always correct.
##
## Returns OK on success, or an Error code on failure.
static func write_sidecar(document_path: String, data: Dictionary) -> Error:
	# Zero-annotation rule: delete the sidecar if no annotations remain.
	var anns: Variant = data.get("annotations", [])
	if not anns is Array or (anns as Array).is_empty():
		return delete_sidecar(document_path)

	# Always stamp the current schema version.
	var payload := data.duplicate(false)
	payload["substrate_version"] = SUBSTRATE_VERSION

	var json_text := JSON.stringify(payload, "\t")

	var sp := sidecar_path_for(document_path)
	var tmp_path := sp + ".tmp"

	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_error(
			("AnnotationSidecar: cannot open tmp file for writing: %s (error %d)") % [tmp_path, FileAccess.get_open_error()]
		)
		return FileAccess.get_open_error()

	f.store_string(json_text)
	f.flush()   # fsync equivalent — ensures data lands before rename
	f.close()

	# Atomic rename (POSIX: atomic within same filesystem; Windows: replace-existing)
	var err := DirAccess.rename_absolute(tmp_path, sp)
	if err != OK:
		push_error(
			("AnnotationSidecar: rename %s → %s failed (error %d)") % [tmp_path, sp, err]
		)
		# Clean up orphaned tmp on failure.
		DirAccess.remove_absolute(tmp_path)
		return err

	return OK


# ── Internal helpers ──────────────────────────────────────────────────────────

## Renames a corrupt sidecar to <path>.corrupt-<unix_seconds>.
## Logs a warning. Never throws — corruption recovery must be silent enough
## that the document still opens.
static func _backup_corrupt(sidecar_path: String) -> void:
	var unix := int(Time.get_unix_time_from_system())
	var backup := ("%s.corrupt-%d") % [sidecar_path, unix]
	var err := DirAccess.rename_absolute(sidecar_path, backup)
	if err == OK:
		push_warning(
			("AnnotationSidecar: corrupt sidecar backed up to %s") % backup
		)
	else:
		push_error(
			("AnnotationSidecar: could not back up corrupt sidecar %s → %s (error %d)") % [sidecar_path, backup, err]
		)
