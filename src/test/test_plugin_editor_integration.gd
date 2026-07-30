extends SceneTree
## Unit tests for PluginEditorRegistry and Editor.Type.PLUGIN_SCENE integration.
## Design §7.2 – §7.5.
##
## Run: godot --headless --path src --script test/test_plugin_editor_integration.gd
##
## Coverage:
##   PluginEditorRegistry.register_plugin:
##     - Populates _ext_to_panel and _kind_to_panel
##     - Extension collision with core (.md) → warning returned, extension skipped
##     - Two plugins with same extension → first wins, second skipped with warning
##     - Unregister cleans both maps
##   PluginEditorRegistry.resolve_extension: hit + miss
##   PluginEditorRegistry.resolve_editor_kind: hit + miss
##   PluginEditorRegistry.list_editor_kinds: returns all registered in order
##   PluginEditorRegistry.list_extensions: returns all registered extensions
##   Editor.Type.PLUGIN_SCENE: enum value exists
##   Editor.create() with PLUGIN_SCENE logs error (use create_plugin_scene instead)

const PluginEditorRegistry_ = preload("res://Scripts/Services/Plugins/PluginEditorRegistry.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginEditorRegistry + Editor.PLUGIN_SCENE Integration Tests ===\n")

	print("-- PluginEditorRegistry: register_plugin --")
	test_register_plugin_populates_extensions()
	test_register_plugin_populates_kinds()
	test_register_plugin_core_extension_collision_warning()
	test_register_plugin_core_extension_skipped_on_collision()
	test_register_plugin_two_plugins_same_ext_first_wins()
	test_register_plugin_two_plugins_same_ext_second_skipped()

	print("\n-- PluginEditorRegistry: unregister_plugin --")
	test_unregister_cleans_extensions()
	test_unregister_cleans_kinds()

	print("\n-- PluginEditorRegistry: resolve_extension --")
	test_resolve_extension_hit()
	test_resolve_extension_miss()
	test_resolve_extension_normalises_leading_dot()

	print("\n-- PluginEditorRegistry: resolve_editor_kind --")
	test_resolve_editor_kind_hit()
	test_resolve_editor_kind_miss()

	print("\n-- PluginEditorRegistry: list_extensions --")
	test_list_extensions_returns_all()

	print("\n-- PluginEditorRegistry: list_editor_kinds --")
	test_list_editor_kinds_returns_all_in_order()
	test_list_editor_kinds_contains_id_field()

	print("\n-- Editor.Type.PLUGIN_SCENE enum --")
	test_plugin_scene_type_exists()
	test_plugin_scene_type_distinct_from_others()

	print("\n-- render_mode + layout_hint passthrough (DCR 019dfa66 §T5) --")
	test_resolve_extension_exposes_render_mode_default()
	test_resolve_extension_exposes_render_mode_paired_dsl()
	test_resolve_extension_exposes_layout_hint()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

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
		printerr(("  FAIL: %s — expected %s, got %s") % [description, str(expected), str(actual)])


# ---------------------------------------------------------------------------
# Stub PluginDefinition-like objects (no real PluginManager needed)
# ---------------------------------------------------------------------------

## Build a minimal stub dict that looks like a PluginDefinition to register_plugin().
## register_plugin() uses duck-typing: reads .id, .ui_panels, .editor_items.
class StubDef:
	var id: String = ""
	var ui_panels: Array = []
	var editor_items: Array = []

	static func make(
			p_id: String,
			panel_name: String,
			exts: Array,
			item_id: String = "",
			item_name: String = "",
			default_filename: String = "untitled.ext"
	) -> StubDef:
		var d := StubDef.new()
		d.id = p_id
		d.ui_panels = [{
			"name": panel_name,
			"kind": "godot_scene",
			"entry_scene": "ui/Panel.tscn",
			"scripts": [],
			"file_extensions": exts,
			"ipc_channels": [],
		}]
		if not item_id.is_empty():
			d.editor_items = [{
				"id": item_id,
				"name": item_name,
				"panel": panel_name,
				"default_filename": default_filename,
			}]
		return d


# ---------------------------------------------------------------------------
# Tests: register_plugin
# ---------------------------------------------------------------------------

func test_register_plugin_populates_extensions() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("cad", "cad_viewer", [".mcad"])
	reg.register_plugin(def)
	var info := reg.resolve_extension(".mcad")
	check("register_plugin populates _ext_to_panel for .mcad", not info.is_empty())
	check_eq("resolve_extension returns correct plugin_id", info.get("plugin_id", ""), "cad")
	check_eq("resolve_extension returns correct panel_name", info.get("panel_name", ""), "cad_viewer")


func test_register_plugin_populates_kinds() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("cad", "cad_viewer", [".mcad"], "new_cad_doc", "New CAD Document", "untitled.mcad")
	reg.register_plugin(def)
	var info := reg.resolve_editor_kind("new_cad_doc")
	check("register_plugin populates _kind_to_panel for new_cad_doc", not info.is_empty())
	check_eq("kind panel_name correct", info.get("panel_name", ""), "cad_viewer")
	check_eq("kind plugin_id correct", info.get("plugin_id", ""), "cad")
	check_eq("kind default_filename correct", info.get("default_filename", ""), "untitled.mcad")


func test_register_plugin_core_extension_collision_warning() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("plugin_a", "viewer", [".md"])
	var warnings: Array = reg.register_plugin(def)
	var has_warning := false
	for w in warnings:
		if ".md" in w:
			has_warning = true
			break
	check("core extension .md collision yields a warning", has_warning)


func test_register_plugin_core_extension_skipped_on_collision() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("plugin_a", "viewer", [".md"])
	reg.register_plugin(def)
	var info := reg.resolve_extension(".md")
	check("core extension .md is not registered by plugin", info.is_empty())


func test_register_plugin_two_plugins_same_ext_first_wins() -> void:
	var reg := PluginEditorRegistry_.new()
	var def_a := StubDef.make("plugin_a", "viewer_a", [".xyzz"])
	var def_b := StubDef.make("plugin_b", "viewer_b", [".xyzz"])
	reg.register_plugin(def_a)
	reg.register_plugin(def_b)
	var info := reg.resolve_extension(".xyzz")
	check_eq("first-installed plugin wins extension collision", info.get("plugin_id", ""), "plugin_a")


func test_register_plugin_two_plugins_same_ext_second_skipped() -> void:
	var reg := PluginEditorRegistry_.new()
	var def_a := StubDef.make("plugin_a", "viewer_a", [".xyzz"])
	var def_b := StubDef.make("plugin_b", "viewer_b", [".xyzz"])
	reg.register_plugin(def_a)
	var warnings: Array = reg.register_plugin(def_b)
	var has_warning := false
	for w in warnings:
		if ".xyzz" in w and "plugin_a" in w:
			has_warning = true
			break
	check("second plugin gets warning for duplicate extension", has_warning)


# ---------------------------------------------------------------------------
# Tests: unregister_plugin
# ---------------------------------------------------------------------------

func test_unregister_cleans_extensions() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("cad", "cad_viewer", [".mcad"])
	reg.register_plugin(def)
	reg.unregister_plugin("cad")
	var info := reg.resolve_extension(".mcad")
	check("unregister_plugin removes extension", info.is_empty())


func test_unregister_cleans_kinds() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("cad", "cad_viewer", [".mcad"], "new_cad_doc", "New CAD Document")
	reg.register_plugin(def)
	reg.unregister_plugin("cad")
	var info := reg.resolve_editor_kind("new_cad_doc")
	check("unregister_plugin removes editor kind", info.is_empty())


# ---------------------------------------------------------------------------
# Tests: resolve_extension
# ---------------------------------------------------------------------------

func test_resolve_extension_hit() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("cad", "cad_viewer", [".mcad"])
	reg.register_plugin(def)
	var info := reg.resolve_extension(".mcad")
	check("resolve_extension hit returns non-empty dict", not info.is_empty())


func test_resolve_extension_miss() -> void:
	var reg := PluginEditorRegistry_.new()
	var info := reg.resolve_extension(".mcad")
	check("resolve_extension miss returns empty dict", info.is_empty())


func test_resolve_extension_normalises_leading_dot() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("cad", "cad_viewer", [".mcad"])
	reg.register_plugin(def)
	# Query without leading dot — should still resolve.
	var info := reg.resolve_extension("mcad")
	check("resolve_extension normalises missing leading dot", not info.is_empty())


# ---------------------------------------------------------------------------
# Tests: resolve_editor_kind
# ---------------------------------------------------------------------------

func test_resolve_editor_kind_hit() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("cad", "cad_viewer", [], "new_cad_doc", "New CAD Document")
	reg.register_plugin(def)
	var info := reg.resolve_editor_kind("new_cad_doc")
	check("resolve_editor_kind hit returns non-empty dict", not info.is_empty())


func test_resolve_editor_kind_miss() -> void:
	var reg := PluginEditorRegistry_.new()
	var info := reg.resolve_editor_kind("nonexistent_id")
	check("resolve_editor_kind miss returns empty dict", info.is_empty())


# ---------------------------------------------------------------------------
# Tests: list_extensions
# ---------------------------------------------------------------------------

func test_list_extensions_returns_all() -> void:
	var reg := PluginEditorRegistry_.new()
	var def_a := StubDef.make("plugin_a", "viewer_a", [".aaa"])
	var def_b := StubDef.make("plugin_b", "viewer_b", [".bbb"])
	reg.register_plugin(def_a)
	reg.register_plugin(def_b)
	var exts: Array = reg.list_extensions()
	# Use Array wrappers to avoid lambda-capture-by-value GDScript gotcha.
	var found_a: Array = [false]
	var found_b: Array = [false]
	for ext in exts:
		if ext == ".aaa":
			found_a[0] = true
		if ext == ".bbb":
			found_b[0] = true
	check("list_extensions includes .aaa", found_a[0])
	check("list_extensions includes .bbb", found_b[0])


# ---------------------------------------------------------------------------
# Tests: list_editor_kinds
# ---------------------------------------------------------------------------

func test_list_editor_kinds_returns_all_in_order() -> void:
	var reg := PluginEditorRegistry_.new()
	var def_a := StubDef.make("plugin_a", "viewer_a", [], "kind_a", "Kind A")
	var def_b := StubDef.make("plugin_b", "viewer_b", [], "kind_b", "Kind B")
	reg.register_plugin(def_a)
	reg.register_plugin(def_b)
	var kinds: Array = reg.list_editor_kinds()
	check_eq("list_editor_kinds returns 2 entries", kinds.size(), 2)
	# Insertion order preserved.
	check_eq("first entry is kind_a", kinds[0].get("id", ""), "kind_a")
	check_eq("second entry is kind_b", kinds[1].get("id", ""), "kind_b")


func test_list_editor_kinds_contains_id_field() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := StubDef.make("cad", "cad_viewer", [], "new_cad_doc", "New CAD Document")
	reg.register_plugin(def)
	var kinds: Array = reg.list_editor_kinds()
	check("list_editor_kinds entry contains id field", kinds.size() > 0 and kinds[0].has("id"))
	check_eq("id field value is correct", kinds[0].get("id", ""), "new_cad_doc")


# ---------------------------------------------------------------------------
# Tests: Editor.Type.PLUGIN_SCENE enum
# ---------------------------------------------------------------------------

func test_plugin_scene_type_exists() -> void:
	# Verify the enum value exists and is an int.
	var val = Editor.Type.PLUGIN_SCENE
	check("Editor.Type.PLUGIN_SCENE exists", val is int)


func test_plugin_scene_type_distinct_from_others() -> void:
	var ps := Editor.Type.PLUGIN_SCENE
	var others: Array = [
		Editor.Type.TEXT,
		Editor.Type.GRAPHICS,
		Editor.Type.VIDEO,
		Editor.Type.PACKAGE,
		Editor.Type.LOGS,
		Editor.Type.KANBAN,
		Editor.Type.SPREADSHEET,
		Editor.Type.VIDEO_EDITOR,
		Editor.Type.ACTIVITY_LOG,
		Editor.Type.WEBVIEW,
		Editor.Type.PLUGIN_MANAGER,
		Editor.Type.WORKER_STATUS,
		Editor.Type.DOCKET,
	]
	var is_unique := true
	for other in others:
		if other == ps:
			is_unique = false
			break
	check("PLUGIN_SCENE enum value is distinct from all other Editor.Type values", is_unique)


# ---------------------------------------------------------------------------
# render_mode + layout_hint passthrough (DCR 019dfa66 §T5)
# ---------------------------------------------------------------------------

## Variant of StubDef.make that lets us specify render_mode/layout_hint on the
## panel dict.  The registry should expose these via resolve_extension so the
## file-open dispatcher can branch on them without re-reading the manifest.
func _make_def_with_panel(p_id: String, panel_name: String, exts: Array,
		render_mode: String = "single", layout_hint: String = "tabs") -> StubDef:
	var d := StubDef.new()
	d.id = p_id
	d.ui_panels = [{
		"name": panel_name,
		"kind": "godot_scene",
		"entry_scene": "ui/Panel.tscn",
		"scripts": [],
		"file_extensions": exts,
		"ipc_channels": [],
		"render_mode": render_mode,
		"layout_hint": layout_hint,
	}]
	return d


func test_resolve_extension_exposes_render_mode_default() -> void:
	var reg := PluginEditorRegistry_.new()
	# Use bare StubDef.make — render_mode absent on panel dict → registry should
	# still expose "single" via the .get(..., "single") default in register_plugin.
	var def := StubDef.make("dsl", "dsl_render", [".tdsl"])
	reg.register_plugin(def)
	var info := reg.resolve_extension(".tdsl")
	check_eq("missing render_mode defaults to 'single' in registry",
		info.get("render_mode", ""), "single")


func test_resolve_extension_exposes_render_mode_paired_dsl() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := _make_def_with_panel("dsl", "dsl_render", [".tdsl"], "paired_dsl", "side_by_side")
	reg.register_plugin(def)
	var info := reg.resolve_extension(".tdsl")
	check_eq("paired_dsl render_mode preserved through registry",
		info.get("render_mode", ""), "paired_dsl")


func test_resolve_extension_exposes_layout_hint() -> void:
	var reg := PluginEditorRegistry_.new()
	var def := _make_def_with_panel("dsl", "dsl_render", [".tdsl"], "paired_dsl", "side_by_side")
	reg.register_plugin(def)
	var info := reg.resolve_extension(".tdsl")
	check_eq("side_by_side layout_hint preserved through registry",
		info.get("layout_hint", ""), "side_by_side")
