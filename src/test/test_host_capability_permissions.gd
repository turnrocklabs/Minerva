extends SceneTree
## Integration test for host.permissions.grant_scope (T5a).
##
## Run: godot --headless --path src --script test/test_host_capability_permissions.gd
##
## Coverage (in-process — direct broker.dispatch with a stub PluginDB + override injection):
##
##   1.  ungranted → capability_not_granted
##   2.  unknown arg key → schema_validation_failed
##   3.  non-absolute path → schema_validation_failed
##   4.  path with '..' → schema_validation_failed
##   5.  path with null byte → schema_validation_failed
##   6.  happy override grant → {granted:true, already_granted:false, cancelled:false}
##       path appears in def.filesystem_paths after
##   7.  cancel override → {granted:false, cancelled:true}
##       def.filesystem_paths unchanged
##   8.  already-granted short-circuit → {granted:true, already_granted:true}
##       override NOT consumed
##   9.  headless + no override → dialog_unavailable
##  10.  persistence: grant via override, fresh PluginScopeGrants sees it
##
## Test isolation: clears policy.json and scoped_paths_grants.json for both
## test plugin IDs at start and end.

const PLUGIN_DB_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDB.gd"
const POLICY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"
const SCOPE_GRANTS_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginScopeGrants.gd"

const TEST_PLUGIN_ID := "permissions_probe_test"
const TEST_PLUGIN_ID_NO_GRANT := "permissions_probe_test_no_grant"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.permissions.grant_scope Capability Test (T5a) ===\n")
	_clear_policy_for_test()
	_clear_scope_grants_for_test()
	await _run_tests()
	_clear_policy_for_test()
	_clear_scope_grants_for_test()
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
	var Grants = load(SCOPE_GRANTS_SCRIPT_PATH)
	check("scripts loaded",
		DB != null and Policy != null and Audit != null and Broker != null and Def != null and Grants != null)

	# Build a stub PluginDB + def with the capability declared.
	var db = DB.new()
	var def = Def.new(TEST_PLUGIN_ID)
	def.host_capabilities = ["host.permissions.grant_scope"] as Array[String]
	def.filesystem_mode = "none"
	def.filesystem_paths.clear()
	db._plugins[TEST_PLUGIN_ID] = def

	var audit = Audit.new()
	var policy = Policy.new(db, audit)
	var broker = Broker.new(policy, audit)

	# Make sure override is clean at start.
	Broker._test_dialog_override = null

	# -------------------------------------------------------------------------
	# 1. ungranted → capability_not_granted
	#    Use a SEPARATE plugin id to avoid policy-persistence pitfall.
	# -------------------------------------------------------------------------
	var db_no = DB.new()
	var def_no = Def.new(TEST_PLUGIN_ID_NO_GRANT)
	def_no.host_capabilities = ["host.permissions.grant_scope"] as Array[String]
	db_no._plugins[TEST_PLUGIN_ID_NO_GRANT] = def_no
	var audit_no = Audit.new()
	var policy_no = Policy.new(db_no, audit_no)
	var broker_no = Broker.new(policy_no, audit_no)

	var deny: Dictionary = await broker_no.dispatch(
		TEST_PLUGIN_ID_NO_GRANT, "host.permissions.grant_scope", {"path": "/tmp/test_vault"}
	)
	check_eq("1. ungranted → capability_not_granted",
		deny.get("error_code", ""), "capability_not_granted")

	# Grant the capability for the main test plugin.
	policy.grant_capability(TEST_PLUGIN_ID, "host.permissions.grant_scope")

	# -------------------------------------------------------------------------
	# 2. unknown arg key → schema_validation_failed
	# -------------------------------------------------------------------------
	var unk: Dictionary = await broker.dispatch(
		TEST_PLUGIN_ID, "host.permissions.grant_scope",
		{"path": "/tmp/test_vault", "bogus": 1}
	)
	check_eq("2. unknown arg key → schema_validation_failed",
		unk.get("error_code", ""), "schema_validation_failed")

	# -------------------------------------------------------------------------
	# 3. non-absolute path → schema_validation_failed
	# -------------------------------------------------------------------------
	var rel_path: Dictionary = await broker.dispatch(
		TEST_PLUGIN_ID, "host.permissions.grant_scope",
		{"path": "relative/path/vault"}
	)
	check_eq("3. non-absolute path → schema_validation_failed",
		rel_path.get("error_code", ""), "schema_validation_failed")

	# -------------------------------------------------------------------------
	# 4. path with '..' → schema_validation_failed
	# -------------------------------------------------------------------------
	var dotdot: Dictionary = await broker.dispatch(
		TEST_PLUGIN_ID, "host.permissions.grant_scope",
		{"path": "/tmp/foo/../etc"}
	)
	check_eq("4. path with '..' → schema_validation_failed",
		dotdot.get("error_code", ""), "schema_validation_failed")

	# -------------------------------------------------------------------------
	# 5. path with null byte → schema_validation_failed
	# -------------------------------------------------------------------------
	var nullbyte: Dictionary = await broker.dispatch(
		TEST_PLUGIN_ID, "host.permissions.grant_scope",
		{"path": "/tmp/foo" + char(0) + "bar"}
	)
	check_eq("5. path with null byte → schema_validation_failed",
		nullbyte.get("error_code", ""), "schema_validation_failed")

	# -------------------------------------------------------------------------
	# 6. happy override grant
	# -------------------------------------------------------------------------
	var grant_path := "/tmp/permissions_probe_vault"
	Broker._test_dialog_override = {"granted": true, "cancelled": false}
	var grant_ok: Dictionary = await broker.dispatch(
		TEST_PLUGIN_ID, "host.permissions.grant_scope",
		{"path": grant_path, "reason": "Need to access vault"}
	)
	check("6a. happy override → success", grant_ok.get("success", false),
		"got: %s" % str(grant_ok))
	check_eq("6b. happy override → granted=true",
		grant_ok.get("result", {}).get("granted", false), true)
	check_eq("6c. happy override → already_granted=false",
		grant_ok.get("result", {}).get("already_granted", true), false)
	check_eq("6d. happy override → cancelled=false",
		grant_ok.get("result", {}).get("cancelled", true), false)
	check_eq("6e. happy override → path matches",
		grant_ok.get("result", {}).get("path", ""), grant_path)
	check("6f. path now in def.filesystem_paths",
		grant_path in def.filesystem_paths,
		"filesystem_paths=%s" % str(def.filesystem_paths))
	check_eq("6g. override cleared",
		Broker._test_dialog_override, null)

	# -------------------------------------------------------------------------
	# 7. cancel override — path NOT in filesystem_paths
	# -------------------------------------------------------------------------
	var cancel_path := "/tmp/permissions_probe_cancel"
	Broker._test_dialog_override = {"granted": false, "cancelled": true}
	var cancel_ok: Dictionary = await broker.dispatch(
		TEST_PLUGIN_ID, "host.permissions.grant_scope",
		{"path": cancel_path}
	)
	check("7a. cancel override → success envelope", cancel_ok.get("success", false),
		"got: %s" % str(cancel_ok))
	check_eq("7b. cancel override → granted=false",
		cancel_ok.get("result", {}).get("granted", true), false)
	check_eq("7c. cancel override → cancelled=true",
		cancel_ok.get("result", {}).get("cancelled", false), true)
	check("7d. cancel path NOT in def.filesystem_paths",
		cancel_path not in def.filesystem_paths,
		"filesystem_paths=%s" % str(def.filesystem_paths))

	# -------------------------------------------------------------------------
	# 8. already-granted short-circuit — override NOT consumed
	# -------------------------------------------------------------------------
	# grant_path was added in test 6. Set a fresh override and verify it is NOT
	# consumed (already-granted check fires before the override check).
	var sentinel := {"granted": true, "cancelled": false}
	Broker._test_dialog_override = sentinel
	var already: Dictionary = await broker.dispatch(
		TEST_PLUGIN_ID, "host.permissions.grant_scope",
		{"path": grant_path}
	)
	check("8a. already-granted → success envelope", already.get("success", false),
		"got: %s" % str(already))
	check_eq("8b. already-granted → already_granted=true",
		already.get("result", {}).get("already_granted", false), true)
	check_eq("8c. already-granted → granted=true",
		already.get("result", {}).get("granted", false), true)
	# Override must still be set (was not consumed).
	check("8d. override NOT consumed by already-granted path",
		Broker._test_dialog_override != null,
		"override was unexpectedly cleared")
	# Clean up the override we left.
	Broker._test_dialog_override = null

	# -------------------------------------------------------------------------
	# 9. headless + no override → dialog_unavailable
	# -------------------------------------------------------------------------
	var new_path := "/tmp/permissions_probe_headless"
	var headless: Dictionary = await broker.dispatch(
		TEST_PLUGIN_ID, "host.permissions.grant_scope",
		{"path": new_path}
	)
	check_eq("9. headless no override → dialog_unavailable",
		headless.get("error_code", ""), "dialog_unavailable")

	# -------------------------------------------------------------------------
	# 10. persistence: grant via override, fresh PluginScopeGrants sees it
	# -------------------------------------------------------------------------
	# grant_path was already granted in test 6; its persistence was written then.
	# Instantiate a fresh PluginScopeGrants (reads from disk) and verify.
	var fresh_grants = Grants.new()
	var persisted: Array = fresh_grants.get_granted_paths(TEST_PLUGIN_ID)
	check("10. persisted grants contain grant_path",
		grant_path in persisted,
		"persisted=%s" % str(persisted))


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
# Test isolation
# ---------------------------------------------------------------------------

func _clear_policy_for_test() -> void:
	# Clears both test plugin IDs from user://plugins/policy.json.
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
	grants.erase(TEST_PLUGIN_ID_NO_GRANT)
	(data as Dictionary)["grants"] = grants
	fa = FileAccess.open(policy_file, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(data, "  "))
	fa.close()


func _clear_scope_grants_for_test() -> void:
	# Clears both test plugin IDs from user://plugins/scoped_paths_grants.json.
	var grants_file: String = ProjectSettings.globalize_path("user://plugins/scoped_paths_grants.json")
	if not FileAccess.file_exists(grants_file):
		return
	var fa := FileAccess.open(grants_file, FileAccess.READ)
	if fa == null:
		return
	var raw := fa.get_as_text()
	fa.close()
	var data: Variant = JSON.parse_string(raw)
	if not data is Dictionary:
		return
	(data as Dictionary).erase(TEST_PLUGIN_ID)
	(data as Dictionary).erase(TEST_PLUGIN_ID_NO_GRANT)
	fa = FileAccess.open(grants_file, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(data, "  "))
	fa.close()
