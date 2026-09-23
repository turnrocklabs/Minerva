extends RefCounted
## The crash-safe part of a marketplace install: replacing
## user://plugins/<id>/ and its DB record, with a record on disk (txn.json in
## the operation's staging directory) saying how far the replacement got, so
## the next start of Minerva can undo it.
##
## Phases, each published (written, then renamed into place) before the step
## it describes:
##   staged     only scratch files exist; recovery deletes them.
##   replacing  the old install (if any) may be in <op>/previous, the new
##              files may be in place, and registration may have changed the
##              DB; recovery moves `previous` back (or removes a first install)
##              and restores the DB record saved in the record.
##   committed  registration was saved; recovery only deletes scratch.
##
## Directories appear only complete: an operation or lock is built under a
## ".new" name with its record inside, then renamed into place. An operation
## belongs to the process named in its record; recovery touches only
## operations whose owner has exited (asked of the OS, never judged by age)
## and claims each by renaming it, so two Minerva processes never recover the
## same one. Ambiguous state is kept and reported, never deleted. A lock per
## plugin keeps two processes from replacing it at once, and a plugin with an
## unresolved earlier operation is not installed again until that is undone.

const RECORD := "txn.json"
const OWNER := "owner.json"
const PREVIOUS := "previous"
const PHASE_STAGED := "staged"
const PHASE_REPLACING := "replacing"
const PHASE_COMMITTED := "committed"

var op_dir := ""
var plugin_id := ""
var had_previous := false
var db_before = null  # PluginDefinition.to_dict() of the record being replaced, or null
var _lock_dir := ""

# Distinguishes this process from an earlier one that had the same pid.
static var _session := "%d-%d" % [Time.get_unix_time_from_system() * 1000, randi()]


## A new operation directory under `staging_root`, recorded as staged.
## Returns null when it cannot be created.
static func begin(staging_root: String) -> RefCounted:
	var txn = load("res://Scripts/Services/Plugins/PluginInstallTransaction.gd").new()
	var name := "op_%d_%d" % [Time.get_ticks_usec(), randi()]
	txn.op_dir = staging_root.path_join(name + ".new")
	DirAccess.make_dir_recursive_absolute(txn.op_dir)
	if not txn.publish(PHASE_STAGED) or DirAccess.rename_absolute(txn.op_dir, staging_root.path_join(name)) != OK:
		_remove_tree(txn.op_dir)
		return null
	txn.op_dir = staging_root.path_join(name)
	return txn


func publish(phase: String) -> bool:
	return _publish_json(op_dir, RECORD, {"format": 1, "phase": phase, "id": plugin_id,
		"had_previous": had_previous, "db_before": db_before, "owner": owner()})


## Drop the record, leaving the directory for recovery to report rather than
## act on: used when a committed install cannot record that it committed.
func discard_record() -> void:
	DirAccess.remove_absolute(op_dir.path_join(RECORD))
	DirAccess.remove_absolute(op_dir.path_join(RECORD + ".tmp"))


## Take the per-plugin lock, then undo whatever an exited process, or an
## earlier failed rollback in this one, left for the plugin. Returns {} or a
## failure: plugin_busy (a live process holds the lock) or recovery_pending
## (the lock is released again).
func lock(staging_root: String, db) -> Dictionary:
	var taken := _take_lock(staging_root)
	if not taken.is_empty():
		return taken
	var pending := _resolve_pending(staging_root, db)
	if not pending.is_empty():
		unlock()
	return pending


func _take_lock(staging_root: String) -> Dictionary:
	var lock_dir := staging_root.path_join("lock_" + plugin_id)
	for attempt in 3:
		var building := lock_dir + ".new-%d-%d" % [OS.get_process_id(), randi()]
		DirAccess.make_dir_recursive_absolute(building)
		if not _publish_json(building, OWNER, owner()):
			_remove_tree(building)
			return {"ok": false, "error": "staging_failed", "detail": {"dir": building}}
		if DirAccess.rename_absolute(building, lock_dir) == OK:
			_lock_dir = lock_dir
			return {}
		_remove_tree(building)
		if not _take_over_stale(lock_dir):
			break
	return {"ok": false, "error": "plugin_busy", "detail": {"id": plugin_id}}


## Whether the per-plugin lock still names this process. Checked right before
## the destructive phase: a stale-lock takeover racing a third process can,
## rarely, hand the lock on (see _take_over_stale).
func holds_lock() -> bool:
	if _lock_dir.is_empty():
		return false
	var holder = _read_json(_lock_dir.path_join(OWNER))
	return holder is Dictionary and _is_self(holder)


func unlock() -> void:
	if not _lock_dir.is_empty() and holds_lock():
		_remove_tree(_lock_dir)
	_lock_dir = ""


## Undo a replacement that did not commit. Returns what was restored; files
## that could not be moved back stay in `previous` for the next attempt.
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


## Undo every operation whose owner process is gone, and delete locks they
## held and the loose scratch older clients left. Returns one entry per
## operation that needs a person: {dir, id, reason}.
static func recover_all(staging_root: String, db) -> Array:
	var problems := []
	var root := DirAccess.open(staging_root)
	if root == null:
		return problems
	root.include_hidden = true
	for file in root.get_files():
		DirAccess.remove_absolute(staging_root.path_join(file))
	for name in root.get_directories():
		var dir := staging_root.path_join(name)
		if name.begins_with("lock_"):
			var holder = _read_json(dir.path_join(OWNER))
			# A ".new" lock without its owner file is being created right now.
			if holder is Dictionary and not owner_alive(holder) or holder == null and not name.contains(".new-"):
				_remove_tree(dir)
			continue
		if not name.begins_with("op_"):
			_remove_tree(dir)  # an older client's extract dir; it never held a backup
			continue
		var record = _read_record(dir)
		if name.ends_with(".new"):
			if record is Dictionary and not owner_alive(record.get("owner", {})):
				_remove_tree(dir)  # created by a process that died before using it
			continue
		if record is Dictionary and owner_alive(record.get("owner", {})):
			continue
		# Claim it: a rename succeeds for exactly one process, which then
		# records itself as owner so others leave it alone.
		var claimed := staging_root.path_join(name.get_slice(".recovering-", 0) + ".recovering-%d" % OS.get_process_id())
		if claimed != dir and DirAccess.rename_absolute(dir, claimed) != OK:
			continue
		# Another process may have claimed it again before the rewrite landed.
		if record is Dictionary:
			record["owner"] = owner()
			if not _publish_json(claimed, RECORD, record):
				continue
			var mine = _read_record(claimed)
			if not (mine is Dictionary and _is_self(mine.get("owner", {}))):
				continue  # re-claimed by another process after the rename
		var problem := _recover(claimed, record, db)
		if problem.is_empty():
			_remove_tree(claimed)
		else:
			problems.append(problem)
	return problems


## With the lock held: recover what exited processes left, then any
## unresolved operation for `plugin_id`: this process's own (a rollback that
## failed earlier) is retried; a live other process's cannot be touched, so
## the install waits. Returns {} or recovery_pending while any of them stands.
func _resolve_pending(staging_root: String, db) -> Dictionary:
	for problem in recover_all(staging_root, db):
		if problem.id == plugin_id:
			return _pending(problem)
	var root := DirAccess.open(staging_root)
	for name in root.get_directories() if root != null else []:
		var dir := staging_root.path_join(name)
		var record = _read_record(dir)
		if dir == op_dir or not name.begins_with("op_") or name.ends_with(".new") or not record is Dictionary \
				or record.get("id") != plugin_id or record.get("phase") != PHASE_REPLACING:
			continue
		# This process holds the lock, so a live owner here kept a failed
		# rollback; its later recovery would undo whatever this install puts
		# in place.
		if not _is_self(record.get("owner", {})):
			return _pending({"dir": dir, "id": plugin_id, "reason":
				"another running Minerva has not yet restored an earlier install of '%s'" % plugin_id})
		var problem := _recover(dir, record, db)
		if not problem.is_empty():
			return _pending(problem)
		_remove_tree(dir)
	return {}


## Drop the unresolved operations for `plugin_id` that this process owns or
## whose owner has exited, because the plugin is being removed: undoing them
## later would bring it back.
## Nothing is dropped while this process is itself installing the plugin:
## that install's `previous` is still its only way back.
static func forget(staging_root: String, plugin_id: String) -> void:
	var holder = _read_json(staging_root.path_join("lock_" + plugin_id).path_join(OWNER))
	if holder is Dictionary and _is_self(holder):
		return
	var root := DirAccess.open(staging_root)
	for name in root.get_directories() if root != null else []:
		var dir := staging_root.path_join(name)
		var record = _read_record(dir)
		if name.begins_with("op_") and record is Dictionary and record.get("id") == plugin_id \
				and (_is_self(record.get("owner", {})) or not owner_alive(record.get("owner", {}))):
			_remove_tree(dir)


static func _pending(problem: Dictionary) -> Dictionary:
	return {"ok": false, "error": "recovery_pending", "detail": problem}


static func _recover(dir: String, record, db) -> Dictionary:
	var has_previous := DirAccess.dir_exists_absolute(dir.path_join(PREVIOUS))
	if not record is Dictionary:
		# Operations appear with their record, so a missing one means it was
		# removed on purpose (see discard_record) or lost; a backup is kept.
		return {} if not has_previous else {"dir": dir, "id": "", "reason":
			"an install left a plugin backup at %s without a readable record; move it back to user://plugins/<id>/ if that plugin is broken, otherwise delete it" % dir.path_join(PREVIOUS)}
	var phase := str(record.get("phase", ""))
	if phase != PHASE_REPLACING:
		return {}  # staged: nothing replaced; committed: the new install stands
	var id := str(record.get("id", ""))
	if not PluginDefinition._is_valid_id(id) or id == "data" or InternalPlugins.has(id):
		return {"dir": dir, "id": id, "reason": "an unfinished install recorded an invalid plugin id '%s'; its backup is kept at %s" % [id, dir]}
	var final_abs := ProjectSettings.globalize_path("user://plugins").path_join(id)
	if not _restore_files(final_abs, dir.path_join(PREVIOUS), bool(record.get("had_previous", false))):
		return {"dir": dir, "id": id, "reason": "could not move the previous version of '%s' back from %s" % [id, dir.path_join(PREVIOUS)]}
	if not restore_record(db, id, record.get("db_before")):
		return {"dir": dir, "id": id, "reason": "restored the files of '%s' but could not save its previous DB record" % id}
	return {}


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


## Rename a lock whose holder has exited out of the way. Returns whether
## taking the lock is worth another try.
static func _take_over_stale(lock_dir: String) -> bool:
	var holder = _read_json(lock_dir.path_join(OWNER))
	if holder is Dictionary and owner_alive(holder):
		return false
	var claimed := lock_dir + ".stale-%d-%d" % [OS.get_process_id(), randi()]
	if DirAccess.rename_absolute(lock_dir, claimed) != OK:
		return true  # it changed hands meanwhile; look again
	# The lock renamed may be a live one taken after the check above.
	var taken = _read_json(claimed.path_join(OWNER))
	if taken is Dictionary and owner_alive(taken):
		DirAccess.rename_absolute(claimed, lock_dir)
		return false
	_remove_tree(claimed)
	return true


## This process, as recorded: pid, executable file name, and session.
static func owner() -> Dictionary:
	return {"pid": OS.get_process_id(), "exe": OS.get_executable_path().get_file(), "session": _session}


static func _is_self(recorded: Dictionary) -> bool:
	return int(recorded.get("pid", 0)) == OS.get_process_id() and str(recorded.get("session", "")) == _session


## Whether the recorded owner is still running: its pid is alive and runs
## the same executable. When the OS cannot say, the owner counts as alive,
## so nothing is recovered out from under a running process.
static func owner_alive(recorded: Dictionary) -> bool:
	var pid := int(recorded.get("pid", 0))
	var exe := str(recorded.get("exe", ""))
	if pid <= 0:
		return false
	if pid == OS.get_process_id():
		return _is_self(recorded)  # else an earlier process with our pid
	var running := ""
	match OS.get_name():
		"Linux", "FreeBSD", "BSD":
			var proc := DirAccess.open("/proc/%d" % pid)
			if proc == null:
				return false
			# An executable replaced on disk reads as "<path> (deleted)".
			running = proc.read_link("exe").trim_suffix(" (deleted)").get_file()
			if running.is_empty():
				return true
		"macOS":
			var out := []
			var code := OS.execute("ps", ["-o", "comm=", "-p", str(pid)], out)
			if code == 1:
				return false  # no such process
			if code != 0 or out.is_empty():
				return true
			running = str(out[0]).strip_edges().get_file()
		"Windows":
			var out := []
			if OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"], out) != 0 or out.is_empty():
				return true
			var line := str(out[0]).strip_edges()
			if not line.begins_with("\""):
				return false  # "INFO: No tasks are running..."
			running = line.get_slice("\"", 1)
		_:
			return true
	return running.to_lower() == exe.to_lower()


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
