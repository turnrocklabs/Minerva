extends SceneTree
## Test: OSOpenPolicy — the pure allowlist behind minerva_os_open (W11).
## Run: godot --headless --path src --script test/test_os_open_policy.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== OSOpenPolicy Tests ===\n")
	test_default_extensions()
	test_refusals()
	test_extra_extensions()
	test_allowed_binaries()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func test_default_extensions() -> void:
	print("test_default_extensions")
	var none: PackedStringArray = []
	check("pdf allowed", OSOpenPolicy.is_allowed("/home/x/tags.pdf", none, none) == true)
	check("png allowed", OSOpenPolicy.is_allowed("/home/x/logo.PNG", none, none) == true)  # case-insensitive
	check("docx allowed", OSOpenPolicy.is_allowed("/a/b/roster.docx", none, none) == true)


func test_refusals() -> void:
	print("test_refusals")
	var none: PackedStringArray = []
	check("exe refused by default", OSOpenPolicy.is_allowed("/home/x/evil.exe", none, none) == false)
	check("sh refused", OSOpenPolicy.is_allowed("/home/x/run.sh", none, none) == false)
	check("no-extension refused", OSOpenPolicy.is_allowed("/home/x/Makefile", none, none) == false)
	check("unknown ext refused", OSOpenPolicy.is_allowed("/home/x/blob.xyz", none, none) == false)


func test_extra_extensions() -> void:
	print("test_extra_extensions")
	var none: PackedStringArray = []
	var extra: PackedStringArray = ["xyz", ".numbers"]  # leading dot tolerated
	check("config extra ext allowed", OSOpenPolicy.is_allowed("/home/x/blob.xyz", extra, none) == true)
	check("config extra ext w/ dot allowed", OSOpenPolicy.is_allowed("/home/x/sheet.numbers", extra, none) == true)
	check("still refuses outside extra", OSOpenPolicy.is_allowed("/home/x/evil.exe", extra, none) == false)


func test_allowed_binaries() -> void:
	print("test_allowed_binaries")
	var none: PackedStringArray = []
	var bins: PackedStringArray = ["Docket.app", "docket.exe"]
	check("named .app bundle allowed (case-insensitive)", OSOpenPolicy.is_allowed("/Applications/docket.APP", none, bins) == true)
	check("named .exe allowed", OSOpenPolicy.is_allowed("C:/Tools/Docket.exe", none, bins) == true)
	check("other .app still refused", OSOpenPolicy.is_allowed("/Applications/Other.app", none, bins) == false)
	check("other .exe still refused", OSOpenPolicy.is_allowed("/x/other.exe", none, bins) == false)
