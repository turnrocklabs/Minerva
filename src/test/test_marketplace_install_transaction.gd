extends SceneTree
## MarketplaceClient installs as a transaction, against real archives served
## over local HTTP and a real PluginDB:
##
##   - archives that are the wrong version, built for another machine, missing
##     their entrypoint, or unsafe to unpack (a link or a name escaping the
##     plugin directory) are refused, and the installed copy is untouched;
##   - a registration that fails after changing the DB puts the old files and
##     the old DB record back; one whose DB cannot be saved says the rollback
##     is incomplete rather than claiming the old install is back;
##   - recovery undoes an exited process's half-done replacement (files and
##     DB record, whether or not the old install had been set aside yet) and
##     half-done first install, keeps a committed one, keeps and reports every
##     backup whose record is missing or untrustworthy, leaves live processes'
##     operations alone, removes an older client's scratch, and does nothing
##     while another process holds the staging lock; an install waits for
##     that lock and for another live process's unrestored operation;
##   - removing a plugin over such a half-done update keeps the update's
##     backup when the removal cannot be saved, and once it is saved recovery
##     never brings the plugin back, even after a crash before cleanup;
##   - a plugin database that cannot be written keeps its previous complete
##     file, and a second process's stale snapshot can neither install nor
##     save over another's install;
##   - the OS releases a process's lock when that process dies (a real child
##     Godot process);
##   - frames keep ticking while a large archive is extracted and verified,
##     and the result names the installed id, version and platform check;
##   - cancelling while downloading, extracting, verifying, or waiting for the
##     user's decision leaves nothing installed and removes only that
##     operation's staging.
##
## Run: godot --headless --path src --script test/test_marketplace_install_transaction.gd

const MARKETPLACE_GD := "res://Scripts/Services/Plugins/MarketplaceClient.gd"
const PLUGINDB_GD := "res://Scripts/Services/Plugins/PluginDB.gd"
const OPERATION_GD := "res://Scripts/Services/Plugins/PluginInstallOperation.gd"
const TXN_GD := "res://Scripts/Services/Plugins/PluginInstallTransaction.gd"
const HELPERS_GD := "res://test/marketplace_test_helpers.gd"
const THROTTLED_PY := "res://test/fixtures/throttled_http_server.py"
const ID := "test_txn_plugin"
const FRESH_ID := "test_txn_fresh"
const PLUGIN_DIR := "user://plugins/" + ID
const STAGING := "user://plugins/.staging"
const BIG_BYTES := 96 * 1024 * 1024

## A PluginDB whose next update_definition applies the change and then
## reports failure: registration that fails after touching the DB.
class FailingDB extends "res://Scripts/Services/Plugins/PluginDB.gd":
	var fail_next := true

	func update_definition(def) -> bool:
		var applied := super(def)
		if fail_next:
			fail_next = false
			return false
		return applied


## A PluginDB that cannot write its file: every save reports failure.
class UnsavableDB extends "res://Scripts/Services/Plugins/PluginDB.gd":
	func save() -> bool:
		return false

	func restore(def) -> bool:
		super(def)
		return false


## A PluginDB whose next saves go as `outcomes` says, in order (false: fail
## as a write error would); later saves are real.
class FlakyDB extends "res://Scripts/Services/Plugins/PluginDB.gd":
	var outcomes: Array = []

	func _save() -> bool:
		if not outcomes.is_empty() and not outcomes.pop_front():
			return false
		return super()


## A PluginDB that copies the staging directory aside the moment a removal
## is saved: what a process that died right then would leave behind.
class SnapshotDB extends "res://Scripts/Services/Plugins/PluginDB.gd":
	var staging := ""
	var snapshot := ""
	## Whether the copy was taken; the test cannot simulate the crash without it.
	var copied := false

	func remove(plugin_id: String) -> bool:
		var removed := super(plugin_id)
		if removed:
			copied = load(HELPERS_GD).copy_tree(staging, snapshot)
		return removed


## An installer that asks the user before registering and waits until the
## question is closed, as PluginManager.collect_skill_consent's dialogs do
## (cancelling the operation closes them as a decline).
class WaitingInstaller extends RefCounted:
	var db

	func collect_skill_consent(_manifest_path: String, _auto_confirm: bool, op) -> Dictionary:
		await op.cancel_requested
		return {"collected": true, "seed": false}

	func has_plugin(id: String) -> bool:
		return db.has_plugin(id)

	func get_by_id(id: String):
		return db.get_by_id(id)

	func install(manifest_path: String, lane: String):
		return db.install(manifest_path, lane)


var _h
var _temp := ""
var _base_url := ""
var _fail := 0


func _init() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL: timed out")
		_h.teardown()
		quit(1))
	await process_frame
	_h = load(HELPERS_GD).new(self)
	# The locks below are the native extension's; without it every case would
	# fail for that one reason, so it is said first.
	if not ClassDB.class_exists("ProcessFileLock"):
		print("FAIL: the native ProcessFileLock class is not loaded")
		_finish(1)
		return
	_temp = "%s/test_install_txn_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	var packed: bool = _pack("v1", "1.0.0", 0) and _pack("v2", "2.0.0", 0) and _pack("big", "3.0.0", BIG_BYTES) \
		and _pack_crafted()
	var port: int = _h.random_high_port()
	_base_url = "http://127.0.0.1:%d/" % port
	if not packed or not await _h.start_http_server(_temp, port):
		print("FAIL: fixture setup")
		_finish(1)
		return

	await _test_refused_archives_leave_install_intact()
	await _test_failed_registration_restores_files_and_record()
	await _test_unsaved_registration_reports_incomplete_rollback()
	await _test_stale_database_writer_is_refused()
	await _test_recovery_after_a_crash()
	await _test_removal_is_never_undone_by_recovery()
	await _test_owner_lock_released_when_its_process_dies()
	await _test_frames_tick_during_extract_and_verify()
	await _test_cancel_at_every_cancellable_stage(port)
	_finish(1 if _fail else 0)


func _test_refused_archives_leave_install_intact() -> void:
	var db = await _installed_v1(load(PLUGINDB_GD).new())
	var client = _client()
	var entry := {"id": ID, "version": "2.1.0",
		"downloads": {client.resolve_platform_target(): _base_url + "v2.tar.gz"}}
	var result: Dictionary = await client.install_from_registry_entry(entry, db)
	_check(result.get("error", "") == "identity_mismatch", "a version other than the entry's is refused: %s" % result)
	for case in [["wrong_arch", "identity_mismatch"], ["no_binary", "identity_mismatch"],
			["escaping_link", "archive_unsafe"], ["dotdot", "archive_unsafe"],
			["huge_pax", "archive_unsafe"], ["global_path", "archive_unsafe"],
			["pax_escape", "archive_unsafe"], ["through_link", "archive_unsafe"],
			["raw_absolute", "archive_unsafe"],
			["link_climb", "archive_unsafe"], ["case_climb", "archive_unsafe"],
			["hard_to_symlink", "archive_unsafe"], ["junk_size", "archive_corrupt"],
			["backslash", "archive_unsafe"], ["empty_linkpath", "archive_unsafe"],
			["slash_file", "archive_unsafe"]]:
		result = await _client().install_from_url(_base_url + case[0] + ".tar.gz", db)
		_check(result.get("error", "") == case[1], "%s is refused as %s: %s" % [case[0], case[1], result])
	_check_v1_intact(db, "after every refused archive")


func _test_failed_registration_restores_files_and_record() -> void:
	var db = await _installed_v1(FailingDB.new())
	var before = db.get_by_id(ID)
	var result: Dictionary = await _client().install_from_url(_base_url + "v2.tar.gz", db)
	_check(result.get("error", "") == "update_definition_failed" and result.get("rollback", {}).get("files_restored") == true \
		and result.rollback.get("db_restored") == true, "registration failure rolls back completely: %s" % result)
	_check(db.get_by_id(ID) == before, "the DB holds the previous record again")
	_check_v1_intact(db, "after a failed registration")


func _test_unsaved_registration_reports_incomplete_rollback() -> void:
	await _installed_v1(load(PLUGINDB_GD).new())
	var db = UnsavableDB.new()
	var result: Dictionary = await _client().install_from_url(_base_url + "v2.tar.gz", db)
	_check(result.get("error", "") == "register_not_saved", "a registration that cannot be saved is not committed: %s" % result)
	_check(result.get("rollback", {}).get("files_restored") == true and result.rollback.get("db_restored") == false,
		"the rollback says the files are back but the DB record is not saved")
	_check("could not be restored" in load(MARKETPLACE_GD).format_install_error(result),
		"the error tells the user the database was not restored")
	# A real write failure: something else occupies the database's side file.
	var real = load(PLUGINDB_GD).new()
	var db_file := ProjectSettings.globalize_path("user://plugins/plugins.json")
	var before := FileAccess.get_file_as_string(db_file)
	DirAccess.make_dir_recursive_absolute(db_file + ".tmp")
	_check(not real.save() and FileAccess.get_file_as_string(db_file) == before,
		"a database save that cannot be written fails and leaves the previous file whole")
	_check(real.has_plugin(ID) and not real.remove(ID) and real.has_plugin(ID),
		"a removal that cannot be saved fails and is undone in memory")
	DirAccess.remove_absolute(db_file + ".tmp")
	# A first install whose commit cannot be saved, and whose rollback cannot
	# save the record's removal either: the record stays and is reported.
	real.remove(ID)
	_h.rm_dir_recursive(PLUGIN_DIR)
	var staging := ProjectSettings.globalize_path(STAGING)
	for name in DirAccess.get_directories_at(staging):
		if name != "owners":
			_h.rm_dir_recursive(staging.path_join(name))  # the operation kept above
	var staged_before := Array(DirAccess.get_directories_at(staging))
	var flaky = FlakyDB.new()
	flaky.outcomes = [true, false, false]  # registration, the commit's save, the rollback's removal
	result = await _client().install_from_url(_base_url + "v1.tar.gz", flaky)
	var kept := Array(DirAccess.get_directories_at(staging)).filter(func(n: String) -> bool: return not n in staged_before)
	var record = JSON.parse_string(FileAccess.get_file_as_string(staging.path_join(kept[0]).path_join("txn.json"))) \
		if kept.size() == 1 else null
	_check(result.get("rollback", {}).get("files_restored") == true and result.rollback.get("db_restored") == false
		and load(PLUGINDB_GD).new().has_plugin(ID), "a rollback whose removal is not saved says so, and the DB file still has it: %s" % result)
	_check(record is Dictionary and record.get("phase") == "replacing" and record.get("id") == ID,
		"its operation is kept for recovery: %s" % [kept])
	for name in kept:
		_h.rm_dir_recursive(staging.path_join(name))
	load(PLUGINDB_GD).new().remove(ID)


## Two Minerva processes, each with its own snapshot of plugins.json: once
## one installs, the other may neither install nor save over that.
func _test_stale_database_writer_is_refused() -> void:
	var first = load(PLUGINDB_GD).new()
	if first.has_plugin(ID):
		first.remove(ID)
	var second = load(PLUGINDB_GD).new()  # both now read the same file
	_h.rm_dir_recursive(PLUGIN_DIR)
	var installed: Dictionary = await _client().install_from_url(_base_url + "v1.tar.gz", first)
	var staging := ProjectSettings.globalize_path(STAGING)
	var staged_before := DirAccess.get_directories_at(staging)
	var refused: Dictionary = await _client().install_from_url(_base_url + "v2.tar.gz", second)
	_check(installed.get("ok", false) and refused.get("error", "") == "plugin_db_stale",
		"the second snapshot's install is refused: %s" % refused)
	_check(not second.save() and load(PLUGINDB_GD).new().get_by_id(ID).version == "1.0.0",
		"and it cannot save over the first's install")
	_check(DirAccess.get_directories_at(staging) == staged_before,
		"and the refused install left nothing staged: %s" % [DirAccess.get_directories_at(staging)])


func _test_recovery_after_a_crash() -> void:
	var db = await _installed_v1(load(PLUGINDB_GD).new())
	var staging := ProjectSettings.globalize_path(STAGING)
	var v1_record: Dictionary = db.get_by_id(ID).to_dict()
	# Operation directories are named op_<session>_<n>; a session nobody holds
	# the owner lock of belongs to an exited process.
	# Half-done: v1 set aside, v2 moved in and registered, then the process died.
	var crashed := _op(staging, "dead-1", {"phase": "replacing", "id": ID, "had_previous": true, "db_before": v1_record})
	DirAccess.rename_absolute(ProjectSettings.globalize_path(PLUGIN_DIR), crashed.path_join("previous"))
	_extract("v2", ProjectSettings.globalize_path(PLUGIN_DIR))
	db.update_definition(PluginDefinition.from_manifest(PLUGIN_DIR + "/manifest.json"))
	# Crashed before setting v1 aside: nothing moved, but the record stands.
	_op(staging, "dead-2", {"phase": "replacing", "id": ID, "had_previous": true, "db_before": v1_record})
	# A first install that crashed after moving its files in and registering.
	var fresh_dir := ProjectSettings.globalize_path("user://plugins/" + FRESH_ID)
	DirAccess.make_dir_recursive_absolute(fresh_dir)
	var fresh_manifest := _manifest("1.0.0")
	fresh_manifest["id"] = FRESH_ID
	_write(fresh_dir.path_join("manifest.json"), JSON.stringify(fresh_manifest))
	db.install(fresh_dir.path_join("manifest.json"))
	var fresh_op := _op(staging, "dead-3", {"phase": "replacing", "id": FRESH_ID, "had_previous": false, "db_before": null})
	# Its commit record never landed: a leftover side file must not count.
	_write(fresh_op.path_join("txn.json.tmp"), JSON.stringify(_record({"phase": "committed", "id": FRESH_ID,
		"had_previous": false, "db_before": null})))
	# Committed before the crash: its leftover backup must not come back.
	DirAccess.make_dir_recursive_absolute(_op(staging, "dead-4", {"phase": "committed", "id": ID,
		"had_previous": true, "db_before": null}).path_join("previous"))
	# Backups whose records cannot be trusted: none, empty, an unknown phase,
	# and another plugin's DB record. Each must be kept and reported.
	for bad in [null, {}, {"phase": "unknown", "id": ID, "had_previous": true, "db_before": null},
			{"phase": "replacing", "id": ID, "had_previous": true, "db_before": {"id": "someone_else"}}]:
		var dir := staging.path_join("op_dead-bad%d_1" % _serial_bad())
		DirAccess.make_dir_recursive_absolute(dir.path_join("previous"))
		if bad != null:
			_write(dir.path_join("txn.json"), JSON.stringify(bad if bad.is_empty() else _record(bad)))
	# This process's own live operation, and a live other process's (its owner
	# lock held here, as that process would).
	_op(staging, load(TXN_GD)._session, {"phase": "replacing", "id": FRESH_ID, "had_previous": false, "db_before": null}, 99)
	var other_process = ClassDB.instantiate("ProcessFileLock")
	DirAccess.make_dir_recursive_absolute(staging.path_join("owners"))
	other_process.try_lock(staging.path_join("owners/live-1.lock"))
	# It set v1 aside (a copy stands in here) before it stopped making progress.
	var live_other := _op(staging, "live-1", {"phase": "replacing", "id": ID, "had_previous": true, "db_before": v1_record})
	_extract("v1", live_other.path_join("previous"))
	_write(live_other.path_join("previous/sentinel.txt"), "v1 install")
	# Docket journals of operations that had written skills or knowledge.
	for op_name in ["op_dead-1_1", "op_dead-3_1", "op_dead-4_1", "op_live-1_1"]:
		load(TXN_GD).save_content(staging.path_join(op_name), FRESH_ID if op_name == "op_dead-3_1" else ID, {})
	# An older client's scratch.
	DirAccess.make_dir_recursive_absolute(staging.path_join("extract_123"))
	_write(staging.path_join("dl_123.tar.gz"), "partial")

	# While another process holds the staging lock, recovery does nothing.
	var busy = ClassDB.instantiate("ProcessFileLock")
	busy.try_lock(staging.path_join("staging.lock"))
	_check(load(MARKETPLACE_GD).sweep_staging(db).is_empty() and DirAccess.dir_exists_absolute(crashed),
		"no recovery while another process holds the staging lock")
	busy.unlock()

	var problems: Array = load(MARKETPLACE_GD).sweep_staging(db)
	_check_v1_intact(db, "after recovery undid the half-done replacement")
	_check(not DirAccess.dir_exists_absolute(fresh_dir) and not db.has_plugin(FRESH_ID),
		"a half-done first install is removed, files and DB record, despite an unlanded commit record")
	var left := Array(DirAccess.get_directories_at(staging))
	_check(not "op_dead-1_1" in left and not "op_dead-2_1" in left and not "op_dead-3_1" in left
		and not "op_dead-4_1" in left and not "extract_123" in left
		and not FileAccess.file_exists(staging.path_join("dl_123.tar.gz")), "recovered and legacy staging is gone: %s" % [left])
	_check("op_%s_99" % load(TXN_GD)._session in left and "op_live-1_1" in left, "live operations are left alone")
	# Docket follows each recovered operation's journal: undone replacements
	# are reconciled, the committed one kept; a live operation's waits.
	var queued := {}
	for entry in load(TXN_GD).content_pending(staging):
		queued[entry.path.get_file()] = [entry.id, entry.committed]
		load(TXN_GD).content_done(entry.path)
	_check(queued == {"op_dead-1_1.json": [ID, false], "op_dead-3_1.json": [FRESH_ID, false],
		"op_dead-4_1.json": [ID, true]},
		"every recovered operation's journal is released, committed or undone, and none of a live one: %s" % [queued])
	_check(left.filter(func(n: String) -> bool: return n.begins_with("op_dead-bad")).size() == 4 and problems.size() == 4,
		"every backup with an untrustworthy record is kept and reported: %s" % [problems])
	# A person acts on those reports; until then they would hold back installs of ID.
	for name in left.filter(func(n: String) -> bool: return n.begins_with("op_dead-bad")):
		_h.rm_dir_recursive(staging.path_join(name))

	# The live other process's unrestored operation holds back installs of ID;
	# once it exits, the next install's recovery pass puts v1 back first.
	var blocked: Dictionary = await _client().install_from_url(_base_url + "v2.tar.gz", db)
	_check(blocked.get("error", "") == "recovery_pending" and DirAccess.dir_exists_absolute(live_other),
		"an install waits for another live process's unrestored operation: %s" % blocked)
	other_process.unlock()
	# An install waits while another process holds the staging lock.
	busy.try_lock(staging.path_join("staging.lock"))
	var op = load(OPERATION_GD).new()
	var box := _run(func(): return await _client().install_from_url(_base_url + "v2.tar.gz", db, false, op))
	await _wait(func() -> bool: return op.stage == "wait")
	await create_timer(0.5).timeout
	_check(op.stage == "wait" and box[0] == null, "an install waits for the staging lock")
	busy.unlock()
	await _wait(func() -> bool: return box[0] != null)
	# That operation had written skills or knowledge: until their repair is
	# done (this installer, a bare PluginDB, cannot run it), installs of ID wait.
	_check(box[0] != null and box[0].get("error", "") == "content_repair_pending" and db.get_by_id(ID).version == "1.0.0"
		and not DirAccess.dir_exists_absolute(live_other),
		"after the other process exits its operation is undone, and an install waits for its Docket repair: %s" % [box[0]])
	load(TXN_GD).content_done(load(TXN_GD).content_path(live_other))
	var resumed: Dictionary = await _client().install_from_url(_base_url + "v2.tar.gz", db)
	_check(resumed.get("ok", false) and resumed.get("version") == "2.0.0" and db.get_by_id(ID).version == "2.0.0",
		"once that repair is done, v2 installs over v1: %s" % [resumed])
	for name in DirAccess.get_directories_at(staging):
		if name != "owners":
			_h.rm_dir_recursive(staging.path_join(name))


## PluginManager.remove_plugin over an exited process's half-done update of
## the plugin: a removal that cannot be saved keeps that update's backup for
## recovery, and a saved removal is not undone by recovery even when the
## process dies before dropping the update's journal.
func _test_removal_is_never_undone_by_recovery() -> void:
	var pm = await _h.bootstrap_plugin_manager()
	if pm == null:
		_check(false, "a PluginManager starts")
		return
	var staging := ProjectSettings.globalize_path(STAGING)
	var db = await _installed_v1(load(PLUGINDB_GD).new())
	var crashed := _half_done_update(db, staging, 1)
	var failing = FlakyDB.new()
	failing.outcomes = [false]
	pm._db = failing
	var refused: Dictionary = await pm.remove_plugin(ID)
	_check(refused.has("error") and load(PLUGINDB_GD).new().has_plugin(ID) and DirAccess.dir_exists_absolute(crashed.path_join("previous")),
		"a removal that cannot be saved keeps the plugin and the backup: %s" % refused)
	db = load(PLUGINDB_GD).new()
	var problems: Array = load(MARKETPLACE_GD).sweep_staging(db)
	_check(problems.is_empty(), "the failed removal left nothing recovery must report: %s" % [problems])
	_check_v1_intact(db, "when recovery runs after the failed removal")

	crashed = _half_done_update(db, staging, 2)
	var snapshot := _temp.path_join("staging_at_removal")
	var snapped := snapshot.path_join(crashed.get_file())
	if not _check(_holds_half_done_update(crashed), "the half-done update is in staging before the removal"):
		pm.queue_free()
		return
	var removing = SnapshotDB.new()
	removing.staging = staging
	removing.snapshot = snapshot
	pm._db = removing
	var removed: Dictionary = await pm.remove_plugin(ID)
	_check(removed.get("ok", false) and not DirAccess.dir_exists_absolute(crashed), "a saved removal drops the unfinished update: %s" % removed)
	if not _check(removing.copied and _holds_half_done_update(snapped),
			"the staging was captured, journal and backup included, as the removal was saved"):
		pm.queue_free()
		return
	# The process died right after saving the removal: its staging is as it was then.
	if not _check(_h.copy_tree(snapped, crashed) and _holds_half_done_update(crashed),
			"the crash leaves that half-done update back in staging"):
		pm.queue_free()
		return
	db = load(PLUGINDB_GD).new()
	problems = load(MARKETPLACE_GD).sweep_staging(db)
	_check(problems.is_empty() and not db.has_plugin(ID) and not DirAccess.dir_exists_absolute(crashed)
		and not FileAccess.file_exists(PLUGIN_DIR + "/sentinel.txt"),
		"recovery after that crash does not bring the removed plugin back: %s" % [problems])
	pm.queue_free()
	_h.rm_dir_recursive(PLUGIN_DIR)
	_h.rm_dir_recursive(snapshot)


## Whether `dir` is a half-done update's operation directory: its journal and
## the set-aside previous version.
func _holds_half_done_update(dir: String) -> bool:
	return FileAccess.file_exists(dir.path_join("txn.json")) and DirAccess.dir_exists_absolute(dir.path_join("previous"))


## An exited process's update of v1 to v2, stopped after v1 was set aside and
## v2 moved in and registered. Returns its operation directory.
func _half_done_update(db, staging: String, serial: int) -> String:
	var dir := _op(staging, "dead-rm", {"phase": "replacing", "id": ID, "had_previous": true,
		"db_before": db.get_by_id(ID).to_dict()}, serial)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(PLUGIN_DIR), dir.path_join("previous"))
	_extract("v2", ProjectSettings.globalize_path(PLUGIN_DIR))
	db.update_definition(PluginDefinition.from_manifest(PLUGIN_DIR + "/manifest.json"))
	return dir


var _bad_serial := 0
func _serial_bad() -> int:
	_bad_serial += 1
	return _bad_serial


func _record(fields: Dictionary) -> Dictionary:
	var record := {"format": 1}
	record.merge(fields)
	return record


## An operation directory for `session` holding a record with `fields`.
func _op(staging: String, session: String, fields: Dictionary, serial: int = 1) -> String:
	var dir := staging.path_join("op_%s_%d" % [session, serial])
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join("txn.json"), JSON.stringify(_record(fields)))
	return dir


## The kernel lock that ownership rests on, across real processes: a child
## Godot holding it makes it busy here; once the child is killed it can be
## taken.
func _test_owner_lock_released_when_its_process_dies() -> void:
	var lock_path := ProjectSettings.globalize_path(STAGING).path_join("owners/child-test.lock")
	var marker := _temp.path_join("child_locked")
	DirAccess.make_dir_recursive_absolute(lock_path.get_base_dir())
	var child := OS.create_process(OS.get_executable_path(), ["--headless", "--path",
		ProjectSettings.globalize_path("res://"), "--script", "res://test/fixtures/hold_process_lock.gd", "--", lock_path, marker])
	await _wait(func() -> bool: return FileAccess.file_exists(marker))
	var probe = ClassDB.instantiate("ProcessFileLock")
	_check(child > 0 and FileAccess.file_exists(marker) and probe.try_lock_status(lock_path) == ERR_BUSY,
		"a lock held by another live process is busy here")
	if child > 0:
		OS.kill(child)
	var give_up := Time.get_ticks_msec() + 10000
	var status: int = probe.try_lock_status(lock_path)
	while status != OK and Time.get_ticks_msec() < give_up:
		await create_timer(0.1).timeout
		status = probe.try_lock_status(lock_path)
	_check(status == OK, "the OS releases it when that process dies")
	probe.unlock()
	DirAccess.remove_absolute(lock_path)


func _test_frames_tick_during_extract_and_verify() -> void:
	var op = load(OPERATION_GD).new()
	var frames := [0]
	var count := func() -> void: frames[0] += 1
	process_frame.connect(count)
	var seen := {}
	op.stage_changed.connect(func(stage: String) -> void: seen[stage] = frames[0])
	var result: Dictionary = await _client().install_from_url(_base_url + "big.tar.gz", null, false, op)
	process_frame.disconnect(count)
	_check(result.get("plugin_id", "") == ID and result.get("version", "") == "3.0.0" \
		and result.get("platform_verified") == false,
		"the result names the installed id, version, and an unverifiable placeholder binary: %s" % result)
	var ticked: int = seen.get("register", 0) - seen.get("extract", 0)
	# Blocking the main thread for this long would leave a frame or two.
	_check(seen.has("verify") and ticked >= 10, "%d frames ticked while %d MiB were extracted and verified" % [ticked, BIG_BYTES >> 20])
	_h.rm_dir_recursive(PLUGIN_DIR)


func _test_cancel_at_every_cancellable_stage(port: int) -> void:
	var sibling := ProjectSettings.globalize_path(STAGING).path_join("op_sibling")
	DirAccess.make_dir_recursive_absolute(sibling)
	_write(sibling.path_join("keep.txt"), "another install's scratch")
	var server := OS.create_process(_h.python_cmd(), [ProjectSettings.globalize_path(THROTTLED_PY),
		_temp.path_join("big.tar.gz"), str(port + 1), "--rate", "1048576"])
	var slow_url := "http://127.0.0.1:%d/big.tar.gz" % (port + 1)
	for i in 50:
		if _h.port_open(port + 1):
			break
		await create_timer(0.1).timeout
	for stage in ["download", "extract", "verify"]:
		var op = load(OPERATION_GD).new()
		var url := slow_url if stage == "download" else _base_url + "big.tar.gz"
		# Extract and verify are cancelled the moment they begin, before the
		# worker could finish them.
		if stage != "download":
			op.stage_changed.connect(func(entered: String) -> void:
				if entered == stage:
					op.cancel())
		var box := _run(func(): return await _client().install_from_url(url, null, false, op))
		if stage == "download":
			await _wait(func() -> bool: return op.done >= 65536)
			op.cancel()
		await _wait(func() -> bool: return box[0] != null)
		_check(box[0] != null and box[0].get("error", "") == "cancelled" and not DirAccess.dir_exists_absolute(op.staging_dir)
			and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(PLUGIN_DIR)),
			"cancelled while %s: nothing installed, its staging gone: %s" % [stage, box[0]])
	if server > 0:
		OS.kill(server)

	var installer := WaitingInstaller.new()
	installer.db = load(PLUGINDB_GD).new()
	if installer.db.has_plugin(ID):
		installer.db.remove(ID)
	var op = load(OPERATION_GD).new()
	var box := _run(func(): return await _client().install_from_url(_base_url + "v1.tar.gz", installer, false, op))
	await _wait(func() -> bool: return op.stage == "confirm")
	op.cancel()
	await _wait(func() -> bool: return box[0] != null)
	_check(box[0] != null and box[0].get("error", "") == "cancelled" and not installer.db.has_plugin(ID)
		and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(PLUGIN_DIR)),
		"cancelled while waiting for the user's decision: nothing installed: %s" % [box[0]])
	_check(FileAccess.file_exists(sibling.path_join("keep.txt")), "another operation's staging is untouched")
	_h.rm_dir_recursive(sibling)


## Start `call` (a coroutine) and return a box its result lands in.
func _run(call: Callable) -> Array:
	var box := [null]
	(func() -> void: box[0] = await call.call()).call()
	return box


## Wait for `ready` to hold, at most 30 s.
func _wait(ready: Callable) -> void:
	var give_up := Time.get_ticks_msec() + 30000
	while not ready.call() and Time.get_ticks_msec() < give_up:
		await process_frame


## Install v1 through `db` (fresh), with a sentinel file beside it.
func _installed_v1(db):
	if db.has_plugin(ID):
		db.remove(ID)
	_h.rm_dir_recursive(PLUGIN_DIR)
	var result: Dictionary = await _client().install_from_url(_base_url + "v1.tar.gz", db)
	if not result.get("ok", false):
		print("FAIL: installing v1: %s" % result)
		_fail += 1
	_write(ProjectSettings.globalize_path(PLUGIN_DIR + "/sentinel.txt"), "v1 install")
	return db


func _check_v1_intact(db, when: String) -> void:
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(PLUGIN_DIR + "/manifest.json"))
	var files_ok: bool = manifest is Dictionary and manifest.get("version") == "1.0.0" \
		and FileAccess.file_exists(PLUGIN_DIR + "/sentinel.txt")
	var record = db.get_by_id(ID)
	_check(files_ok and record != null and record.version == "1.0.0", "v1 files and DB record intact %s" % when)


func _manifest(version: String, entrypoint: String = "./test-binary") -> Dictionary:
	return {"id": ID, "name": "Transaction Test Plugin", "version": version, "host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": entrypoint, "args": []},
		"tools": [], "ui": {"panels": [], "ipc_messages": []},
		"permissions": {"host_capabilities": []}, "autostart": false, "auto_reload": false}


## Archive `<name>.tar.gz` in the temp dir: manifest, placeholder binary,
## optional random payload, SHA256SUMS.
func _pack(name: String, version: String, payload_bytes: int) -> bool:
	var dir := _temp.path_join(name)
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join("manifest.json"), JSON.stringify(_manifest(version)))
	_write(dir.path_join("test-binary"), "PLACEHOLDER")
	if payload_bytes > 0:
		var f := FileAccess.open(dir.path_join("payload.bin"), FileAccess.WRITE)
		f.store_buffer(Crypto.new().generate_random_bytes(payload_bytes))
		f.close()
	return _h.pack_plugin_dir(dir, _temp.path_join(name + ".tar.gz"))


## Archives no install may accept, built with Python's tarfile so that names
## and links tar itself would not write can be recorded:
##   wrong_arch     entrypoint is a 64-bit ELF for a machine other than this one
##   no_binary      manifest names an entrypoint the archive lacks
##   escaping_link  a symlink pointing out of the plugin directory
##   dotdot         a member named ../outside.txt
##   huge_pax       a pax record over the scanner's metadata bound
##   global_path    a global pax record renaming every later member
##   pax_escape     a harmless-looking member renamed by pax to ../escape.txt
##   through_link   link -> sub then link/x.txt, written through the link
##   raw_absolute   a member named /abs.txt (normalising would hide the "/")
##   link_climb     d/e/s -> ../../d then l -> d/e/s/../../../x: inside the
##                  archive read as text, outside once the OS follows d/e/s
##   case_climb     d/e/L2 -> .. then d/e/L1 -> l2/../../x, which climbs out
##                  where the filesystem ignores case (macOS, Windows)
##   backslash      d/l -> a\b\c/../../..: three levels up where a backslash
##                  is not a separator (Linux, macOS), so above the plugin
##   empty_linkpath a/l -> ../../../x overridden by an empty pax linkpath, which
##                  bsdtar ignores
##   slash_file     a regular file named "d/", whose data bsdtar reads as headers
##   junk_size      a header whose size field starts with a non-digit, which
##                  tar implementations read differently
##   hard_to_symlink a/b/s -> .. then hard link h -> a/b/s: tar copies the
##                  symlink to h, where ".." is above the plugin (refused as
##                  an archive holding both link kinds)
func _pack_crafted() -> bool:
	var other_machine := 0xB7 if MarketplaceClient.resolve_platform_target() != "linux-arm64" else 0x3E
	var spec := {
		"wrong_arch": {"manifest": _manifest("2.0.0"), "binary_machine": other_machine},
		"no_binary": {"manifest": _manifest("2.0.0", "./missing-binary")},
		"escaping_link": {"manifest": _manifest("2.0.0"), "links": [["escape", "../../../../etc"]]},
		"dotdot": {"manifest": _manifest("2.0.0"), "extra_name": "../outside.txt"},
		"huge_pax": {"manifest": _manifest("2.0.0"), "pax": {"comment": "x".repeat(70000)}},
		"global_path": {"manifest": _manifest("2.0.0"), "global_pax": {"path": "renamed.txt"}},
		"pax_escape": {"manifest": _manifest("2.0.0"), "pax": {"path": "../escape.txt"}},
		"through_link": {"manifest": _manifest("2.0.0"), "links": [["link", "sub"]], "extra_name": "link/x.txt"},
		"raw_absolute": {"manifest": _manifest("2.0.0"), "extra_name": "/abs.txt"},
		"link_climb": {"manifest": _manifest("2.0.0"), "links": [["d/e/s", "../../d"], ["l", "d/e/s/../../../x"]]},
		"case_climb": {"manifest": _manifest("2.0.0"), "links": [["d/e/L2", ".."], ["d/e/L1", "l2/../../x"]]},
		"backslash": {"manifest": _manifest("2.0.0"), "links": [["d/l", "a\\b\\c/../../.."]]},
		"empty_linkpath": {"manifest": _manifest("2.0.0"), "links": [["a/l", "../../../x"]], "link_pax": {"linkpath": ""}},
		"slash_file": {"manifest": _manifest("2.0.0"), "extra_name": "d/"},
		"junk_size": {"manifest": _manifest("2.0.0"), "junk_size": "x0000001000"},
		"hard_to_symlink": {"manifest": _manifest("2.0.0"), "links": [["a/b/s", ".."]], "hard_links": [["h", "a/b/s"]]},
	}
	_write(_temp.path_join("crafted.json"), JSON.stringify(spec))
	var script := """
import hashlib, io, json, struct, sys, tarfile
root = sys.argv[1]
for name, s in json.load(open(root + '/crafted.json')).items():
    files = {'manifest.json': json.dumps(s['manifest']).encode()}
    if 'binary_machine' in s:
        files['test-binary'] = b'\\x7fELF\\x02\\x01\\x01' + bytes(9) + struct.pack('<HH', 2, s['binary_machine']) + bytes(44)
    elif s['manifest']['backend']['entrypoint'] == './test-binary':
        files['test-binary'] = b'PLACEHOLDER'
    files['SHA256SUMS'] = ''.join('%s  %s\\n' % (hashlib.sha256(v).hexdigest(), k) for k, v in files.items()).encode()
    with tarfile.open('%s/%s.tar.gz' % (root, name), 'w:gz', format=tarfile.PAX_FORMAT,
                      pax_headers=s.get('global_pax', {})) as tar:
        for k, v in files.items():
            info = tarfile.TarInfo('./' + k); info.size = len(v)
            if k == 'manifest.json' and 'pax' in s:
                info.pax_headers = s['pax']
            tar.addfile(info, io.BytesIO(v))
        for link, target in s.get('links', []):
            info = tarfile.TarInfo(link); info.type = tarfile.SYMTYPE; info.linkname = target
            info.pax_headers = s.get('link_pax', {}); tar.addfile(info)
        if 'junk_size' in s:
            buf = bytearray(tarfile.TarInfo('junk.txt').tobuf(tarfile.GNU_FORMAT))
            buf[124:136] = s['junk_size'].encode().ljust(12, b'\\0')
            buf[148:156] = b' ' * 8
            buf[148:156] = b'%06o\\0 ' % sum(buf)
            tar.fileobj.write(bytes(buf) + bytes(512)); tar.offset += 1024
        for link, target in s.get('hard_links', []):
            info = tarfile.TarInfo(link); info.type = tarfile.LNKTYPE; info.linkname = target; tar.addfile(info)
        if 'extra_name' in s:
            info = tarfile.TarInfo(s['extra_name']); info.size = 1; tar.addfile(info, io.BytesIO(b'x'))
"""
	_write(_temp.path_join("crafted.py"), script)
	return _h.run_cmd(_h.python_cmd(), [_temp.path_join("crafted.py"), _temp])


func _extract(name: String, into_abs: String) -> void:
	DirAccess.make_dir_recursive_absolute(into_abs)
	_h.run_cmd("tar", ["-xzf", _temp.path_join(name + ".tar.gz"), "-C", into_abs])


func _client():
	var client = load(MARKETPLACE_GD).new()
	root.add_child(client)
	return client


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _check(ok: bool, what: String) -> bool:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1
	return ok


func _finish(code: int) -> void:
	var db = load(PLUGINDB_GD).new()
	for id in [ID, FRESH_ID]:
		if db.has_plugin(id):
			db.remove(id)
		_h.rm_dir_recursive("user://plugins/" + id)
	_h.teardown()
	_h.remove_tree(_temp)
	print("=== %s ===" % ("FAIL" if code else "PASS"))
	quit(code)
