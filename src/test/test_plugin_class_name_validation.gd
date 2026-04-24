extends SceneTree
## Unit tests for plugin class_name prefix validation and collision detection.
##
## Covers design §6.1, §6.2, §6.3.
##
## Run: godot --headless --path src --script test/test_plugin_class_name_validation.gd
##
## Coverage:
##   PluginDefinition.canonical_prefix:
##     - simple id ("cad" -> "Cad")
##     - underscore id ("obs_controller" -> "Obscontroller")
##     - digits + underscore ("pcb_v2" -> "Pcbv2")
##     - already-capitalised input ("CAD" -> "Cad")
##
##   Prefix regex acceptance (plugin "cad"):
##     - "Cad_Viewer"         legal
##     - "Cad_OrbitCamera"    legal
##     - "Cad_Edge_Label"     legal
##
##   Prefix regex rejection (plugin "cad"):
##     - "Viewer"             illegal (no prefix)
##     - "CADViewer"          illegal (wrong prefix, no separator)
##     - "cad_Viewer"         illegal (lower-case prefix)
##     - "Cad"                illegal (prefix-only, no suffix)
##
##   validate_class_names():
##     - clean plugin: no errors
##     - bad prefix: class_name_bad_prefix
##     - intra-plugin duplicate: class_name_duplicated_in_plugin
##     - cross-plugin collision: class_name collision (conflicts_with plugin:<id>)
##     - core collision: class_name collision (conflicts_with core)
##     - structured error format matches §6.3 keys
##
##   _scan_script_for_class_name():
##     - file with class_name declaration returns identifier
##     - file without class_name returns ""
##     - file with leading comments before class_name returns identifier
##     - nonexistent file returns ""
##
##   scan_class_names():
##     - populates class_names from panel scripts
##     - duplicate class_name across two scripts → only one entry
##     - script with no class_name → not added

const PluginDefinition_ = preload("res://Scripts/Services/Plugins/PluginDefinition.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginClassNameValidation Tests ===\n")

	print("-- canonical_prefix --")
	test_canonical_prefix_simple()
	test_canonical_prefix_underscore()
	test_canonical_prefix_digits_and_underscore()
	test_canonical_prefix_already_uppercase_input()

	print("\n-- regex acceptance (plugin 'cad') --")
	test_regex_accept_cad_viewer()
	test_regex_accept_cad_orbitcamera()
	test_regex_accept_cad_edge_label()

	print("\n-- regex rejection (plugin 'cad') --")
	test_regex_reject_no_prefix()
	test_regex_reject_wrong_prefix_no_sep()
	test_regex_reject_lowercase_prefix()
	test_regex_reject_prefix_only_no_suffix()

	print("\n-- validate_class_names: success paths --")
	test_validate_clean_plugin_ok()

	print("\n-- validate_class_names: failure paths --")
	test_validate_bad_prefix()
	test_validate_intra_plugin_duplicate()
	test_validate_cross_plugin_collision()
	test_validate_core_collision()

	print("\n-- validate_class_names: structured error format §6.3 --")
	test_error_format_collision_has_required_keys()

	print("\n-- _scan_script_for_class_name --")
	test_scan_file_with_class_name()
	test_scan_file_without_class_name()
	test_scan_file_with_leading_comments()
	test_scan_nonexistent_file()

	print("\n-- scan_class_names --")
	test_scan_class_names_populates()
	test_scan_class_names_no_duplicate()
	test_scan_class_names_skips_no_classname_script()

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
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Build a minimal PluginDefinition for testing, without panel scanning.
func _make_def(plugin_id: String, cnames: Array[String]) -> PluginDefinition_:
	var def := PluginDefinition_.new(plugin_id)
	def.id = plugin_id
	def.name = plugin_id
	def.version = "0.1.0"
	def.entrypoint = "server.py"
	for cn in cnames:
		def.class_names.append(cn)
	return def


## Return true if validate_class_names returns an error with the given error key.
func _validates_with_error(def: PluginDefinition_, other: Dictionary, core: Array, error_key: String) -> bool:
	var result: Dictionary = def.validate_class_names(other, core)
	return result.get("error", "") == error_key


## Check whether a class_name matches the prefix regex for a given plugin_id.
func _matches_prefix_regex(plugin_id: String, cn: String) -> bool:
	var prefix: String = PluginDefinition_.canonical_prefix(plugin_id)
	var pattern: String = ("^%s_[A-Za-z0-9_]+$") % prefix
	var rx := RegEx.new()
	if rx.compile(pattern) != OK:
		return false
	return rx.search(cn) != null


# ---------------------------------------------------------------------------
# Write a temp .gd file with given content, return the absolute path.
# We use user:// so FileAccess can write there in headless mode.
# ---------------------------------------------------------------------------

var _temp_files: Array[String] = []

func _write_temp_gd(filename: String, content: String) -> String:
	var path: String = "user://test_cn_%s" % filename
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(content)
		f.close()
	_temp_files.append(path)
	return ProjectSettings.globalize_path(path)


func _cleanup_temp_files() -> void:
	for path in _temp_files:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_temp_files.clear()


# ===========================================================================
# canonical_prefix tests
# ===========================================================================

func test_canonical_prefix_simple() -> void:
	check_eq("canonical_prefix('cad') == 'Cad'",
		PluginDefinition_.canonical_prefix("cad"), "Cad")


func test_canonical_prefix_underscore() -> void:
	check_eq("canonical_prefix('obs_controller') == 'Obscontroller'",
		PluginDefinition_.canonical_prefix("obs_controller"), "Obscontroller")


func test_canonical_prefix_digits_and_underscore() -> void:
	check_eq("canonical_prefix('pcb_v2') == 'Pcbv2'",
		PluginDefinition_.canonical_prefix("pcb_v2"), "Pcbv2")


func test_canonical_prefix_already_uppercase_input() -> void:
	# Plugin ids are constrained to lowercase by _is_valid_id, but canonical_prefix
	# itself should still be safe to call with mixed-case input.
	# capitalize() on "CAD" -> "Cad"; replace("_","") is a no-op.
	check_eq("canonical_prefix('CAD') == 'Cad'",
		PluginDefinition_.canonical_prefix("CAD"), "Cad")


# ===========================================================================
# Regex acceptance tests (plugin "cad")
# ===========================================================================

func test_regex_accept_cad_viewer() -> void:
	check("'Cad_Viewer' accepted for plugin 'cad'",
		_matches_prefix_regex("cad", "Cad_Viewer"))


func test_regex_accept_cad_orbitcamera() -> void:
	check("'Cad_OrbitCamera' accepted for plugin 'cad'",
		_matches_prefix_regex("cad", "Cad_OrbitCamera"))


func test_regex_accept_cad_edge_label() -> void:
	check("'Cad_Edge_Label' accepted for plugin 'cad'",
		_matches_prefix_regex("cad", "Cad_Edge_Label"))


# ===========================================================================
# Regex rejection tests (plugin "cad")
# ===========================================================================

func test_regex_reject_no_prefix() -> void:
	check("'Viewer' rejected (no prefix) for plugin 'cad'",
		not _matches_prefix_regex("cad", "Viewer"))


func test_regex_reject_wrong_prefix_no_sep() -> void:
	check("'CADViewer' rejected (wrong prefix, no separator) for plugin 'cad'",
		not _matches_prefix_regex("cad", "CADViewer"))


func test_regex_reject_lowercase_prefix() -> void:
	check("'cad_Viewer' rejected (lower-case prefix) for plugin 'cad'",
		not _matches_prefix_regex("cad", "cad_Viewer"))


func test_regex_reject_prefix_only_no_suffix() -> void:
	check("'Cad' rejected (prefix-only, no suffix) for plugin 'cad'",
		not _matches_prefix_regex("cad", "Cad"))


# ===========================================================================
# validate_class_names: success
# ===========================================================================

func test_validate_clean_plugin_ok() -> void:
	var def := _make_def("cad", ["Cad_Viewer", "Cad_OrbitCamera"])
	var result: Dictionary = def.validate_class_names({}, [])
	check("clean plugin with valid class_names: no error", result.is_empty())


# ===========================================================================
# validate_class_names: failure paths
# ===========================================================================

func test_validate_bad_prefix() -> void:
	# "Viewer" has no prefix — should fail class_name_bad_prefix.
	var def := _make_def("cad", ["Viewer"])
	check("bad prefix returns class_name_bad_prefix error",
		_validates_with_error(def, {}, [], "class_name_bad_prefix"))

	# Also check that the detail dict has expected keys.
	var result: Dictionary = def.validate_class_names({}, [])
	var detail: Dictionary = result.get("detail", {})
	check("bad_prefix detail has 'class_name' key", detail.has("class_name"))
	check("bad_prefix detail has 'plugin' key", detail.has("plugin"))
	check("bad_prefix detail has 'expected_prefix' key", detail.has("expected_prefix"))
	check_eq("bad_prefix detail.class_name == 'Viewer'",
		detail.get("class_name", ""), "Viewer")
	check_eq("bad_prefix detail.expected_prefix == 'Cad'",
		detail.get("expected_prefix", ""), "Cad")


func test_validate_intra_plugin_duplicate() -> void:
	# Two class_names from the same plugin — simulate by injecting duplicates
	# directly into the class_names array (scan_class_names deduplicates, but
	# the validate method must also catch it in case class_names is populated
	# by other means).
	var def := _make_def("cad", [])
	# Bypass scan_class_names to inject a duplicate directly.
	def.class_names.append("Cad_Widget")
	def.class_names.append("Cad_Widget")
	check("intra-plugin duplicate returns class_name_duplicated_in_plugin",
		_validates_with_error(def, {}, [], "class_name_duplicated_in_plugin"))


func test_validate_cross_plugin_collision() -> void:
	# Plugin B tries to register "Foo_Widget" which is already owned by plugin A.
	# Note: "Foo_Widget" doesn't match plugin B's prefix ("Bar"), so we'd get
	# class_name_bad_prefix first.  To isolate the collision test, use a name
	# that matches B's prefix but collides with A's registry.
	# Plugin bar -> prefix Bar; class "Bar_Widget" is valid prefix-wise.
	# We pre-seed the registry with "Bar_Widget" belonging to another plugin.
	var def_b := _make_def("bar", ["Bar_Widget"])
	# other_names: "Bar_Widget" belongs to plugin "bar_first"
	# Wrap in Array to avoid lambda-capture-by-value issues with Dictionary literal.
	var other_names_holder: Array = [{"Bar_Widget": "bar_first"}]
	var result: Dictionary = def_b.validate_class_names(other_names_holder[0], [])
	check("cross-plugin collision returns 'class_name collision'",
		result.get("error", "") == "class_name collision")
	var detail: Dictionary = result.get("detail", {})
	check("collision detail has 'conflicts_with' key", detail.has("conflicts_with"))
	check("conflicts_with starts with 'plugin:'",
		str(detail.get("conflicts_with", "")).begins_with("plugin:"))


func test_validate_core_collision() -> void:
	# Plugin "editor" tries to register "Editor_X" which collides with a core class.
	# But "Editor_X" has prefix "Editor" which matches plugin "editor".
	# Core list contains "Editor_X".
	var def := _make_def("editor", ["Editor_X"])
	var core_names_holder: Array = [["Editor_X"]]
	var result: Dictionary = def.validate_class_names({}, core_names_holder[0])
	check("core collision returns 'class_name collision'",
		result.get("error", "") == "class_name collision")
	var detail: Dictionary = result.get("detail", {})
	check_eq("core collision conflicts_with == 'core'",
		str(detail.get("conflicts_with", "")), "core")


# ===========================================================================
# Structured error format §6.3
# ===========================================================================

func test_error_format_collision_has_required_keys() -> void:
	# Verify the collision error matches the §6.3 schema:
	#   { "error": "class_name collision",
	#     "detail": { "class_name": ..., "plugin": ..., "conflicts_with": ... } }
	var def := _make_def("foo", ["Foo_Thing"])
	var other_holder: Array = [{"Foo_Thing": "other_plugin"}]
	var result: Dictionary = def.validate_class_names(other_holder[0], [])

	check("error key is 'class_name collision'",
		result.get("error", "") == "class_name collision")
	check("result has 'detail' key", result.has("detail"))
	var detail: Dictionary = result.get("detail", {})
	check("detail has 'class_name'", detail.has("class_name"))
	check("detail has 'plugin'", detail.has("plugin"))
	check("detail has 'conflicts_with'", detail.has("conflicts_with"))
	check_eq("detail.class_name == 'Foo_Thing'",
		detail.get("class_name", ""), "Foo_Thing")
	check_eq("detail.conflicts_with == 'plugin:other_plugin'",
		str(detail.get("conflicts_with", "")), "plugin:other_plugin")


# ===========================================================================
# _scan_script_for_class_name
# ===========================================================================

func test_scan_file_with_class_name() -> void:
	var path: String = _write_temp_gd("with_cn.gd",
		"class_name MyWidget\nextends Control\n")
	var result: String = PluginDefinition_._scan_script_for_class_name(path)
	check_eq("file with class_name returns identifier", result, "MyWidget")
	_cleanup_temp_files()


func test_scan_file_without_class_name() -> void:
	var path: String = _write_temp_gd("without_cn.gd",
		"extends Control\n\nfunc _ready() -> void:\n\tpass\n")
	var result: String = PluginDefinition_._scan_script_for_class_name(path)
	check_eq("file without class_name returns empty string", result, "")
	_cleanup_temp_files()


func test_scan_file_with_leading_comments() -> void:
	var content := "# My plugin viewer\n# Copyright 2026\n\nclass_name Cad_Viewer\nextends Control\n"
	var path: String = _write_temp_gd("leading_comments.gd", content)
	var result: String = PluginDefinition_._scan_script_for_class_name(path)
	check_eq("file with leading comments before class_name returns identifier",
		result, "Cad_Viewer")
	_cleanup_temp_files()


func test_scan_nonexistent_file() -> void:
	var result: String = PluginDefinition_._scan_script_for_class_name(
		"/nonexistent/path/that/does/not/exist.gd")
	check_eq("nonexistent file returns empty string", result, "")


# ===========================================================================
# scan_class_names
# ===========================================================================

func test_scan_class_names_populates() -> void:
	# Write two scripts with class_name declarations, wire them into a def.
	var path_a: String = _write_temp_gd("scan_a.gd", "class_name Myplugin_Alpha\nextends Control\n")
	var path_b: String = _write_temp_gd("scan_b.gd", "class_name Myplugin_Beta\nextends Node\n")

	var def := PluginDefinition_.new("myplugin")
	def.data_directory = ""
	# Use an abs_path_resolver so we don't need data_directory.
	# Map relative names directly to the temp paths.
	var path_map_holder: Array = [{"scan_a.gd": path_a, "scan_b.gd": path_b}]
	var resolver := func(rel: String) -> String:
		return path_map_holder[0].get(rel, "")

	def.ui_panels = [{
		"name": "my_panel",
		"kind": "godot_scene",
		"entry_scene": "scene.tscn",
		"scripts": ["scan_a.gd", "scan_b.gd"],
	}]

	def.scan_class_names(resolver)

	check_eq("scan_class_names populates 2 entries", def.class_names.size(), 2)
	check("scan_class_names has Myplugin_Alpha", def.class_names.has("Myplugin_Alpha"))
	check("scan_class_names has Myplugin_Beta", def.class_names.has("Myplugin_Beta"))
	_cleanup_temp_files()


func test_scan_class_names_no_duplicate() -> void:
	# Two scripts that happen to declare the same class_name (unusual but
	# defensively handled — scan_class_names deduplicates before validate sees them).
	var path_a: String = _write_temp_gd("dup_a.gd", "class_name Myplugin_Widget\nextends Control\n")
	var path_b: String = _write_temp_gd("dup_b.gd", "class_name Myplugin_Widget\nextends Node\n")

	var def := PluginDefinition_.new("myplugin")
	var path_map_holder: Array = [{"dup_a.gd": path_a, "dup_b.gd": path_b}]
	var resolver := func(rel: String) -> String:
		return path_map_holder[0].get(rel, "")

	def.ui_panels = [{
		"name": "p",
		"kind": "godot_scene",
		"entry_scene": "scene.tscn",
		"scripts": ["dup_a.gd", "dup_b.gd"],
	}]

	def.scan_class_names(resolver)

	# scan_class_names deduplicates; validate_class_names would still catch
	# intra-plugin duplicates if they appeared — but scan should produce at most 1.
	check("scan_class_names deduplicates same name across scripts",
		def.class_names.size() == 1)
	_cleanup_temp_files()


func test_scan_class_names_skips_no_classname_script() -> void:
	var path_a: String = _write_temp_gd("noname.gd", "extends Control\nfunc _ready():\n\tpass\n")

	var def := PluginDefinition_.new("myplugin")
	var path_map_holder: Array = [{"noname.gd": path_a}]
	var resolver := func(rel: String) -> String:
		return path_map_holder[0].get(rel, "")

	def.ui_panels = [{
		"name": "p",
		"kind": "godot_scene",
		"entry_scene": "scene.tscn",
		"scripts": ["noname.gd"],
	}]

	def.scan_class_names(resolver)

	check_eq("scan_class_names skips scripts without class_name",
		def.class_names.size(), 0)
	_cleanup_temp_files()
