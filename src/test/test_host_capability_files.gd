extends SceneTree
## Integration test for host.files.read + host.files.write capabilities (T5 R1).
##
## Run: godot --headless --path src --script test/test_host_capability_files.gd
##
## Tracks docket: minerva 019df8e3bd7973e5bb2d6acfe1f74611
## Parent DCR:    minerva 019df8e2d0937613a326389a4df133fb
##
## Coverage (in-process — direct broker.dispatch with a stub PluginDB):
##   read:
##     - happy path (text encoding) round-trips an existing file
##     - happy path (base64 encoding) returns valid base64 of the bytes
##     - missing file → io_error
##     - out-of-scope path → target_not_allowlisted
##     - relative path → schema_validation_failed
##     - `..` traversal → schema_validation_failed
##     - oversize file → payload_too_large
##     - unknown args → schema_validation_failed
##     - manifest with filesystem.mode != scoped_paths → filesystem_disabled
##     - ungranted capability → capability_not_granted
##
##   write:
##     - happy path (text) writes file, then read confirms content
##     - happy path (base64) decodes correctly to bytes-on-disk
##     - missing 'content' arg → schema_validation_failed
##     - invalid base64 'content' → schema_validation_failed
##     - oversize content → payload_too_large
##     - create_parents=true creates missing parent dirs
##     - create_parents=false (default) → io_error when parent dir missing
##     - out-of-scope path rejected
##
##   audit:
##     - successful read/write → capability_dispatched
##     - filesystem_disabled / target_not_allowlisted → capability_failed
##     - capability_not_granted → capability_denied
##
## Test isolation: clears `files_probe_test` from user://plugins/policy.json
## both before and after the run, since PluginPolicy persists grants and
## subsequent runs would see leaked state otherwise.

const PLUGIN_DB_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDB.gd"
const POLICY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"

const TEST_PLUGIN_ID := "files_probe_test"

var _pass_count: int = 0
var _fail_count: int = 0
var _scope_dir: String = ""


func _init() -> void:
	print("=== host.files.* Capability Test (T5 R1 + T2) ===\n")
	_clear_policy_for_test()
	_scope_dir = _make_scope_dir()
	await _run_tests()
	_clear_policy_for_test()
	_remove_scope_dir()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Test bodies
# ---------------------------------------------------------------------------

func _run_tests() -> void:
	var DB = load(PLUGIN_DB_SCRIPT_PATH)
	var Policy = load(POLICY_SCRIPT_PATH)
	var Audit = load(AUDIT_SCRIPT_PATH)
	var Broker = load(BROKER_SCRIPT_PATH)
	var Def = load(DEFINITION_SCRIPT_PATH)
	check("scripts loaded",
		DB != null and Policy != null and Audit != null and Broker != null and Def != null)

	var db = DB.new()
	var def = Def.new(TEST_PLUGIN_ID)
	var caps: Array[String] = [
		"host.files.read", "host.files.write",
		"host.files.list", "host.files.exists", "host.files.stat",
		"host.files.mkdir", "host.files.delete", "host.files.move",
	]
	def.host_capabilities = caps
	def.filesystem_mode = "scoped_paths"
	var paths: Array[String] = [_scope_dir]
	def.filesystem_paths = paths
	db._plugins[TEST_PLUGIN_ID] = def

	var audit = Audit.new()
	var policy = Policy.new(db, audit)
	var broker = Broker.new(policy, audit)

	# Without a grant, dispatch must deny — assert the deny path BEFORE granting.
	var deny: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": _scope_dir.path_join("anything.txt")})
	check_eq("read without grant → capability_not_granted",
		deny.get("error_code", ""), "capability_not_granted")
	var denied_entries: Array = audit.get_entries(TEST_PLUGIN_ID, "capability_denied")
	check("audit logs capability_denied for ungranted call", denied_entries.size() > 0)

	policy.grant_capability(TEST_PLUGIN_ID, "host.files.read")
	policy.grant_capability(TEST_PLUGIN_ID, "host.files.write")
	policy.grant_capability(TEST_PLUGIN_ID, "host.files.list")
	policy.grant_capability(TEST_PLUGIN_ID, "host.files.exists")
	policy.grant_capability(TEST_PLUGIN_ID, "host.files.stat")
	policy.grant_capability(TEST_PLUGIN_ID, "host.files.mkdir")
	policy.grant_capability(TEST_PLUGIN_ID, "host.files.delete")
	policy.grant_capability(TEST_PLUGIN_ID, "host.files.move")

	_test_write_then_read(broker)
	_test_write_base64_round_trip(broker)
	_test_read_missing_file(broker)
	_test_read_oversize(broker)
	_test_read_out_of_scope(broker)
	_test_read_relative_path(broker)
	_test_read_dotdot_traversal(broker)
	_test_read_unknown_arg(broker)
	_test_write_missing_content(broker)
	_test_write_invalid_base64(broker)
	_test_write_oversize(broker)
	_test_write_out_of_scope(broker)
	_test_write_create_parents_true(broker)
	_test_write_create_parents_false_missing_dir(broker)
	_test_filesystem_disabled_when_mode_none(Def, db, broker)
	_test_read_null_byte_in_path(broker)
	_test_read_directory_path(broker)
	_test_write_to_directory_path(broker)
	_test_audit_dispatched_and_failed(audit)

	# T2 new capabilities
	await _test_list_happy(broker)
	await _test_list_hidden_filter(broker)
	await _test_list_not_a_directory(broker)
	await _test_list_io_error(broker)
	await _test_list_scope_deny(broker)
	await _test_list_ungranted(broker, Def, db)
	await _test_exists_happy_file(broker)
	await _test_exists_happy_dir(broker)
	await _test_exists_false(broker)
	await _test_exists_scope_deny_on_nonexistent(broker)
	await _test_stat_happy_file(broker)
	await _test_stat_happy_dir(broker)
	await _test_stat_io_error(broker)
	await _test_mkdir_happy(broker)
	await _test_mkdir_idempotent(broker)
	await _test_mkdir_file_conflict(broker)
	await _test_mkdir_parents_true(broker)
	await _test_mkdir_parents_false_missing_parent(broker)
	await _test_mkdir_scope_deny(broker)
	await _test_delete_happy_file(broker)
	await _test_delete_empty_dir(broker)
	await _test_delete_nonempty_dir_nonrecursive(broker)
	await _test_delete_nonempty_dir_recursive(broker)
	await _test_delete_scope_deny(broker)
	await _test_move_happy(broker)
	await _test_move_dest_exists_no_overwrite(broker)
	await _test_move_dest_exists_overwrite(broker)
	await _test_move_source_out_of_scope(broker)
	await _test_move_dest_out_of_scope(broker)


func _test_write_then_read(broker) -> void:
	var p: String = _scope_dir.path_join("hello.txt")
	var write_res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.write",
		{"path": p, "content": "hello world", "encoding": "text"})
	check("write text: success", write_res.get("success", false), "got: %s" % str(write_res))
	check_eq("write text: bytes_written matches",
		int(write_res.get("result", {}).get("bytes_written", 0)), 11)

	var read_res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": p})
	check("read text: success", read_res.get("success", false), "got: %s" % str(read_res))
	check_eq("read text: content matches written",
		str(read_res.get("result", {}).get("content", "")), "hello world")
	check_eq("read text: encoding defaulted to text",
		str(read_res.get("result", {}).get("encoding", "")), "text")
	check_eq("read text: size matches",
		int(read_res.get("result", {}).get("size", 0)), 11)


func _test_write_base64_round_trip(broker) -> void:
	var p: String = _scope_dir.path_join("blob.bin")
	# Pretend this is a small image: bytes [0xDE, 0xAD, 0xBE, 0xEF]
	var b64: String = Marshalls.raw_to_base64(PackedByteArray([0xDE, 0xAD, 0xBE, 0xEF]))
	var write_res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.write",
		{"path": p, "content": b64, "encoding": "base64"})
	check("write base64: success", write_res.get("success", false), "got: %s" % str(write_res))
	check_eq("write base64: 4 bytes on disk",
		int(write_res.get("result", {}).get("bytes_written", 0)), 4)

	var read_res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": p, "encoding": "base64"})
	check("read base64: success", read_res.get("success", false), "got: %s" % str(read_res))
	check_eq("read base64: round-trip content matches",
		str(read_res.get("result", {}).get("content", "")), b64)


func _test_read_missing_file(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": _scope_dir.path_join("never_existed.txt")})
	check_eq("read missing → io_error", res.get("error_code", ""), "io_error")


func _test_read_oversize(broker) -> void:
	# Write a file that exceeds the 8 MiB cap, then attempt to read it.
	var p: String = _scope_dir.path_join("oversize.bin")
	var fa := FileAccess.open(p, FileAccess.WRITE)
	check("oversize fixture: file opened for write", fa != null)
	if fa == null:
		return
	# 8 MiB + 1 byte
	var oversize_bytes: PackedByteArray = PackedByteArray()
	oversize_bytes.resize((8 * 1024 * 1024) + 1)
	fa.store_buffer(oversize_bytes)
	fa.close()

	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": p})
	check_eq("read oversize → payload_too_large",
		res.get("error_code", ""), "payload_too_large")


func _test_read_out_of_scope(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": "/etc/passwd"})
	check_eq("read /etc/passwd → target_not_allowlisted",
		res.get("error_code", ""), "target_not_allowlisted")


func _test_read_relative_path(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": "relative/x.txt"})
	check_eq("read relative path → schema_validation_failed",
		res.get("error_code", ""), "schema_validation_failed")


func _test_read_dotdot_traversal(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": _scope_dir.path_join("..").path_join("escape.txt")})
	check_eq("read .. traversal → schema_validation_failed",
		res.get("error_code", ""), "schema_validation_failed")


func _test_read_unknown_arg(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": _scope_dir.path_join("hello.txt"), "extra_key": 42})
	check_eq("read unknown arg → schema_validation_failed",
		res.get("error_code", ""), "schema_validation_failed")


func _test_write_missing_content(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.write",
		{"path": _scope_dir.path_join("nope.txt")})
	check_eq("write without content → schema_validation_failed",
		res.get("error_code", ""), "schema_validation_failed")


func _test_write_invalid_base64(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.write",
		{"path": _scope_dir.path_join("bad.bin"),
		"content": "not!!valid!!base64!!", "encoding": "base64"})
	check_eq("write invalid base64 → schema_validation_failed",
		res.get("error_code", ""), "schema_validation_failed")


func _test_write_oversize(broker) -> void:
	# 9 MiB string
	var oversize: String = "x".repeat(9 * 1024 * 1024)
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.write",
		{"path": _scope_dir.path_join("big.txt"), "content": oversize})
	check_eq("write oversize → payload_too_large",
		res.get("error_code", ""), "payload_too_large")


func _test_write_out_of_scope(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.write",
		{"path": "/etc/imran_was_here", "content": "no"})
	check_eq("write /etc/* → target_not_allowlisted",
		res.get("error_code", ""), "target_not_allowlisted")


func _test_write_create_parents_true(broker) -> void:
	var p: String = _scope_dir.path_join("nested/deep/created.txt")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.write",
		{"path": p, "content": "ok", "create_parents": true})
	check("write create_parents=true: success",
		res.get("success", false), "got: %s" % str(res))
	check("write create_parents=true: file actually present",
		FileAccess.file_exists(p))


func _test_write_create_parents_false_missing_dir(broker) -> void:
	# Default create_parents=false. The directory was just created above ('nested/deep')
	# so use a different missing-dir path here.
	var p: String = _scope_dir.path_join("absent_dir/sub.txt")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.write",
		{"path": p, "content": "no"})
	check_eq("write missing parent (no create_parents) → io_error",
		res.get("error_code", ""), "io_error")


func _test_filesystem_disabled_when_mode_none(Def, db, broker) -> void:
	# Construct a separate plugin def whose manifest does NOT enable filesystem.
	# Even with the policy grant, the broker must refuse because the plugin
	# never declared scoped paths.
	const NO_FS_ID := "files_probe_test_no_fs"
	var def_no_fs = Def.new(NO_FS_ID)
	var no_fs_caps: Array[String] = ["host.files.read"]
	def_no_fs.host_capabilities = no_fs_caps
	def_no_fs.filesystem_mode = "none"
	var no_fs_paths: Array[String] = []
	def_no_fs.filesystem_paths = no_fs_paths
	db._plugins[NO_FS_ID] = def_no_fs

	# Need to grant on the broker's policy so we get past the policy gate and
	# hit the manifest cross-check inside the handler.
	broker.policy.grant_capability(NO_FS_ID, "host.files.read")
	var res: Dictionary = await broker.dispatch(NO_FS_ID, "host.files.read",
		{"path": _scope_dir.path_join("hello.txt")})
	check_eq("plugin without scoped_paths → filesystem_disabled",
		res.get("error_code", ""), "filesystem_disabled")

	# Cleanup the secondary policy entry too.
	broker.policy.revoke_capability(NO_FS_ID, "host.files.read")


func _test_read_null_byte_in_path(broker) -> void:
	# A null byte would be silently truncated at the libc layer; the validator
	# rejects it explicitly so the audit trail and FileAccess agree.
	var poisoned: String = _scope_dir.path_join("hello.txt") + char(0) + "..extra"
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": poisoned})
	check_eq("read with embedded null byte → schema_validation_failed",
		res.get("error_code", ""), "schema_validation_failed")


func _test_read_directory_path(broker) -> void:
	# FileAccess.open(<directory>, READ) returns null on Linux; the broker
	# surfaces that as io_error rather than crashing.
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.read",
		{"path": _scope_dir})
	check_eq("read of a directory path → io_error",
		res.get("error_code", ""), "io_error")


func _test_write_to_directory_path(broker) -> void:
	# Existing directory at the target path: write must fail io_error, not
	# clobber it. The scope_dir is, of course, a directory.
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.write",
		{"path": _scope_dir, "content": "x"})
	check_eq("write to a directory path → io_error",
		res.get("error_code", ""), "io_error")


func _test_audit_dispatched_and_failed(audit) -> void:
	var dispatched: Array = audit.get_entries(TEST_PLUGIN_ID, "capability_dispatched")
	check("audit log has capability_dispatched entries (read/write happy paths)",
		dispatched.size() >= 4, "got %d" % dispatched.size())
	var failed: Array = audit.get_entries(TEST_PLUGIN_ID, "capability_failed")
	check("audit log has capability_failed entries (broker-level rejects)",
		failed.size() >= 4, "got %d" % failed.size())


# ---------------------------------------------------------------------------
# T2: host.files.list tests
# ---------------------------------------------------------------------------

func _test_list_happy(broker) -> void:
	var list_dir: String = _scope_dir.path_join("list_happy")
	DirAccess.make_dir_absolute(list_dir)
	# Create 2 files and 1 subdir.
	var fa := FileAccess.open(list_dir.path_join("a.txt"), FileAccess.WRITE)
	fa.store_string("aaa"); fa.close()
	fa = FileAccess.open(list_dir.path_join("b.txt"), FileAccess.WRITE)
	fa.store_string("bb"); fa.close()
	DirAccess.make_dir_absolute(list_dir.path_join("subdir"))

	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.list",
		{"path": list_dir})
	check("list happy: success", res.get("success", false), "got: %s" % str(res))
	var entries: Array = res.get("result", {}).get("entries", [])
	check_eq("list happy: 3 entries", entries.size(), 3)
	var kinds: Dictionary = {}
	for e in entries:
		kinds[str(e.get("kind", ""))] = true
	check("list happy: has dir kind", kinds.has("dir"))
	check("list happy: has file kind", kinds.has("file"))
	# Verify name is basename only
	for e in entries:
		var name: String = str(e.get("name", ""))
		check("list happy: name has no slash", not name.contains("/"))
	# Dirs have size=0
	for e in entries:
		if str(e.get("kind", "")) == "dir":
			check_eq("list happy: dir size=0", int(e.get("size", -1)), 0)


func _test_list_hidden_filter(broker) -> void:
	var list_dir: String = _scope_dir.path_join("list_hidden")
	DirAccess.make_dir_absolute(list_dir)
	var fa := FileAccess.open(list_dir.path_join("visible.txt"), FileAccess.WRITE)
	fa.store_string("x"); fa.close()
	fa = FileAccess.open(list_dir.path_join(".hidden"), FileAccess.WRITE)
	fa.store_string("h"); fa.close()

	# Without include_hidden: only visible.txt
	var res1: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.list",
		{"path": list_dir})
	check("list hidden filter: success without include_hidden",
		res1.get("success", false), "got: %s" % str(res1))
	var entries1: Array = res1.get("result", {}).get("entries", [])
	check_eq("list hidden filter: 1 entry without include_hidden", entries1.size(), 1)
	check_eq("list hidden filter: visible entry name",
		str(entries1[0].get("name", "")), "visible.txt")

	# With include_hidden=true: both entries
	var res2: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.list",
		{"path": list_dir, "include_hidden": true})
	check("list hidden filter: success with include_hidden=true",
		res2.get("success", false), "got: %s" % str(res2))
	var entries2: Array = res2.get("result", {}).get("entries", [])
	check_eq("list hidden filter: 2 entries with include_hidden=true", entries2.size(), 2)


func _test_list_not_a_directory(broker) -> void:
	var p: String = _scope_dir.path_join("hello.txt")
	# hello.txt was created by an earlier test
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.list",
		{"path": p})
	check_eq("list on file → not_a_directory", res.get("error_code", ""), "not_a_directory")


func _test_list_io_error(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.list",
		{"path": _scope_dir.path_join("nonexistent_dir_xyz")})
	check_eq("list non-existent dir → io_error", res.get("error_code", ""), "io_error")


func _test_list_scope_deny(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.list",
		{"path": "/etc"})
	check_eq("list /etc → target_not_allowlisted",
		res.get("error_code", ""), "target_not_allowlisted")


func _test_list_ungranted(broker, Def, db) -> void:
	const UNGRANTED_ID := "files_probe_test_ungranted"
	var def2 = Def.new(UNGRANTED_ID)
	var caps2: Array[String] = ["host.files.list"]
	def2.host_capabilities = caps2
	def2.filesystem_mode = "scoped_paths"
	var paths2: Array[String] = [_scope_dir]
	def2.filesystem_paths = paths2
	db._plugins[UNGRANTED_ID] = def2
	# Intentionally do NOT grant capability.
	var res: Dictionary = await broker.dispatch(UNGRANTED_ID, "host.files.list",
		{"path": _scope_dir})
	check_eq("list without grant → capability_not_granted",
		res.get("error_code", ""), "capability_not_granted")
	# Cleanup db entry
	db._plugins.erase(UNGRANTED_ID)


# ---------------------------------------------------------------------------
# T2: host.files.exists tests
# ---------------------------------------------------------------------------

func _test_exists_happy_file(broker) -> void:
	var p: String = _scope_dir.path_join("hello.txt")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.exists",
		{"path": p})
	check("exists happy file: success", res.get("success", false), "got: %s" % str(res))
	check_eq("exists happy file: exists=true", bool(res.get("result", {}).get("exists", false)), true)
	check_eq("exists happy file: kind=file", str(res.get("result", {}).get("kind", "")), "file")


func _test_exists_happy_dir(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.exists",
		{"path": _scope_dir})
	check("exists happy dir: success", res.get("success", false), "got: %s" % str(res))
	check_eq("exists happy dir: exists=true", bool(res.get("result", {}).get("exists", false)), true)
	check_eq("exists happy dir: kind=dir", str(res.get("result", {}).get("kind", "")), "dir")


func _test_exists_false(broker) -> void:
	var p: String = _scope_dir.path_join("definitely_not_here_xyz.txt")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.exists",
		{"path": p})
	check("exists false: success", res.get("success", false), "got: %s" % str(res))
	check_eq("exists false: exists=false", bool(res.get("result", {}).get("exists", true)), false)
	check_eq("exists false: kind=null", res.get("result", {}).get("kind", "WRONG"), null)


func _test_exists_scope_deny_on_nonexistent(broker) -> void:
	# Scope check runs even for paths that don't exist.
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.exists",
		{"path": "/etc/no_such_file_ever"})
	check_eq("exists scope deny on nonexistent → target_not_allowlisted",
		res.get("error_code", ""), "target_not_allowlisted")


# ---------------------------------------------------------------------------
# T2: host.files.stat tests
# ---------------------------------------------------------------------------

func _test_stat_happy_file(broker) -> void:
	var p: String = _scope_dir.path_join("hello.txt")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.stat",
		{"path": p})
	check("stat happy file: success", res.get("success", false), "got: %s" % str(res))
	check_eq("stat happy file: kind=file", str(res.get("result", {}).get("kind", "")), "file")
	check("stat happy file: size > 0", int(res.get("result", {}).get("size", 0)) > 0)
	check("stat happy file: modified_unix > 0", int(res.get("result", {}).get("modified_unix", 0)) > 0)


func _test_stat_happy_dir(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.stat",
		{"path": _scope_dir})
	check("stat happy dir: success", res.get("success", false), "got: %s" % str(res))
	check_eq("stat happy dir: kind=dir", str(res.get("result", {}).get("kind", "")), "dir")
	check_eq("stat happy dir: size=0", int(res.get("result", {}).get("size", 0)), 0)


func _test_stat_io_error(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.stat",
		{"path": _scope_dir.path_join("no_such_file.txt")})
	check_eq("stat missing → io_error", res.get("error_code", ""), "io_error")


# ---------------------------------------------------------------------------
# T2: host.files.mkdir tests
# ---------------------------------------------------------------------------

func _test_mkdir_happy(broker) -> void:
	var p: String = _scope_dir.path_join("mkdir_new")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.mkdir",
		{"path": p})
	check("mkdir happy: success", res.get("success", false), "got: %s" % str(res))
	check_eq("mkdir happy: created=true", bool(res.get("result", {}).get("created", false)), true)
	check("mkdir happy: dir actually exists", DirAccess.dir_exists_absolute(p))


func _test_mkdir_idempotent(broker) -> void:
	# mkdir_new was just created above
	var p: String = _scope_dir.path_join("mkdir_new")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.mkdir",
		{"path": p})
	check("mkdir idempotent: success", res.get("success", false), "got: %s" % str(res))
	check_eq("mkdir idempotent: created=false", bool(res.get("result", {}).get("created", true)), false)


func _test_mkdir_file_conflict(broker) -> void:
	# hello.txt exists as a file — mkdir on it must fail.
	var p: String = _scope_dir.path_join("hello.txt")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.mkdir",
		{"path": p})
	check_eq("mkdir on file → io_error", res.get("error_code", ""), "io_error")


func _test_mkdir_parents_true(broker) -> void:
	var p: String = _scope_dir.path_join("mkdir_deep/nested/dir")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.mkdir",
		{"path": p, "parents": true})
	check("mkdir parents=true: success", res.get("success", false), "got: %s" % str(res))
	check("mkdir parents=true: dir exists", DirAccess.dir_exists_absolute(p))


func _test_mkdir_parents_false_missing_parent(broker) -> void:
	var p: String = _scope_dir.path_join("nonexistent_parent/child")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.mkdir",
		{"path": p})
	check_eq("mkdir parents=false missing parent → io_error",
		res.get("error_code", ""), "io_error")


func _test_mkdir_scope_deny(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.mkdir",
		{"path": "/etc/minerva_test_dir"})
	check_eq("mkdir /etc/* → target_not_allowlisted",
		res.get("error_code", ""), "target_not_allowlisted")


# ---------------------------------------------------------------------------
# T2: host.files.delete tests
# ---------------------------------------------------------------------------

func _test_delete_happy_file(broker) -> void:
	var p: String = _scope_dir.path_join("delete_me.txt")
	var fa := FileAccess.open(p, FileAccess.WRITE)
	fa.store_string("bye"); fa.close()

	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.delete",
		{"path": p})
	check("delete file: success", res.get("success", false), "got: %s" % str(res))
	check_eq("delete file: kind=file", str(res.get("result", {}).get("kind", "")), "file")
	check_eq("delete file: removed=true", bool(res.get("result", {}).get("removed", false)), true)
	check("delete file: file gone", not FileAccess.file_exists(p))


func _test_delete_empty_dir(broker) -> void:
	var p: String = _scope_dir.path_join("delete_empty_dir")
	DirAccess.make_dir_absolute(p)

	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.delete",
		{"path": p})
	check("delete empty dir: success", res.get("success", false), "got: %s" % str(res))
	check_eq("delete empty dir: kind=dir", str(res.get("result", {}).get("kind", "")), "dir")
	check("delete empty dir: dir gone", not DirAccess.dir_exists_absolute(p))


func _test_delete_nonempty_dir_nonrecursive(broker) -> void:
	var p: String = _scope_dir.path_join("delete_nonempty")
	DirAccess.make_dir_absolute(p)
	var fa := FileAccess.open(p.path_join("x.txt"), FileAccess.WRITE)
	fa.store_string("x"); fa.close()

	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.delete",
		{"path": p})
	check_eq("delete nonempty dir recursive=false → io_error",
		res.get("error_code", ""), "io_error")
	# Cleanup manually so later tests work
	DirAccess.remove_absolute(p.path_join("x.txt"))
	DirAccess.remove_absolute(p)


func _test_delete_nonempty_dir_recursive(broker) -> void:
	var p: String = _scope_dir.path_join("delete_recursive")
	DirAccess.make_dir_recursive_absolute(p.path_join("sub"))
	var fa := FileAccess.open(p.path_join("a.txt"), FileAccess.WRITE)
	fa.store_string("a"); fa.close()
	fa = FileAccess.open(p.path_join("sub/b.txt"), FileAccess.WRITE)
	fa.store_string("b"); fa.close()

	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.delete",
		{"path": p, "recursive": true})
	check("delete recursive: success", res.get("success", false), "got: %s" % str(res))
	check("delete recursive: dir gone", not DirAccess.dir_exists_absolute(p))
	check("delete recursive: entries_removed > 0",
		int(res.get("result", {}).get("entries_removed", 0)) > 0)


func _test_delete_scope_deny(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.delete",
		{"path": "/tmp/some_other_file"})
	check_eq("delete out-of-scope → target_not_allowlisted",
		res.get("error_code", ""), "target_not_allowlisted")


# ---------------------------------------------------------------------------
# T2: host.files.move tests
# ---------------------------------------------------------------------------

func _test_move_happy(broker) -> void:
	var src: String = _scope_dir.path_join("move_src.txt")
	var dst: String = _scope_dir.path_join("move_dst.txt")
	var fa := FileAccess.open(src, FileAccess.WRITE)
	fa.store_string("moveme"); fa.close()

	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.move",
		{"source": src, "dest": dst})
	check("move happy: success", res.get("success", false), "got: %s" % str(res))
	check_eq("move happy: overwritten=false", bool(res.get("result", {}).get("overwritten", true)), false)
	check("move happy: dest exists", FileAccess.file_exists(dst))
	check("move happy: src gone", not FileAccess.file_exists(src))


func _test_move_dest_exists_no_overwrite(broker) -> void:
	var src: String = _scope_dir.path_join("move_src2.txt")
	var dst: String = _scope_dir.path_join("move_dst2.txt")
	var fa := FileAccess.open(src, FileAccess.WRITE)
	fa.store_string("src"); fa.close()
	fa = FileAccess.open(dst, FileAccess.WRITE)
	fa.store_string("existing"); fa.close()

	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.move",
		{"source": src, "dest": dst})
	check_eq("move dest exists no overwrite → io_error",
		res.get("error_code", ""), "io_error")
	# Cleanup
	DirAccess.remove_absolute(src)
	DirAccess.remove_absolute(dst)


func _test_move_dest_exists_overwrite(broker) -> void:
	var src: String = _scope_dir.path_join("move_src3.txt")
	var dst: String = _scope_dir.path_join("move_dst3.txt")
	var fa := FileAccess.open(src, FileAccess.WRITE)
	fa.store_string("new_content"); fa.close()
	fa = FileAccess.open(dst, FileAccess.WRITE)
	fa.store_string("old_content"); fa.close()

	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.move",
		{"source": src, "dest": dst, "overwrite": true})
	check("move overwrite=true: success", res.get("success", false), "got: %s" % str(res))
	check_eq("move overwrite=true: overwritten=true",
		bool(res.get("result", {}).get("overwritten", false)), true)
	check("move overwrite=true: dest exists", FileAccess.file_exists(dst))
	check("move overwrite=true: src gone", not FileAccess.file_exists(src))
	# Verify content was replaced
	var fa2 := FileAccess.open(dst, FileAccess.READ)
	var content: String = fa2.get_as_text(); fa2.close()
	check_eq("move overwrite=true: dest content is new", content, "new_content")


func _test_move_source_out_of_scope(broker) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.move",
		{"source": "/etc/passwd", "dest": _scope_dir.path_join("stolen.txt")})
	check_eq("move source out of scope → target_not_allowlisted",
		res.get("error_code", ""), "target_not_allowlisted")


func _test_move_dest_out_of_scope(broker) -> void:
	var src: String = _scope_dir.path_join("hello.txt")
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.files.move",
		{"source": src, "dest": "/tmp/escaped.txt"})
	check_eq("move dest out of scope → target_not_allowlisted",
		res.get("error_code", ""), "target_not_allowlisted")


# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------

func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		var msg := "  FAIL: %s" % label
		if not detail.is_empty():
			msg += " — " + detail
		print(msg)


func check_eq(label: String, actual, expected) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])


# ---------------------------------------------------------------------------
# Filesystem fixtures
# ---------------------------------------------------------------------------

func _make_scope_dir() -> String:
	var base: String = "/tmp/files_probe_test_" + str(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(base)
	return base


func _remove_scope_dir() -> void:
	if _scope_dir.is_empty():
		return
	# Remove the directory tree. DirAccess only supports per-file removal so
	# walk it.
	_rm_rf(_scope_dir)


func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	while true:
		var name := d.get_next()
		if name.is_empty():
			break
		if name == "." or name == "..":
			continue
		var sub: String = path.path_join(name)
		if d.current_is_dir():
			_rm_rf(sub)
		else:
			DirAccess.remove_absolute(sub)
	d.list_dir_end()
	DirAccess.remove_absolute(path)


# ---------------------------------------------------------------------------
# Policy isolation
# ---------------------------------------------------------------------------

func _clear_policy_for_test() -> void:
	# PluginPolicy persists grants under user://plugins/policy.json; grants
	# from a prior test run would otherwise leak into the deny-path assertion.
	# Mirror the cleanup the laptop's host.documents tests do for doc_probe_test.
	var policy_file: String = ProjectSettings.globalize_path("user://plugins/policy.json")
	if not FileAccess.file_exists(policy_file):
		return
	var fa := FileAccess.open(policy_file, FileAccess.READ)
	if fa == null:
		return
	var raw := fa.get_as_text()
	fa.close()
	var data: Variant = JSON.parse_string(raw)
	if not data is Dictionary:
		return
	var grants: Dictionary = (data as Dictionary).get("grants", {})
	for key in [TEST_PLUGIN_ID, "files_probe_test_no_fs", "files_probe_test_ungranted"]:
		grants.erase(key)
	(data as Dictionary)["grants"] = grants
	fa = FileAccess.open(policy_file, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(data, "  "))
	fa.close()
