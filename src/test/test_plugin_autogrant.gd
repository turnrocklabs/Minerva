extends SceneTree
## Verifies install-time capability auto-grant grants EVERY declared capability,
## including host.permissions.grant_scope (formerly quarantined on
## PluginManager._NEVER_AUTO_GRANT). Owner decision: install is the trust act,
## so a manifest's declared caps are all granted at install (user can revoke).
##
## Run: godot --headless --path src --script test/test_plugin_autogrant.gd

const PM_SCRIPT := "res://Scripts/Services/Plugins/PluginManager.gd"
const POLICY_SCRIPT := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const DB_SCRIPT := "res://Scripts/Services/Plugins/PluginDB.gd"
const AUDIT_SCRIPT := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const DEF_SCRIPT := "res://Scripts/Services/Plugins/PluginDefinition.gd"

const TEST_ID := "autogrant_probe_test"

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== Plugin install auto-grant test ===\n")
	_clear_policy()
	await _run()
	_clear_policy()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	# Let autoloads (SingletonObject) finish registering before load()-ing
	# PluginManager; it references SingletonObject and won't compile standalone
	# until the global is live. Mirrors test_host_capability_pdf.
	await process_frame

	var PM = load(PM_SCRIPT)
	var Policy = load(POLICY_SCRIPT)
	var DB = load(DB_SCRIPT)
	var Audit = load(AUDIT_SCRIPT)
	var Def = load(DEF_SCRIPT)
	check("scripts loaded",
		PM != null and Policy != null and DB != null and Audit != null and Def != null)

	# Owner decision: nothing is quarantined from auto-grant anymore.
	check("_NEVER_AUTO_GRANT is empty", PM._NEVER_AUTO_GRANT.is_empty(),
		"got: %s" % str(PM._NEVER_AUTO_GRANT))

	var db = DB.new()
	var audit = Audit.new()
	var policy = Policy.new(db, audit)

	var def = Def.new(TEST_ID)
	var caps: Array[String] = [
		"host.pdf.generate",
		"host.files.write",
		"host.permissions.grant_scope",
	]
	def.host_capabilities = caps
	db._plugins[TEST_ID] = def

	var pm = PM.new()
	pm._policy_ref = policy
	pm._auto_grant_declared_capabilities(def)
	pm.free()

	check("auto-grant: host.pdf.generate granted",
		policy.is_capability_granted(TEST_ID, "host.pdf.generate"))
	check("auto-grant: host.files.write granted",
		policy.is_capability_granted(TEST_ID, "host.files.write"))
	check("auto-grant: host.permissions.grant_scope granted (no longer quarantined)",
		policy.is_capability_granted(TEST_ID, "host.permissions.grant_scope"))


# ---------------------------------------------------------------------------
# Infra
# ---------------------------------------------------------------------------

func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % label)
	else:
		_fail += 1
		var msg := "  FAIL: %s" % label
		if not detail.is_empty():
			msg += " — " + detail
		print(msg)


func _clear_policy() -> void:
	# PluginPolicy persists grants under user://plugins/policy.json; clear our
	# probe id before and after so grants don't leak across runs.
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
	grants.erase(TEST_ID)
	(data as Dictionary)["grants"] = grants
	fa = FileAccess.open(policy_file, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(data, "  "))
	fa.close()
