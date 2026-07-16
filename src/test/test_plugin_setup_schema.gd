extends SceneTree
## Unit tests for SetupSchema (manifest `setup` stanza validation) and its
## wiring into PluginDefinition.validate() / from_manifest().
##
## Run: godot --headless --path src --script test/test_plugin_setup_schema.gd
##
## Docs/design/plugin-setup-pipeline.md §1 is the frozen contract under test:
##   - no `setup` stanza -> valid
##   - a fully valid stanza (the design doc's own example) -> valid
##   - one test per typed error code: setup_unknown_step_type,
##     setup_step_missing_field, setup_path_escape (absolute + '..'),
##     setup_bad_requires, setup_empty_argv
##   - GDScript's JSON.parse() returns every number as float -- a
##     whole-number float (e.g. timeout_s round-tripped as 60.0) must not be
##     spuriously rejected
##   - PluginDefinition.validate()/from_manifest() actually reject a bad
##     `setup` stanza at load time (fixture manifests, not just in-memory dicts)

const SetupSchema_ = preload("res://Scripts/Services/Plugins/Setup/SetupSchema.gd")
const PluginDefinition_ = preload("res://Scripts/Services/Plugins/PluginDefinition.gd")

const FIXTURE_DIR := "res://test/fixtures/plugin_setup"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== SetupSchema Tests ===\n")

	print("-- baseline acceptance --")
	test_no_setup_stanza_is_valid()
	test_full_valid_stanza_is_valid()
	test_whole_number_float_timeout_tolerated()

	print("\n-- setup_unknown_step_type --")
	test_unknown_step_type()

	print("\n-- setup_step_missing_field --")
	test_missing_required_field_names_index_and_field()

	print("\n-- setup_path_escape --")
	test_absolute_path_rejected()
	test_dotdot_traversal_rejected()

	print("\n-- setup_bad_requires --")
	test_requires_missing_tool()
	test_requires_missing_min()
	test_requires_bad_min_format()

	print("\n-- setup_empty_argv --")
	test_exec_empty_argv_rejected()
	test_exec_non_string_argv_entry_rejected()

	print("\n-- PluginDefinition wiring (load-time rejection) --")
	test_plugin_definition_validate_surfaces_setup_errors()
	test_plugin_definition_validate_accepts_valid_setup()
	test_from_manifest_rejects_bad_setup_fixture()
	test_from_manifest_accepts_good_setup_fixture()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Baseline acceptance
# ---------------------------------------------------------------------------

func test_no_setup_stanza_is_valid() -> void:
	var errors := SetupSchema_.validate_setup({})
	check("empty setup dict -> no errors", errors.is_empty(), "got: %s" % str(errors))


func test_full_valid_stanza_is_valid() -> void:
	# The exact example from Docs/design/plugin-setup-pipeline.md §1.
	var setup := {
		"requires": [
			{"tool": "go", "min": "1.22"},
			{"tool": "python", "min": "3.10"},
		],
		"steps": [
			{"type": "go_build", "package": "./", "output": "bin/pcb-plugin"},
			{"type": "python_venv", "dir": "worker", "install": "editable"},
			{"type": "copy", "from": "assets/policy.json", "to": "bin/policy.json"},
			{"type": "exec", "argv": ["./scripts/postinstall.sh"], "artifact": "bin/generated.dat"},
		],
	}
	var errors := SetupSchema_.validate_setup(setup)
	check("design-doc example stanza -> no errors", errors.is_empty(), "got: %s" % str(errors))


func test_whole_number_float_timeout_tolerated() -> void:
	# Round-trip through JSON.parse so timeout_s genuinely arrives as a
	# float, exactly like a real manifest.json load would produce.
	var json := JSON.new()
	var text := JSON.stringify({
		"steps": [
			{"type": "exec", "argv": ["./run.sh"], "timeout_s": 60},
		],
	})
	check("fixture JSON parses", json.parse(text) == OK)
	var setup: Dictionary = json.data
	var timeout_val: Variant = setup["steps"][0]["timeout_s"]
	check("json round-trip produced a float for timeout_s", timeout_val is float, "got type for %s" % str(timeout_val))

	var errors := SetupSchema_.validate_setup(setup)
	check("whole-number float timeout_s does not trip schema errors", errors.is_empty(), "got: %s" % str(errors))


# ---------------------------------------------------------------------------
# setup_unknown_step_type
# ---------------------------------------------------------------------------

func test_unknown_step_type() -> void:
	var setup := {"steps": [{"type": "rust_build", "foo": "bar"}]}
	var errors := SetupSchema_.validate_setup(setup)
	check("unknown step type -> exactly one error", errors.size() == 1, "got: %s" % str(errors))
	if errors.size() == 1:
		check("error code is setup_unknown_step_type", errors[0].get("error", "") == "setup_unknown_step_type")
		check("detail names step_index", errors[0].get("detail", {}).get("step_index", -1) == 0)
		var msg := SetupSchema_.format_error(errors[0])
		check("formatted message names the code and the step index",
				msg.begins_with("setup_unknown_step_type") and msg.contains("steps[0]"), "got: %s" % msg)


# ---------------------------------------------------------------------------
# setup_step_missing_field
# ---------------------------------------------------------------------------

func test_missing_required_field_names_index_and_field() -> void:
	# go_build requires "package" and "output"; declare only "package".
	var setup := {"steps": [
		{"type": "copy", "from": "a", "to": "b"},
		{"type": "go_build", "package": "./"},
	]}
	var errors := SetupSchema_.validate_setup(setup)
	check("missing field -> exactly one error", errors.size() == 1, "got: %s" % str(errors))
	if errors.size() == 1:
		var e: Dictionary = errors[0]
		check("error code is setup_step_missing_field", e.get("error", "") == "setup_step_missing_field")
		check("detail names step_index 1", e.get("detail", {}).get("step_index", -1) == 1)
		check("detail names the missing field 'output'", e.get("detail", {}).get("field", "") == "output")
		var msg := SetupSchema_.format_error(e)
		check("formatted message names step index and field",
				msg.contains("steps[1]") and msg.contains("'output'"), "got: %s" % msg)


# ---------------------------------------------------------------------------
# setup_path_escape
# ---------------------------------------------------------------------------

func test_absolute_path_rejected() -> void:
	var setup := {"steps": [
		{"type": "copy", "from": "a.txt", "to": "/etc/passwd"},
	]}
	var errors := SetupSchema_.validate_setup(setup)
	check("absolute path -> exactly one error", errors.size() == 1, "got: %s" % str(errors))
	if errors.size() == 1:
		check("error code is setup_path_escape", errors[0].get("error", "") == "setup_path_escape")
		check("detail names field 'to'", errors[0].get("detail", {}).get("field", "") == "to")


func test_dotdot_traversal_rejected() -> void:
	var setup := {"steps": [
		{"type": "go_build", "package": "./", "output": "../../outside/bin"},
	]}
	var errors := SetupSchema_.validate_setup(setup)
	check("'..' traversal -> exactly one error", errors.size() == 1, "got: %s" % str(errors))
	if errors.size() == 1:
		check("error code is setup_path_escape", errors[0].get("error", "") == "setup_path_escape")
		check("detail names field 'output'", errors[0].get("detail", {}).get("field", "") == "output")


# ---------------------------------------------------------------------------
# setup_bad_requires
# ---------------------------------------------------------------------------

func test_requires_missing_tool() -> void:
	var setup := {"requires": [{"min": "1.0"}]}
	var errors := SetupSchema_.validate_setup(setup)
	check("missing 'tool' -> at least one setup_bad_requires error",
			errors.size() > 0 and errors[0].get("error", "") == "setup_bad_requires", "got: %s" % str(errors))


func test_requires_missing_min() -> void:
	var setup := {"requires": [{"tool": "go"}]}
	var errors := SetupSchema_.validate_setup(setup)
	check("missing 'min' -> at least one setup_bad_requires error",
			errors.size() > 0 and errors[0].get("error", "") == "setup_bad_requires", "got: %s" % str(errors))


func test_requires_bad_min_format() -> void:
	var setup := {"requires": [{"tool": "go", "min": "not-a-version!!"}]}
	var errors := SetupSchema_.validate_setup(setup)
	check("non-semver-ish 'min' -> exactly one setup_bad_requires error",
			errors.size() == 1 and errors[0].get("error", "") == "setup_bad_requires", "got: %s" % str(errors))


# ---------------------------------------------------------------------------
# setup_empty_argv
# ---------------------------------------------------------------------------

func test_exec_empty_argv_rejected() -> void:
	var setup := {"steps": [{"type": "exec", "argv": []}]}
	var errors := SetupSchema_.validate_setup(setup)
	check("empty argv -> exactly one error", errors.size() == 1, "got: %s" % str(errors))
	if errors.size() == 1:
		check("error code is setup_empty_argv", errors[0].get("error", "") == "setup_empty_argv")


func test_exec_non_string_argv_entry_rejected() -> void:
	var setup := {"steps": [{"type": "exec", "argv": ["ok", 5]}]}
	var errors := SetupSchema_.validate_setup(setup)
	check("non-string argv entry -> exactly one error", errors.size() == 1, "got: %s" % str(errors))
	if errors.size() == 1:
		check("error code is setup_empty_argv", errors[0].get("error", "") == "setup_empty_argv")


# ---------------------------------------------------------------------------
# PluginDefinition wiring
# ---------------------------------------------------------------------------

func test_plugin_definition_validate_surfaces_setup_errors() -> void:
	var def := PluginDefinition_.new("wiring_bad")
	def.name = "Wiring Bad"
	def.version = "0.1.0"
	def.entrypoint = "python3"
	def.setup = {"steps": [{"type": "not_a_real_type"}]}
	var errors := def.validate()
	var found := false
	for e in errors:
		if e.begins_with("setup_unknown_step_type"):
			found = true
	check("PluginDefinition.validate() surfaces the setup_unknown_step_type error", found, "got: %s" % str(errors))


func test_plugin_definition_validate_accepts_valid_setup() -> void:
	var def := PluginDefinition_.new("wiring_good")
	def.name = "Wiring Good"
	def.version = "0.1.0"
	def.entrypoint = "python3"
	def.setup = {"steps": [{"type": "copy", "from": "a", "to": "b"}]}
	var errors := def.validate()
	var setup_errors: Array = errors.filter(func(e): return e.begins_with("setup_"))
	check("PluginDefinition.validate() has no setup_* errors for a valid stanza",
			setup_errors.is_empty(), "got: %s" % str(setup_errors))


func test_from_manifest_rejects_bad_setup_fixture() -> void:
	var path := FIXTURE_DIR.path_join("bad_setup_manifest.json")
	var def := PluginDefinition_.from_manifest(path)
	check("from_manifest() returns null for a manifest with an invalid setup stanza", def == null)


func test_from_manifest_accepts_good_setup_fixture() -> void:
	var path := FIXTURE_DIR.path_join("good_setup_manifest.json")
	var def := PluginDefinition_.from_manifest(path)
	check("from_manifest() loads a manifest with a valid setup stanza", def != null)
	if def != null:
		check("loaded definition's setup.steps has 2 entries",
				(def.setup.get("steps", []) as Array).size() == 2)


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
