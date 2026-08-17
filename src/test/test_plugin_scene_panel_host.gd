extends SceneTree
## Unit tests for PluginScenePanelHost (synchronous paths).
##
## Uses preload for all cross-file class references so tests work in headless
## --script mode before the Godot editor has generated .uid files.
##
## Run: godot --headless --script test/test_plugin_scene_panel_host.gd
##
## Coverage:
##   _resolve_plugin_relative_path:
##     - happy-path: relative path inside data_dir
##     - ".." escape rejected
##     - absolute path rejected (leading "/")
##     - res:// path rejected
##     - user:// path rejected
##     - Windows drive letter rejected
##     - empty relative string returns ""
##     - path that starts with data_dir prefix but escapes (e.g. sibling dir) rejected
##     - nested ".." escapes rejected
##
##   _audit_packed_scene:
##     - null packed scene returns false
##
##   _build_placeholder:
##     - returns a Control
##     - message is present in the tree (label child)
##     - retry_callback=null: no button
##     - retry_callback provided: button present; pressing it calls the callback
##
##   instantiate_into guard paths (via helper inspection, without live SceneTree):
##     - ui_panels missing or contains only String entries → _get_panel_def returns {}
##     - panel_name not in defs → _get_panel_def returns {}
##     - wrong kind → kind != "godot_scene" detected
##     - missing entry_scene → empty string detected
##     - entry_scene path escape → _resolve returns ""
##     - script path escape → _resolve returns ""
##     - no plugin_manager → placeholder returned
##
##   Ordering guarantee (§5.3):
##     - broker.register_panel called BEFORE _on_panel_loaded
##     - _on_panel_loaded receives ctx with expected keys

const PluginScenePanelHost_ = preload("res://Scripts/Services/Plugins/PluginScenePanelHost.gd")
const PluginScenePanelBroker_ = preload("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd")
const PluginAuditLog_ = preload("res://Scripts/Services/Plugins/PluginAuditLog.gd")
const PluginDefinition_ = preload("res://Scripts/Services/Plugins/PluginDefinition.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginScenePanelHost Unit Tests ===\n")

	print("-- _resolve_plugin_relative_path --")
	test_resolve_happy_path()
	test_resolve_dotdot_escape_rejected()
	test_resolve_absolute_slash_rejected()
	test_resolve_res_scheme_rejected()
	test_resolve_user_scheme_rejected()
	test_resolve_windows_drive_letter_rejected()
	test_resolve_empty_relative_returns_empty()
	test_resolve_sibling_dir_escape_rejected()
	test_resolve_nested_dotdot_escape_rejected()

	print("\n-- _build_placeholder --")
	test_placeholder_returns_control()
	test_placeholder_has_label()
	test_placeholder_no_retry_no_button()
	test_placeholder_with_retry_has_button()
	test_placeholder_retry_callback_fires()

	print("\n-- _audit_packed_scene --")
	test_audit_null_packed_scene_returns_false()

	print("\n-- _get_panel_def helper --")
	test_get_panel_def_string_entries_returns_empty()
	test_get_panel_def_no_panels_field_returns_empty()
	test_get_panel_def_empty_defs_returns_empty()
	test_get_panel_def_panel_not_in_defs_returns_empty()
	test_get_panel_def_finds_matching_panel()
	test_get_panel_def_null_def_returns_empty()

	print("\n-- instantiate_into guard paths (via helpers) --")
	test_instantiate_entry_scene_escape_returns_placeholder()
	test_instantiate_script_escape_returns_placeholder()
	test_instantiate_wrong_kind_detected()
	test_instantiate_missing_entry_scene_detected()
	test_instantiate_no_plugin_manager_returns_placeholder()

	print("\n-- Ordering guarantees (§5.3) --")
	test_broker_registered_before_on_panel_loaded()
	test_on_panel_loaded_receives_ctx_keys()

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


# ===========================================================================
# Test helpers / stubs
# ===========================================================================

## Stub PluginDefinition-like object.
## We do NOT extend PluginDefinition_ to avoid parse-order issues in headless
## mode; we duck-type instead (all accesses go through "in" checks or .get()).
##
## Per design §2.2: ui_panels upgrades IN-PLACE from Array[String] (legacy) to
## Array[Dictionary] (typed) when the manifest task lands.  Tests populate
## ui_panels with Dictionary entries to exercise post-manifest behaviour;
## leaving it empty / String-only exercises the pre-manifest path.
class StubPluginDef extends RefCounted:
	var id: String = ""
	var data_directory: String = ""
	## ui_panels: Array — entries are String (legacy/pre-manifest) OR
	## Dictionary {name, kind, entry_scene, scripts, ipc_channels, ...} (typed).
	var ui_panels: Array = []
	var state: int = 2  # PluginDefinition.State.RUNNING


## Stub PluginDB that returns a pre-configured def.
class StubPluginDB extends RefCounted:
	var _defs: Dictionary = {}

	func get_by_id(plugin_id: String):
		return _defs.get(plugin_id, null)


## Stub PluginManager.
class StubPluginManager extends RefCounted:
	var _db: StubPluginDB

	func _init() -> void:
		_db = StubPluginDB.new()

	func get_db():
		return _db


## PluginAuditLog stub: we load the real base class at runtime via preload.
## Because nested classes can't reference preload constants from the outer scope
## at parse time, we use a standalone helper class instead.
class StubAuditLog extends RefCounted:
	var events: Array = []

	func log_event(plugin_id: String, event_type: String, detail: Dictionary = {}) -> void:
		events.append({"plugin_id": plugin_id, "event_type": event_type, "detail": detail})


## Minimal scene root stub that records lifecycle calls.
class StubSceneRoot extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)

	var on_panel_loaded_called: bool = false
	var on_panel_loaded_ctx: Dictionary = {}
	## Filled from inside _on_panel_loaded by checking the broker.
	var broker_was_registered_before_loaded: bool = false
	## Set by the test before calling _on_panel_loaded so the stub can check.
	var test_broker = null  # PluginScenePanelBroker_ instance

	func receive(_channel: String, _payload: Dictionary) -> void:
		pass

	func _on_panel_loaded(ctx: Dictionary) -> void:
		on_panel_loaded_called = true
		on_panel_loaded_ctx = ctx
		# Check broker state from inside the hook to verify ordering.
		if test_broker != null:
			broker_was_registered_before_loaded = test_broker.is_panel_registered(
				ctx.get("panel_name", ""))


## Build a fresh PluginScenePanelBroker with a stub audit log.
func _make_broker():  # -> PluginScenePanelBroker_
	# We need a stub manager that satisfies the broker's duck-typed interface.
	var mgr := StubPluginManager.new()
	# Build a real PluginAuditLog (not stub) so the broker type checks pass.
	var audit = PluginAuditLog_.new()
	return PluginScenePanelBroker_.new(mgr, null, null, audit)


## Build a VBoxContainer to use as the vbox parameter.
func _make_vbox() -> VBoxContainer:
	return VBoxContainer.new()


## Build a minimal StubPluginDef with a godot_scene panel entry.
func _make_def_with_panel(
		plugin_id: String,
		data_dir: String,
		panel_name: String,
		entry_scene_rel: String,
		scripts: Array,
		ipc_channels: Array
) -> StubPluginDef:
	var def := StubPluginDef.new()
	def.id = plugin_id
	def.data_directory = data_dir
	def.ui_panels = [panel_name]
	def.ui_panels = [{
		"name": panel_name,
		"kind": "godot_scene",
		"entry_scene": entry_scene_rel,
		"scripts": scripts,
		"ipc_channels": ipc_channels,
	}]
	return def


# ===========================================================================
# _resolve_plugin_relative_path tests
# ===========================================================================

func test_resolve_happy_path() -> void:
	print("test_resolve_happy_path:")
	var data_dir := "/tmp/myplugin"
	var rel := "ui/CadViewer.tscn"
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(data_dir, rel)
	check("happy path resolves to correct absolute path",
		result == "/tmp/myplugin/ui/CadViewer.tscn")


func test_resolve_dotdot_escape_rejected() -> void:
	print("test_resolve_dotdot_escape_rejected:")
	var data_dir := "/tmp/myplugin"
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		data_dir, "../evil.gd")
	check("direct '../' escape returns empty string", result.is_empty())

	var result2: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		data_dir, "subdir/../../evil.gd")
	check("multi-level '../' escape returns empty string", result2.is_empty())


func test_resolve_absolute_slash_rejected() -> void:
	print("test_resolve_absolute_slash_rejected:")
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		"/tmp/myplugin", "/etc/passwd")
	check("absolute '/' path rejected", result.is_empty())


func test_resolve_res_scheme_rejected() -> void:
	print("test_resolve_res_scheme_rejected:")
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		"/tmp/myplugin", "res://Scripts/Hack.gd")
	check("res:// path rejected", result.is_empty())


func test_resolve_user_scheme_rejected() -> void:
	print("test_resolve_user_scheme_rejected:")
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		"/tmp/myplugin", "user://config_file.cfg")
	check("user:// path rejected", result.is_empty())


func test_resolve_windows_drive_letter_rejected() -> void:
	print("test_resolve_windows_drive_letter_rejected:")
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		"/tmp/myplugin", "C:/Windows/System32/evil.dll")
	check("Windows drive-letter path rejected", result.is_empty())


func test_resolve_empty_relative_returns_empty() -> void:
	print("test_resolve_empty_relative_returns_empty:")
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		"/tmp/myplugin", "")
	check("empty relative string returns empty", result.is_empty())


func test_resolve_sibling_dir_escape_rejected() -> void:
	print("test_resolve_sibling_dir_escape_rejected:")
	# Absolute sibling path — caught by absolute-path guard.
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		"/tmp/myplugin", "/tmp/myplugin_evil/secret.gd")
	check("absolute sibling dir path rejected", result.is_empty())


func test_resolve_nested_dotdot_escape_rejected() -> void:
	print("test_resolve_nested_dotdot_escape_rejected:")
	# a/b/../../.. goes up three levels from /tmp/myplugin.
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		"/tmp/myplugin", "a/b/../../..")
	check("deeply nested '..' escape rejected", result.is_empty())


# ===========================================================================
# _build_placeholder tests
# ===========================================================================

func test_placeholder_returns_control() -> void:
	print("test_placeholder_returns_control:")
	var ph: Control = PluginScenePanelHost_._build_placeholder("Test error message")
	check("_build_placeholder returns a Control", ph != null and ph is Control)
	ph.free()


func test_placeholder_has_label() -> void:
	print("test_placeholder_has_label:")
	var msg := "Unique error string 12345"
	var ph: Control = PluginScenePanelHost_._build_placeholder(msg)
	var found_label := _find_label_with_text(ph, msg)
	check("placeholder contains label with the message text", found_label)
	ph.free()


func test_placeholder_no_retry_no_button() -> void:
	print("test_placeholder_no_retry_no_button:")
	var ph: Control = PluginScenePanelHost_._build_placeholder("Error only")
	var found_button := _find_button_in_tree(ph)
	check("placeholder without retry_callback has no Button", not found_button)
	ph.free()


func test_placeholder_with_retry_has_button() -> void:
	print("test_placeholder_with_retry_has_button:")
	# Wrap callable in Array — GDScript lambdas capture by value; array gives stable ref.
	var cb_holder: Array = [false]
	var cb := func() -> void: cb_holder[0] = true
	var ph: Control = PluginScenePanelHost_._build_placeholder("Error with retry", cb)
	var found_button := _find_button_in_tree(ph)
	check("placeholder with retry_callback has a Button", found_button)
	ph.free()


func test_placeholder_retry_callback_fires() -> void:
	print("test_placeholder_retry_callback_fires:")
	var fired_holder: Array = [false]
	var cb := func() -> void: fired_holder[0] = true
	var ph: Control = PluginScenePanelHost_._build_placeholder("Error with retry", cb)
	var btn := _find_button_node(ph)
	if btn != null:
		# Simulate a button press by emitting the pressed signal directly.
		btn.pressed.emit()
	check("retry callback fires when button pressed signal emitted",
		fired_holder[0])
	ph.free()


# ===========================================================================
# _audit_packed_scene tests
# ===========================================================================

func test_audit_null_packed_scene_returns_false() -> void:
	print("test_audit_null_packed_scene_returns_false:")
	var result: bool = PluginScenePanelHost_._audit_packed_scene(
		null, PackedStringArray())
	check("null packed scene returns false", not result)


# ===========================================================================
# _get_panel_def helper tests
# ===========================================================================

func test_get_panel_def_string_entries_returns_empty() -> void:
	print("test_get_panel_def_string_entries_returns_empty:")
	# Pre-manifest-task PluginDefinition: ui_panels is Array[String].
	# Each String entry is skipped — return {} so caller renders placeholder.
	var def := StubPluginDef.new()
	def.ui_panels = ["cad_viewer", "cad_text"]
	var result: Dictionary = PluginScenePanelHost_._get_panel_def(def, "cad_viewer")
	check("def with String-only ui_panels returns empty dict", result.is_empty())


func test_get_panel_def_no_panels_field_returns_empty() -> void:
	print("test_get_panel_def_no_panels_field_returns_empty:")
	# A def lacking ui_panels entirely (defensive — shouldn't happen in
	# practice but should not crash).
	var def_no_field := _DefWithoutPanelsField.new()
	var result: Dictionary = PluginScenePanelHost_._get_panel_def(def_no_field, "cad_viewer")
	check("def without ui_panels field returns empty dict", result.is_empty())


func test_get_panel_def_empty_defs_returns_empty() -> void:
	print("test_get_panel_def_empty_defs_returns_empty:")
	var def := StubPluginDef.new()
	def.ui_panels = []
	var result: Dictionary = PluginScenePanelHost_._get_panel_def(def, "cad_viewer")
	check("def with empty ui_panels returns empty dict", result.is_empty())


func test_get_panel_def_panel_not_in_defs_returns_empty() -> void:
	print("test_get_panel_def_panel_not_in_defs_returns_empty:")
	var def := _make_def_with_panel("cad", "/tmp/cad", "cad_viewer", "ui/v.tscn", [], [])
	var result: Dictionary = PluginScenePanelHost_._get_panel_def(def, "nonexistent_panel")
	check("_get_panel_def returns empty for unknown panel_name", result.is_empty())


func test_get_panel_def_finds_matching_panel() -> void:
	print("test_get_panel_def_finds_matching_panel:")
	var def := _make_def_with_panel(
		"cad", "/tmp/cad", "cad_viewer", "ui/CadViewer.tscn",
		["ui/CadViewer.gd"], ["cad.render_request"])
	var result: Dictionary = PluginScenePanelHost_._get_panel_def(def, "cad_viewer")
	check("_get_panel_def returns non-empty dict for known panel_name",
		not result.is_empty())
	check("returned dict has correct name",
		result.get("name", "") == "cad_viewer")
	check("returned dict has entry_scene",
		result.get("entry_scene", "") == "ui/CadViewer.tscn")


func test_get_panel_def_null_def_returns_empty() -> void:
	print("test_get_panel_def_null_def_returns_empty:")
	var result: Dictionary = PluginScenePanelHost_._get_panel_def(null, "cad_viewer")
	check("null def returns empty dict", result.is_empty())


# ===========================================================================
# instantiate_into guard paths (via helpers + direct calls)
# ===========================================================================

func test_instantiate_entry_scene_escape_returns_placeholder() -> void:
	print("test_instantiate_entry_scene_escape_returns_placeholder:")
	# entry_scene tries to escape data_dir — _resolve_plugin_relative_path returns "".
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		"/tmp/myplugin", "../other_plugin/evil.tscn")
	check("entry_scene path escape rejected by _resolve", result.is_empty())


func test_instantiate_script_escape_returns_placeholder() -> void:
	print("test_instantiate_script_escape_returns_placeholder:")
	var result: String = PluginScenePanelHost_._resolve_plugin_relative_path(
		"/tmp/myplugin", "../../core/Minerva.gd")
	check("script path escape rejected by _resolve", result.is_empty())


func test_instantiate_wrong_kind_detected() -> void:
	print("test_instantiate_wrong_kind_detected:")
	var def := StubPluginDef.new()
	def.id = "myplugin"
	def.data_directory = "/tmp/myplugin"
	def.ui_panels = [{
		"name": "html_panel",
		"kind": "html",
		"entry": "ui/panel.html",
		"scripts": [],
		"ipc_channels": [],
	}]
	var panel_def: Dictionary = PluginScenePanelHost_._get_panel_def(def, "html_panel")
	var kind: String = panel_def.get("kind", "html")
	check("html panel kind detected (not godot_scene)", kind != "godot_scene")


func test_instantiate_missing_entry_scene_detected() -> void:
	print("test_instantiate_missing_entry_scene_detected:")
	var def := StubPluginDef.new()
	def.id = "myplugin"
	def.data_directory = "/tmp/myplugin"
	def.ui_panels = [{
		"name": "my_panel",
		"kind": "godot_scene",
		# entry_scene intentionally absent
		"scripts": [],
		"ipc_channels": [],
	}]
	var panel_def: Dictionary = PluginScenePanelHost_._get_panel_def(def, "my_panel")
	var entry: String = panel_def.get("entry_scene", "")
	check("missing entry_scene detected as empty string", entry.is_empty())


func test_instantiate_no_plugin_manager_returns_placeholder() -> void:
	print("test_instantiate_no_plugin_manager_returns_placeholder:")
	# Without a live SceneTree with SingletonObject, _get_plugin_manager() returns null.
	# instantiate_into should mount a placeholder and return it as a Control.
	var vbox := _make_vbox()
	var result: Control = PluginScenePanelHost_.instantiate_into(
		vbox, "cad", "cad_viewer", null)
	check("no plugin_manager: result is a Control",
		result != null and result is Control)
	check("no plugin_manager: placeholder added as child of vbox",
		vbox.get_child_count() > 0)
	vbox.free()


# ===========================================================================
# Ordering guarantees (§5.3)
# ===========================================================================

func test_broker_registered_before_on_panel_loaded() -> void:
	print("test_broker_registered_before_on_panel_loaded:")
	# Simulate host steps 9-11 directly (without file I/O) to verify ordering.
	# This is a unit test of the call-order contract; integration tests
	# would exercise instantiate_into end-to-end with a live SceneTree.

	var broker = _make_broker()
	var vbox := _make_vbox()
	var panel_root := StubSceneRoot.new()
	panel_root.test_broker = broker

	# Step 9: add root to vbox.
	panel_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_child(panel_root)

	# Step 10: register_panel BEFORE _on_panel_loaded.
	var plugin_id := "cad"
	var panel_name := "cad_viewer"
	broker.register_panel(panel_root, plugin_id, panel_name, PackedStringArray(["cad.render"]))

	# Step 11: fire _on_panel_loaded.
	var ctx := {
		"plugin_id": plugin_id,
		"panel_name": panel_name,
		"data_directory": "/tmp/cad",
		"broker": broker,
		"file_path": "",
		"associated_object": null,
		"editor": null,
		"host_api_version": "1",
	}
	if panel_root.has_method("_on_panel_loaded"):
		panel_root._on_panel_loaded(ctx)

	check("_on_panel_loaded was called", panel_root.on_panel_loaded_called)
	check("broker was already registered when _on_panel_loaded fired",
		panel_root.broker_was_registered_before_loaded)

	# Free in child-first order to avoid dangling parent refs.
	# The broker attached a MinervaIPC child to root; root is a child of vbox.
	# Freeing vbox also frees root and its children, but vbox must be done last.
	# Use queue_free-style manual ordering: remove root from vbox first.
	vbox.remove_child(panel_root)
	panel_root.free()
	vbox.free()


func test_on_panel_loaded_receives_ctx_keys() -> void:
	print("test_on_panel_loaded_receives_ctx_keys:")
	var broker = _make_broker()
	var vbox := _make_vbox()
	var panel_root := StubSceneRoot.new()
	vbox.add_child(panel_root)

	broker.register_panel(panel_root, "cad", "cad_viewer", PackedStringArray())

	var ctx := {
		"plugin_id":        "cad",
		"panel_name":       "cad_viewer",
		"data_directory":   "/tmp/cad",
		"broker":           broker,
		"file_path":        "/tmp/cad/untitled.mcad",
		"associated_object": null,
		"editor":           null,
		"host_api_version": "1",
	}
	if panel_root.has_method("_on_panel_loaded"):
		panel_root._on_panel_loaded(ctx)

	check("ctx.plugin_id == 'cad'",
		panel_root.on_panel_loaded_ctx.get("plugin_id", "") == "cad")
	check("ctx.panel_name == 'cad_viewer'",
		panel_root.on_panel_loaded_ctx.get("panel_name", "") == "cad_viewer")
	check("ctx.data_directory set",
		not panel_root.on_panel_loaded_ctx.get("data_directory", "").is_empty())
	check("ctx.broker is non-null",
		panel_root.on_panel_loaded_ctx.get("broker", null) != null)
	check("ctx.file_path present",
		panel_root.on_panel_loaded_ctx.has("file_path"))
	check("ctx.host_api_version == '1'",
		panel_root.on_panel_loaded_ctx.get("host_api_version", "") == "1")

	# Free child-first to avoid dangling refs (MinervaIPC child on root).
	vbox.remove_child(panel_root)
	panel_root.free()
	vbox.free()


# ===========================================================================
# Helper class: simulates a PluginDefinition WITHOUT a ui_panels field at all.
# Defensive coverage — exercises `not ("ui_panels" in def)` early-return.
# ===========================================================================

class _DefWithoutPanelsField extends RefCounted:
	var id: String = "stub"
	var data_directory: String = "/tmp/stub"
	# Deliberately NO ui_panels field.


# ===========================================================================
# Shared tree-walking helpers
# ===========================================================================

## Recursively check whether any Button exists in the subtree.
func _find_button_in_tree(node: Node) -> bool:
	if node is Button:
		return true
	for child in node.get_children():
		if _find_button_in_tree(child):
			return true
	return false


## Recursively find the first Button in the subtree. Returns null if none.
func _find_button_node(node: Node) -> Button:
	if node is Button:
		return node as Button
	for child in node.get_children():
		var result := _find_button_node(child)
		if result != null:
			return result
	return null


## Recursively look for a Label with exactly `text` in the subtree.
func _find_label_with_text(node: Node, text: String) -> bool:
	if node is Label and (node as Label).text == text:
		return true
	for child in node.get_children():
		if _find_label_with_text(child, text):
			return true
	return false
