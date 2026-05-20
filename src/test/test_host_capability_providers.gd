extends SceneTree
## Integration test for host.providers.chat capability (broker T1 R2).
##
## Run: godot --headless --path src --script test/test_host_capability_providers.gd
##
## Covers DCR task 019e1cdb9e197689b4163764d49f7ca2 (T1 R2):
##   Unit (CapabilityBroker direct, no subprocess):
##     1. schema_validation_failed — missing messages
##     2. schema_validation_failed — missing model
##     3. payload_too_large — oversized base64 image
##     4. model_not_available — unknown model name
##     5. model_ambiguous — skipped if no multi-provider model available
##     6. budget_exceeded — leaf level (plugin/<id>/<provider>/<model>)
##     7. budget_exceeded — provider level (plugin/<id>/<provider>)
##     8. budget_exceeded — plugin level (plugin/<id>)
##     9. infinity sentinel does NOT bypass exceeded parent
##    10. capability_not_granted — deny path via no-caps fixture (integration)
##    11. wire reconstruction smoke — vision envelope reaches model-lookup step
##
## NOTE: PluginManager.gd and MCPServerConnection.gd reference SingletonObject
## at parse time. In --script mode autoloads register lazily, so top-level
## preload() would fail. Use deferred load() once autoloads are wired.

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const CAPABILITY_BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const PLUGIN_POLICY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const PLUGIN_AUDIT_LOG_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const PLUGIN_ERRORS_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginErrors.gd"

const FIXTURE_DIR_REL := "/test/fixtures/provider_probe"
const NO_CAPS_FIXTURE_DIR_REL := "/test/fixtures/provider_probe_no_caps"

const S_RUNNING := 2
const S_STOPPED := 3

## Minimal 1×1 transparent PNG (67 bytes). Known-good binary, encoded inline.
const TINY_PNG_B64 := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.providers.chat Capability Integration Test ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	var fixture_dir: String = ProjectSettings.globalize_path("res://" + FIXTURE_DIR_REL)
	var manifest_path: String = fixture_dir + "/manifest.json"
	var probe_script: String = fixture_dir + "/provider_probe.py"

	var no_caps_dir: String = ProjectSettings.globalize_path("res://" + NO_CAPS_FIXTURE_DIR_REL)
	var no_caps_manifest: String = no_caps_dir + "/manifest.json"
	var no_caps_script: String = no_caps_dir + "/provider_probe_no_caps.py"

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
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout
		print("SingletonObject ready after %dms\n" % (Time.get_ticks_msec() - (deadline_ms - 10000)))

	await _run_unit_tests()
	await _run_integration_tests(manifest_path, no_caps_manifest)


# ---------------------------------------------------------------------------
# Unit tests — CapabilityBroker host.providers.chat dispatch (no subprocess)
# ---------------------------------------------------------------------------

func _run_unit_tests() -> void:
	print("-- Unit: CapabilityBroker host.providers.chat dispatch --")

	var AuditLogScript = load(PLUGIN_AUDIT_LOG_SCRIPT_PATH)
	var PolicyScript = load(PLUGIN_POLICY_SCRIPT_PATH)
	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)

	check("scripts loaded", AuditLogScript != null and PolicyScript != null and BrokerScript != null)
	if AuditLogScript == null or PolicyScript == null or BrokerScript == null:
		return

	var audit = AuditLogScript.new()
	var policy = PolicyScript.new(null, audit, false)
	var broker = BrokerScript.new(policy, audit)

	policy.grant_capability("provider_probe_test", "host.providers.chat")

	# ---------------------------------------------------------------------------
	# Case 1: schema_validation_failed — missing 'messages'
	# ---------------------------------------------------------------------------
	print("\n-- Case 1: schema_validation_failed — missing messages --")
	var r1: Dictionary = await broker.dispatch("provider_probe_test", "host.providers.chat",
		{"model": "default"})
	check("case 1: success=false", not r1.get("success", true), "got: %s" % str(r1))
	check("case 1: error_code=schema_validation_failed",
		r1.get("error_code", "") == "schema_validation_failed",
		"got error_code: '%s'" % r1.get("error_code", ""))
	var audit_entries_1: Array = audit.get_entries("provider_probe_test", "capability_failed")
	check("case 1: audit records capability_failed", audit_entries_1.size() > 0,
		"capability_failed count=%d" % audit_entries_1.size())

	# ---------------------------------------------------------------------------
	# Case 2: schema_validation_failed — missing 'model'
	# ---------------------------------------------------------------------------
	print("\n-- Case 2: schema_validation_failed — missing model --")
	var r2: Dictionary = await broker.dispatch("provider_probe_test", "host.providers.chat",
		{"messages": [{"role": "user", "text": "hello"}]})
	check("case 2: success=false", not r2.get("success", true), "got: %s" % str(r2))
	check("case 2: error_code=schema_validation_failed",
		r2.get("error_code", "") == "schema_validation_failed",
		"got error_code: '%s'" % r2.get("error_code", ""))

	# ---------------------------------------------------------------------------
	# Case 3: payload_too_large — oversized base64 image
	# ---------------------------------------------------------------------------
	print("\n-- Case 3: payload_too_large — oversized image --")
	# 12 MB decoded → ~16 MB base64 string (base64 is 4/3 of raw)
	# _CHAT_MAX_IMAGE_BYTES = 10 MB. Approximate decoded = len * 0.75.
	# To exceed 10MB: len * 0.75 > 10*1024*1024 → len > 13981013 chars.
	# Use 14M chars of 'A' to reliably trigger the check.
	var big_b64: String = "A".repeat(14 * 1024 * 1024)
	var r3: Dictionary = await broker.dispatch("provider_probe_test", "host.providers.chat", {
		"model": "default",
		"messages": [{"role": "user", "text": "big", "images": [big_b64]}],
	})
	check("case 3: success=false", not r3.get("success", true), "got: %s" % str(r3))
	check("case 3: error_code=payload_too_large",
		r3.get("error_code", "") == "payload_too_large",
		"got error_code: '%s'" % r3.get("error_code", ""))

	# ---------------------------------------------------------------------------
	# Case 4: model_not_available — unknown model name
	# ---------------------------------------------------------------------------
	print("\n-- Case 4: model_not_available — unknown model --")
	var r4: Dictionary = await broker.dispatch("provider_probe_test", "host.providers.chat", {
		"model": "definitely-not-a-real-model-xyz",
		"messages": [{"role": "user", "text": "test"}],
	})
	check("case 4: success=false", not r4.get("success", true), "got: %s" % str(r4))
	check("case 4: error_code=model_not_available",
		r4.get("error_code", "") == "model_not_available",
		"got error_code: '%s'" % r4.get("error_code", ""))

	# ---------------------------------------------------------------------------
	# Case 5: model_ambiguous — skipped (no multi-provider model in test env)
	# ---------------------------------------------------------------------------
	print("\n-- Case 5: model_ambiguous — skipped: no multi-provider model available in headless env --")
	print("  SKIP: case 5 (model_ambiguous) — headless env has no dynamic providers; cannot create natural ambiguity without network")

	# ---------------------------------------------------------------------------
	# Cases 6–9: budget checks via SingletonObject.cost_tracker
	# These require SingletonObject to be present (provides the cost_tracker).
	# ---------------------------------------------------------------------------
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	var cost_tracker = so.get("cost_tracker") if so != null else null

	if cost_tracker == null:
		print("\n  WARNING: SingletonObject.cost_tracker not available — skipping budget cases 6-9")
		print("  SKIP: case 6 (budget_exceeded leaf)")
		print("  SKIP: case 7 (budget_exceeded provider)")
		print("  SKIP: case 8 (budget_exceeded plugin)")
		print("  SKIP: case 9 (infinity does not bypass parent)")
	else:
		# Use the LocalProvider (nemotron-3-nano, provider=local) for budget tests because:
		# - input_token_cost = 0.0 → API key check is skipped (free provider)
		# - budget check runs BEFORE generate_content → testable without real Ollama
		# CoreProvider ("default") is NOT usable here: input_token_cost=10.0 + empty API_KEY
		# in headless → provider_disabled fires before the budget check.
		# Also: ensure LOCAL provider is enabled for the duration of the budget tests,
		# in case the user's saved config has it disabled (Ollama not running).
		var provider_key: String = "local"
		var model_key: String = "nemotron-3-nano"
		var plugin_id_key: String = "provider_probe_test"
		var _so_budget = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
		var _local_was_enabled: bool = true
		if _so_budget != null and _so_budget.has_method("is_provider_enabled"):
			_local_was_enabled = _so_budget.is_provider_enabled(_so_budget.API_PROVIDER.LOCAL)
			if not _local_was_enabled:
				_so_budget._enabled_providers[_so_budget.API_PROVIDER.LOCAL] = true
				print("  (forced LOCAL provider enabled for budget tests)")

		var key_leaf: String = "plugin/%s/%s/%s" % [plugin_id_key, provider_key, model_key]
		var key_provider: String = "plugin/%s/%s" % [plugin_id_key, provider_key]
		var key_plugin: String = "plugin/%s" % plugin_id_key

		var now_ts: String = Time.get_datetime_string_from_system(true)

		# ---------------------------------------------------------------------------
		# Case 6: budget_exceeded — leaf level
		# ---------------------------------------------------------------------------
		print("\n-- Case 6: budget_exceeded — leaf level --")
		cost_tracker.set_budget(key_leaf, 0.0001, 0.8, "day")
		# Inject a ledger entry pushing spend over budget
		cost_tracker._ledger.append({
			"ts": now_ts,
			"provider": provider_key,
			"model": model_key,
			"input_tokens": 1,
			"output_tokens": 1,
			"cost_usd": 0.001,
			"chat_id": key_leaf,
		})
		var r6: Dictionary = await broker.dispatch("provider_probe_test", "host.providers.chat", {
			"model": "nemotron-3-nano",
			"provider": "local",
			"messages": [{"role": "user", "text": "test budget leaf"}],
		})
		check("case 6: success=false", not r6.get("success", true), "got: %s" % str(r6))
		check("case 6: error_code=budget_exceeded",
			r6.get("error_code", "") == "budget_exceeded",
			"got error_code: '%s'" % r6.get("error_code", ""))
		check("case 6: which_budget is leaf key",
			r6.get("which_budget", "") == key_leaf,
			"got which_budget: '%s'" % r6.get("which_budget", ""))
		# Teardown
		cost_tracker.clear_budget(key_leaf)
		cost_tracker._ledger.clear()

		# ---------------------------------------------------------------------------
		# Case 7: budget_exceeded — provider level
		# ---------------------------------------------------------------------------
		print("\n-- Case 7: budget_exceeded — provider level --")
		cost_tracker.set_budget(key_provider, 0.0001, 0.8, "day")
		cost_tracker._ledger.append({
			"ts": now_ts,
			"provider": provider_key,
			"model": model_key,
			"input_tokens": 1,
			"output_tokens": 1,
			"cost_usd": 0.001,
			"chat_id": key_provider,
		})
		var r7: Dictionary = await broker.dispatch("provider_probe_test", "host.providers.chat", {
			"model": "nemotron-3-nano",
			"provider": "local",
			"messages": [{"role": "user", "text": "test budget provider"}],
		})
		check("case 7: success=false", not r7.get("success", true), "got: %s" % str(r7))
		check("case 7: error_code=budget_exceeded",
			r7.get("error_code", "") == "budget_exceeded",
			"got error_code: '%s'" % r7.get("error_code", ""))
		check("case 7: which_budget is provider key",
			r7.get("which_budget", "") == key_provider,
			"got which_budget: '%s'" % r7.get("which_budget", ""))
		# Teardown
		cost_tracker.clear_budget(key_provider)
		cost_tracker._ledger.clear()

		# ---------------------------------------------------------------------------
		# Case 8: budget_exceeded — plugin level
		# ---------------------------------------------------------------------------
		print("\n-- Case 8: budget_exceeded — plugin level --")
		cost_tracker.set_budget(key_plugin, 0.0001, 0.8, "day")
		cost_tracker._ledger.append({
			"ts": now_ts,
			"provider": provider_key,
			"model": model_key,
			"input_tokens": 1,
			"output_tokens": 1,
			"cost_usd": 0.001,
			"chat_id": key_plugin,
		})
		var r8: Dictionary = await broker.dispatch("provider_probe_test", "host.providers.chat", {
			"model": "nemotron-3-nano",
			"provider": "local",
			"messages": [{"role": "user", "text": "test budget plugin"}],
		})
		check("case 8: success=false", not r8.get("success", true), "got: %s" % str(r8))
		check("case 8: error_code=budget_exceeded",
			r8.get("error_code", "") == "budget_exceeded",
			"got error_code: '%s'" % r8.get("error_code", ""))
		check("case 8: which_budget is plugin key",
			r8.get("which_budget", "") == key_plugin,
			"got which_budget: '%s'" % r8.get("which_budget", ""))
		# Teardown
		cost_tracker.clear_budget(key_plugin)
		cost_tracker._ledger.clear()

		# ---------------------------------------------------------------------------
		# Case 9: infinity sentinel does NOT bypass parent
		# ---------------------------------------------------------------------------
		print("\n-- Case 9: infinity sentinel does NOT bypass exceeded parent --")
		# Leaf = infinity (-1.0), plugin level = tight budget exceeded
		cost_tracker.set_budget(key_leaf, -1.0, 0.8, "day")
		cost_tracker.set_budget(key_plugin, 0.0001, 0.8, "day")
		# Inject spend at leaf-level chat_id — the plugin-level key is a prefix, so it
		# aggregates this via get_spend_for_key prefix matching.
		cost_tracker._ledger.append({
			"ts": now_ts,
			"provider": provider_key,
			"model": model_key,
			"input_tokens": 1,
			"output_tokens": 1,
			"cost_usd": 0.001,
			"chat_id": key_leaf,
		})
		var r9: Dictionary = await broker.dispatch("provider_probe_test", "host.providers.chat", {
			"model": "nemotron-3-nano",
			"provider": "local",
			"messages": [{"role": "user", "text": "test infinity sentinel"}],
		})
		check("case 9: success=false (parent budget enforced)",
			not r9.get("success", true), "got: %s" % str(r9))
		check("case 9: error_code=budget_exceeded",
			r9.get("error_code", "") == "budget_exceeded",
			"got error_code: '%s'" % r9.get("error_code", ""))
		check("case 9: which_budget is plugin key (not leaf)",
			r9.get("which_budget", "") == key_plugin,
			"got which_budget: '%s'" % r9.get("which_budget", ""))
		# Teardown
		cost_tracker.clear_budget(key_leaf)
		cost_tracker.clear_budget(key_plugin)
		cost_tracker._ledger.clear()
		# Restore LOCAL provider enabled state
		if _so_budget != null and not _local_was_enabled:
			_so_budget._enabled_providers[_so_budget.API_PROVIDER.LOCAL] = false

	# ---------------------------------------------------------------------------
	# Case 11: wire reconstruction smoke (unit, no LLM needed)
	# ---------------------------------------------------------------------------
	print("\n-- Case 11: wire reconstruction smoke — vision envelope --")
	# Submit a valid vision request with a known 1×1 PNG.
	# The broker must parse past schema/payload checks and reach the model-lookup
	# step. The error returned must NOT be schema_validation_failed or
	# payload_too_large — any other error (model_not_available, provider_disabled,
	# budget_exceeded, etc.) means wire→ChatHistoryItem reconstruction succeeded.
	var r11: Dictionary = await broker.dispatch("provider_probe_test", "host.providers.chat", {
		"model": "default",
		"messages": [
			{"role": "user", "text": "What is in this image?", "images": [TINY_PNG_B64]},
		],
	})
	# We expect this to fail somewhere downstream (no real LLM in headless),
	# but NOT at schema or payload validation.
	var r11_code: String = r11.get("error_code", "")
	check("case 11: error is NOT schema_validation_failed",
		r11_code != "schema_validation_failed",
		"got error_code: '%s'" % r11_code)
	check("case 11: error is NOT payload_too_large",
		r11_code != "payload_too_large",
		"got error_code: '%s'" % r11_code)
	# The error should be model_not_available, provider_disabled, budget_exceeded,
	# provider_error, or success (if somehow a provider is reachable). Any of these
	# proves the wire reconstruction passed.
	var r11_valid_codes: Array = ["model_not_available", "provider_disabled", "provider_error",
		"budget_exceeded", ""]  # "" means success
	var r11_ok_error: bool = r11_code in r11_valid_codes or r11.get("success", false)
	check("case 11: error code indicates past wire reconstruction (reached model-lookup or beyond)",
		r11_ok_error,
		"got error_code: '%s'" % r11_code)

	print("\n  (unit tests complete)\n")


# ---------------------------------------------------------------------------
# Integration tests — real subprocess fixtures (cases 10 deny path)
# ---------------------------------------------------------------------------

func _run_integration_tests(manifest_path: String, no_caps_manifest: String) -> void:
	print("-- Integration: provider_probe + provider_probe_no_caps fixtures --")

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

	# --- Install + start provider_probe (happy-path fixture) ---
	var def = db.get_by_id("provider_probe")
	if def == null:
		print("  provider_probe not in DB — installing...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin (provider_probe) ok",
			install_result.get("ok", false) == true,
			"got: %s" % str(install_result))
		def = db.get_by_id("provider_probe")
	check("provider_probe definition loaded", def != null)
	if def == null:
		return

	if def.state == S_RUNNING:
		await pm.stop_plugin("provider_probe")

	# Grant host.providers.chat capability via policy
	var policy = pm.get_policy()
	if policy == null:
		var so_for_policy = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
		if so_for_policy != null and "plugin_policy" in so_for_policy:
			policy = so_for_policy.get("plugin_policy")
	if policy != null:
		policy.grant_capability("provider_probe", "host.providers.chat")
		print("  Granted host.providers.chat to provider_probe via policy")
	else:
		print("  WARNING: no policy available — grant skipped")

	print("\n-- start_plugin (provider_probe) --")
	var start_result = await pm.start_plugin("provider_probe")
	check("start_plugin ok", start_result.get("ok", false) == true,
		"got: %s" % str(start_result))
	check("state == RUNNING", def.state == S_RUNNING, "state=%d" % def.state)

	var conn = pm.get_connection("provider_probe")
	check("connection exists", conn != null)

	if conn != null:
		# Verify the fixture can reach the broker (expect model error, not crash)
		print("\n-- probe_chat_text (expect non-crash error from broker) --")
		var chat_call = await conn.call_tool("probe_chat_text", {
			"model": "definitely-not-a-real-model-xyz",
			"messages": [{"role": "user", "text": "hello"}],
		})
		check("probe_chat_text returned a Dictionary", chat_call is Dictionary,
			"got type %d" % typeof(chat_call))
		if chat_call is Dictionary:
			check("probe_chat_text has no tool-level error (broker responded)",
				not chat_call.has("error"),
				"error: %s" % str(chat_call.get("error", "")))
			var cap_code: String = str(chat_call.get("error_code", ""))
			check("probe_chat_text broker returned structured error_code (not empty crash)",
				not cap_code.is_empty() or chat_call.get("success", false),
				"got: %s" % str(chat_call))

	# --- STOP provider_probe ---
	print("\n-- stop_plugin (provider_probe) --")
	if conn != null:
		check("no pending STDIO requests after calls",
			conn.pending_request_count() == 0,
			"pending_request_count=%d" % conn.pending_request_count())
	var stop_result = await pm.stop_plugin("provider_probe")
	check("stop_plugin ok", stop_result.get("ok", false) == true,
		"got: %s" % str(stop_result))
	check("state == STOPPED", def.state == S_STOPPED, "state=%d" % def.state)

	# ---------------------------------------------------------------------------
	# Case 10: deny path — no manifest grant
	# ---------------------------------------------------------------------------
	print("\n-- Case 10: capability_not_granted — provider_probe_no_caps --")

	var def_nc = db.get_by_id("provider_probe_no_caps")
	if def_nc == null:
		var install_nc = await pm.install_plugin(no_caps_manifest, true)
		check("install_plugin (no_caps) ok",
			install_nc.get("ok", false) == true,
			"got: %s" % str(install_nc))
		def_nc = db.get_by_id("provider_probe_no_caps")
	check("provider_probe_no_caps definition loaded", def_nc != null)
	if def_nc == null:
		return

	if def_nc.state == S_RUNNING:
		await pm.stop_plugin("provider_probe_no_caps")

	var start_nc = await pm.start_plugin("provider_probe_no_caps")
	check("start_plugin (no_caps) ok", start_nc.get("ok", false) == true,
		"got: %s" % str(start_nc))

	var conn_nc = pm.get_connection("provider_probe_no_caps")
	check("connection (no_caps) exists", conn_nc != null)
	if conn_nc != null:
		var denied_call = await conn_nc.call_tool("probe_chat_denied", {})
		check("probe_chat_denied returned a Dictionary", denied_call is Dictionary,
			"got type %d" % typeof(denied_call))
		if denied_call is Dictionary:
			check("case 10: probe_chat_denied was_denied=true",
				denied_call.get("was_denied", false) == true,
				"got: %s" % str(denied_call))
			var deny_code: String = str(denied_call.get("error_code", ""))
			check("case 10: error_code=capability_not_granted",
				deny_code == "capability_not_granted",
				"got error_code: '%s'" % deny_code)

	# Audit log: denial recorded for no_caps fixture
	var audit_log = pm.get_audit_log()
	if audit_log == null:
		var so_for_audit = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
		if so_for_audit != null and "plugin_audit_log" in so_for_audit:
			audit_log = so_for_audit.get("plugin_audit_log")
	if audit_log != null:
		var nc_denied = audit_log.get_entries("provider_probe_no_caps", "capability_denied")
		check("case 10: audit log records capability_denied for no_caps fixture",
			nc_denied.size() > 0,
			"denied count=%d" % nc_denied.size())
	else:
		print("  WARNING: no audit_log available — skipping audit assertion for case 10")

	# re-entrancy guard
	if conn_nc != null:
		check("no pending STDIO requests on no_caps conn",
			conn_nc.pending_request_count() == 0,
			"pending_request_count=%d" % conn_nc.pending_request_count())

	# Clean up
	await pm.stop_plugin("provider_probe_no_caps")


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
