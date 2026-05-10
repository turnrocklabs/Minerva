extends SceneTree
## Integration test for host.editors.list + host.editors.export (T5 R2).
##
## Run: godot --headless --path src --script test/test_host_capability_editors.gd
##
## Tracks docket: minerva 019df8e3bd7973e5bb2d6acfe1f74611
## Parent DCR:    minerva 019df8e2d0937613a326389a4df133fb
##
## Coverage (in-process — direct broker.dispatch with stub PluginDB):
##   list:
##     - happy path returns {editors: []} when editor_pane is null (headless)
##     - audit log records capability_dispatched
##     - deny path (no grant) → capability_not_granted, audit logs denied
##
##   export:
##     - missing editor_name → schema_validation_failed
##     - empty editor_name → schema_validation_failed
##     - missing format → schema_validation_failed
##     - empty format → schema_validation_failed
##     - unknown arg → schema_validation_failed
##     - bogus editor_name (with required args) → editor_not_found
##
##   audit:
##     - dispatched + denied + failed event classes recorded as per shape
##
## Real graphics editor exercise (compose_final_image → PNG round trip) is
## deferred to the HITL pass, since it requires a running editor pane.

const PLUGIN_DB_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDB.gd"
const POLICY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"

const TEST_PLUGIN_ID := "editors_probe_test"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.editors.* Capability Test (T5 R2) ===\n")
	_clear_policy_for_test()
	await _run_tests()
	_clear_policy_for_test()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	var DB = load(PLUGIN_DB_SCRIPT_PATH)
	var Policy = load(POLICY_SCRIPT_PATH)
	var Audit = load(AUDIT_SCRIPT_PATH)
	var Broker = load(BROKER_SCRIPT_PATH)
	var Def = load(DEFINITION_SCRIPT_PATH)

	var db = DB.new()
	var def = Def.new(TEST_PLUGIN_ID)
	var caps: Array[String] = ["host.editors.list", "host.editors.export"]
	def.host_capabilities = caps
	db._plugins[TEST_PLUGIN_ID] = def

	var audit = Audit.new()
	var policy = Policy.new(db, audit)
	var broker = Broker.new(policy, audit)

	# Deny path before grant — assert capability_not_granted is the audit class.
	var pre_grant: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.editors.list", {})
	check_eq("list without grant → capability_not_granted",
		pre_grant.get("error_code", ""), "capability_not_granted")
	var pre_denied: Array = audit.get_entries(TEST_PLUGIN_ID, "capability_denied")
	check("audit logs capability_denied for ungranted list", pre_denied.size() > 0)

	policy.grant_capability(TEST_PLUGIN_ID, "host.editors.list")
	policy.grant_capability(TEST_PLUGIN_ID, "host.editors.export")

	# --- list happy path (headless: empty editor_pane) ----------------------
	var list_res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.editors.list", {})
	check("list: success in headless",
		list_res.get("success", false), "got: %s" % str(list_res))
	var inner: Dictionary = list_res.get("result", {})
	check("list: result.editors is Array",
		inner.get("editors") is Array, "got type: %s" % typeof(inner.get("editors")))
	# In headless, editor_pane is null → empty list. The shape contract is what
	# matters here, not the count.

	var dispatched: Array = audit.get_entries(TEST_PLUGIN_ID, "capability_dispatched")
	check("audit: list call recorded as dispatched",
		dispatched.size() > 0, "entries: %d" % dispatched.size())

	# --- export validation paths -------------------------------------------
	_check_export_error(broker, {}, "schema_validation_failed",
		"export: no args → schema_validation_failed")
	_check_export_error(broker, {"editor_name": ""}, "schema_validation_failed",
		"export: empty editor_name → schema_validation_failed")
	_check_export_error(broker, {"editor_name": "x"}, "schema_validation_failed",
		"export: missing format → schema_validation_failed")
	_check_export_error(broker, {"editor_name": "x", "format": ""}, "schema_validation_failed",
		"export: empty format → schema_validation_failed")
	_check_export_error(broker, {"editor_name": "x", "format": "png", "extra": 1},
		"schema_validation_failed",
		"export: unknown arg → schema_validation_failed")

	# Bogus editor name with valid args reaches the editor lookup and fails
	# with editor_not_found (broker-validation error → audit FAILED, not DENIED).
	var bogus: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.editors.export",
		{"editor_name": "no_such_editor_xyz", "format": "png"})
	check_eq("export: bogus editor_name → editor_not_found",
		bogus.get("error_code", ""), "editor_not_found")

	var failed: Array = audit.get_entries(TEST_PLUGIN_ID, "capability_failed")
	check("audit: broker-level errors recorded as capability_failed",
		failed.size() >= 5, "got %d failed entries" % failed.size())


func _check_export_error(broker, args: Dictionary, expected_code: String, label: String) -> void:
	var res: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, "host.editors.export", args)
	if res.get("error_code", "") == expected_code:
		_pass_count += 1
		print("  PASS: %s" % label)
	else:
		_fail_count += 1
		print("  FAIL: %s — expected %s, got %s" % [label, expected_code, str(res)])


# ---------------------------------------------------------------------------
# Test infrastructure (shared shape with test_host_capability_files)
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


func _clear_policy_for_test() -> void:
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
	(data as Dictionary)["grants"] = grants
	fa = FileAccess.open(policy_file, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(data, "  "))
	fa.close()
