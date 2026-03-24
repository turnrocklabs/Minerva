extends SceneTree
## Test: CodeToolsPolicy — port of CodeTools policy.py
## Run: godot --headless --script src/test/test_codetools_policy.gd

# CodeToolsPolicy is available globally via class_name

var _pass_count: int = 0
var _fail_count: int = 0

func _init() -> void:
	print("=== CodeTools Policy Tests ===\n")

	test_default_policy_allows_everything()
	test_baseline_denies_policy_json()
	test_baseline_denies_policy_partial()
	test_custom_deny_pattern_blocks_match()
	test_custom_deny_pattern_allows_nonmatch()
	test_invalid_regex_skipped_gracefully()
	test_missing_policy_file_returns_empty_policy()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Write a minimal policy JSON to a temp file and return the path.
func write_temp_policy(content: String) -> String:
	var path := "/tmp/test_codetools_policy_%d.json" % randi()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	return path


## Create a fresh CodeToolsPolicy loaded from the given path (bypasses singleton).
func make_policy(policy_path: String) -> RefCounted:
	var p: RefCounted = CodeToolsPolicy.new()
	p._load_policy(policy_path)
	return p


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func test_default_policy_allows_everything() -> void:
	print("test_default_policy_allows_everything:")
	# Use a path that definitely doesn't exist so we get an empty policy.
	var p = make_policy("/tmp/no_such_policy_file_minerva_test.json")
	check("empty policy allows arbitrary command", p.check_bash_command("ls -la") == "")
	check("empty policy allows echo", p.check_bash_command("echo hello") == "")
	check("empty policy allows git push", p.check_bash_command("git push origin main") == "")


func test_baseline_denies_policy_json() -> void:
	print("test_baseline_denies_policy_json:")
	var p = make_policy("/tmp/no_such_policy_file_minerva_test.json")
	var result: String = p.check_bash_command("cat ~/.codetools/policy.json")
	check("baseline denies .codetools/policy.json access", result != "")
	check("error mentions system path", "Protected system path" in result)


func test_baseline_denies_policy_partial() -> void:
	print("test_baseline_denies_policy_partial:")
	var p = make_policy("/tmp/no_such_policy_file_minerva_test.json")
	var result: String = p.check_bash_command("rm ~/.codetools/policy")
	check("baseline partial pattern also denied", result != "")


func test_custom_deny_pattern_blocks_match() -> void:
	print("test_custom_deny_pattern_blocks_match:")
	# Use a simple literal pattern to avoid JSON escape complexity.
	var path: String = write_temp_policy('{"bash": {"deny": ["rm -rf"]}}')
	var p = make_policy(path)
	var result: String = p.check_bash_command("rm -rf /tmp/junk")
	check("custom pattern blocks matching command", result != "")
	check("error mentions pattern", "Pattern matched:" in result)


func test_custom_deny_pattern_allows_nonmatch() -> void:
	print("test_custom_deny_pattern_allows_nonmatch:")
	var path: String = write_temp_policy('{"bash": {"deny": ["rm -rf"]}}')
	var p = make_policy(path)
	var result: String = p.check_bash_command("ls /tmp")
	check("custom pattern allows non-matching command", result == "")


func test_invalid_regex_skipped_gracefully() -> void:
	print("test_invalid_regex_skipped_gracefully:")
	# "[invalid" is an unclosed character class — invalid regex in most engines.
	var path: String = write_temp_policy('{"bash": {"deny": ["[invalid", "safe_pattern"]}}')
	var p = make_policy(path)
	# Invalid regex should be silently skipped; valid one should still work.
	var result_safe: String = p.check_bash_command("safe_pattern run")
	var result_ok: String = p.check_bash_command("totally unrelated command")
	check("invalid regex does not crash policy load", true)
	check("valid pattern after invalid one still enforced", result_safe != "")
	check("unrelated command still allowed", result_ok == "")


func test_missing_policy_file_returns_empty_policy() -> void:
	print("test_missing_policy_file_returns_empty_policy:")
	var p = make_policy("/tmp/definitely_does_not_exist_xyz987.json")
	check("missing file gives zero deny patterns", p.bash_deny_patterns.size() == 0)
	check("missing file allows arbitrary command", p.check_bash_command("anything goes") == "")
