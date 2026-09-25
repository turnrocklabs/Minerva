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
##              and restores the DB record saved in the record. A removal of
##              the plugin marks the record "removing" before it saves; then
##              the DB alone says whether the removal happened (_recover).
##              When the replaced plugin's data directory was saved to
##              <op>/previous-data before the new version was registered and
##              started ("data_saved"),
##              recovery puts that copy back too ("had_data" false: the plugin
##              had no data directory, so any the new version made is removed).
##   committed  registration and this record were saved; recovery only
##              deletes scratch.
##   pending_first_start
##              an update of a STOPPED plugin: registered and saved like a
##              commit, but <op>/previous and db_before are kept until the new
##              version's first successful start (PluginPendingUpgrade), since
##              only a start shows it works. Recovery keeps such an operation,
##              unless its plugin is no longer installed. The first start
##              saves the data and republishes the operation as `replacing`,
##              so a crash during it is rolled back like any replacement.
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
##
## This covers a process that crashes or is killed. Records and files are not
## synced to disk, so after a power loss the OS may not have kept them.

const AtomicFile := preload("res://Scripts/Services/Plugins/AtomicFile.gd")
const RECORD := "txn.json"
const PREVIOUS := "previous"
const PREVIOUS_DATA := "previous-data"
## Under the staging root: an operation's Docket journal, one
## "<op dir name>.json" = {id, journal, committed, reason} per operation that wrote
## a plugin's skills or knowledge (save_content). The journal holds the
## definition applied and the records it overwrote as they were (customised
## ones taken with consent, and pristine knowledge). The entry waits while the operation's
## directory exists (under whatever name adopt gave it); once that goes
## (committed, rolled back, or recovered),
## PluginManager.reconcile_recovered brings Docket in line from it.
const CONTENT_PENDING := "content-pending"
const STAGING_LOCK := "staging.lock"
const OWNERS := "owners"
const PHASE_STAGED := "staged"
const PHASE_REPLACING := "replacing"
const PHASE_COMMITTED := "committed"
const PHASE_PENDING := "pending_first_start"

var op_dir := ""
var plugin_id := ""
var had_previous := false
var db_before = null  # PluginDefinition.to_dict() of the record being replaced, or null
var data_saved := false  # the plugin's data directory is saved at <op>/previous-data
var had_data := false  # it existed when saved; if not, rolling back removes one
# Its CONTENT_PENDING entry's name: the directory's first name, kept when
# adopt renames the directory.
var content_name := ""
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
	txn.content_name = txn.op_dir.get_file()
	DirAccess.make_dir_recursive_absolute(txn.op_dir)
	if not txn.publish(PHASE_STAGED):
		_remove_tree(txn.op_dir)
		return null
	return txn


func publish(phase: String) -> bool:
	return _publish_json(op_dir, RECORD, {"format": 1, "phase": phase, "id": plugin_id,
		"had_previous": had_previous, "db_before": db_before, "data_saved": data_saved,
		"had_data": had_data, "content": content_name})


## Copy the plugin's data directory `data_abs` to <op>/previous-data, so a
## rollback can undo what the new version did to it, and publish that it is
## saved. Returns false, having published nothing new,
## when it cannot.
func save_data(data_abs: String) -> bool:
	had_data = DirAccess.dir_exists_absolute(data_abs)
	if had_data and not _copy_tree(data_abs, op_dir.path_join(PREVIOUS_DATA)):
		_remove_tree(op_dir.path_join(PREVIOUS_DATA))
		had_data = false
		return false
	data_saved = true
	if publish(PHASE_REPLACING):
		return true
	data_saved = false
	return false


## Wait for the staging lock (another process may be replacing a plugin),
## then undo what exited processes left and check `plugin_id` has no
## unresolved earlier operation. Returns {} while holding the lock, or a
## failure without it: cancelled (op cancelled while waiting),
## install_lock_failed (the lock file cannot be used at all), plugin_db_stale
## (another Minerva changed the plugin database since this one read it), or
## recovery_pending.
func enter(staging_root: String, db, op, tree: SceneTree) -> Dictionary:
	_staging_lock = ClassDB.instantiate("ProcessFileLock")
	var lock_path := staging_root.path_join(STAGING_LOCK)
	var status: int = _staging_lock.try_lock_status(lock_path)
	while status == ERR_BUSY and not op.cancelled:
		await tree.process_frame
		status = _staging_lock.try_lock_status(lock_path)
	if status != OK and status != ERR_BUSY:
		_staging_lock = null
		return {"ok": false, "error": "install_lock_failed", "detail": {"path": lock_path, "reason": error_string(status)}}
	# A cancel that arrived during the last wait still stops the install.
	if op.cancelled:
		leave()
		return {"ok": false, "error": "cancelled", "detail": {}}
	if db != null and db.has_method("is_stale") and db.is_stale():
		leave()
		return {"ok": false, "error": "plugin_db_stale", "detail": {}}
	var pending := _resolve_pending(staging_root, db)
	if not pending.is_empty():
		leave()
	return pending


func leave() -> void:
	if _staging_lock != null:
		_staging_lock.unlock()
		_staging_lock = null


## Undo a replacement that did not commit. Returns what was restored; files
## or data that could not be moved back stay in the operation directory
## (kept_at) for a later pass.
func roll_back(final_abs: String, db, previous_def) -> Dictionary:
	var files := _restore_files(final_abs, op_dir.path_join(PREVIOUS), had_previous)
	var data := not data_saved or _restore_data(plugin_id, op_dir.path_join(PREVIOUS_DATA), had_data)
	var record := restore_record(db, plugin_id, previous_def)
	return {"files_restored": files, "data_saved": data_saved, "data_restored": data,
		"db_restored": record, "kept_at": "" if files and data else op_dir}


## Put back the DB record `before` (a PluginDefinition, its dictionary, or
## null for a first install). Returns whether the result was saved.
static func restore_record(db, id: String, before) -> bool:
	if db == null:
		return true
	if before == null:
		# remove() saves; when it cannot, the record stays, in memory and on disk.
		return not db.has_plugin(id) or db.remove(id)
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
	if lock.try_lock_status(staging_root.path_join(STAGING_LOCK)) != OK:
		return []
	var problems := recover_all(staging_root, db)
	lock.unlock()
	return problems


## With the staging lock held: undo every operation whose owner has exited
## and delete scratch older clients left. Returns [{dir, id, reason}] for
## what cannot be undone. A committed operation's Docket journal is marked
## committed before its directory goes (see CONTENT_PENDING).
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
		if name == OWNERS or name == CONTENT_PENDING:
			continue
		if not name.begins_with("op_"):
			_remove_tree(dir)  # an older client's extract dir; it never held a backup
			continue
		if _owner_alive(staging_root, _session_of(name)):
			continue
		var record = _read_record(dir)
		if _awaiting_first_start(record):
			# Kept until the plugin's first start decides it, unless the plugin
			# was removed (a crash between saving a removal and end_removal).
			if db != null and not db.has_plugin(record.id):
				_remove_tree(dir)
			continue
		var committed: bool = _validate(record).is_empty() and record.phase == PHASE_COMMITTED
		if committed and not mark_committed(dir):
			problems.append({"dir": dir, "id": record.id, "reason": "the install of '%s' finished, but that could not be recorded for its skills and knowledge in %s; free disk space there" % [
				record.id, staging_root.path_join(CONTENT_PENDING)]})
			continue
		var problem := _recover(dir, record, db)
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
	for name in root.get_directories() if root != null else PackedStringArray():
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


## Start removing `plugin_id`: take the staging lock, so no install replaces
## anything until end_removal, and mark each unfinished replacement of it as
## being removed (see _recover), so that once the removal is saved no crash
## before end_removal can bring the plugin back. Returns {lock, marked} to
## pass to end_removal, or {error} when the removal must wait or cannot be
## made safe: an install holds the lock, the lock cannot be used, a live
## other process owns an unfinished install of it, or a mark cannot be saved.
static func begin_removal(staging_root: String, target_plugin_id: String) -> Dictionary:
	if not ClassDB.class_exists("ProcessFileLock"):
		# Operations another build left cannot be resolved without the lock.
		if not _operations_for(staging_root, target_plugin_id).is_empty():
			return {"error": "Plugin '%s' has an unfinished install that this build (without native file locks) cannot resolve" % target_plugin_id}
		return {"lock": null, "marked": []}
	var lock = ClassDB.instantiate("ProcessFileLock")
	DirAccess.make_dir_recursive_absolute(staging_root)
	var status: int = lock.try_lock_status(staging_root.path_join(STAGING_LOCK))
	if status == ERR_BUSY:
		return {"error": "An install is in progress; remove plugin '%s' once it finishes" % target_plugin_id}
	if status != OK:
		return {"error": "Cannot lock %s: %s" % [staging_root.path_join(STAGING_LOCK), error_string(status)]}
	var names := _operations_for(staging_root, target_plugin_id)
	for name in names:
		if _session_of(name) != _session and _owner_alive(staging_root, _session_of(name)):
			lock.unlock()
			return {"error": "Another running Minerva has an unfinished install of plugin '%s'; remove it once that Minerva restores it or exits" % target_plugin_id}
	var removal := {"lock": lock, "marked": []}
	for name in names:
		var dir := staging_root.path_join(name)
		var record = _read_record(dir)
		if not _validate(record).is_empty() or record.phase != PHASE_REPLACING:
			continue  # never restored automatically, so nothing to guard
		record["removing"] = true
		if not _publish_json(dir, RECORD, record):
			end_removal(staging_root, target_plugin_id, removal, false)
			return {"error": "Could not record the removal of plugin '%s' in %s" % [target_plugin_id, dir]}
		removal.marked.append(dir)
	return removal


## Finish a removal begun with begin_removal. When the plugin's removal was
## saved (`removed`) its unfinished installs are dropped; otherwise their
## marks are cleared so recovery restores them as before, and their backups
## stay.
static func end_removal(staging_root: String, target_plugin_id: String, removal: Dictionary, removed: bool) -> void:
	if removal.get("lock") == null:
		return
	if removed:
		for name in _operations_for(staging_root, target_plugin_id):
			_remove_tree(staging_root.path_join(name))
	else:
		for dir in removal.marked:
			var record = _read_record(dir)
			if record is Dictionary:
				record.erase("removing")
				_publish_json(dir, RECORD, record)  # if this fails, _recover reports the backup
	removal.lock.unlock()


static func _operations_for(staging_root: String, target_plugin_id: String) -> Array:
	var names := []
	var root := DirAccess.open(staging_root)
	for name in root.get_directories() if root != null else PackedStringArray():
		var record = _read_record(staging_root.path_join(name))
		if name.begins_with("op_") and record is Dictionary and record.get("id") == target_plugin_id:
			names.append(name)
	return names


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
	# Marked by begin_removal: if the plugin is gone from the DB the removal
	# was saved and the backup must not come back. If it is still there the
	# removal failed or a new install followed; which one cannot be told, so
	# the backup is kept and reported rather than restored over it.
	if record.get("removing", false):
		if db != null and not db.has_plugin(record.id):
			return {}
		return {"dir": dir, "id": record.id, "reason":
			"an install of '%s' was interrupted while the plugin was being removed; its previous version is kept at %s: move it back to user://plugins/%s/ if you want it, otherwise delete it or remove the plugin again" % [record.id, backup, record.id]}
	var final_abs := ProjectSettings.globalize_path("user://plugins").path_join(record.id)
	if not _restore_files(final_abs, backup, record.had_previous):
		return {"dir": dir, "id": record.id, "reason": "could not move the previous version of '%s' back from %s" % [record.id, backup]}
	if record.get("data_saved", false) and not _restore_data(record.id, dir.path_join(PREVIOUS_DATA), record.get("had_data", false)):
		return {"dir": dir, "id": record.id, "reason": "restored the files of '%s' but could not move its saved data back from %s" % [record.id, dir.path_join(PREVIOUS_DATA)]}
	if not restore_record(db, record.id, record.db_before):
		return {"dir": dir, "id": record.id, "reason": "restored the files of '%s' but could not save its previous DB record" % record.id}
	return {}


## Whether `record` is a valid update still waiting for its first start.
static func _awaiting_first_start(record) -> bool:
	return _validate(record).is_empty() and record.phase == PHASE_PENDING


## The update of `plugin_id` waiting for its first start, as a transaction to
## finish or roll back, or null. Its operation directory may belong to an
## earlier Minerva process.
static func pending_for(staging_root: String, plugin_id: String) -> RefCounted:
	var root := DirAccess.open(staging_root)
	for name in root.get_directories() if root != null else PackedStringArray():
		var dir := staging_root.path_join(name)
		var record = _read_record(dir)
		if name.begins_with("op_") and _awaiting_first_start(record) and record.id == plugin_id:
			var txn = load("res://Scripts/Services/Plugins/PluginInstallTransaction.gd").new()
			txn.op_dir = dir
			txn.plugin_id = plugin_id
			txn.had_previous = record.had_previous
			txn.db_before = record.db_before
			txn.content_name = _content_name(dir)
			return txn
	return null


## Whether an operation for `plugin_id` was left mid-replacement (a rollback
## that did not finish): its files, record or data may not be what the
## plugin last ran with, so nothing may start it until it is recovered.
static func has_unfinished(staging_root: String, plugin_id: String) -> bool:
	var root := DirAccess.open(staging_root)
	for name in root.get_directories() if root != null else PackedStringArray():
		var record = _read_record(staging_root.path_join(name))
		if name.begins_with("op_") and record is Dictionary and record.get("id") == plugin_id \
				and record.get("phase") == PHASE_REPLACING:
			return true
	return false


## With the staging lock held (try_enter), undo what is unfinished for
## `plugin_id` (see _resolve_pending). Returns {} or recovery_pending.
func recover_unfinished(staging_root: String, db) -> Dictionary:
	return _resolve_pending(staging_root, db)


## Make this process the owner of this operation, which another process may
## have created, by renaming its directory into this session. With the
## staging lock held, so no other process is touching it. Returns whether it
## is now this session's.
func adopt(staging_root: String) -> bool:
	# This session's lifetime owner lock first: without it another process
	# would take this process for exited and recover the operation under it.
	if not _hold_owner_lock(staging_root):
		return false
	if _session_of(op_dir.get_file()) == _session:
		return true
	_serial += 1
	var adopted := staging_root.path_join("op_%s_%d" % [_session, _serial])
	if DirAccess.rename_absolute(op_dir, adopted) != OK:
		return false
	op_dir = adopted
	return true


## Take the staging lock without waiting. Returns whether it is held (then
## call leave()); false while an install or recovery holds it.
func try_enter(staging_root: String) -> bool:
	_staging_lock = ClassDB.instantiate("ProcessFileLock")
	if _staging_lock != null and _staging_lock.try_lock_status(staging_root.path_join(STAGING_LOCK)) == OK:
		return true
	_staging_lock = null
	return false


## Why `record` cannot be trusted, or "" when it is a complete record of a
## known phase whose plugin id and saved DB record agree.
static func _validate(record) -> String:
	if not record is Dictionary:
		return "missing or unreadable"
	if record.get("format") != 1 or not record.get("phase") in [PHASE_STAGED, PHASE_REPLACING, PHASE_COMMITTED, PHASE_PENDING]:
		return "of an unknown format or phase"
	if not record.get("id") is String or not record.get("had_previous") is bool \
			or not record.get("removing", false) is bool or not record.get("data_saved", false) is bool \
			or not record.get("had_data", false) is bool:
		return "incomplete"
	var id: String = record.id
	if record.phase == PHASE_STAGED and id.is_empty():
		return ""
	if not PluginDefinition._is_valid_id(id) or id == "data":
		return "for an invalid plugin id '%s'" % id
	var before = record.get("db_before")
	if before != null and not (before is Dictionary and before.get("id") == id):
		return "for '%s' but holding another plugin's DB record" % id
	return ""


## Remove what an unfinished install put at `final_abs` and move the old
## install back from `previous_abs`. Returns whether `final_abs` again holds
## what it held before the install.
static func _restore_files(final_abs: String, previous_abs: String, previous_exists: bool) -> bool:
	if previous_exists and not DirAccess.dir_exists_absolute(previous_abs):
		return true  # it was never moved aside
	_remove_tree(final_abs)
	if not previous_exists:
		return not DirAccess.dir_exists_absolute(final_abs)
	return DirAccess.rename_absolute(previous_abs, final_abs) == OK


## The data directory of `id` again holds what was saved at `saved_abs`
## (nothing, when it had none). Returns whether it does.
static func _restore_data(id: String, saved_abs: String, saved_existed: bool) -> bool:
	var data_abs := data_directory(id)
	if saved_existed and not DirAccess.dir_exists_absolute(saved_abs):
		return DirAccess.dir_exists_absolute(data_abs)  # moved back by an earlier pass
	_remove_tree(data_abs)
	if not saved_existed:
		return not DirAccess.dir_exists_absolute(data_abs)
	return DirAccess.rename_absolute(saved_abs, data_abs) == OK


## Where plugin `id` keeps its data (PluginManager creates it on install).
static func data_directory(id: String) -> String:
	return ProjectSettings.globalize_path("user://plugins/data").path_join(id)


## Copy the tree at `from_abs` to `to_abs`: directories, hidden files, file
## modes, and symlinks as links (never followed). Returns false on any error.
static func _copy_tree(from_abs: String, to_abs: String) -> bool:
	var src := DirAccess.open(from_abs)
	if src == null or DirAccess.make_dir_recursive_absolute(to_abs) != OK:
		return false
	src.include_hidden = true
	for name in src.get_directories() + src.get_files():
		var from := from_abs.path_join(name)
		var to := to_abs.path_join(name)
		if src.is_link(name):
			if src.create_link(src.read_link(name), to) != OK:
				return false
		elif src.dir_exists(name):
			if not _copy_tree(from, to):
				return false
		else:
			if DirAccess.copy_absolute(from, to) != OK:
				return false
			var mode := FileAccess.get_unix_permissions(from)
			if mode != 0:
				FileAccess.set_unix_permissions(to, mode)
	return true


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
	# Only a lock actually taken proves the owner exited; busy or unusable
	# counts as alive.
	if probe.try_lock_status(staging_root.path_join(OWNERS).path_join(session + ".lock")) != OK:
		return true
	probe.unlock()
	return false


## "op_<session>_<serial>" -> "<session>"; older clients' names give "".
static func _session_of(name: String) -> String:
	var parts := name.split("_")
	return parts[1] if parts.size() == 3 and parts[1].contains("-") else ""


## The published record. A leftover txn.json.tmp is a write that never
## landed and is never read: publication is a single atomic replace.
static func _read_record(dir: String):
	return _read_json(dir.path_join(RECORD))


## The CONTENT_PENDING entry of the operation in `op_dir`.
static func content_path(op_dir: String) -> String:
	return op_dir.get_base_dir().path_join(CONTENT_PENDING).path_join(_content_name(op_dir) + ".json")


## The name of `op_dir`'s CONTENT_PENDING entry, as its record gives it.
static func _content_name(op_dir: String) -> String:
	var record = _read_record(op_dir)
	return str(record.get("content", op_dir.get_file())) if record is Dictionary else op_dir.get_file()


## Save `journal` as the Docket journal of plugin `id`'s operation in
## `op_dir`, before its first Docket write. Returns whether it was saved.
static func save_content(op_dir: String, id: String, journal: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(op_dir.get_base_dir().path_join(CONTENT_PENDING))
	return requeue_content(content_path(op_dir), id, journal)


## The journal save_content saved for `op_dir`, or {}.
static func content_journal(op_dir: String) -> Dictionary:
	var entry = _read_json(content_path(op_dir))
	return entry.journal if entry is Dictionary and entry.get("journal") is Dictionary else {}


## Record that the operation in `op_dir` committed, so its Docket content
## stays (a no-op when it wrote none). Until this succeeds its directory must
## stay, or the entry would be taken for a rollback. Returns whether it did.
static func mark_committed(op_dir: String) -> bool:
	var entry = _read_json(content_path(op_dir))
	if not entry is Dictionary:
		return not FileAccess.file_exists(content_path(op_dir))
	return entry.get("committed", false) == true or requeue_content(content_path(op_dir),
		str(entry.get("id", "")), entry.get("journal", {}) if entry.get("journal") is Dictionary else {}, true)


## Every entry whose operation has ended (no operation directory's record
## names it):
## [{path, id, journal, committed, reason}]. Remove each one's file with content_done
## once Docket follows it, or narrow it with requeue_content.
static func content_pending(staging_root: String) -> Array:
	var live := {}
	for name in DirAccess.get_directories_at(staging_root):
		if name.begins_with("op_"):
			live[_content_name(staging_root.path_join(name))] = true
	var pending := []
	var dir := staging_root.path_join(CONTENT_PENDING)
	for file in DirAccess.get_files_at(dir):
		if live.has(file.get_basename()):
			continue
		var entry = _read_json(dir.path_join(file))
		if entry is Dictionary and entry.get("id") is String:
			pending.append({"path": dir.path_join(file), "id": entry.id,
				"journal": entry.get("journal", {}) if entry.get("journal") is Dictionary else {},
				"committed": entry.get("committed", false) == true, "reason": str(entry.get("reason", ""))})
	return pending


## Queue, for reconcile_recovered, the cleanup of the Docket content of plugin
## `id`, removed while its content could not all be removed (`reason`), with
## `journal` (the paths it reached them at). Returns whether it was saved.
static func queue_cleanup(staging_root: String, id: String, journal: Dictionary, reason: String) -> bool:
	var dir := staging_root.path_join(CONTENT_PENDING)
	DirAccess.make_dir_recursive_absolute(dir)
	return requeue_content(dir.path_join("removed_%s_%d.json" % [id, Time.get_ticks_usec()]), id, journal, false, reason)


static func content_done(path: String) -> void:
	if not path.is_empty():
		DirAccess.remove_absolute(path)


## Write the CONTENT_PENDING entry at `path`, with why an earlier attempt
## to follow it did not finish (`reason`). Returns whether it was saved.
static func requeue_content(path: String, id: String, journal: Dictionary, committed := false,
		reason := "") -> bool:
	return AtomicFile.write(path, JSON.stringify({"id": id, "journal": journal, "committed": committed,
		"reason": reason}))


static func _read_json(path: String):
	return JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null


static func _publish_json(dir: String, name: String, value) -> bool:
	return AtomicFile.write(dir.path_join(name), JSON.stringify(value))


static func _remove_tree(path: String) -> void:
	load("res://Scripts/Services/Plugins/MarketplaceClient.gd")._rm_dir_recursive(path)
