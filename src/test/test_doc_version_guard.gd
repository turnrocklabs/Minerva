extends SceneTree
## P3 concurrency-rail tests (DCR 019ea404ffcd): DocVersionGuard.check, the
## optimistic-concurrency decision MCPDocTools uses to stop a human+agent
## whole-buffer clobber. Tested directly (the helper is dependency-free); a real
## DocumentBuffer drives the version-bump contract the guard relies on.
## Run: godot --headless --path src --script test/test_doc_version_guard.gd

const DocVersionGuard := preload("res://Scripts/Services/Documents/DocVersionGuard.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== doc version-guard (P3) tests ===")
	test_omitted_version_proceeds()
	test_matching_version_proceeds()
	test_stale_version_rejected()
	test_retry_after_reread_succeeds()
	test_json_float_version_accepted()
	test_real_buffer_bump_drives_guard()
	print("=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func _eq(desc: String, actual: Variant, expected: Variant) -> void:
	_check("%s (got %s, want %s)" % [desc, str(actual), str(expected)], actual == expected)


func test_omitted_version_proceeds() -> void:
	print("test_omitted_version_proceeds:")
	_eq("no if_match_version -> proceed (empty)", DocVersionGuard.check({}, 0, "f").is_empty(), true)


func test_matching_version_proceeds() -> void:
	print("test_matching_version_proceeds:")
	_eq("version matches -> proceed", DocVersionGuard.check({"if_match_version": 3}, 3, "f").is_empty(), true)


func test_stale_version_rejected() -> void:
	print("test_stale_version_rejected:")
	var g := DocVersionGuard.check({"if_match_version": 0}, 1, "f.gd")
	_eq("stale write rejected (code)", g.get("code"), "version_mismatch")
	_eq("reports want", g.get("want"), 0)
	_eq("reports got (current)", g.get("got"), 1)
	_eq("carries path", g.get("path"), "f.gd")
	_check("error message carries want/got (broker forwards only .error)",
		String(g.get("error", "")).contains("want 0") and String(g.get("error", "")).contains("got 1"))


func test_retry_after_reread_succeeds() -> void:
	print("test_retry_after_reread_succeeds:")
	# agent saw v0, write rejected at v1; re-reads -> retries with v1 -> proceeds
	_eq("rejected at stale", DocVersionGuard.check({"if_match_version": 0}, 1, "f").get("code"), "version_mismatch")
	_eq("retry with fresh version proceeds", DocVersionGuard.check({"if_match_version": 1}, 1, "f").is_empty(), true)


func test_json_float_version_accepted() -> void:
	print("test_json_float_version_accepted:")
	# GDScript JSON.parse yields numbers as float; if_match_version may arrive 1.0
	_eq("float 1.0 matches int version 1", DocVersionGuard.check({"if_match_version": 1.0}, 1, "f").is_empty(), true)
	_eq("float 0.0 vs version 1 rejected", DocVersionGuard.check({"if_match_version": 0.0}, 1, "f").get("code"), "version_mismatch")


func test_real_buffer_bump_drives_guard() -> void:
	print("test_real_buffer_bump_drives_guard:")
	# Integration of the contract: apply_edit bumps version, which the guard reads.
	var buf := DocumentBuffer.new("/tmp/version_guard_test.txt", "v0")
	var read_version := buf.version            # agent reads version
	buf.apply_edit("v1")                        # human edits in between
	_check("apply_edit bumped version", buf.version == read_version + 1)
	_eq("agent's stale write rejected", DocVersionGuard.check({"if_match_version": read_version}, buf.version, buf.file_path).get("code"), "version_mismatch")
	_eq("write at current version proceeds", DocVersionGuard.check({"if_match_version": buf.version}, buf.version, buf.file_path).is_empty(), true)
