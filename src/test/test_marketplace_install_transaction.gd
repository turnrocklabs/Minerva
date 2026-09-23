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
##   - a plugin database that cannot be written keeps its previous complete
##     file;
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
var _sha := ""
var _fail := 0


func _init() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL: timed out")
		_h.teardown()
		quit(1))
	await process_frame
	_h = load(HELPERS_GD).new(self)
	_temp = "%s/test_install_txn_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	_sha = "sha256sum" if _h.have_cmd("sha256sum") else "shasum -a 256"
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
	await _test_recovery_after_a_crash()
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
			["pax_escape", "archive_unsafe"], ["through_link", "archive_unsafe"]]:
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
	DirAccess.remove_absolute(db_file + ".tmp")


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
	_op(staging, "dead-3", {"phase": "replacing", "id": FRESH_ID, "had_previous": false, "db_before": null})
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
		"a half-done first install is removed, files and DB record")
	var left := Array(DirAccess.get_directories_at(staging))
	_check(not "op_dead-1_1" in left and not "op_dead-2_1" in left and not "op_dead-3_1" in left
		and not "op_dead-4_1" in left and not "extract_123" in left
		and not FileAccess.file_exists(staging.path_join("dl_123.tar.gz")), "recovered and legacy staging is gone: %s" % [left])
	_check("op_%s_99" % load(TXN_GD)._session in left and "op_live-1_1" in left, "live operations are left alone")
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
	_check(box[0] != null and box[0].get("ok", false) and box[0].get("version") == "2.0.0" and db.get_by_id(ID).version == "2.0.0"
		and not DirAccess.dir_exists_absolute(live_other),
		"after the other process exits its operation is undone and v2 installs over v1: %s" % [box[0]])
	for name in DirAccess.get_directories_at(staging):
		if name != "owners":
			_h.rm_dir_recursive(staging.path_join(name))


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
	var server := OS.create_process("python3", [ProjectSettings.globalize_path(THROTTLED_PY),
		_temp.path_join("big.tar.gz"), str(port + 1), "--rate", "1048576"])
	var slow_url := "http://127.0.0.1:%d/big.tar.gz" % (port + 1)
	for i in 50:
		if OS.execute("bash", ["-c", "exec 3<>/dev/tcp/127.0.0.1/%d" % (port + 1)]) == 0:
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
	return _h.run_cmd("bash", ["-c", "cd '%s' && %s $(ls) > SHA256SUMS && tar -czf ../%s.tar.gz ." % [dir, _sha, name]])


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
func _pack_crafted() -> bool:
	var other_machine := 0xB7 if MarketplaceClient.resolve_platform_target() != "linux-arm64" else 0x3E
	var spec := {
		"wrong_arch": {"manifest": _manifest("2.0.0"), "binary_machine": other_machine},
		"no_binary": {"manifest": _manifest("2.0.0", "./missing-binary")},
		"escaping_link": {"manifest": _manifest("2.0.0"), "link": ["escape", "../../../../etc"]},
		"dotdot": {"manifest": _manifest("2.0.0"), "extra_name": "../outside.txt"},
		"huge_pax": {"manifest": _manifest("2.0.0"), "pax": {"comment": "x".repeat(70000)}},
		"global_path": {"manifest": _manifest("2.0.0"), "global_pax": {"path": "renamed.txt"}},
		"pax_escape": {"manifest": _manifest("2.0.0"), "pax": {"path": "../escape.txt"}},
		"through_link": {"manifest": _manifest("2.0.0"), "link": ["link", "sub"], "extra_name": "link/x.txt"},
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
        if 'link' in s:
            info = tarfile.TarInfo(s['link'][0]); info.type = tarfile.SYMTYPE; info.linkname = s['link'][1]; tar.addfile(info)
        if 'extra_name' in s:
            info = tarfile.TarInfo(s['extra_name']); info.size = 1; tar.addfile(info, io.BytesIO(b'x'))
"""
	_write(_temp.path_join("crafted.py"), script)
	return _h.run_cmd("python3", [_temp.path_join("crafted.py"), _temp])


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


func _check(ok: bool, what: String) -> void:
	print(("PASS: " if ok else "FAIL: ") + what)
	if not ok:
		_fail += 1


func _finish(code: int) -> void:
	var db = load(PLUGINDB_GD).new()
	for id in [ID, FRESH_ID]:
		if db.has_plugin(id):
			db.remove(id)
		_h.rm_dir_recursive("user://plugins/" + id)
	_h.teardown()
	OS.execute("rm", ["-rf", _temp])
	print("=== %s ===" % ("FAIL" if code else "PASS"))
	quit(code)
