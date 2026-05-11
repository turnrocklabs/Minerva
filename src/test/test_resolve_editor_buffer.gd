extends SceneTree
## Unit tests for CapabilityBroker._resolve_editor_buffer (phase 5 R7 follow-up).
##
## Run: godot --headless --path src --script test/test_resolve_editor_buffer.gd
##
## Tracks docket: minerva 019e18e43acc75f0b8e5196877d66d4e
##
## Background — the bypass class this guards against:
##   Pre-fix, _resolve_editor_buffer fell through to
##   DocumentRegistry.get_or_create_buffer(ed_file) for PLUGIN_SCENE editors
##   that did NOT have a broker-attached buffer. That created an incidental
##   buffer for any plugin-scene editor with a file path (e.g. .mdeck files
##   opened via the file menu), which then routed the host.documents.*
##   capability handlers through the buffer-canonical branch — bypassing
##   the panel-canonical IPC round-trip AND the broker's blob-strip walker.
##
##   The post-fix behavior: for PLUGIN_SCENE editors, ONLY the broker-
##   attached buffer counts (the paired_dsl pattern via
##   PluginScenePanelBroker.attach_buffer_to_panel). No fallthrough.
##   Non-PLUGIN_SCENE editors still use the path-keyed fallthrough — that's
##   how MCPDocTools' doc_read/doc_write expose text/graphics editors.
##
##   Saved hint: minerva-plugin-platform/host-documents-get-node-buffer-canonical-bypasses-strip
##   Fix commit: (this round)
##
## Coverage:
##   1. PLUGIN_SCENE with file_path in DocumentRegistry but no broker attach
##      → returns null (the bypass-class fix — this is the regression guard).
##   2. PLUGIN_SCENE with no file_path and no broker attach → returns null
##      (anonymous panel — explicit defense even though the fall-through
##      wouldn't have triggered in this case pre-fix either).
##   3. Non-PLUGIN_SCENE (TEXT) with file_path in DocumentRegistry → returns
##      the registry buffer (path-keyed fallthrough preserved for editors
##      that legitimately use it).
##   4. Editor with no file_path and an anonymous buffer via
##      get_document_buffer() → returns that buffer (anonymous-bound path
##      still works regardless of editor type).

const CAPABILITY_BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const PLUGIN_AUDIT_LOG_SCRIPT_PATH  := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const PLUGIN_POLICY_SCRIPT_PATH     := "res://Scripts/Services/Plugins/PluginPolicy.gd"

const TEST_PLUGIN_SCENE_FILE := "/tmp/_resolve_editor_buffer_test_plugin_scene.mdeck"
const TEST_TEXT_FILE         := "/tmp/_resolve_editor_buffer_test_text.txt"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== _resolve_editor_buffer Unit Tests (phase 5 R7 follow-up) ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	await process_frame  # let autoloads register

	var AuditScript  = load(PLUGIN_AUDIT_LOG_SCRIPT_PATH)
	var PolicyScript = load(PLUGIN_POLICY_SCRIPT_PATH)
	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	check("scripts loaded",
		AuditScript != null and PolicyScript != null and BrokerScript != null)
	if AuditScript == null or PolicyScript == null or BrokerScript == null:
		return

	# Pre-seed DocumentRegistry with buffers for our test files. The registry
	# is a process-wide singleton; tests must use unique paths to avoid
	# colliding with each other across runs.
	var registry = DocumentRegistry.get_instance()
	registry.get_or_create_buffer(TEST_PLUGIN_SCENE_FILE)
	registry.get_or_create_buffer(TEST_TEXT_FILE)

	_test_plugin_scene_with_incidental_registry_buffer_returns_null(BrokerScript, PolicyScript, AuditScript)
	_test_plugin_scene_anonymous_returns_null(BrokerScript, PolicyScript, AuditScript)
	_test_non_plugin_scene_with_registry_buffer_returns_registry_buffer(BrokerScript, PolicyScript, AuditScript)
	_test_anonymous_bound_buffer_path_still_works(BrokerScript, PolicyScript, AuditScript)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		var msg := "  FAIL: %s" % label
		if not detail.is_empty():
			msg += " — " + detail
		printerr(msg)


func _make_broker(BrokerScript, PolicyScript, AuditScript) -> Object:
	var audit  = AuditScript.new()
	var policy = PolicyScript.new(null, audit)
	return BrokerScript.new(policy, audit)


# Mock editor — duck-types the fields _resolve_editor_buffer reads.
# Plain Dictionary works because `editor.type if "type" in editor` and the
# other dotted accesses also work on Dictionary in GDScript. But the
# anonymous-bound path requires `editor.has_method("get_document_buffer")`,
# which Dictionaries don't satisfy — so for tests that exercise that path
# we use a small RefCounted instead (see _AnonymousBoundEditor below).
func _mock_editor(type_val: int, file_path: String, plugin_id: String = "",
		panel_name: String = "") -> Dictionary:
	return {
		"type": type_val,
		"file": file_path,
		"plugin_id": plugin_id,
		"panel_name": panel_name,
	}


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# REGRESSION GUARD: this is the case that previously returned a registry
# buffer and caused the 58MB list_slides overflow (phase 5 R7 HITL).
# Post-fix, it must return null so capability handlers route through the
# panel-canonical branch (where the strip walker lives).
func _test_plugin_scene_with_incidental_registry_buffer_returns_null(
		BrokerScript, PolicyScript, AuditScript) -> void:
	print("\n-- _test_plugin_scene_with_incidental_registry_buffer_returns_null --")
	var broker = _make_broker(BrokerScript, PolicyScript, AuditScript)

	# Sanity: the registry IS holding a buffer for this path (we pre-seeded
	# it). If this assert fails the test setup is wrong.
	var registry = DocumentRegistry.get_instance()
	var seeded = registry.get_or_create_buffer(TEST_PLUGIN_SCENE_FILE)
	check("test fixture: registry has a buffer for the test path",
		seeded.get("ok", false))

	# Mock a PLUGIN_SCENE editor with the file path set. No broker attach
	# has been called — this is the host_owned_save case (e.g. .mdeck).
	var ed: Dictionary = _mock_editor(
		Editor.Type.PLUGIN_SCENE,
		TEST_PLUGIN_SCENE_FILE,
		"some_plugin",
		"some_panel",
	)
	var result: Variant = broker._resolve_editor_buffer(ed)
	check("plugin-scene editor with incidental registry buffer → null",
		result == null,
		"got: %s (pre-fix would have been the registry buffer, triggering buffer-canonical bypass)" % str(result))


func _test_plugin_scene_anonymous_returns_null(BrokerScript, PolicyScript, AuditScript) -> void:
	print("\n-- _test_plugin_scene_anonymous_returns_null --")
	var broker = _make_broker(BrokerScript, PolicyScript, AuditScript)
	var ed: Dictionary = _mock_editor(Editor.Type.PLUGIN_SCENE, "", "p", "panel")
	var result: Variant = broker._resolve_editor_buffer(ed)
	check("anonymous plugin-scene editor → null", result == null,
		"got: %s" % str(result))


# Non-PLUGIN_SCENE editors still use the path-keyed fallthrough. This is
# the behavior MCPDocTools.doc_read/doc_write relies on for text/graphics
# editors. Verifying we didn't break that.
func _test_non_plugin_scene_with_registry_buffer_returns_registry_buffer(
		BrokerScript, PolicyScript, AuditScript) -> void:
	print("\n-- _test_non_plugin_scene_with_registry_buffer_returns_registry_buffer --")
	var broker = _make_broker(BrokerScript, PolicyScript, AuditScript)
	var ed: Dictionary = _mock_editor(Editor.Type.TEXT, TEST_TEXT_FILE)
	var result: Variant = broker._resolve_editor_buffer(ed)
	check("text editor with registry buffer → buffer non-null", result != null,
		"path-keyed fallthrough must still work for non-plugin-scene editors")
	if result != null:
		var registry = DocumentRegistry.get_instance()
		var expected = registry.get_or_create_buffer(TEST_TEXT_FILE).get("buffer")
		check("text editor returns the SAME buffer instance as the registry",
			result == expected)


# RefCounted with get_document_buffer() — exercises the anonymous-bound path
# at the end of _resolve_editor_buffer. This path runs for any editor type;
# verifying it survives the PLUGIN_SCENE early-return.
class _AnonymousBoundEditor extends RefCounted:
	var type: int
	var file: String = ""
	var plugin_id: String = ""
	var panel_name: String = ""
	var _bound_buffer

	func _init(type_val: int, bound) -> void:
		type = type_val
		_bound_buffer = bound

	func get_document_buffer():
		return _bound_buffer


func _test_anonymous_bound_buffer_path_still_works(
		BrokerScript, PolicyScript, AuditScript) -> void:
	print("\n-- _test_anonymous_bound_buffer_path_still_works --")
	var broker = _make_broker(BrokerScript, PolicyScript, AuditScript)

	# Get a real buffer from the registry to use as the anonymous-bound
	# target (any DocumentBuffer instance works).
	var registry = DocumentRegistry.get_instance()
	var anon = registry.get_or_create_buffer("/tmp/_resolve_editor_buffer_test_anon.txt")
	check("test fixture: anonymous buffer created", anon.get("ok", false))
	if not anon.get("ok", false):
		return

	# Anonymous editor: type=TEXT, no file path, but `get_document_buffer()`
	# returns a real buffer. Must return that buffer.
	var ed_text := _AnonymousBoundEditor.new(Editor.Type.TEXT, anon.buffer)
	var result_text: Variant = broker._resolve_editor_buffer(ed_text)
	check("anonymous-bound TEXT editor → returns the bound buffer",
		result_text == anon.buffer,
		"got: %s" % str(result_text))

	# Anonymous PLUGIN_SCENE editor with bound buffer but no broker attach.
	# Under the new architectural rule, PLUGIN_SCENE editors only honor
	# the broker-attached buffer — NOT get_document_buffer(). So this must
	# return null even though get_document_buffer() would return a buffer.
	# (The anonymous-bound path is downstream of the PLUGIN_SCENE early-return.)
	var ed_plugin := _AnonymousBoundEditor.new(Editor.Type.PLUGIN_SCENE, anon.buffer)
	ed_plugin.plugin_id = "p"
	ed_plugin.panel_name = "panel"
	var result_plugin: Variant = broker._resolve_editor_buffer(ed_plugin)
	check("anonymous-bound PLUGIN_SCENE editor without broker attach → null",
		result_plugin == null,
		"got: %s (plugin-scene only honors broker-attached buffers)" % str(result_plugin))
