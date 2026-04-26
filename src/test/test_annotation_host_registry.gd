extends SceneTree
## Unit tests for AnnotationHostRegistry — the in-memory editor_name → host map
## that lets MCP tools answer "what's currently in the panel" without a save.
##
## Run: godot --headless --path src --script test/test_annotation_host_registry.gd

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationHostRegistry Tests ===\n")

	test_register_and_get()
	test_get_unknown_returns_null()
	test_register_overwrites_same_key()
	test_deregister_removes_entry()
	test_deregister_unknown_is_noop()
	test_register_empty_name_is_noop()
	test_register_null_host_is_noop()
	test_list_editor_names_returns_keys()
	test_reset_for_test_clears_all()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_register_and_get() -> void:
	print("test_register_and_get:")
	AnnotationHostRegistry._reset_for_test()
	var host := AnnotationHost.new()
	AnnotationHostRegistry.register("My Panel", host)
	var retrieved := AnnotationHostRegistry.get_host("My Panel")
	check("retrieved == registered host", retrieved == host)


func test_get_unknown_returns_null() -> void:
	print("test_get_unknown_returns_null:")
	AnnotationHostRegistry._reset_for_test()
	check("unknown editor returns null", AnnotationHostRegistry.get_host("Nope") == null)


func test_register_overwrites_same_key() -> void:
	print("test_register_overwrites_same_key:")
	AnnotationHostRegistry._reset_for_test()
	var first := AnnotationHost.new()
	var second := AnnotationHost.new()
	AnnotationHostRegistry.register("Same", first)
	AnnotationHostRegistry.register("Same", second)
	var got := AnnotationHostRegistry.get_host("Same")
	check("second registration wins", got == second)


func test_deregister_removes_entry() -> void:
	print("test_deregister_removes_entry:")
	AnnotationHostRegistry._reset_for_test()
	var host := AnnotationHost.new()
	AnnotationHostRegistry.register("Goodbye", host)
	AnnotationHostRegistry.deregister("Goodbye")
	check("after deregister: get returns null", AnnotationHostRegistry.get_host("Goodbye") == null)


func test_deregister_unknown_is_noop() -> void:
	print("test_deregister_unknown_is_noop:")
	AnnotationHostRegistry._reset_for_test()
	# Should not error.
	AnnotationHostRegistry.deregister("Never registered")
	check("deregister of unknown is silent", true)


func test_register_empty_name_is_noop() -> void:
	print("test_register_empty_name_is_noop:")
	AnnotationHostRegistry._reset_for_test()
	var host := AnnotationHost.new()
	AnnotationHostRegistry.register("", host)
	check("empty name not registered", AnnotationHostRegistry.list_editor_names().is_empty())


func test_register_null_host_is_noop() -> void:
	print("test_register_null_host_is_noop:")
	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register("Null Host", null)
	check("null host not registered", AnnotationHostRegistry.list_editor_names().is_empty())


func test_list_editor_names_returns_keys() -> void:
	print("test_list_editor_names_returns_keys:")
	AnnotationHostRegistry._reset_for_test()
	var a := AnnotationHost.new()
	var b := AnnotationHost.new()
	AnnotationHostRegistry.register("Alpha", a)
	AnnotationHostRegistry.register("Beta", b)
	var names: Array = AnnotationHostRegistry.list_editor_names()
	check("two names registered", names.size() == 2)
	check("Alpha present", names.has("Alpha"))
	check("Beta present", names.has("Beta"))


func test_reset_for_test_clears_all() -> void:
	print("test_reset_for_test_clears_all:")
	AnnotationHostRegistry.register("X", AnnotationHost.new())
	AnnotationHostRegistry.register("Y", AnnotationHost.new())
	AnnotationHostRegistry._reset_for_test()
	check("registry empty after reset", AnnotationHostRegistry.list_editor_names().is_empty())
