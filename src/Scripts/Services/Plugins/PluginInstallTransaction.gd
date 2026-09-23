extends RefCounted
## The crash-safe part of a marketplace install: replacing
## user://plugins/<id>/ and its DB record, with a record on disk (txn.json in
## the operation's staging directory) saying how far the replacement got, so
## a later pass can undo it.
##
## Phases, each published (written, then renamed into place) before the step
## it describes:
##   staged     only scratch files exist; recovery deletes them.
##   replacing  the old install (if any) may be in <op>/previous, the new
##              files may be in place, and registration may have changed the
##              DB; recovery moves `previous` back (or removes a first install)
##              and restores the DB record saved in the record.
##   committed  registration and this record were saved; recovery only
##              deletes scratch.
##
## Exclusion comes from OS file locks (ProcessFileLock: flock / LockFileEx),
## which the OS releases however a process ends:
##   staging.lock           held for each install's destructive section (from
##                          checking for unfinished work, through setting the
##                          old install aside, to commit or rollback) and for
##                          every recovery pass, so no two processes ever
##                          replace plugins or recover at the same time.
##   owners/<session>.lock  held by each Minerva process for its lifetime. An
##                          operation directory is named after its session, so
##                          its owner has exited exactly when that lock can be
##                          taken.
## Recovery therefore acts only on operations of exited processes, while no
## process can be replacing anything. A record that is missing or not fully
## valid never justifies deleting a backup: that operation is kept and
## reported.

const RECORD := "txn.json"
const PREVIOUS := "previous"
const STAGING_LOCK := "staging.lock"
const OWNERS := "owners"
const PHASE_STAGED := "staged"
const PHASE_REPLACING := "replacing"
const PHASE_COMMITTED := "committed"

var op_dir := ""
var plugin_id := ""
var had_previous := false
var db_before = null  # PluginDefinition.to_dict() of the record being replaced, or null
var _staging_lock = null  # ProcessFileLock while in the destructive section

# This process's session: distinct from every earlier process, even one that
# had the same pid. Digits and "-" only, so it can sit in a directory name.
static var _session := "%d-%d" % [Time.get_unix_time_from_system() * 1000, randi()]
static var _owner_lock = null  # ProcessFileLock on owners/<_session>.lock, held for life
static var _serial := 0


## A new operation directory, named after this process's session and
## recorded as staged. Returns null when it cannot be created or the
## platform has no ProcessFileLock (then nothing may be replaced).
static func begin(staging_root: String) -> RefCounted:
	if not _hold_owner_lock(staging_root):
		return null
	_serial += 1
	var txn = load("res://Scripts/Services/Plugins/PluginInstallTransaction.gd").new()
	txn.op_dir = staging_root.path_join("op_%s_%d" % [_session, _serial])
	DirAccess.make_dir_recursive_absolute(txn.op_dir)
	if not txn.publish(PHASE_STAGED):
		_remove_tree(txn.op_dir)
		return null
	return txn


func publish(phase: String) -> bool:
	return _publish_json(op_dir, RECORD, {"format": 1, "phase": phase, "id": plugin_id,
		"had_previous": had_previous, "db_before": db_before})


## Wait for the staging lock (another process may be replacing a plugin),
## then undo what exited processes left and check `plugin_id` has no
## unresolved earlier operation. Returns {} while holding the lock, or a
## failure without it: cancelled (op cancelled while waiting) or
## recovery_pending.
func enter(staging_root: String, db, op, tree: SceneTree) -> Dictionary:
	_staging_lock = ClassDB.instantiate("ProcessFileLock")
	while not _staging_lock.try_lock(staging_root.path_join(STAGING_LOCK)):
		if op.cancelled:
			_staging_lock = null
			return {"ok": false, "error": "cancelled", "detail": {}}
		await tree.process_frame
	# A cancel that arrived during the last wait still stops the install.
	if op.cancelled:
		leave()
		return {"ok": false, "error": "cancelled", "detail": {}}
	var pending := _resolve_pending(staging_root, db)
	if not pending.is_empty():
		leave()
	return pending


func leave() -> void:
	if _staging_lock != null:
		_staging_lock.unlock()
		_staging_lock = null


## Undo a replacement that did not commit. Returns what was restored; files
## that could not be moved back stay in `previous` for a later pass.
func roll_back(final_abs: String, db, previous_def) -> Dictionary:
	var files := _restore_files(final_abs, op_dir.path_join(PREVIOUS), had_previous)
	var record := restore_record(db, plugin_id, previous_def)
	return {"files_restored": files, "db_restored": record,
		"kept_at": "" if files else op_dir.path_join(PREVIOUS)}


## Put back the DB record `before` (a PluginDefinition, its dictionary, or
## null for a first install). Returns whether the result was saved.
static func restore_record(db, id: String, before) -> bool:
	if db == null:
		return true
	if before == null:
		if db.has_plugin(id):
			db.remove(id)
		return db.save()
	var def = before if not before is Dictionary else PluginDefinition.from_dict(before)
	return def != null and db.restore(def)


## One recovery pass at startup, if no other process holds the staging lock
## (if one does, the next install's pass recovers instead). Returns the
## operations that need a person: [{dir, id, reason}].
static func sweep(staging_root: String, db) -> Array:
	var lock = ClassDB.instantiate("ProcessFileLock")
	if lock == null:
		return []
	DirAccess.make_dir_recursive_absolute(staging_root)
	if not lock.try_lock(staging_root.path_join(STAGING_LOCK)):
		return []
	var problems := recover_all(staging_root, db)
	lock.unlock()
	return problems


## With the staging lock held: undo every operation whose owner has exited
## and delete scratch older clients left. Returns [{dir, id, reason}] for
## what cannot be undone.
static func recover_all(staging_root: String, db) -> Array:
	var problems := []
	var root := DirAccess.open(staging_root)
	if root == null:
		return problems
	root.include_hidden = true
	for file in root.get_files():
		if file != STAGING_LOCK:
			DirAccess.remove_absolute(staging_root.path_join(file))  # an older client's download
	for name in root.get_directories():
		var dir := staging_root.path_join(name)
		if name == OWNERS:
			continue
		if not name.begins_with("op_"):
			_remove_tree(dir)  # an older client's extract dir; it never held a backup
			continue
		if _owner_alive(staging_root, _session_of(name)):
			continue
		var problem := _recover(dir, _read_record(dir), db)
		if problem.is_empty():
			_remove_tree(dir)
		else:
			problems.append(problem)
	return problems


## With the staging lock held: recover what exited processes left, then
## check the live operations for `plugin_id`: this process's own (a rollback
## that failed earlier) is retried; another live process's cannot be touched,
## so the install waits. Returns {} or recovery_pending.
func _resolve_pending(staging_root: String, db) -> Dictionary:
	for problem in recover_all(staging_root, db):
		if problem.id == plugin_id:
			return _pending(problem)
	var root := DirAccess.open(staging_root)
	for name in root.get_directories() if root != null else []:
		var dir := staging_root.path_join(name)
		var record = _read_record(dir)
		if dir == op_dir or not name.begins_with("op_") or not _validate(record).is_empty() \
				or record.id != plugin_id or record.phase != PHASE_REPLACING:
			continue
		if _session_of(name) != _session:
			return _pending({"dir": dir, "id": plugin_id, "reason":
				"another running Minerva has not yet restored an earlier install of '%s'" % plugin_id})
		var problem := _recover(dir, record, db)
		if not problem.is_empty():
			return _pending(problem)
		_remove_tree(dir)
	return {}


## Drop the unresolved operations for `plugin_id` owned by this process or by
## exited ones, because the plugin is being removed and undoing them later
## would bring it back. Returns "" when done, else why the removal must wait
## (dropping nothing): an install holds the staging lock, a live other process
## owns one of them, or this build has no ProcessFileLock.
static func forget(staging_root: String, plugin_id: String) -> String:
	if not _has_operation_for(staging_root, plugin_id):
		return ""
	var lock = ClassDB.instantiate("ProcessFileLock")
	if lock == null:
		return "Plugin '%s' has an unfinished install, and this build cannot lock its install records; update Minerva's native libraries" % plugin_id
	if not lock.try_lock(staging_root.path_join(STAGING_LOCK)):
		return "An install is in progress; remove plugin '%s' once it finishes" % plugin_id
	var ok := true
	var root := DirAccess.open(staging_root)
	for name in root.get_directories() if root != null else []:
		var record = _read_record(staging_root.path_join(name))
		if not name.begins_with("op_") or not (record is Dictionary and record.get("id") == plugin_id):
			continue
		if _owner_alive(staging_root, _session_of(name)) and _session_of(name) != _session:
			ok = false
		else:
			_remove_tree(staging_root.path_join(name))
	lock.unlock()
	return "" if ok else "Another running Minerva has an unfinished install of plugin '%s'; remove it once that Minerva restores it or exits" % plugin_id


static func _has_operation_for(staging_root: String, plugin_id: String) -> bool:
	var root := DirAccess.open(staging_root)
	for name in root.get_directories() if root != null else []:
		var record = _read_record(staging_root.path_join(name))
		if name.begins_with("op_") and record is Dictionary and record.get("id") == plugin_id:
			return true
	return false


static func _pending(problem: Dictionary) -> Dictionary:
	return {"ok": false, "error": "recovery_pending", "detail": problem}


static func _recover(dir: String, record, db) -> Dictionary:
	var backup := dir.path_join(PREVIOUS)
	var invalid := _validate(record)
	if not invalid.is_empty():
		# Only a directory holding no backup can be discarded unexplained.
		if not DirAccess.dir_exists_absolute(backup):
			return {}
		return {"dir": dir, "id": str(record.get("id", "")) if record is Dictionary else "", "reason":
			"an unfinished install left a plugin backup at %s with a record that is %s; move it back to user://plugins/<id>/ if that plugin is broken, otherwise delete it" % [backup, invalid]}
	match record.phase:
		PHASE_STAGED:
			if DirAccess.dir_exists_absolute(backup):
				return {"dir": dir, "id": record.id, "reason": "a staged install holds an unexpected backup at %s" % backup}
			return {}
		PHASE_COMMITTED:
			return {}  # the new install stands; its backup is obsolete
	var final_abs := ProjectSettings.globalize_path("user://plugins").path_join(record.id)
	if not _restore_files(final_abs, backup, record.had_previous):
		return {"dir": dir, "id": record.id, "reason": "could not move the previous version of '%s' back from %s" % [record.id, backup]}
	if not restore_record(db, record.id, record.db_before):
		return {"dir": dir, "id": record.id, "reason": "restored the files of '%s' but could not save its previous DB record" % record.id}
	return {}


## Why `record` cannot be trusted, or "" when it is a complete record of a
## known phase whose plugin id and saved DB record agree.
static func _validate(record) -> String:
	if not record is Dictionary:
		return "missing or unreadable"
	if record.get("format") != 1 or not record.get("phase") in [PHASE_STAGED, PHASE_REPLACING, PHASE_COMMITTED]:
		return "of an unknown format or phase"
	if not record.get("id") is String or not record.get("had_previous") is bool:
		return "incomplete"
	var id: String = record.id
	if record.phase == PHASE_STAGED and id.is_empty():
		return ""
	if not PluginDefinition._is_valid_id(id) or id == "data" or InternalPlugins.has(id):
		return "for an invalid plugin id '%s'" % id
	var before = record.get("db_before")
	if before != null and not (before is Dictionary and before.get("id") == id):
		return "for '%s' but holding another plugin's DB record" % id
	return ""


## Remove what an unfinished install put at `final_abs` and move the old
## install back from `previous_abs`. Returns whether `final_abs` again holds
## what it held before the install.
static func _restore_files(final_abs: String, previous_abs: String, had_previous: bool) -> bool:
	if had_previous and not DirAccess.dir_exists_absolute(previous_abs):
		return true  # it was never moved aside
	_remove_tree(final_abs)
	if not had_previous:
		return not DirAccess.dir_exists_absolute(final_abs)
	return DirAccess.rename_absolute(previous_abs, final_abs) == OK


## Take this process's owner lock once; it is released only when the process
## ends. False when the platform has no ProcessFileLock.
static func _hold_owner_lock(staging_root: String) -> bool:
	if _owner_lock != null:
		return true
	var lock = ClassDB.instantiate("ProcessFileLock")
	if lock == null:
		return false
	DirAccess.make_dir_recursive_absolute(staging_root.path_join(OWNERS))
	if not lock.try_lock(staging_root.path_join(OWNERS).path_join(_session + ".lock")):
		return false
	_owner_lock = lock
	return true


## Whether the process whose session is `session` still runs, i.e. holds its
## owner lock. A lock that can be taken belongs to an exited process; with no
## ProcessFileLock the owner counts as alive. Owner files are never deleted:
## a process could be taking a lock on the file being removed.
static func _owner_alive(staging_root: String, session: String) -> bool:
	if session == _session:
		return true
	var probe = ClassDB.instantiate("ProcessFileLock")
	if probe == null:
		return true
	DirAccess.make_dir_recursive_absolute(staging_root.path_join(OWNERS))
	var path := staging_root.path_join(OWNERS).path_join(session + ".lock")
	if not probe.try_lock(path):
		return true
	probe.unlock()
	return false


## "op_<session>_<serial>" -> "<session>"; older clients' names give "".
static func _session_of(name: String) -> String:
	var parts := name.split("_")
	return parts[1] if parts.size() == 3 and parts[1].contains("-") else ""


static func _read_record(dir: String):
	var record = _read_json(dir.path_join(RECORD))
	return record if record is Dictionary else _read_json(dir.path_join(RECORD + ".tmp"))


static func _read_json(path: String):
	return JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null


## Write `value` to dir/name so a reader sees either the old or the new file.
static func _publish_json(dir: String, name: String, value) -> bool:
	var tmp := dir.path_join(name + ".tmp")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null or not f.store_string(JSON.stringify(value)):
		return false
	f.close()
	# Windows cannot rename over an existing file; readers fall back to the
	# .tmp copy when the file itself is missing.
	if OS.get_name() == "Windows":
		DirAccess.remove_absolute(dir.path_join(name))
	return DirAccess.rename_absolute(tmp, dir.path_join(name)) == OK


static func _remove_tree(path: String) -> void:
	load("res://Scripts/Services/Plugins/MarketplaceClient.gd")._rm_dir_recursive(path)
