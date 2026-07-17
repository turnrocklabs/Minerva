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

	# Bug 019f6b9221b6 / host-resolution ambiguity: panel-host-priority policy.
	test_panel_host_wins_when_registered_after_text_host()
	test_panel_host_stays_when_text_host_registers_after()
	test_two_text_hosts_still_last_wins()
	test_two_panel_hosts_still_last_wins()
	test_deregister_with_expected_host_is_identity_checked()
	test_deregister_without_expected_host_preserves_legacy_behavior()

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


# ── Stub hosts for the panel-host-priority collision policy ──────────────────
#
# Mirror the live shape (bug 019f6b9221b6): a generic buffer-canonical text
# host and a plugin panel host both try to bind the same editor_name. Real
# hosts are TextEditorAnnotationHost (get_document_identity().kind == "text")
# and an off-tree plugin host such as the pcb plugin's PcbAnnotationHost
# (kind == "pcb") — these stubs reproduce just the identity contract so the
# test stays generic (zero pcb vocabulary) and lives entirely in core.

class _StubTextHost extends AnnotationHost:
	func get_document_identity() -> Dictionary:
		return {"kind": "text", "path": "", "display_name": "Text", "save_policy": "sidecar"}


class _StubPanelHost extends AnnotationHost:
	func get_document_identity() -> Dictionary:
		return {"kind": "widget", "path": "", "display_name": "Widget", "save_policy": "sidecar"}


func test_panel_host_wins_when_registered_after_text_host() -> void:
	print("test_panel_host_wins_when_registered_after_text_host:")
	AnnotationHostRegistry._reset_for_test()
	var text_host := _StubTextHost.new()
	var panel_host := _StubPanelHost.new()
	AnnotationHostRegistry.register("shared.name", text_host)
	AnnotationHostRegistry.register("shared.name", panel_host)
	check("panel host wins after text-then-panel registration",
		AnnotationHostRegistry.get_host("shared.name") == panel_host)


func test_panel_host_stays_when_text_host_registers_after() -> void:
	print("test_panel_host_stays_when_text_host_registers_after:")
	AnnotationHostRegistry._reset_for_test()
	var panel_host := _StubPanelHost.new()
	var text_host := _StubTextHost.new()
	AnnotationHostRegistry.register("shared.name", panel_host)
	AnnotationHostRegistry.register("shared.name", text_host)
	check("panel host is NOT displaced by a later text-host registration",
		AnnotationHostRegistry.get_host("shared.name") == panel_host)


func test_two_text_hosts_still_last_wins() -> void:
	print("test_two_text_hosts_still_last_wins:")
	AnnotationHostRegistry._reset_for_test()
	var first := _StubTextHost.new()
	var second := _StubTextHost.new()
	AnnotationHostRegistry.register("shared.name", first)
	AnnotationHostRegistry.register("shared.name", second)
	check("equal-tier (text/text) collision still last-wins",
		AnnotationHostRegistry.get_host("shared.name") == second)


func test_two_panel_hosts_still_last_wins() -> void:
	print("test_two_panel_hosts_still_last_wins:")
	AnnotationHostRegistry._reset_for_test()
	var first := _StubPanelHost.new()
	var second := _StubPanelHost.new()
	AnnotationHostRegistry.register("shared.name", first)
	AnnotationHostRegistry.register("shared.name", second)
	check("equal-tier (panel/panel) collision still last-wins",
		AnnotationHostRegistry.get_host("shared.name") == second)


func test_deregister_with_expected_host_is_identity_checked() -> void:
	print("test_deregister_with_expected_host_is_identity_checked:")
	AnnotationHostRegistry._reset_for_test()
	var text_host := _StubTextHost.new()
	var panel_host := _StubPanelHost.new()
	AnnotationHostRegistry.register("shared.name", text_host)
	AnnotationHostRegistry.register("shared.name", panel_host)  # panel wins per policy
	# The (losing) text host's owning editor closes and deregisters itself,
	# correctly identifying which host it owns. It must NOT wipe out the
	# panel host's live registration.
	AnnotationHostRegistry.deregister("shared.name", text_host)
	check("identity-checked deregister of a non-owning host is a no-op",
		AnnotationHostRegistry.get_host("shared.name") == panel_host)
	AnnotationHostRegistry.deregister("shared.name", panel_host)
	check("identity-checked deregister of the actual owner removes the entry",
		AnnotationHostRegistry.get_host("shared.name") == null)


func test_deregister_without_expected_host_preserves_legacy_behavior() -> void:
	print("test_deregister_without_expected_host_preserves_legacy_behavior:")
	AnnotationHostRegistry._reset_for_test()
	var host := AnnotationHost.new()
	AnnotationHostRegistry.register("Legacy", host)
	# Existing Editor.gd call sites pass only editor_name — must keep erasing
	# unconditionally so today's runtime behavior is unchanged by this fix.
	AnnotationHostRegistry.deregister("Legacy")
	check("no-arg deregister still erases unconditionally",
		AnnotationHostRegistry.get_host("Legacy") == null)
