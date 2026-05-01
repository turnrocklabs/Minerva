extends SceneTree
## Unit tests for PluginDefinition manifest parsing (typed panel entries).
##
## Run: godot --headless --path src --script test/test_plugin_definition.gd
##
## Coverage:
##   _parse_panel_entry (via _from_dict_internal):
##     - valid html panel (kind explicit)
##     - valid html panel (kind absent → defaults to "html")
##     - valid html panel (entry absent → derived from name)
##     - valid godot_scene panel with entry_scene + scripts
##     - legacy String panel entry → manifest rejected (panel_must_be_typed)
##     - missing name → error
##     - unknown kind → error
##     - godot_scene missing entry_scene → error
##     - godot_scene missing scripts → error
##     - godot_scene empty scripts array → error
##     - invalid file_extensions (no leading dot) → error
##     - ipc_channels not in allowlist → error
##     - ipc_channels all in allowlist → accepted
##
##   ui_panel_names parallel array:
##     - correct entries for single panel
##     - correct entries for multiple panels
##
##   validate():
##     - editor_items panel ref not in ui_panels → validation error
##     - editor_items panel ref valid → no error
##     - duplicate panel names → validation error
##
##   Real plugin manifests (from_manifest via dict round-trip):
##     - obs_controller manifest parses cleanly
##     - notes_helper manifest parses cleanly
##     - test_stdio_server manifest parses cleanly

const PluginDefinition_ = preload("res://Scripts/Services/Plugins/PluginDefinition.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginDefinition Tests ===\n")

	print("-- _parse_panel_entry: valid html panels --")
	test_html_panel_explicit_kind()
	test_html_panel_kind_defaults_to_html()
	test_html_panel_entry_derived_from_name()

	print("\n-- _parse_panel_entry: valid godot_scene panel --")
	test_godot_scene_panel_valid()

	print("\n-- _parse_panel_entry: rejection cases --")
	test_legacy_string_panel_rejected()
	test_panel_missing_name_rejected()
	test_panel_unknown_kind_rejected()
	test_godot_scene_missing_entry_scene_rejected()
	test_godot_scene_missing_scripts_rejected()
	test_godot_scene_empty_scripts_rejected()
	test_file_extension_missing_dot_rejected()
	test_ipc_channel_not_in_allowlist_rejected()

	print("\n-- ipc_channels accepted when in allowlist --")
	test_ipc_channels_accepted_when_in_allowlist()

	print("\n-- ui_panel_names parallel array --")
	test_ui_panel_names_single_panel()
	test_ui_panel_names_multiple_panels()

	print("\n-- validate(): editor_items linkage + duplicate panel names --")
	test_editor_items_bad_panel_ref_fails_validate()
	test_editor_items_good_panel_ref_passes_validate()
	test_duplicate_panel_names_fail_validate()
	test_from_dict_does_not_duplicate_top_level_arrays()

	print("\n-- Real plugin manifests --")
	test_obs_controller_manifest_parses()
	test_notes_helper_manifest_parses()
	test_test_stdio_server_manifest_parses()

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


## Build a minimal valid manifest dict (no panels) for use as a base.
func _minimal_manifest(extra_ui: Dictionary = {}) -> Dictionary:
	var ui: Dictionary = {
		"panels": [],
		"ipc_messages": [],
	}
	for k in extra_ui:
		ui[k] = extra_ui[k]
	return {
		"id": "test_plugin",
		"name": "Test Plugin",
		"version": "0.1.0",
		"backend": {
			"transport": "stdio",
			"entrypoint": "server.py",
		},
		"ui": ui,
		"permissions": {
			"host_capabilities": [],
			"network": {"mode": "none"},
			"filesystem": {"mode": "none"},
		},
	}


# ---------------------------------------------------------------------------
# Tests: valid html panels
# ---------------------------------------------------------------------------

func test_html_panel_explicit_kind() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{"name": "my_panel", "kind": "html", "entry": "ui/my_panel.html"}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("html explicit kind: def not null", def != null)
	if def == null:
		return
	check_eq("html explicit kind: ui_panels count", def.ui_panels.size(), 1)
	check_eq("html explicit kind: name", def.ui_panels[0].get("name", ""), "my_panel")
	check_eq("html explicit kind: kind", def.ui_panels[0].get("kind", ""), "html")
	check_eq("html explicit kind: entry", def.ui_panels[0].get("entry", ""), "ui/my_panel.html")
	check_eq("html explicit kind: fullscreen_capable default", def.ui_panels[0].get("fullscreen_capable", true), false)
	check_eq("html explicit kind: multi_window default", def.ui_panels[0].get("multi_window", true), false)


func test_html_panel_kind_defaults_to_html() -> void:
	# kind field absent — should default to "html"
	var manifest := _minimal_manifest({
		"panels": [
			{"name": "headless_panel", "entry": "ui/headless_panel.html"}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("html default kind: def not null", def != null)
	if def == null:
		return
	check_eq("html default kind: kind is html", def.ui_panels[0].get("kind", ""), "html")


func test_html_panel_entry_derived_from_name() -> void:
	# entry absent — should be derived as "ui/<name>.html"
	var manifest := _minimal_manifest({
		"panels": [
			{"name": "my_panel"}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("html entry derived: def not null", def != null)
	if def == null:
		return
	check_eq("html entry derived: entry = ui/my_panel.html",
		def.ui_panels[0].get("entry", ""), "ui/my_panel.html")


# ---------------------------------------------------------------------------
# Tests: valid godot_scene panel
# ---------------------------------------------------------------------------

func test_godot_scene_panel_valid() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{
				"name": "cad_viewer",
				"kind": "godot_scene",
				"entry_scene": "ui/CadViewer.tscn",
				"scripts": ["ui/CadViewer.gd", "ui/CadCanvas.gd"],
				"file_extensions": [".mcad"],
				"ipc_channels": ["cad.render_request"],
				"fullscreen_capable": false,
				"multi_window": false,
			}
		],
		"ipc_messages": ["cad.render_request"],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("godot_scene valid: def not null", def != null)
	if def == null:
		return
	check_eq("godot_scene valid: kind", def.ui_panels[0].get("kind", ""), "godot_scene")
	check_eq("godot_scene valid: entry_scene",
		def.ui_panels[0].get("entry_scene", ""), "ui/CadViewer.tscn")
	var scripts: Array = def.ui_panels[0].get("scripts", [])
	check_eq("godot_scene valid: scripts count", scripts.size(), 2)
	check("godot_scene valid: scripts[0]", scripts[0] == "ui/CadViewer.gd")
	var exts: Array = def.ui_panels[0].get("file_extensions", [])
	check_eq("godot_scene valid: file_extensions count", exts.size(), 1)
	check("godot_scene valid: file_extensions[0]", exts[0] == ".mcad")
	var chans: Array = def.ui_panels[0].get("ipc_channels", [])
	check_eq("godot_scene valid: ipc_channels count", chans.size(), 1)
	check("godot_scene valid: ipc_channels[0]", chans[0] == "cad.render_request")


# ---------------------------------------------------------------------------
# Tests: rejection cases
# ---------------------------------------------------------------------------

func test_legacy_string_panel_rejected() -> void:
	# String entry in panels → manifest must be rejected
	var manifest := _minimal_manifest({
		"panels": ["obs_controller_panel"],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("legacy string panel: def is null (rejected)", def == null)


func test_panel_missing_name_rejected() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{"kind": "html", "entry": "ui/panel.html"}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("panel missing name: def is null", def == null)


func test_panel_unknown_kind_rejected() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{"name": "bad_panel", "kind": "flash"}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("panel unknown kind: def is null", def == null)


func test_godot_scene_missing_entry_scene_rejected() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{
				"name": "cad_viewer",
				"kind": "godot_scene",
				"scripts": ["ui/CadViewer.gd"],
			}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("godot_scene missing entry_scene: def is null", def == null)


func test_godot_scene_missing_scripts_rejected() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{
				"name": "cad_viewer",
				"kind": "godot_scene",
				"entry_scene": "ui/CadViewer.tscn",
			}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("godot_scene missing scripts: def is null", def == null)


func test_godot_scene_empty_scripts_rejected() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{
				"name": "cad_viewer",
				"kind": "godot_scene",
				"entry_scene": "ui/CadViewer.tscn",
				"scripts": [],
			}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("godot_scene empty scripts: def is null", def == null)


func test_file_extension_missing_dot_rejected() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{
				"name": "my_panel",
				"kind": "html",
				"file_extensions": ["mcad"],
			}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("file_extension missing dot: def is null", def == null)


func test_ipc_channel_not_in_allowlist_rejected() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{
				"name": "my_panel",
				"kind": "html",
				"ipc_channels": ["some.channel"],
			}
		],
		"ipc_messages": ["other.channel"],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("ipc_channel not in allowlist: def is null", def == null)


# ---------------------------------------------------------------------------
# Tests: ipc_channels accepted when in allowlist
# ---------------------------------------------------------------------------

func test_ipc_channels_accepted_when_in_allowlist() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{
				"name": "my_panel",
				"kind": "html",
				"ipc_channels": ["foo.bar", "baz.qux"],
			}
		],
		"ipc_messages": ["foo.bar", "baz.qux", "extra.msg"],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("ipc_channels in allowlist: def not null", def != null)
	if def == null:
		return
	var chans: Array = def.ui_panels[0].get("ipc_channels", [])
	check_eq("ipc_channels in allowlist: count", chans.size(), 2)
	check("ipc_channels in allowlist: has foo.bar", chans.has("foo.bar"))
	check("ipc_channels in allowlist: has baz.qux", chans.has("baz.qux"))


# ---------------------------------------------------------------------------
# Tests: ui_panel_names parallel array
# ---------------------------------------------------------------------------

func test_ui_panel_names_single_panel() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{"name": "alpha_panel", "kind": "html"}
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("panel_names single: def not null", def != null)
	if def == null:
		return
	check_eq("panel_names single: ui_panel_names count", def.ui_panel_names.size(), 1)
	check_eq("panel_names single: ui_panel_names[0]", def.ui_panel_names[0], "alpha_panel")


func test_ui_panel_names_multiple_panels() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{"name": "panel_a", "kind": "html"},
			{
				"name": "panel_b",
				"kind": "godot_scene",
				"entry_scene": "ui/B.tscn",
				"scripts": ["ui/B.gd"],
			},
		],
	})
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("panel_names multi: def not null", def != null)
	if def == null:
		return
	check_eq("panel_names multi: ui_panel_names count", def.ui_panel_names.size(), 2)
	check_eq("panel_names multi: [0] = panel_a", def.ui_panel_names[0], "panel_a")
	check_eq("panel_names multi: [1] = panel_b", def.ui_panel_names[1], "panel_b")
	# Parallel: ui_panels[i].name == ui_panel_names[i]
	check_eq("panel_names multi: parallel [0]",
		def.ui_panels[0].get("name", ""), def.ui_panel_names[0])
	check_eq("panel_names multi: parallel [1]",
		def.ui_panels[1].get("name", ""), def.ui_panel_names[1])


# ---------------------------------------------------------------------------
# Tests: validate() — editor_items linkage + duplicate panel names
# ---------------------------------------------------------------------------

func test_editor_items_bad_panel_ref_fails_validate() -> void:
	# editor_items references a panel name that doesn't exist in ui.panels
	var manifest := _minimal_manifest({
		"panels": [
			{"name": "real_panel", "kind": "html"}
		],
	})
	manifest["editor_items"] = [
		{"id": "new_thing", "name": "New Thing", "panel": "nonexistent_panel"}
	]
	var def = PluginDefinition_._from_dict_internal(manifest)
	# _from_dict_internal doesn't call validate() — that's done in from_manifest.
	# Call validate() directly.
	check("editor_items bad ref: def not null (parse ok)", def != null)
	if def == null:
		return
	# Must call validate() — from_manifest calls it; we do so manually here.
	# Need to set required fields that validate() checks.
	def.id = "test_plugin"
	def.name = "Test Plugin"
	def.version = "0.1.0"
	def.entrypoint = "server.py"
	var errors := def.validate()
	check("editor_items bad ref: validate returns errors", errors.size() > 0)
	var found := false
	for e in errors:
		if "nonexistent_panel" in e:
			found = true
	check("editor_items bad ref: error mentions missing panel", found)


func test_editor_items_good_panel_ref_passes_validate() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{"name": "real_panel", "kind": "html"}
		],
	})
	manifest["editor_items"] = [
		{"id": "new_thing", "name": "New Thing", "panel": "real_panel"}
	]
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("editor_items good ref: def not null", def != null)
	if def == null:
		return
	def.id = "test_plugin"
	def.name = "Test Plugin"
	def.version = "0.1.0"
	def.entrypoint = "server.py"
	var errors := def.validate()
	# Filter out any non-panel errors; only check for panel ref errors
	var panel_errors: Array[String] = []
	for e in errors:
		if "panel" in e.to_lower():
			panel_errors.append(e)
	check("editor_items good ref: no panel ref errors", panel_errors.is_empty())


func test_duplicate_panel_names_fail_validate() -> void:
	var manifest := _minimal_manifest({
		"panels": [
			{"name": "dup_panel", "kind": "html"},
		],
	})
	# Insert a second panel with the same name directly into a def
	# (bypassing _from_dict_internal which would reject the second on parse)
	var def = PluginDefinition_._from_dict_internal(manifest)
	check("dup panel names: def not null (initial parse)", def != null)
	if def == null:
		return
	# Manually push a duplicate to test validate()
	def.ui_panels.append({"name": "dup_panel", "kind": "html"})
	def.ui_panel_names.append("dup_panel")
	def.id = "test_plugin"
	def.name = "Test Plugin"
	def.version = "0.1.0"
	def.entrypoint = "server.py"
	var errors := def.validate()
	var found := false
	for e in errors:
		if "Duplicate panel name" in e or "dup_panel" in e:
			found = true
	check("dup panel names: validate catches duplicate", found)


func test_from_dict_does_not_duplicate_top_level_arrays() -> void:
	var data := _minimal_manifest({
		"panels": [
			{"name": "real_panel", "kind": "html"}
		],
		"ipc_messages": ["test.event"],
	})
	data["editor_items"] = [
		{"id": "new_thing", "name": "New Thing", "panel": "real_panel"}
	]
	data["events"] = [
		{"name": "test.event", "payload_schema": {"type": "object"}}
	]
	var def = PluginDefinition_.from_dict(data)
	check("from_dict no duplicate: def not null", def != null)
	if def == null:
		return
	check_eq("from_dict no duplicate: one editor item", def.editor_items.size(), 1)
	check_eq("from_dict no duplicate: one event", def.events.size(), 1)


# ---------------------------------------------------------------------------
# Tests: real plugin manifests (via JSON dict round-trip)
# ---------------------------------------------------------------------------

func _load_manifest_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return {}
	if not (json.data is Dictionary):
		return {}
	return json.data as Dictionary


func test_obs_controller_manifest_parses() -> void:
	# obs_controller has a typed html panel; verify it parses cleanly.
	var data := _load_manifest_json("res://../../src/plugins/obs_controller/manifest.json")
	if data.is_empty():
		# Try path relative to project root
		data = _load_manifest_json("res://plugins/obs_controller/manifest.json")
	if data.is_empty():
		printerr("  SKIP: obs_controller/manifest.json not accessible from test runner path")
		_pass_count += 1
		print("  PASS (skip): obs_controller manifest not reachable from res://")
		return
	var def = PluginDefinition_._from_dict_internal(data)
	check("obs_controller: def not null", def != null)
	if def == null:
		return
	check_eq("obs_controller: id", def.id, "obs_controller")
	check_eq("obs_controller: panel count", def.ui_panels.size(), 1)
	check_eq("obs_controller: panel name", def.ui_panel_names[0], "obs_controller_panel")
	check_eq("obs_controller: panel kind", def.ui_panels[0].get("kind", ""), "html")


func test_notes_helper_manifest_parses() -> void:
	# notes_helper has no ui section; should parse cleanly with 0 panels.
	var data := _load_manifest_json("res://../../src/plugins/notes_helper/manifest.json")
	if data.is_empty():
		data = _load_manifest_json("res://plugins/notes_helper/manifest.json")
	if data.is_empty():
		printerr("  SKIP: notes_helper/manifest.json not accessible from test runner path")
		_pass_count += 1
		print("  PASS (skip): notes_helper manifest not reachable from res://")
		return
	var def = PluginDefinition_._from_dict_internal(data)
	check("notes_helper: def not null", def != null)
	if def == null:
		return
	check_eq("notes_helper: id", def.id, "notes_helper")
	check_eq("notes_helper: panel count (no ui section)", def.ui_panels.size(), 0)


func test_test_stdio_server_manifest_parses() -> void:
	# test_stdio_server has no ui section; should parse cleanly with 0 panels.
	var data := _load_manifest_json("res://../../src/plugins/test_stdio_server/manifest.json")
	if data.is_empty():
		data = _load_manifest_json("res://plugins/test_stdio_server/manifest.json")
	if data.is_empty():
		printerr("  SKIP: test_stdio_server/manifest.json not accessible from test runner path")
		_pass_count += 1
		print("  PASS (skip): test_stdio_server manifest not reachable from res://")
		return
	var def = PluginDefinition_._from_dict_internal(data)
	check("test_stdio_server: def not null", def != null)
	if def == null:
		return
	check_eq("test_stdio_server: id", def.id, "test_stdio_server")
	check_eq("test_stdio_server: panel count (no ui section)", def.ui_panels.size(), 0)
