extends SceneTree
## Integration test for host.dialogs.file_picker + host.dialogs.directory_picker (T3).
##
## Run: godot --headless --path src --script test/test_host_capability_dialogs.gd
##
## Coverage (in-process — direct broker.dispatch with a stub PluginDB + override injection):
##
##   file_picker:
##     1. ungranted → capability_not_granted
##     2. unknown arg key → schema_validation_failed
##     3. invalid mode value → schema_validation_failed
##     4. invalid filter entry (non-String) → schema_validation_failed
##     5. happy path override {cancelled:false, path:...} → success, override cleared
##     6. cancelled path override {cancelled:true} → success
##     7. headless + no override → dialog_unavailable
##     8. override consumed once (second call hits headless guard)
##
##   directory_picker:
##     9. ungranted → capability_not_granted
##    10. happy path override → success
##    11. headless + no override → dialog_unavailable
##
## Test isolation: clears "dialogs_probe_test" from user://plugins/policy.json
## both before and after the run.

const PLUGIN_DB_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDB.gd"
const POLICY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"

const TEST_PLUGIN_ID := "dialogs_probe_test"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.dialogs.* Capability Test (T3) ===\n")
	_clear_policy_for_test()
	await _run_tests()
	_clear_policy_for_test()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

func _run_tests() -> void:
	var DB = load(PLUGIN_DB_SCRIPT_PATH)
	var Policy = load(POLICY_SCRIPT_PATH)
	var Audit = load(AUDIT_SCRIPT_PATH)
	var Broker = load(BROKER_SCRIPT_PATH)
	var Def = load(DEFINITION_SCRIPT_PATH)
	check("scripts loaded",
		DB != null and Policy != null and Audit != null and Broker != null and Def != null)

	var db = DB.new()
	var def = Def.new(TEST_PLUGIN_ID)
	var caps: Array[String] = [
		"host.dialogs.file_picker",
		"host.dialogs.directory_picker",
	]
	def.host_capabilities = caps
	db._plugins[TEST_PLUGIN_ID] = def

	var audit = Audit.new()
	var policy = Policy.new(db, audit)
	var broker = Broker.new(policy, audit)

	# Make sure override is clean at start
	Broker._test_dialog_override = null

	# -------------------------------------------------------------------------
	# file_picker tests
	# -------------------------------------------------------------------------

	# 1. ungranted → capability_not_granted
	var deny_fp: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.file_picker", {})
	check_eq("file_picker ungranted → capability_not_granted",
		deny_fp.get("error_code", ""), "capability_not_granted")

	# Grant capabilities now
	policy.grant_capability(TEST_PLUGIN_ID, "host.dialogs.file_picker")
	policy.grant_capability(TEST_PLUGIN_ID, "host.dialogs.directory_picker")

	# 2. unknown arg key → schema_validation_failed
	var unk_arg: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.file_picker",
		{"bogus": 1})
	check_eq("file_picker unknown arg → schema_validation_failed",
		unk_arg.get("error_code", ""), "schema_validation_failed")

	# 3. invalid mode value → schema_validation_failed
	var bad_mode: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.file_picker",
		{"mode": "edit"})
	check_eq("file_picker invalid mode → schema_validation_failed",
		bad_mode.get("error_code", ""), "schema_validation_failed")

	# 4. invalid filter entry (non-String in array) → schema_validation_failed
	var bad_filter: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.file_picker",
		{"filters": [42]})
	check_eq("file_picker non-string filter → schema_validation_failed",
		bad_filter.get("error_code", ""), "schema_validation_failed")

	# 5. happy path with override {cancelled:false, path:...} → success, override cleared after
	Broker._test_dialog_override = {"cancelled": false, "path": "/tmp/foo.txt"}
	var pick_ok: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.file_picker", {})
	check("file_picker happy override → success", pick_ok.get("success", false),
		"got: %s" % str(pick_ok))
	check_eq("file_picker happy override → correct path",
		pick_ok.get("result", {}).get("path", ""), "/tmp/foo.txt")
	check_eq("file_picker happy override → cancelled=false",
		pick_ok.get("result", {}).get("cancelled", true), false)
	check_eq("file_picker override cleared after dispatch",
		Broker._test_dialog_override, null)

	# 6. cancelled path override {cancelled:true} → success
	Broker._test_dialog_override = {"cancelled": true}
	var pick_cancel: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.file_picker", {})
	check("file_picker cancel override → success", pick_cancel.get("success", false),
		"got: %s" % str(pick_cancel))
	check_eq("file_picker cancel override → cancelled=true",
		pick_cancel.get("result", {}).get("cancelled", false), true)

	# 7. headless + no override → dialog_unavailable
	# (override is already null from case 6 consuming it; DisplayServer is headless in test)
	var headless_fp: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.file_picker", {})
	check_eq("file_picker headless no override → dialog_unavailable",
		headless_fp.get("error_code", ""), "dialog_unavailable")

	# 8. override consumed once — set override, dispatch, then dispatch again (override now null)
	Broker._test_dialog_override = {"cancelled": false, "path": "/tmp/first.txt"}
	var first_call: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.file_picker", {})
	check("file_picker override first call → success", first_call.get("success", false),
		"got: %s" % str(first_call))
	# Second call — override is gone, should hit headless guard
	var second_call: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.file_picker", {})
	check_eq("file_picker second call (override gone) → dialog_unavailable",
		second_call.get("error_code", ""), "dialog_unavailable")

	# -------------------------------------------------------------------------
	# directory_picker tests
	# -------------------------------------------------------------------------

	# 9. ungranted — use a SEPARATE plugin_id. Same id won't work because
	# PluginPolicy._save() persisted the earlier grants to user://plugins/policy.json,
	# so a new Policy.new() loads them back even within the same run.
	# _clear_policy_for_test() handles both ids at start.
	var alt_id := "dialogs_probe_test_no_grant"
	var db2 = DB.new()
	var def2 = Def.new(alt_id)
	var caps2: Array[String] = ["host.dialogs.directory_picker"]
	def2.host_capabilities = caps2
	db2._plugins[alt_id] = def2
	var audit2 = Audit.new()
	var policy2 = Policy.new(db2, audit2)
	var broker2 = Broker.new(policy2, audit2)
	var deny_dp: Dictionary = await broker2.dispatch(alt_id, "host.dialogs.directory_picker", {})
	check_eq("directory_picker ungranted → capability_not_granted",
		deny_dp.get("error_code", ""), "capability_not_granted")

	# 10. happy path override
	Broker._test_dialog_override = {"cancelled": false, "path": "/tmp/my_vault"}
	var dir_ok: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.directory_picker", {})
	check("directory_picker happy override → success", dir_ok.get("success", false),
		"got: %s" % str(dir_ok))
	check_eq("directory_picker happy override → correct path",
		dir_ok.get("result", {}).get("path", ""), "/tmp/my_vault")

	# 11. headless + no override → dialog_unavailable
	var headless_dp: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.dialogs.directory_picker", {})
	check_eq("directory_picker headless no override → dialog_unavailable",
		headless_dp.get("error_code", ""), "dialog_unavailable")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		var msg := "  FAIL: %s" % label
		if not detail.is_empty():
			msg += " — " + detail
		print(msg)


func check_eq(label: String, actual, expected) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s — expected %s, got %s" % [label, str(expected), str(actual)])


# ---------------------------------------------------------------------------
# Policy isolation
# ---------------------------------------------------------------------------

func _clear_policy_for_test() -> void:
	# Clears BOTH the grant-path id and the deny-path id. Both shapes of policy
	# persistence (cross-run + intra-run via Policy.new()) read this file.
	var policy_file: String = ProjectSettings.globalize_path("user://plugins/policy.json")
	if not FileAccess.file_exists(policy_file):
		return
	var fa := FileAccess.open(policy_file, FileAccess.READ)
	if fa == null:
		return
	var raw := fa.get_as_text()
	fa.close()
	var data: Variant = JSON.parse_string(raw)
	if not data is Dictionary:
		return
	var grants: Dictionary = (data as Dictionary).get("grants", {})
	grants.erase(TEST_PLUGIN_ID)
	grants.erase("dialogs_probe_test_no_grant")
	(data as Dictionary)["grants"] = grants
	fa = FileAccess.open(policy_file, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(data, "  "))
	fa.close()
