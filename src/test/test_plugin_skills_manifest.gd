extends SceneTree
## Unit tests for PluginDefinition skills[] manifest support (DCR 019df57b T1).
##
## Run: godot --headless --path src --script test/test_plugin_skills_manifest.gd
##
## Coverage:
##   _from_dict_internal:
##     - manifest with no skills field — skills array stays empty
##     - manifest with empty skills array — skills array stays empty
##     - manifest with one valid skill — skills array has one entry
##     - manifest with multiple valid skills — skills array preserves order
##     - to_dict() round-trip preserves skills
##     - to_dict() omits skills field when empty
##
##   validate():
##     - all required fields present + good prefix + valid tool_deps → no errors
##     - missing each required field → error mentions field name
##     - bad skill id prefix (wrong plugin id) → error
##     - bad skill id prefix (uppercase) → error
##     - empty skill id → error
##     - duplicate skill ids in same manifest → manifest_duplicate_skill_id
##     - tool_deps not an Array → error
##     - tool_deps entry not a String → error
##     - tool_deps entry empty string → error
##     - skill entry is not a Dictionary → error
##     - empty tool_deps array is allowed
##     - optimization is optional

const PluginDefinitionScript = preload("res://Scripts/Services/Plugins/PluginDefinition.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginDefinition skills[] Tests ===\n")

	print("-- parsing & round-trip --")
	test_no_skills_field_is_empty()
	test_empty_skills_array_is_empty()
	test_one_valid_skill_parsed()
	test_multiple_skills_preserve_order()
	test_to_dict_round_trip_preserves_skills()
	test_to_dict_omits_skills_when_empty()
	test_non_dict_skill_entries_skipped_at_parse_time()

	print("\n-- validate(): happy path --")
	test_valid_skill_no_errors()
	test_empty_tool_deps_allowed()
	test_optimization_optional()

	print("\n-- validate(): required fields --")
	test_missing_id_caught()
	test_missing_title_caught()
	test_missing_summary_caught()
	test_missing_system_prompt_caught()
	test_missing_outcome_caught()
	test_missing_preconditions_caught()
	test_missing_steps_caught()
	test_missing_tool_deps_caught()
	test_missing_target_caught()

	print("\n-- validate(): id prefix rule --")
	test_wrong_plugin_id_prefix_rejected()
	test_uppercase_in_skill_id_rejected()
	test_empty_skill_id_rejected()

	print("\n-- validate(): duplicate id --")
	test_duplicate_skill_id_rejected()

	print("\n-- validate(): tool_deps shape --")
	test_tool_deps_not_array_rejected()
	test_tool_dep_non_string_rejected()
	test_tool_dep_empty_string_rejected()

	print("\n-- validate(): skill entry shape --")
	test_skill_entry_not_dict_rejected()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func _base_manifest(plugin_id: String = "demo") -> Dictionary:
	return {
		"id": plugin_id,
		"name": "Demo Plugin",
		"version": "0.1.0",
		"backend": {"transport": "stdio", "entrypoint": "python plugin.py"},
		"ui": {"panels": [], "ipc_messages": []},
		"tools": [],
	}


func _valid_skill(plugin_id: String = "demo", short_id: String = "make_thing") -> Dictionary:
	return {
		"id": "minerva_%s_%s" % [plugin_id, short_id],
		"title": "Make a thing",
		"summary": "Composes a thing from inputs.",
		"system_prompt": "You are a thing-maker.",
		"outcome": "A thing exists.",
		"preconditions": "An input is available.",
		"steps": "1. Read input. 2. Make thing.",
		"tool_deps": ["minerva_demo_create_thing"],
		"target": "all",
	}


func _has_error_containing(errors: Array[String], substr: String) -> bool:
	for e in errors:
		if substr in e:
			return true
	return false


## Build a PluginDefinition with given skills array.
##
## We can't simply do `def.skills = [skill]` because skills is `Array[Dictionary]`
## and a plain `[...]` literal is untyped Array; assignment fails the type guard.
## Routing through .assign() coerces the elements, mirroring how _from_dict_internal
## populates the field via .append() during parse.
func _def_with_skills(plugin_id: String, skill_dicts: Array) -> PluginDefinitionScript:
	var def = PluginDefinitionScript.from_dict(_base_manifest(plugin_id))
	def.skills.assign(skill_dicts)
	return def


# ---------------------------------------------------------------------------
# Parsing & round-trip
# ---------------------------------------------------------------------------

func test_no_skills_field_is_empty() -> void:
	print("test_no_skills_field_is_empty")
	var def = PluginDefinitionScript.from_dict(_base_manifest())
	check("def is non-null", def != null)
	check("skills array is empty", def.skills.is_empty())


func test_empty_skills_array_is_empty() -> void:
	print("test_empty_skills_array_is_empty")
	var manifest := _base_manifest()
	manifest["skills"] = []
	var def = PluginDefinitionScript.from_dict(manifest)
	check("def is non-null", def != null)
	check("skills array is empty", def.skills.is_empty())


func test_one_valid_skill_parsed() -> void:
	print("test_one_valid_skill_parsed")
	var manifest := _base_manifest()
	manifest["skills"] = [_valid_skill()]
	var def = PluginDefinitionScript.from_dict(manifest)
	check("def is non-null", def != null)
	check("skills has 1 entry", def.skills.size() == 1)
	check("skill id preserved", def.skills[0].get("id", "") == "minerva_demo_make_thing")


func test_multiple_skills_preserve_order() -> void:
	print("test_multiple_skills_preserve_order")
	var manifest := _base_manifest()
	manifest["skills"] = [
		_valid_skill("demo", "alpha"),
		_valid_skill("demo", "beta"),
		_valid_skill("demo", "gamma"),
	]
	var def = PluginDefinitionScript.from_dict(manifest)
	check("3 skills parsed", def.skills.size() == 3)
	check("order preserved", def.skills[0].get("id") == "minerva_demo_alpha"
		and def.skills[1].get("id") == "minerva_demo_beta"
		and def.skills[2].get("id") == "minerva_demo_gamma")


func test_to_dict_round_trip_preserves_skills() -> void:
	print("test_to_dict_round_trip_preserves_skills")
	var manifest := _base_manifest()
	manifest["skills"] = [_valid_skill()]
	var def = PluginDefinitionScript.from_dict(manifest)
	var serialized: Dictionary = def.to_dict()
	check("serialized has skills key", serialized.has("skills"))
	check("serialized skills count is 1", (serialized.get("skills", []) as Array).size() == 1)
	var def2 = PluginDefinitionScript.from_dict(serialized)
	check("round-trip parses", def2 != null)
	check("round-trip preserves skill id",
		def2.skills.size() == 1 and def2.skills[0].get("id") == "minerva_demo_make_thing")


func test_to_dict_omits_skills_when_empty() -> void:
	print("test_to_dict_omits_skills_when_empty")
	var def = PluginDefinitionScript.from_dict(_base_manifest())
	var serialized: Dictionary = def.to_dict()
	check("serialized omits skills key when empty", not serialized.has("skills"))


func test_non_dict_skill_entries_skipped_at_parse_time() -> void:
	print("test_non_dict_skill_entries_skipped_at_parse_time")
	var manifest := _base_manifest()
	manifest["skills"] = ["a string", 42, _valid_skill()]
	var def = PluginDefinitionScript.from_dict(manifest)
	check("non-dict entries skipped at parse", def.skills.size() == 1)


# ---------------------------------------------------------------------------
# validate(): happy path
# ---------------------------------------------------------------------------

func test_valid_skill_no_errors() -> void:
	print("test_valid_skill_no_errors")
	var def := _def_with_skills("demo", [_valid_skill()])
	var errors := def.validate()
	check("no validation errors", errors.is_empty())


func test_empty_tool_deps_allowed() -> void:
	print("test_empty_tool_deps_allowed")
	var skill := _valid_skill()
	skill["tool_deps"] = []
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("empty tool_deps array is valid", errors.is_empty())


func test_optimization_optional() -> void:
	print("test_optimization_optional")
	var skill := _valid_skill()
	skill.erase("optimization")  # ensure absent
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("optimization absent is OK", errors.is_empty())


# ---------------------------------------------------------------------------
# validate(): required fields
# ---------------------------------------------------------------------------

func _missing_field_check(field: String) -> void:
	var skill := _valid_skill()
	skill.erase(field)
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("missing '%s' produces error" % field,
		_has_error_containing(errors, field))


func test_missing_id_caught() -> void:
	print("test_missing_id_caught")
	# When id is missing, prefix check also fires (empty id).  Either signal is acceptable.
	var skill := _valid_skill()
	skill.erase("id")
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("missing 'id' produces an error",
		_has_error_containing(errors, "id") or _has_error_containing(errors, "empty"))


func test_missing_title_caught() -> void:
	print("test_missing_title_caught")
	_missing_field_check("title")


func test_missing_summary_caught() -> void:
	print("test_missing_summary_caught")
	_missing_field_check("summary")


func test_missing_system_prompt_caught() -> void:
	print("test_missing_system_prompt_caught")
	_missing_field_check("system_prompt")


func test_missing_outcome_caught() -> void:
	print("test_missing_outcome_caught")
	_missing_field_check("outcome")


func test_missing_preconditions_caught() -> void:
	print("test_missing_preconditions_caught")
	_missing_field_check("preconditions")


func test_missing_steps_caught() -> void:
	print("test_missing_steps_caught")
	_missing_field_check("steps")


func test_missing_tool_deps_caught() -> void:
	print("test_missing_tool_deps_caught")
	_missing_field_check("tool_deps")


func test_missing_target_caught() -> void:
	print("test_missing_target_caught")
	_missing_field_check("target")


# ---------------------------------------------------------------------------
# validate(): id prefix
# ---------------------------------------------------------------------------

func test_wrong_plugin_id_prefix_rejected() -> void:
	print("test_wrong_plugin_id_prefix_rejected")
	var skill := _valid_skill()
	skill["id"] = "minerva_otherplugin_make_thing"
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("wrong plugin id prefix produces error",
		_has_error_containing(errors, "must match"))


func test_uppercase_in_skill_id_rejected() -> void:
	print("test_uppercase_in_skill_id_rejected")
	var skill := _valid_skill()
	skill["id"] = "minerva_demo_MakeThing"
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("uppercase in skill id produces error",
		_has_error_containing(errors, "must match"))


func test_empty_skill_id_rejected() -> void:
	print("test_empty_skill_id_rejected")
	var skill := _valid_skill()
	skill["id"] = ""
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("empty skill id produces error",
		_has_error_containing(errors, "empty"))


# ---------------------------------------------------------------------------
# validate(): duplicate
# ---------------------------------------------------------------------------

func test_duplicate_skill_id_rejected() -> void:
	print("test_duplicate_skill_id_rejected")
	var s1 := _valid_skill("demo", "make_thing")
	var s2 := _valid_skill("demo", "make_thing")  # same id
	var def := _def_with_skills("demo", [s1, s2])
	var errors := def.validate()
	check("duplicate skill id flagged",
		_has_error_containing(errors, "manifest_duplicate_skill_id"))


# ---------------------------------------------------------------------------
# validate(): tool_deps
# ---------------------------------------------------------------------------

func test_tool_deps_not_array_rejected() -> void:
	print("test_tool_deps_not_array_rejected")
	var skill := _valid_skill()
	skill["tool_deps"] = "minerva_demo_thing"  # string instead of array
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("tool_deps non-array flagged",
		_has_error_containing(errors, "Array"))


func test_tool_dep_non_string_rejected() -> void:
	print("test_tool_dep_non_string_rejected")
	var skill := _valid_skill()
	skill["tool_deps"] = ["minerva_demo_alpha", 42]
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("non-string tool_dep flagged",
		_has_error_containing(errors, "String"))


func test_tool_dep_empty_string_rejected() -> void:
	print("test_tool_dep_empty_string_rejected")
	var skill := _valid_skill()
	skill["tool_deps"] = ["minerva_demo_alpha", ""]
	var def := _def_with_skills("demo", [skill])
	var errors := def.validate()
	check("empty-string tool_dep flagged",
		_has_error_containing(errors, "non-empty"))


# ---------------------------------------------------------------------------
# validate(): non-dict skill entry
# ---------------------------------------------------------------------------

func test_skill_entry_not_dict_rejected() -> void:
	print("test_skill_entry_not_dict_rejected")
	# We can't stuff a non-dict into Array[Dictionary] (typed-array guard rejects
	# at assignment).  The parse-time filter and the typed-array guard together
	# guarantee no non-dict ever reaches validate().  This test instead verifies
	# the validate loop survives a structurally-empty Dictionary entry — which
	# IS allowed past the typed-array guard, and exercises the missing-field
	# branch fully.
	var def := _def_with_skills("demo", [{}])
	var errors := def.validate()
	check("empty-dict skill entry produces multiple errors (one per missing field)",
		errors.size() >= REQUIRED_FIELD_COUNT)


# Mirrors PluginDefinition.REQUIRED_SKILL_FIELDS.size() — keep in sync if the
# constant changes.  9 required fields per DCR 019df57b.
const REQUIRED_FIELD_COUNT := 9
