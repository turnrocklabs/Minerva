extends SceneTree
## Integration test for host.documents.list_open + host.documents.get_state
## (broker phase 3 reads).
##
## Run: godot --headless --path src --script test/test_host_capability_documents.gd
##
## Tracks docket: minerva 019df8e3576f7b53b606d574c1f809f5
## Parent DCR:    minerva 019df8e2d0937613a326389a4df133fb
##
## Coverage:
##   Unit (CapabilityBroker direct, no subprocess):
##     - list_open returns {documents:[]} when editor_pane is null (headless)
##     - get_state with empty editor_name → schema_validation_failed
##     - get_state with bogus editor_name → editor_not_found
##     - audit log records dispatched + denied entries
##
##   Integration (real fixture subprocess):
##     - probe_list happy path: granted plugin gets documents array (empty in headless)
##     - probe_state with bogus name: structured editor_not_found error
##     - deny path: separate fixture without host.documents.* declared gets denied,
##       audit log records the denial
##
## NOTE: PluginManager.gd and MCPServerConnection.gd reference SingletonObject
## at parse time. In --script mode autoloads register lazily, so top-level
## preload() would fail. Use deferred load() once autoloads are wired.

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const CAPABILITY_BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const PLUGIN_POLICY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const PLUGIN_AUDIT_LOG_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const PLUGIN_ERRORS_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginErrors.gd"

const FIXTURE_DIR_REL := "/test/fixtures/document_probe"
const NO_CAPS_FIXTURE_DIR_REL := "/test/fixtures/document_probe_no_caps"

const S_RUNNING := 2
const S_STOPPED := 3

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.documents.* Capability Test (broker phase 3 reads) ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	var fixture_dir: String = ProjectSettings.globalize_path("res://" + FIXTURE_DIR_REL)
	var manifest_path: String = fixture_dir + "/manifest.json"
	var probe_script: String = fixture_dir + "/document_probe.py"

	var no_caps_dir: String = ProjectSettings.globalize_path("res://" + NO_CAPS_FIXTURE_DIR_REL)
	var no_caps_manifest: String = no_caps_dir + "/manifest.json"
	var no_caps_script: String = no_caps_dir + "/document_probe_no_caps.py"

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: fixture manifest not found at %s" % manifest_path)
		_fail_count += 1
		return
	if not FileAccess.file_exists(probe_script):
		printerr("FAIL: fixture script not found at %s" % probe_script)
		_fail_count += 1
		return
	if not FileAccess.file_exists(no_caps_manifest):
		printerr("FAIL: no-caps fixture manifest not found at %s" % no_caps_manifest)
		_fail_count += 1
		return
	if not FileAccess.file_exists(no_caps_script):
		printerr("FAIL: no-caps fixture script not found at %s" % no_caps_script)
		_fail_count += 1
		return

	var py_check := OS.execute("python3", ["--version"], [], true)
	if py_check != OK:
		print("SKIP: python3 not available — skipping fixture plugin tests")
		quit(0)
		return

	print("Fixture dir:         %s" % fixture_dir)
	print("No-caps fixture dir: %s\n" % no_caps_dir)

	# Wait one frame for autoloads to register
	await process_frame

	# Wait for SingletonObject.plugin_tool_registry (≤10s).
	# (Even though this test doesn't use the wired registry directly, several of
	# the runtime services we touch initialise on the same _ready chain.)
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout
		print("SingletonObject ready after %dms\n" % (Time.get_ticks_msec() - (deadline_ms - 10000)))

	await _run_unit_tests()
	await _run_integration_tests(manifest_path, no_caps_manifest)


# ---------------------------------------------------------------------------
# Unit tests — CapabilityBroker host.documents.* dispatch
# ---------------------------------------------------------------------------

func _run_unit_tests() -> void:
	print("-- Unit: CapabilityBroker host.documents.* dispatch --")

	var AuditLogScript = load(PLUGIN_AUDIT_LOG_SCRIPT_PATH)
	var PolicyScript = load(PLUGIN_POLICY_SCRIPT_PATH)
	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var PluginErrorsScript = load(PLUGIN_ERRORS_SCRIPT_PATH)

	check("scripts loaded", AuditLogScript != null and PolicyScript != null
		and BrokerScript != null and PluginErrorsScript != null)
	if AuditLogScript == null or PolicyScript == null or BrokerScript == null:
		return

	var audit = AuditLogScript.new()
	var policy = PolicyScript.new(null, audit)
	var broker = BrokerScript.new(policy, audit)

	policy.grant_capability("doc_probe_test", "host.documents.list_open")
	policy.grant_capability("doc_probe_test", "host.documents.get_state")

	# --- list_open: empty result in headless (no editor_pane) ---
	var list_result: Dictionary = await broker.dispatch("doc_probe_test",
		"host.documents.list_open", {})
	check("list_open returns success=true", list_result.get("success", false),
		"got: %s" % str(list_result))
	var inner: Dictionary = list_result.get("result", {})
	check("list_open result has 'documents' key", inner.has("documents"),
		"keys: %s" % str(inner.keys()))
	check("list_open documents is an Array", inner.get("documents") is Array,
		"got type: %s" % typeof(inner.get("documents")))
	# In headless, editor_pane may or may not exist depending on autoload state;
	# either way, .documents must be a list (possibly empty).

	# --- audit: dispatched event recorded for list_open ---
	var dispatched: Array = audit.get_entries("doc_probe_test", "capability_dispatched")
	check("audit log has capability_dispatched entry for list_open",
		dispatched.size() > 0,
		"entries: %s" % str(dispatched))

	# --- get_state: empty editor_name → schema_validation_failed ---
	var bad_args: Dictionary = await broker.dispatch("doc_probe_test",
		"host.documents.get_state", {})
	check("get_state with empty editor_name returns success=false",
		not bad_args.get("success", true),
		"got: %s" % str(bad_args))
	check("get_state empty-name error_code is schema_validation_failed",
		bad_args.get("error_code", "") == "schema_validation_failed",
		"got: %s" % str(bad_args))

	# --- get_state: bogus editor_name → editor_not_found ---
	var not_found: Dictionary = await broker.dispatch("doc_probe_test",
		"host.documents.get_state", {"editor_name": "no_such_editor_xyz"})
	check("get_state with bogus name returns success=false",
		not not_found.get("success", true),
		"got: %s" % str(not_found))
	check("get_state bogus-name error_code is editor_not_found",
		not_found.get("error_code", "") == "editor_not_found",
		"got: %s" % str(not_found))

	# --- deny path: ungranted capability rejected ---
	var deny_result: Dictionary = await broker.dispatch("doc_probe_test",
		"host.documents.set_state", {"editor_name": "x"})
	check("ungranted host.documents.set_state returns success=false",
		not deny_result.get("success", true),
		"got: %s" % str(deny_result))
	var deny_code: String = deny_result.get("error_code", "")
	check("ungranted capability has structured error_code",
		deny_code in ["capability_not_granted", "unknown_capability"],
		"got error_code: '%s'" % deny_code)

	# --- audit: denied entry exists ---
	var denied: Array = audit.get_entries("doc_probe_test", "capability_denied")
	check("audit log records denied entry",
		denied.size() > 0,
		"denied entries: %s" % str(denied))

	print("  (unit tests complete)\n")


# ---------------------------------------------------------------------------
# Integration tests — real subprocess fixtures
# ---------------------------------------------------------------------------

func _run_integration_tests(manifest_path: String, no_caps_manifest: String) -> void:
	print("-- Integration: document_probe fixture --")

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	check("PluginManager script loaded", pm_script != null)
	if pm_script == null:
		return

	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame
	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db

	# --- HAPPY-PATH FIXTURE: install + start ---
	var def = db.get_by_id("document_probe")
	if def == null:
		print("  document_probe not in DB — installing...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin (document_probe) ok",
			install_result.get("ok", false) == true,
			"got: %s" % str(install_result))
		def = db.get_by_id("document_probe")
	check("document_probe definition loaded", def != null)
	if def == null:
		return

	if def.state == S_RUNNING:
		await pm.stop_plugin("document_probe")

	# Grant required capabilities. The standalone PluginManager uses the
	# SingletonObject's policy when present (same pattern as the channel test).
	var policy = pm.get_policy()
	if policy == null:
		var so_for_policy = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
		if so_for_policy != null and "plugin_policy" in so_for_policy:
			policy = so_for_policy.get("plugin_policy")
	if policy != null:
		policy.grant_capability("document_probe", "host.documents.list_open")
		policy.grant_capability("document_probe", "host.documents.get_state")
		print("  Granted host.documents.{list_open,get_state} to document_probe")
	else:
		print("  WARNING: no policy available — happy-path assertions may fail")

	print("\n-- start_plugin (document_probe) --")
	var start_result = await pm.start_plugin("document_probe")
	check("start_plugin ok", start_result.get("ok", false) == true,
		"got: %s" % str(start_result))
	check("state == RUNNING", def.state == S_RUNNING,
		"state=%d" % def.state)

	var conn = pm.get_connection("document_probe")
	check("connection exists", conn != null)
	if conn == null:
		return

	# --- HAPPY: probe_list ---
	print("\n-- Happy: probe_list --")
	var list_call = await conn.call_tool("probe_list", {})
	check("probe_list returned a Dictionary", list_call is Dictionary,
		"got type %d" % typeof(list_call))
	if list_call is Dictionary:
		check("probe_list has no top-level error",
			not list_call.has("error"),
			"error: %s" % str(list_call.get("error", "")))
		check("probe_list reports was_denied=false (capability granted)",
			list_call.get("was_denied", true) == false,
			"got: %s" % str(list_call))
		check("probe_list returns documents array",
			list_call.get("documents") is Array,
			"got: %s" % str(list_call.get("documents")))

	# --- get_state with bogus editor_name ---
	print("\n-- get_state on bogus editor name --")
	var bogus_call = await conn.call_tool("probe_state",
		{"editor_name": "no_such_tab_xyz"})
	check("probe_state (bogus) returned a Dictionary", bogus_call is Dictionary,
		"got type %d" % typeof(bogus_call))
	if bogus_call is Dictionary:
		check("probe_state (bogus) reports was_denied=true (lookup failed)",
			bogus_call.get("was_denied", false) == true,
			"got: %s" % str(bogus_call))
		check("probe_state (bogus) error_code is editor_not_found",
			str(bogus_call.get("error_code", "")) == "editor_not_found",
			"got: %s" % str(bogus_call))

	print("\n-- stop_plugin (document_probe) --")
	var stop_result = await pm.stop_plugin("document_probe")
	check("stop_plugin ok", stop_result.get("ok", false) == true,
		"got: %s" % str(stop_result))
	check("state == STOPPED (document_probe)", def.state == S_STOPPED,
		"state=%d" % def.state)

	# --- DENY-PATH FIXTURE: install + start no-caps fixture ---
	print("\n-- Deny: document_probe_no_caps --")
	var def_nc = db.get_by_id("document_probe_no_caps")
	if def_nc == null:
		var install_nc = await pm.install_plugin(no_caps_manifest, true)
		check("install_plugin (no_caps) ok",
			install_nc.get("ok", false) == true,
			"got: %s" % str(install_nc))
		def_nc = db.get_by_id("document_probe_no_caps")
	check("document_probe_no_caps definition loaded", def_nc != null)
	if def_nc == null:
		return

	if def_nc.state == S_RUNNING:
		await pm.stop_plugin("document_probe_no_caps")

	var start_nc = await pm.start_plugin("document_probe_no_caps")
	check("start_plugin (no_caps) ok", start_nc.get("ok", false) == true,
		"got: %s" % str(start_nc))

	var conn_nc = pm.get_connection("document_probe_no_caps")
	check("connection (no_caps) exists", conn_nc != null)
	if conn_nc != null:
		var denied_call = await conn_nc.call_tool("probe_list_denied", {})
		check("probe_list_denied returned a Dictionary", denied_call is Dictionary,
			"got type %d" % typeof(denied_call))
		if denied_call is Dictionary:
			check("probe_list_denied reports was_denied=true",
				denied_call.get("was_denied", false) == true,
				"got: %s" % str(denied_call))
			var deny_code: String = str(denied_call.get("error_code", ""))
			check("denied error_code is capability_not_granted",
				deny_code == "capability_not_granted",
				"got error_code: '%s'" % deny_code)

	# --- AUDIT LOG: deny event recorded for no_caps fixture ---
	var audit_log = pm.get_audit_log()
	if audit_log == null:
		var so_for_audit = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
		if so_for_audit != null and "plugin_audit_log" in so_for_audit:
			audit_log = so_for_audit.get("plugin_audit_log")
	if audit_log != null:
		var nc_denied = audit_log.get_entries("document_probe_no_caps", "capability_denied")
		check("audit log records capability_denied for no_caps fixture",
			nc_denied.size() > 0,
			"denied count=%d" % nc_denied.size())
		var dp_dispatched = audit_log.get_entries("document_probe", "capability_dispatched")
		check("audit log records capability_dispatched for granted fixture",
			dp_dispatched.size() > 0,
			"dispatched count=%d" % dp_dispatched.size())
	else:
		print("  WARNING: no audit_log available — skipping audit assertions")

	# --- _in_stdio_request guard health (re-entrancy contract) ---
	if conn != null:
		check("_in_stdio_request false on happy-path conn after teardown",
			conn.get("_in_stdio_request") == false,
			"_in_stdio_request=%s" % str(conn.get("_in_stdio_request")))
	if conn_nc != null:
		check("_in_stdio_request false on deny-path conn after teardown",
			conn_nc.get("_in_stdio_request") == false,
			"_in_stdio_request=%s" % str(conn_nc.get("_in_stdio_request")))

	# Clean up no_caps fixture
	await pm.stop_plugin("document_probe_no_caps")


# ---------------------------------------------------------------------------
# Harness
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
