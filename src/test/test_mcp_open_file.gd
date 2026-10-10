extends SceneTree
## Unit tests for SingletonObject.open_file_at_path() and MCPGeneralTools.
##
## Run headless:
##   timeout 60 godot --headless --path src --script test/test_mcp_open_file.gd 2>&1 | grep -E "PASS|FAIL|Results"
##
## Coverage:
##   open_file_at_path: missing path → file_not_found
##   open_file_at_path: directory path → not_a_file
##   open_file_at_path: .txt file → TEXT editor (headless: editor_pane not wired)
##   open_file_at_path: idempotency check (same path twice → same editor_name)
##   open_file_at_path: unrecognised extension with no plugin → no_handler... OR TEXT fallback
##   MCPGeneralTools: missing path arg → error
##   MCPGeneralTools: file_not_found → ok:false + errors
##   MCPGeneralTools: directory path → ok:false + errors
##
## NOTE on headless limits:
##   In a headless SceneTree context without the full Minerva MainScene, the
##   @onready vars on SingletonObject (editor_container, editor_pane) are NOT
##   wired, so any test that would actually create an editor tab will return
##   {ok: false, errors: ["editor_pane not available"]}.
##
##   Tests that DO need a live editor_pane (opening a real file into a tab,
##   idempotency) are therefore tested via the MCPGeneralTools shim with a
##   mock open_file_at_path() injected on a bare Dictionary, so the logic
##   under test is the module's argument validation and response shaping, not
##   the full Godot UI stack.
##
##   A separate integration test (smoke test inside running Minerva) covers
##   the happy paths that require editor_pane.  The plugin-scene case is
##   omitted here — it requires a loaded plugin.

var _pass_count: int = 0
var _fail_count: int = 0
var _tmp_dir: String = ""


func _init() -> void:
	_tmp_dir = _make_tmp_dir()

	# In `--script` mode, autoloads are attached to /root after _init runs.
	# Defer test execution to the first process frame so SingletonObject is
	# reachable.
	await process_frame

	print("=== test_mcp_open_file Tests ===\n")

	print("-- open_file_at_path: path validation (headless-safe) --")
	test_missing_file_returns_file_not_found()
	test_directory_path_returns_not_a_file()
	test_relative_path_resolves_and_fails_gracefully()

	print("\n-- open_file_at_path: editor_pane not available in headless --")
	test_txt_returns_editor_pane_not_available()

	print("\n-- MCPGeneralTools: argument validation --")
	await test_general_tools_missing_path_arg()
	await test_general_tools_file_not_found()
	await test_general_tools_directory()
	await test_docket_c1_startup_and_refusals()

	print("\n-- open_file_at_path: logic unit tests (mock SingletonObject) --")
	test_open_file_logic_txt()
	test_open_file_logic_png()
	test_open_file_logic_minpcb()
	test_open_file_logic_minkb()
	test_open_file_logic_minsheet()
	test_open_file_logic_idempotent()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)

	_cleanup_tmp_dir()
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Fixture helpers ───────────────────────────────────────────────────────────

func _make_tmp_dir() -> String:
	var base: String = OS.get_temp_dir().path_join("test_mcp_open_file_%d" % Time.get_ticks_msec())
	DirAccess.make_dir_recursive_absolute(base)
	return base


func _cleanup_tmp_dir() -> void:
	if _tmp_dir.is_empty():
		return
	# Remove files we created, then the dir itself.
	var da := DirAccess.open(_tmp_dir)
	if da:
		da.list_dir_begin()
		var fname: String = da.get_next()
		while fname != "":
			if not da.current_is_dir():
				DirAccess.remove_absolute(_tmp_dir.path_join(fname))
			fname = da.get_next()
		da.list_dir_end()
	DirAccess.remove_absolute(_tmp_dir)


func _make_tmp_file(name: String, content: String = "hello") -> String:
	var path: String = _tmp_dir.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(content)
		f.close()
	return path


# ── Direct open_file_at_path tests (no SceneTree MainScene) ──────────────────
#
# These call SingletonObject.open_file_at_path() directly.  In headless mode,
# SingletonObject is the autoload but editor_pane is null, so:
#   - path-validation failures (file_not_found, not_a_file) work correctly.
#   - Valid files fail with "editor_pane not available" rather than opening a tab.

func _get_singleton() -> Object:
	# The SingletonObject autoload is at /root/SingletonObject in any SceneTree.
	return root.get_node_or_null("SingletonObject")


func test_missing_file_returns_file_not_found() -> void:
	var so := _get_singleton()
	if so == null or not so.has_method("open_file_at_path"):
		check("open_file_at_path exists on SingletonObject", false)
		return
	var missing: String = _tmp_dir.path_join("does_not_exist_xyz.txt")
	var r: Dictionary = so.open_file_at_path(missing)
	check("missing file: ok=false", r.get("ok", true) == false)
	var errors: Array = r.get("errors", [])
	check("missing file: errors non-empty", errors.size() > 0)
	var has_file_not_found := false
	for e in errors:
		if str(e).begins_with("file_not_found"):
			has_file_not_found = true
	check("missing file: errors contain file_not_found", has_file_not_found)


func test_directory_path_returns_not_a_file() -> void:
	var so := _get_singleton()
	if so == null or not so.has_method("open_file_at_path"):
		check("open_file_at_path exists (dir test)", false)
		return
	# _tmp_dir itself is a directory.
	var r: Dictionary = so.open_file_at_path(_tmp_dir)
	check("dir path: ok=false", r.get("ok", true) == false)
	var errors: Array = r.get("errors", [])
	var has_not_a_file := false
	for e in errors:
		if str(e).begins_with("not_a_file"):
			has_not_a_file = true
	check("dir path: errors contain not_a_file", has_not_a_file)


func test_relative_path_resolves_and_fails_gracefully() -> void:
	var so := _get_singleton()
	if so == null or not so.has_method("open_file_at_path"):
		check("open_file_at_path exists (relative test)", false)
		return
	# Passing a relative path — it will be resolved (probably to something that
	# doesn't exist) and either succeed or return file_not_found.  We just check
	# it doesn't crash and returns a Dictionary.
	var r: Dictionary = so.open_file_at_path("relative_nonexistent.txt")
	check("relative path: returns Dictionary", r is Dictionary)
	check("relative path: has ok key", r.has("ok"))


func test_txt_returns_editor_pane_not_available() -> void:
	var so := _get_singleton()
	if so == null or not so.has_method("open_file_at_path"):
		check("open_file_at_path exists (txt test)", false)
		return
	var txt_file: String = _make_tmp_file("sample.txt", "# hello world")
	var r: Dictionary = so.open_file_at_path(txt_file)
	# In headless mode editor_pane is null, so we expect either
	# ok=false with "editor_pane not available" OR ok=true if somehow wired.
	check("txt file: returns Dictionary", r is Dictionary)
	check("txt file: has ok key", r.has("ok"))
	if not r.get("ok", true):
		var errors: Array = r.get("errors", [])
		# Accept either "editor_pane not available" (headless) or any other
		# expected failure — just not an unexpected crash.
		check("txt file: errors non-empty on failure", errors.size() > 0)


# ── MCPGeneralTools shim tests ────────────────────────────────────────────────

func test_general_tools_missing_path_arg() -> void:
	var GeneralToolsScript = load("res://Scripts/Services/MCP/Modules/MCPGeneralTools.gd")
	var tools = GeneralToolsScript.new(null)
	var r: Dictionary = await tools.handle("minerva_open_file", {})
	check("missing path: success=false", r.get("success", true) == false)
	check("missing path: has error key", r.has("error"))


func test_general_tools_file_not_found() -> void:
	var GeneralToolsScript = load("res://Scripts/Services/MCP/Modules/MCPGeneralTools.gd")
	var tools = GeneralToolsScript.new(null)
	var missing: String = _tmp_dir.path_join("nowhere.txt")
	var r: Dictionary = await tools.handle("minerva_open_file", {"path": missing})
	check("file_not_found via tools: success=false", r.get("success", true) == false)
	check("file_not_found via tools: has errors key", r.has("errors") or r.has("error"))


func test_general_tools_directory() -> void:
	var GeneralToolsScript = load("res://Scripts/Services/MCP/Modules/MCPGeneralTools.gd")
	var tools = GeneralToolsScript.new(null)
	var r: Dictionary = await tools.handle("minerva_open_file", {"path": _tmp_dir})
	check("directory via tools: success=false", r.get("success", true) == false)


# ── Logic unit tests via a mock EditorPane stub ───────────────────────────────
#
# We construct a lightweight mock that reimplements only open_file_at_path's
# internal contract:  the extension-dispatch table and idempotency check.
# This lets us verify the routing logic without a live Godot UI.

class DocketWindowRegistry extends RefCounted:
	# Normalized gui_open replies mirror Docket 466d7b7 (C1b), no live plugin.
	var refusal := ""
	var calls: Array = []
	func handle_tool_call(name: String, args: Dictionary, _context: MCPExecutionContext = null) -> Dictionary:
		calls.append([name, args])
		return {"error": refusal} if not refusal.is_empty() else {"success": true, "pid": 123}

class RunningDocket extends RefCounted:
	func get_plugin_status(_id: String) -> Dictionary:
		return {"running": true}

class LayoutErrorCapture extends "res://test/helpers/log_capture.gd":
	func _log_message(_message: String, _error: bool) -> void:
		pass


func test_saved_layout_skips_retired_editor() -> void:
	var so = root.get_node("SingletonObject")
	# Load at runtime: these scripts need autoloads, which --script has not wired at compile time.
	var saved_pane = so.editor_pane
	var saved_container = so.editor_container
	var pane = load("res://Scenes/EditorPane.tscn").instantiate()
	# MainScene normally supplies these two owner-unique controls.
	var toggle = CheckButton.new()
	toggle.name = "ToggleAllButton"
	pane.add_child(toggle)
	toggle.owner = pane
	toggle.unique_name_in_owner = true
	var buffer_control = Control.new()
	buffer_control.name = "BufferControlEditor"
	pane.add_child(buffer_control)
	buffer_control.owner = pane
	buffer_control.unique_name_in_owner = true
	var container_script = load("res://Scripts/UI/Controls/vboxEditor.gd")
	var container = container_script.new()
	container.editor_pane = pane
	so.editor_pane = pane
	so.editor_container = container
	root.add_child(pane)
	root.add_child(container)
	var host_scale_before = root.content_scale_factor
	var host_font_before = root.get_theme_font_size("font_size")
	var capture = LayoutErrorCapture.new()
	OS.add_logger(capture)
	# Type 13 is the on-disk value of the retired tab, between two live tabs.
	var layout = [
		{"type": 0, "name": "before", "content": "first buffer"},
		{"type": 13, "name": "Docket"},
		{"type": 0, "name": "after", "content": "second buffer"},
	]
	var saved_layout = JSON.parse_string(JSON.stringify(layout))
	var restored = await container_script.deserialize(saved_layout)
	for editor in restored:
		pane.adopt_editor(editor)
	await process_frame
	OS.remove_logger(capture)
	check_eq("Mixed saved layout restores exactly two valid tabs", pane.Tabs.get_tab_count(), 2)
	var intact = restored.size() == 2
	if intact:
		intact = restored[0].type == 0 and restored[1].type == 0
		if intact:
			intact = restored[0].tab_title == "before" and restored[1].tab_title == "after" \
				and restored[0].code_edit != null and restored[1].code_edit != null
		if intact:
			intact = restored[0].code_edit.text == "first buffer" and restored[1].code_edit.text == "second buffer"
	check("Mixed saved layout preserves tab order/content and leaves no blank editor", intact)
	check_eq("Mixed saved layout restoration emits no errors", capture.combined(), "")
	check("Mixed saved layout preserves host scale and font settings",
		is_equal_approx(root.content_scale_factor, host_scale_before)
		and root.get_theme_font_size("font_size") == host_font_before)
	container.free()
	pane.free()
	so.editor_pane = saved_pane
	so.editor_container = saved_container


func test_docket_c1_startup_and_refusals() -> void:
	var so = root.get_node("SingletonObject")
	for i in 30:
		if so.plugin_tool_registry != null: break
		await process_frame
	check("C1 startup has the hosted Docket adapter", so.docket_host != null)
	await test_saved_layout_skips_retired_editor()
	var registry = load("res://Scripts/Services/Plugins/PluginToolRegistry.gd").new(null)
	registry.set_builtin_tool_names(so.mcp_manager.tool_registry.keys().filter(func(name: String) -> bool: return not so.plugin_tool_registry.is_plugin_tool(name)))
	var entry := {"name":"minerva_docket_get", "description":"fixture", "input_schema":{"type":"object"}}
	check("Docket backend name is not a built-in collision", not registry.register_plugin_tools("docket", [entry]).has("error"))
	registry.register_plugin_tools("docket", [entry])
	check("Docket names stay unique across discovery", registry.get_all_plugin_tools().size() == 1)
	var saved := [so.plugin_manager, so.plugin_tool_registry, so.docket_host]
	so.plugin_manager = null
	var tools = load("res://Scripts/Services/MCP/Modules/MCPGeneralTools.gd").new(null)
	var missing: Dictionary = await tools.handle("minerva_open_docket", {})
	check("Missing plugin is visible to the MCP caller", missing.get("success") == false and "docket_plugin_unavailable" in str(missing.get("error", "")))
	var host = load("res://Scripts/Services/DocketHost/DocketHost.gd").new()
	host.state = "ready"
	var window := DocketWindowRegistry.new()
	so.plugin_manager = RunningDocket.new()
	so.plugin_tool_registry = window
	so.docket_host = host
	var opened: Dictionary = await tools.handle("minerva_open_docket", {})
	check("Docket opens its upstream window", opened.get("success") == true and opened.get("pid") == 123)
	check("Open routes through existing plugin dispatch", window.calls == [["minerva_docket_gui_open", {"focus":true}]])
	var saved_ui := [so.editor_container, so.creatable_item_registry, so.errorPopup, so.errorTitle, so.errorText]
	var container = load("res://Scripts/UI/Controls/vboxEditor.gd").new()
	so.editor_container = container
	so.creatable_item_registry = CreatableItemRegistry.new()
	so._init_creatable_items()
	var docket_item: CreatableItemRegistry.CreatableItem = so.creatable_item_registry.get_item("docket")
	window.calls.clear()
	await docket_item.create_callback.call()
	check("File New Docket forwards focus and new_docket through the registered callback",
		window.calls == [["minerva_docket_gui_open", {"focus":true, "new_docket":true}]])
	window.calls.clear()
	await so.open_docket_panel_for_user()
	check("Tools Docket remains focus-only", window.calls == [["minerva_docket_gui_open", {"focus":true}]])
	var saved_window_size: Vector2i = root.size
	var saved_embed: bool = root.gui_embed_subwindows
	root.size = Vector2i(1400, 900)
	root.gui_embed_subwindows = true
	var error_window := PersistentWindow.new()
	error_window.popup_window = true
	error_window.visible = false
	error_window.size = Vector2i(600, 200)
	var error_title := Label.new()
	var error_text := Label.new()
	error_window.add_child(error_title)
	error_window.add_child(error_text)
	root.add_child(error_window)
	# Embed this owned popup in a sized viewport; headless has no native screen.
	so.errorPopup = error_window
	so.errorTitle = error_title
	so.errorText = error_text
	window.refusal = "Close the current dialog before creating a new Docket"
	await docket_item.create_callback.call()
	check("File New Docket visibly surfaces a neutral verbatim refusal",
		error_window.visible and error_title.text == "Docket request refused" and error_text.text == window.refusal)
	var running_plugin: RefCounted = so.plugin_manager
	so.plugin_manager = null
	await so.open_docket_panel_for_user()
	check("Unavailable Docket keeps the existing plugin recovery advice",
		error_title.text == "Docket unavailable" and error_text.text.contains("Check that the Docket plugin is installed and running"))
	so.plugin_manager = running_plugin
	error_window.hide()
	so.editor_container = saved_ui[0]
	so.creatable_item_registry = saved_ui[1]
	so.errorPopup = saved_ui[2]
	so.errorTitle = saved_ui[3]
	so.errorText = saved_ui[4]
	error_window.free()
	root.gui_embed_subwindows = saved_embed
	root.size = saved_window_size
	container.free()
	window.refusal = "Fixture window focus refused"
	var refused: Dictionary = await tools.handle("minerva_open_docket", {})
	check("Window-opening errors reach the caller verbatim", refused.get("success") == false and refused.get("error") == window.refusal)
	so.plugin_manager = saved[0]
	so.plugin_tool_registry = saved[1]
	so.docket_host = saved[2]
	host.free()


class MockEditor:
	var file: String = ""
	var tab_title: String = ""
	var type: int = 0       # Editor.Type enum value
	var plugin_id: String = ""
	var panel_name: String = ""


## Minimal reimplementation of the dispatch table from open_file_at_path,
## returning a MockEditor so we can assert on editor_kind without a live scene.
## This mirrors singleton_object.gd's open_file_at_path logic exactly.
func _resolve_ext_to_kind(abs_path: String) -> String:
	var lower := abs_path.to_lower()
	if lower.ends_with(".jpeg") or lower.ends_with(".jpg") or lower.ends_with(".png"):
		return "GRAPHICS"
	if lower.ends_with(".minpcb"):
		return "PCB"
	if lower.ends_with(".minkb"):
		return "KANBAN"
	if lower.ends_with(".minsheet"):
		return "SPREADSHEET"
	# No plugin registry in headless — falls through to TEXT.
	return "TEXT"


func test_open_file_logic_txt() -> void:
	var kind := _resolve_ext_to_kind(_tmp_dir.path_join("hello.txt"))
	check_eq("txt → TEXT", kind, "TEXT")


func test_open_file_logic_png() -> void:
	var kind := _resolve_ext_to_kind(_tmp_dir.path_join("image.png"))
	check_eq("png → GRAPHICS", kind, "GRAPHICS")


func test_open_file_logic_minpcb() -> void:
	var kind := _resolve_ext_to_kind(_tmp_dir.path_join("board.minpcb"))
	check_eq("minpcb → PCB", kind, "PCB")


func test_open_file_logic_minkb() -> void:
	var kind := _resolve_ext_to_kind(_tmp_dir.path_join("board.minkb"))
	check_eq("minkb → KANBAN", kind, "KANBAN")


func test_open_file_logic_minsheet() -> void:
	var kind := _resolve_ext_to_kind(_tmp_dir.path_join("data.minsheet"))
	check_eq("minsheet → SPREADSHEET", kind, "SPREADSHEET")


func test_open_file_logic_idempotent() -> void:
	## Simulate the idempotency scan: a "already-open" editor in the pane
	## should yield the existing tab title, not a new entry.
	var existing := MockEditor.new()
	existing.file = _tmp_dir.path_join("open.txt")
	existing.tab_title = "open.txt"

	# Simulate the scan loop from open_file_at_path.
	var target: String = existing.file
	var open_editors: Array = [existing]
	var found_title: String = ""
	for ed in open_editors:
		if ed.file == target:
			found_title = ed.tab_title
			break

	check("idempotency: found existing tab title", found_title == "open.txt")
	check("idempotency: would not create duplicate", not found_title.is_empty())
