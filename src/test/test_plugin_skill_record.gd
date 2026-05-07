extends SceneTree
## Unit tests for PluginSkillRecord (DCR 019df57b T2).
##
## Run: godot --headless --path src --script test/test_plugin_skill_record.gd
##
## Coverage:
##   compute_hash:
##     - same input → same hash (determinism)
##     - key order doesn't matter (sort_keys canonicalisation)
##     - different content → different hash
##     - manifest entry vs full docket record hash equally when content matches
##     - hash ignores runtime fields (source / customised / pristine_hash / etc.)
##     - hash includes nested dict (optimization) deterministically
##     - hash changes when tool_deps order changes (arrays are ordered)
##     - empty input still hashes (no crash)
##
##   is_plugin_seeded / get_plugin_id / normalize_source:
##     - plugin: prefix detection
##     - id extraction
##     - empty source → "user"
##     - "user" / "master" → unchanged
##     - missing source key → "user"
##
##   has_unsatisfied_deps / is_customised / is_deprecated:
##     - default behaviours (missing fields)
##     - true / false branches

const PluginSkillRecordScript := preload("res://Scripts/Services/Plugins/PluginSkillRecord.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PluginSkillRecord Tests ===\n")

	print("-- compute_hash --")
	test_hash_is_deterministic()
	test_hash_ignores_key_order()
	test_hash_changes_on_content_change()
	test_hash_manifest_equals_record_when_content_matches()
	test_hash_ignores_runtime_fields()
	test_hash_includes_optimization_dict()
	test_hash_array_order_matters_for_tool_deps()
	test_hash_empty_dict_does_not_crash()
	test_hash_is_64_char_hex()

	print("\n-- is_plugin_seeded / get_plugin_id / normalize_source --")
	test_is_plugin_seeded_true()
	test_is_plugin_seeded_false_for_user()
	test_is_plugin_seeded_false_for_master()
	test_is_plugin_seeded_false_for_empty()
	test_get_plugin_id_extracts()
	test_get_plugin_id_empty_for_non_plugin()
	test_normalize_source_empty_to_user()
	test_normalize_source_missing_to_user()
	test_normalize_source_user_unchanged()
	test_normalize_source_master_unchanged()
	test_normalize_source_plugin_unchanged()

	print("\n-- has_unsatisfied_deps / is_customised / is_deprecated --")
	test_has_unsatisfied_deps_true()
	test_has_unsatisfied_deps_false_when_empty()
	test_has_unsatisfied_deps_false_when_missing()
	test_is_customised_default_false()
	test_is_customised_true()
	test_is_deprecated_default_false()
	test_is_deprecated_true()

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


func _manifest_entry() -> Dictionary:
	return {
		"id": "minerva_demo_make_thing",
		"title": "Make a thing",
		"summary": "Composes a thing.",
		"system_prompt": "You are a thing-maker.",
		"outcome": "A thing exists.",
		"preconditions": "An input is available.",
		"steps": "1. Read input. 2. Make.",
		"tool_deps": ["minerva_demo_alpha", "minerva_demo_beta"],
		"target": "all",
		"optimization": {"context_window": 200000, "tool_budget": 30000},
	}


# ---------------------------------------------------------------------------
# compute_hash
# ---------------------------------------------------------------------------

func test_hash_is_deterministic() -> void:
	print("test_hash_is_deterministic")
	var entry := _manifest_entry()
	var h1 := PluginSkillRecordScript.compute_hash(entry)
	var h2 := PluginSkillRecordScript.compute_hash(entry)
	check("same input yields same hash", h1 == h2)
	check("hash is non-empty", not h1.is_empty())


func test_hash_ignores_key_order() -> void:
	print("test_hash_ignores_key_order")
	var entry_a := _manifest_entry()
	# Build a structurally different dict by inserting in opposite order.
	var entry_b := {}
	var keys := entry_a.keys()
	keys.reverse()
	for k in keys:
		entry_b[k] = entry_a[k]
	var h_a := PluginSkillRecordScript.compute_hash(entry_a)
	var h_b := PluginSkillRecordScript.compute_hash(entry_b)
	check("hash is key-order-independent", h_a == h_b)


func test_hash_changes_on_content_change() -> void:
	print("test_hash_changes_on_content_change")
	var entry := _manifest_entry()
	var h_before := PluginSkillRecordScript.compute_hash(entry)
	entry["steps"] = "1. Read input. 2. Make a DIFFERENT thing."
	var h_after := PluginSkillRecordScript.compute_hash(entry)
	check("changing steps changes hash", h_before != h_after)


func test_hash_manifest_equals_record_when_content_matches() -> void:
	print("test_hash_manifest_equals_record_when_content_matches")
	var manifest := _manifest_entry()
	# Simulate a docket record with all the runtime fields populated.
	var record := manifest.duplicate(true)
	record["source"] = "plugin:demo"
	record["customised"] = false
	record["pristine_hash"] = "abc"
	record["pristine_content"] = manifest.duplicate(true)
	record["unsatisfied_deps"] = []
	record["deprecated"] = false
	record["created_at"] = "2026-05-07T00:00:00"
	record["updated_at"] = "2026-05-07T00:00:00"
	record["status"] = "active"
	record["type"] = "skill"
	record["tags"] = ["from-test"]
	# T4 reconciliation relies on this equivalence.
	check("manifest hash == record hash when content matches",
		PluginSkillRecordScript.compute_hash(manifest)
		== PluginSkillRecordScript.compute_hash(record))


func test_hash_ignores_runtime_fields() -> void:
	print("test_hash_ignores_runtime_fields")
	var entry_a := _manifest_entry()
	var entry_b := _manifest_entry()
	entry_b["source"] = "plugin:demo"
	entry_b["customised"] = true
	entry_b["pristine_hash"] = "deadbeef"
	entry_b["unsatisfied_deps"] = ["x"]
	entry_b["deprecated"] = true
	entry_b["tags"] = ["random"]
	entry_b["status"] = "archived"
	check("runtime fields don't shift the hash",
		PluginSkillRecordScript.compute_hash(entry_a)
		== PluginSkillRecordScript.compute_hash(entry_b))


func test_hash_includes_optimization_dict() -> void:
	print("test_hash_includes_optimization_dict")
	var entry := _manifest_entry()
	var h_before := PluginSkillRecordScript.compute_hash(entry)
	entry["optimization"] = {"context_window": 100000, "tool_budget": 30000}
	var h_after := PluginSkillRecordScript.compute_hash(entry)
	check("changing nested optimization changes hash", h_before != h_after)


func test_hash_array_order_matters_for_tool_deps() -> void:
	print("test_hash_array_order_matters_for_tool_deps")
	var entry_a := _manifest_entry()
	var entry_b := entry_a.duplicate(true)
	entry_b["tool_deps"] = ["minerva_demo_beta", "minerva_demo_alpha"]
	check("reordering tool_deps changes hash (arrays are ordered)",
		PluginSkillRecordScript.compute_hash(entry_a)
		!= PluginSkillRecordScript.compute_hash(entry_b))


func test_hash_empty_dict_does_not_crash() -> void:
	print("test_hash_empty_dict_does_not_crash")
	var h := PluginSkillRecordScript.compute_hash({})
	check("empty dict still produces a hash", not h.is_empty())


func test_hash_is_64_char_hex() -> void:
	print("test_hash_is_64_char_hex")
	var h := PluginSkillRecordScript.compute_hash(_manifest_entry())
	check("hash is exactly 64 chars (sha256 hex)", h.length() == 64)
	var hex_only := true
	for c in h:
		if not (c in "0123456789abcdef"):
			hex_only = false
			break
	check("hash is lowercase hex", hex_only)


# ---------------------------------------------------------------------------
# Source classification
# ---------------------------------------------------------------------------

func test_is_plugin_seeded_true() -> void:
	print("test_is_plugin_seeded_true")
	check("plugin:demo → true",
		PluginSkillRecordScript.is_plugin_seeded({"source": "plugin:demo"}))
	check("plugin:obs_controller → true",
		PluginSkillRecordScript.is_plugin_seeded({"source": "plugin:obs_controller"}))


func test_is_plugin_seeded_false_for_user() -> void:
	print("test_is_plugin_seeded_false_for_user")
	check("user → false",
		not PluginSkillRecordScript.is_plugin_seeded({"source": "user"}))


func test_is_plugin_seeded_false_for_master() -> void:
	print("test_is_plugin_seeded_false_for_master")
	check("master → false",
		not PluginSkillRecordScript.is_plugin_seeded({"source": "master"}))


func test_is_plugin_seeded_false_for_empty() -> void:
	print("test_is_plugin_seeded_false_for_empty")
	check("empty source → false",
		not PluginSkillRecordScript.is_plugin_seeded({"source": ""}))
	check("missing source → false",
		not PluginSkillRecordScript.is_plugin_seeded({}))


func test_get_plugin_id_extracts() -> void:
	print("test_get_plugin_id_extracts")
	check("plugin:demo → 'demo'",
		PluginSkillRecordScript.get_plugin_id({"source": "plugin:demo"}) == "demo")
	check("plugin:obs_controller → 'obs_controller'",
		PluginSkillRecordScript.get_plugin_id({"source": "plugin:obs_controller"}) == "obs_controller")


func test_get_plugin_id_empty_for_non_plugin() -> void:
	print("test_get_plugin_id_empty_for_non_plugin")
	check("user → ''",
		PluginSkillRecordScript.get_plugin_id({"source": "user"}) == "")
	check("master → ''",
		PluginSkillRecordScript.get_plugin_id({"source": "master"}) == "")
	check("empty → ''",
		PluginSkillRecordScript.get_plugin_id({}) == "")


func test_normalize_source_empty_to_user() -> void:
	print("test_normalize_source_empty_to_user")
	check("empty source → user",
		PluginSkillRecordScript.normalize_source({"source": ""}) == "user")


func test_normalize_source_missing_to_user() -> void:
	print("test_normalize_source_missing_to_user")
	check("missing source key → user",
		PluginSkillRecordScript.normalize_source({}) == "user")


func test_normalize_source_user_unchanged() -> void:
	print("test_normalize_source_user_unchanged")
	check("user → user",
		PluginSkillRecordScript.normalize_source({"source": "user"}) == "user")


func test_normalize_source_master_unchanged() -> void:
	print("test_normalize_source_master_unchanged")
	check("master → master",
		PluginSkillRecordScript.normalize_source({"source": "master"}) == "master")


func test_normalize_source_plugin_unchanged() -> void:
	print("test_normalize_source_plugin_unchanged")
	check("plugin:demo → plugin:demo",
		PluginSkillRecordScript.normalize_source({"source": "plugin:demo"}) == "plugin:demo")


# ---------------------------------------------------------------------------
# Predicates
# ---------------------------------------------------------------------------

func test_has_unsatisfied_deps_true() -> void:
	print("test_has_unsatisfied_deps_true")
	check("non-empty array → true",
		PluginSkillRecordScript.has_unsatisfied_deps({"unsatisfied_deps": ["x"]}))


func test_has_unsatisfied_deps_false_when_empty() -> void:
	print("test_has_unsatisfied_deps_false_when_empty")
	check("empty array → false",
		not PluginSkillRecordScript.has_unsatisfied_deps({"unsatisfied_deps": []}))


func test_has_unsatisfied_deps_false_when_missing() -> void:
	print("test_has_unsatisfied_deps_false_when_missing")
	check("missing key → false",
		not PluginSkillRecordScript.has_unsatisfied_deps({}))


func test_is_customised_default_false() -> void:
	print("test_is_customised_default_false")
	check("missing → false", not PluginSkillRecordScript.is_customised({}))
	check("explicit false → false", not PluginSkillRecordScript.is_customised({"customised": false}))


func test_is_customised_true() -> void:
	print("test_is_customised_true")
	check("explicit true → true",
		PluginSkillRecordScript.is_customised({"customised": true}))


func test_is_deprecated_default_false() -> void:
	print("test_is_deprecated_default_false")
	check("missing → false", not PluginSkillRecordScript.is_deprecated({}))
	check("explicit false → false", not PluginSkillRecordScript.is_deprecated({"deprecated": false}))


func test_is_deprecated_true() -> void:
	print("test_is_deprecated_true")
	check("explicit true → true",
		PluginSkillRecordScript.is_deprecated({"deprecated": true}))
