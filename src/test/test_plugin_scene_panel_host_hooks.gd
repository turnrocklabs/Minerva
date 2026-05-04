extends SceneTree
## Headless tests for PluginScenePanelHost.invoke_restore_from_note and
## invoke_render_for_llm — the two new hooks added in DCR work item
## 019df4dcf8ec (host protocol for plugin_data note round-trip).
##
## Run:
##   godot --headless --path ~/github/Minerva/src \
##     --script test/test_plugin_scene_panel_host_hooks.gd

var Host: Script = null

var _pass: int = 0
var _fail: int = 0


# ── Stub panels ────────────────────────────────────────────────────────

class StubRestorePanel extends Node:
	var last_payload: Dictionary = {}
	var return_value: bool = true

	func _on_panel_restore_from_note(payload: Dictionary) -> bool:
		last_payload = payload
		return return_value


class StubRenderPanel extends Node:
	var last_ctx: Dictionary = {}
	var return_value: Variant = null

	func _on_panel_render_for_llm(ctx: Dictionary) -> Variant:
		last_ctx = ctx
		return return_value


class BarePanel extends Node:
	pass


# ── Lifecycle ──────────────────────────────────────────────────────────

func _init() -> void:
	process_frame.connect(_run_tests, CONNECT_ONE_SHOT)


func _run_tests() -> void:
	Host = load("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")

	print("=== PluginScenePanelHost new hooks — invoke_restore_from_note + invoke_render_for_llm ===\n")

	test_restore_returns_true_when_stub_returns_true()
	test_restore_returns_false_when_stub_returns_false()
	test_restore_handles_missing_hook()
	test_restore_handles_null_panel()
	test_restore_passes_payload_through()

	test_render_returns_array_when_stub_returns_array()
	test_render_returns_empty_when_stub_returns_non_array()
	test_render_returns_empty_when_method_missing()
	test_render_returns_empty_when_panel_null()
	test_render_passes_ctx_through()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(description: String, condition: bool) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		printerr("  FAIL: %s" % description)


# ── invoke_restore_from_note ───────────────────────────────────────────

func test_restore_returns_true_when_stub_returns_true() -> void:
	print("test_restore_returns_true_when_stub_returns_true:")
	var stub: = StubRestorePanel.new()
	stub.return_value = true
	root.add_child(stub)
	var ok: bool = Host.invoke_restore_from_note(stub, {"version": 1, "deck": {}})
	_check("returns true", ok == true)
	stub.queue_free()


func test_restore_returns_false_when_stub_returns_false() -> void:
	print("test_restore_returns_false_when_stub_returns_false:")
	var stub: = StubRestorePanel.new()
	stub.return_value = false
	root.add_child(stub)
	var ok: bool = Host.invoke_restore_from_note(stub, {"version": 99})
	_check("returns false", ok == false)
	stub.queue_free()


func test_restore_handles_missing_hook() -> void:
	print("test_restore_handles_missing_hook:")
	var bare: = BarePanel.new()
	root.add_child(bare)
	var ok: bool = Host.invoke_restore_from_note(bare, {})
	_check("returns false when hook missing", ok == false)
	bare.queue_free()


func test_restore_handles_null_panel() -> void:
	print("test_restore_handles_null_panel:")
	var ok: bool = Host.invoke_restore_from_note(null, {})
	_check("returns false when panel_root null", ok == false)


func test_restore_passes_payload_through() -> void:
	print("test_restore_passes_payload_through:")
	var stub: = StubRestorePanel.new()
	stub.return_value = true
	root.add_child(stub)
	var sent: = {"version": 1, "plugin_id": "presentation", "deck": {"slides": [{"id": "s1"}]}}
	var _ok: bool = Host.invoke_restore_from_note(stub, sent)
	_check("payload reached panel verbatim", stub.last_payload == sent)
	stub.queue_free()


# ── invoke_render_for_llm ──────────────────────────────────────────────

func test_render_returns_array_when_stub_returns_array() -> void:
	print("test_render_returns_array_when_stub_returns_array:")
	var stub: = StubRenderPanel.new()
	var img: = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	stub.return_value = [
		{"type": "text", "text": "Slide 1: Hello"},
		{"type": "image", "image": img, "alt": "Slide 1"},
		{"type": "text", "text": "Slide 2: World"},
	]
	root.add_child(stub)
	var parts: Array = Host.invoke_render_for_llm(stub, {})
	_check("returned 3 parts", parts.size() == 3)
	if parts.size() == 3:
		_check("first part is text", String((parts[0] as Dictionary).get("type", "")) == "text")
		_check("second part is image", String((parts[1] as Dictionary).get("type", "")) == "image")
		_check("third part is text", String((parts[2] as Dictionary).get("type", "")) == "text")
	stub.queue_free()


func test_render_returns_empty_when_stub_returns_non_array() -> void:
	print("test_render_returns_empty_when_stub_returns_non_array:")
	var stub: = StubRenderPanel.new()
	stub.return_value = {"this": "is", "not": "an array"}
	root.add_child(stub)
	var parts: Array = Host.invoke_render_for_llm(stub, {})
	_check("returns empty Array on non-Array result", parts.size() == 0)
	stub.queue_free()


func test_render_returns_empty_when_method_missing() -> void:
	print("test_render_returns_empty_when_method_missing:")
	var bare: = BarePanel.new()
	root.add_child(bare)
	var parts: Array = Host.invoke_render_for_llm(bare, {})
	_check("returns empty Array when hook absent", parts.size() == 0)
	bare.queue_free()


func test_render_returns_empty_when_panel_null() -> void:
	print("test_render_returns_empty_when_panel_null:")
	var parts: Array = Host.invoke_render_for_llm(null, {})
	_check("returns empty Array when panel_root null", parts.size() == 0)


func test_render_passes_ctx_through() -> void:
	print("test_render_passes_ctx_through:")
	var stub: = StubRenderPanel.new()
	stub.return_value = []
	root.add_child(stub)
	var sent: = {"plugin_id": "presentation", "panel_name": "SlideEditorPanel"}
	var _parts: Array = Host.invoke_render_for_llm(stub, sent)
	_check("ctx reached panel verbatim", stub.last_ctx == sent)
	stub.queue_free()
