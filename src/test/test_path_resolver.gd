extends SceneTree
## Test: PathResolver — path normalization and policy hook.
## Run: godot --headless --script src/test/test_path_resolver.gd

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PathResolver Tests ===\n")

	test_empty_path_errors()
	test_absolute_path_passes_through()
	test_tilde_expands_to_home()
	test_res_path_is_globalized()
	test_user_path_is_globalized()
	test_relative_path_passes_through()

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
# Tests
# ---------------------------------------------------------------------------

func test_empty_path_errors() -> void:
	print("test_empty_path_errors")
	var r := PathResolver.resolve("")
	check("ok=false on empty path", not r.ok)
	check("error mentions empty", "empty" in str(r.get("error", "")))


func test_absolute_path_passes_through() -> void:
	print("test_absolute_path_passes_through")
	var r := PathResolver.resolve("/tmp/foo.txt")
	check("ok=true on absolute path", r.ok)
	check("path returned unchanged", r.path == "/tmp/foo.txt")


func test_tilde_expands_to_home() -> void:
	print("test_tilde_expands_to_home")
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	if home.is_empty():
		print("  SKIP: no HOME/USERPROFILE in env")
		return
	var r := PathResolver.resolve("~/foo.txt")
	check("ok=true on tilde path", r.ok)
	check("tilde expanded to HOME", r.path == home + "/foo.txt")


func test_res_path_is_globalized() -> void:
	print("test_res_path_is_globalized")
	var r := PathResolver.resolve("res://project.godot")
	check("ok=true on res:// path", r.ok)
	check("res:// resolved to absolute", r.path.begins_with("/") or r.path.length() > 2 and r.path[1] == ":")


func test_user_path_is_globalized() -> void:
	print("test_user_path_is_globalized")
	var r := PathResolver.resolve("user://test.cfg")
	check("ok=true on user:// path", r.ok)
	check("user:// not equal to input", r.path != "user://test.cfg")


func test_relative_path_passes_through() -> void:
	print("test_relative_path_passes_through")
	# Relative paths are intentionally passed through (per ReadTool convention).
	var r := PathResolver.resolve("relative/path.txt")
	check("ok=true on relative path", r.ok)
	check("relative path unchanged", r.path == "relative/path.txt")
