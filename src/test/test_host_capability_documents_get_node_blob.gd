extends SceneTree
## Unit tests for host.documents.get_node and host.documents.get_blob
## capabilities (broker phase 5 R2).
##
## Run: godot --headless --path src --script test/test_host_capability_documents_get_node_blob.gd
##
## Tracks docket: minerva 019e15965ef573458fd5ffd0dbe35182 (Phase 5)
##
## Coverage:
##   get_node schema validation:
##     - empty editor_name → schema_validation_failed
##     - malformed path (no leading /) → schema_validation_failed
##   get_node resolution:
##     - bogus editor_name → editor_not_found
##     - path that doesn't exist in doc → found=false (non-error)
##     - valid path in known doc → found=true + correct subtree
##   get_blob schema validation:
##     - empty editor_name → schema_validation_failed
##     - empty blob_handle → schema_validation_failed
##   get_blob blob store:
##     - bogus editor_name → editor_not_found
##     - unknown handle → blob_not_found
##     - known handle → success + bytes_b64 + content_type
##   Policy gate:
##     - get_node denied when capability not granted
##     - get_blob denied when capability not granted
##
## NOTE: PluginScenePanelBroker._get_blob_record is a private method used
## directly in tests (not through the full IPC chain) to pre-populate the
## blob store.  This is the same pattern used by test_blob_store.gd.

const CAPABILITY_BROKER_SCRIPT_PATH   := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const PLUGIN_POLICY_SCRIPT_PATH       := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const PLUGIN_AUDIT_LOG_SCRIPT_PATH    := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const PLUGIN_ERRORS_SCRIPT_PATH       := "res://Scripts/Services/Plugins/PluginErrors.gd"
const PANEL_BROKER_SCRIPT_PATH        := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== host.documents.get_node + get_blob Capability Tests (phase 5 R2) ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	# Wait one frame for autoloads to register.
	await process_frame

	var AuditScript  = load(PLUGIN_AUDIT_LOG_SCRIPT_PATH)
	var PolicyScript = load(PLUGIN_POLICY_SCRIPT_PATH)
	var BrokerScript = load(CAPABILITY_BROKER_SCRIPT_PATH)
	var PanelBrokerScript = load(PANEL_BROKER_SCRIPT_PATH)

	check("scripts loaded",
		AuditScript != null and PolicyScript != null
		and BrokerScript != null and PanelBrokerScript != null)
	if AuditScript == null or PolicyScript == null or BrokerScript == null or PanelBrokerScript == null:
		return

	await _test_get_node_schema_validation(PolicyScript, BrokerScript, AuditScript)
	await _test_get_node_resolution(PolicyScript, BrokerScript, AuditScript, PanelBrokerScript)
	await _test_get_blob_schema_validation(PolicyScript, BrokerScript, AuditScript)
	await _test_get_blob_store(PolicyScript, BrokerScript, AuditScript, PanelBrokerScript)
	await _test_policy_gate(PolicyScript, BrokerScript, AuditScript)


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
		printerr(msg)


func _make_broker(PolicyScript, BrokerScript, AuditScript) -> Array:
	var audit  = AuditScript.new()
	var policy = PolicyScript.new(null, audit, false)
	var broker = BrokerScript.new(policy, audit)
	return [broker, policy, audit]


# ---------------------------------------------------------------------------
# get_node: schema validation
# ---------------------------------------------------------------------------

func _test_get_node_schema_validation(PolicyScript, BrokerScript, AuditScript) -> void:
	print("\n-- _test_get_node_schema_validation_rejects_empty_editor_name --")
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]; var policy = parts[1]
	policy.grant_capability("get_node_test", "host.documents.get_node")

	var r: Dictionary = await broker.dispatch("get_node_test",
		"host.documents.get_node", {"editor_name": "", "path": "/slides"})
	check("empty editor_name → success=false", not r.get("success", true),
		"got: %s" % str(r))
	check("empty editor_name → schema_validation_failed",
		r.get("error_code", "") == "schema_validation_failed",
		"got error_code: '%s'" % r.get("error_code", ""))

	print("\n-- _test_get_node_schema_validation_rejects_malformed_path --")
	var r2: Dictionary = await broker.dispatch("get_node_test",
		"host.documents.get_node", {"editor_name": "my_deck", "path": "slides/0"})
	check("malformed path (no leading /) → success=false", not r2.get("success", true),
		"got: %s" % str(r2))
	check("malformed path → schema_validation_failed",
		r2.get("error_code", "") == "schema_validation_failed",
		"got error_code: '%s'" % r2.get("error_code", ""))

	# Edge case: empty path is valid (root pointer).
	# This will fail with editor_not_found (no editor_pane in headless) not schema error.
	var r3: Dictionary = await broker.dispatch("get_node_test",
		"host.documents.get_node", {"editor_name": "my_deck", "path": ""})
	check("empty path is valid (not schema error)",
		r3.get("error_code", "") != "schema_validation_failed",
		"got error_code: '%s'" % r3.get("error_code", ""))


# ---------------------------------------------------------------------------
# get_node: resolution
# ---------------------------------------------------------------------------

func _test_get_node_resolution(PolicyScript, BrokerScript, AuditScript, _PanelBrokerScript) -> void:
	print("\n-- _test_get_node_returns_editor_not_found_for_bogus_editor --")
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]; var policy = parts[1]
	policy.grant_capability("get_node_test2", "host.documents.get_node")

	var r: Dictionary = await broker.dispatch("get_node_test2",
		"host.documents.get_node",
		{"editor_name": "no_such_editor_xyz_get_node", "path": "/slides"})
	check("bogus editor → success=false", not r.get("success", true),
		"got: %s" % str(r))
	check("bogus editor → editor_not_found",
		r.get("error_code", "") == "editor_not_found",
		"got error_code: '%s'" % r.get("error_code", ""))

	print("\n-- _test_get_node_returns_found_false_for_missing_path --")
	# We can't easily inject a real editor in headless, but we can verify the
	# broker doesn't error when resolving against an empty doc (the headless
	# fallback).  A missing editor returns editor_not_found, which is the
	# headless outcome.  We test found=false at the JsonPointer level directly.
	var JsonPointerScript = load("res://Scripts/Services/Plugins/JsonPointer.gd")
	check("JsonPointer loaded", JsonPointerScript != null)
	if JsonPointerScript != null:
		var doc := {"slides": [{"title": "First"}]}
		var res: Dictionary = JsonPointerScript.resolve(doc, "/missing_key")
		check("JsonPointer: missing key → found=false", not res.get("found", true),
			"got: %s" % str(res))
		check("JsonPointer: missing key → value null", res.get("value", "NOT_NULL") == null,
			"got value: %s" % str(res.get("value")))

	print("\n-- _test_get_node_returns_subtree_for_valid_path --")
	# Test JsonPointer.resolve directly with a known document.
	if JsonPointerScript != null:
		var doc2 := {
			"slides": [
				{"id": "s1", "title": "Intro", "tile_count": 2},
				{"id": "s2", "title": "Details", "tile_count": 5},
			],
			"aspect": "16:9",
		}
		# Resolve a top-level key.
		var res_aspect: Dictionary = JsonPointerScript.resolve(doc2, "/aspect")
		check("resolve /aspect → found=true", res_aspect.get("found", false),
			"got: %s" % str(res_aspect))
		check("resolve /aspect → correct value", res_aspect.get("value", "") == "16:9",
			"got value: %s" % str(res_aspect.get("value")))

		# Resolve into an array element.
		var res_slide: Dictionary = JsonPointerScript.resolve(doc2, "/slides/1/title")
		check("resolve /slides/1/title → found=true", res_slide.get("found", false),
			"got: %s" % str(res_slide))
		check("resolve /slides/1/title → 'Details'", res_slide.get("value", "") == "Details",
			"got value: %s" % str(res_slide.get("value")))

		# Resolve missing nested key → found=false, not an error.
		var res_missing: Dictionary = JsonPointerScript.resolve(doc2, "/slides/0/speaker_notes")
		check("resolve missing nested key → found=false", not res_missing.get("found", true),
			"got: %s" % str(res_missing))
		check("resolve missing nested key → value null",
			res_missing.get("value", "NOT_NULL") == null,
			"got value: %s" % str(res_missing.get("value")))

		# Resolve root (empty pointer) → whole doc.
		var res_root: Dictionary = JsonPointerScript.resolve(doc2, "")
		check("resolve root '' → found=true", res_root.get("found", false),
			"got: %s" % str(res_root))
		check("resolve root '' → same dict", res_root.get("value", null) == doc2,
			"got value type: %s" % typeof(res_root.get("value")))


# ---------------------------------------------------------------------------
# get_blob: schema validation
# ---------------------------------------------------------------------------

func _test_get_blob_schema_validation(PolicyScript, BrokerScript, AuditScript) -> void:
	print("\n-- _test_get_blob_schema_validation_rejects_empty_editor_name --")
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]; var policy = parts[1]
	policy.grant_capability("get_blob_test", "host.documents.get_blob")

	var r: Dictionary = await broker.dispatch("get_blob_test",
		"host.documents.get_blob", {"editor_name": "", "blob_handle": "blob-1"})
	check("empty editor_name → success=false", not r.get("success", true),
		"got: %s" % str(r))
	check("empty editor_name → schema_validation_failed",
		r.get("error_code", "") == "schema_validation_failed",
		"got error_code: '%s'" % r.get("error_code", ""))

	print("\n-- _test_get_blob_schema_validation_rejects_empty_handle --")
	var r2: Dictionary = await broker.dispatch("get_blob_test",
		"host.documents.get_blob", {"editor_name": "my_deck", "blob_handle": ""})
	check("empty blob_handle → success=false", not r2.get("success", true),
		"got: %s" % str(r2))
	check("empty blob_handle → schema_validation_failed",
		r2.get("error_code", "") == "schema_validation_failed",
		"got error_code: '%s'" % r2.get("error_code", ""))


# ---------------------------------------------------------------------------
# get_blob: blob store interactions
# ---------------------------------------------------------------------------

func _test_get_blob_store(PolicyScript, BrokerScript, AuditScript, PanelBrokerScript) -> void:
	print("\n-- _test_get_blob_returns_editor_not_found_for_bogus_editor --")
	var parts := _make_broker(PolicyScript, BrokerScript, AuditScript)
	var broker = parts[0]; var policy = parts[1]
	policy.grant_capability("get_blob_test2", "host.documents.get_blob")

	# No editor_pane in headless → _find_editor_by_name returns null → editor_not_found.
	var r: Dictionary = await broker.dispatch("get_blob_test2",
		"host.documents.get_blob",
		{"editor_name": "no_such_editor_xyz_get_blob", "blob_handle": "blob-1"})
	check("bogus editor → success=false", not r.get("success", true),
		"got: %s" % str(r))
	check("bogus editor → editor_not_found",
		r.get("error_code", "") == "editor_not_found",
		"got error_code: '%s'" % r.get("error_code", ""))

	print("\n-- _test_get_blob_returns_blob_not_found_for_unknown_handle --")
	# Test blob_not_found via PluginErrors directly (broker can't reach the panel
	# broker's store in headless, so we verify the error factory produces the
	# right shape).
	var PluginErrorsScript = load("res://Scripts/Services/Plugins/PluginErrors.gd")
	check("PluginErrors loaded", PluginErrorsScript != null)
	if PluginErrorsScript != null:
		var err: Dictionary = PluginErrorsScript.blob_not_found("test_plugin", "my_deck", "blob-99")
		check("blob_not_found → success=false", not err.get("success", true),
			"got: %s" % str(err))
		check("blob_not_found → error_code blob_not_found",
			err.get("error_code", "") == "blob_not_found",
			"got error_code: '%s'" % err.get("error_code", ""))
		check("blob_not_found → editor_name present",
			err.get("editor_name", "") == "my_deck",
			"got: %s" % str(err))
		check("blob_not_found → blob_handle present",
			err.get("blob_handle", "") == "blob-99",
			"got: %s" % str(err))
		check("blob_not_found → plugin_id present",
			err.get("plugin_id", "") == "test_plugin",
			"got: %s" % str(err))

	print("\n-- _test_get_blob_returns_bytes_b64_and_content_type_for_known_handle --")
	# Use PluginScenePanelBroker directly to store a blob, then verify
	# _get_blob_record returns the right shape — this mirrors how the broker
	# handler reads from the panel broker's store.
	var audit_pb  = load(PLUGIN_AUDIT_LOG_SCRIPT_PATH).new()
	var panel_broker = PanelBrokerScript.new(null, null, null, audit_pb)

	var test_bytes := PackedByteArray([0x89, 0x50, 0x4E, 0x47])  # PNG magic bytes
	var handle: String = panel_broker._store_blob("test_editor", test_bytes, "image/png")
	check("_store_blob returns a handle", not handle.is_empty(),
		"handle: '%s'" % handle)

	var rec: Dictionary = panel_broker._get_blob_record("test_editor", handle)
	check("_get_blob_record found=true", rec.get("found", false),
		"got: %s" % str(rec))
	check("_get_blob_record content_type correct",
		rec.get("content_type", "") == "image/png",
		"got content_type: '%s'" % rec.get("content_type", ""))
	check("_get_blob_record bytes match",
		rec.get("bytes", PackedByteArray()) == test_bytes,
		"got bytes size: %d" % rec.get("bytes", PackedByteArray()).size())

	# Verify base64 encoding round-trips correctly.
	var b64: String = Marshalls.raw_to_base64(rec.get("bytes", PackedByteArray()))
	var decoded: PackedByteArray = Marshalls.base64_to_raw(b64)
	check("base64 round-trip preserves bytes",
		decoded == test_bytes,
		"decoded size: %d, expected: %d" % [decoded.size(), test_bytes.size()])

	# Unknown handle returns found=false.
	var rec_missing: Dictionary = panel_broker._get_blob_record("test_editor", "blob-999")
	check("unknown handle → found=false", not rec_missing.get("found", true),
		"got: %s" % str(rec_missing))


# ---------------------------------------------------------------------------
# Policy gate: both caps denied when not granted
# ---------------------------------------------------------------------------

func _test_policy_gate(PolicyScript, BrokerScript, AuditScript) -> void:
	print("\n-- _test_get_node_denied_when_capability_not_granted --")
	# Fresh broker with no grants — deny-by-default.
	var audit  = AuditScript.new()
	var policy = PolicyScript.new(null, audit, false)
	var broker = BrokerScript.new(policy, audit)

	var r_node: Dictionary = await broker.dispatch("no_grant_plugin",
		"host.documents.get_node",
		{"editor_name": "my_deck", "path": "/slides"})
	check("get_node with no grant → success=false", not r_node.get("success", true),
		"got: %s" % str(r_node))
	var node_code: String = r_node.get("error_code", "")
	check("get_node with no grant → capability_not_granted",
		node_code == "capability_not_granted",
		"got error_code: '%s'" % node_code)

	# Audit log should have a denied entry.
	var denied_entries: Array = audit.get_entries("no_grant_plugin", "capability_denied")
	check("policy denial recorded in audit log",
		denied_entries.size() >= 1,
		"denied_entries: %s" % str(denied_entries))

	print("\n-- _test_get_blob_denied_when_capability_not_granted --")
	var r_blob: Dictionary = await broker.dispatch("no_grant_plugin",
		"host.documents.get_blob",
		{"editor_name": "my_deck", "blob_handle": "blob-1"})
	check("get_blob with no grant → success=false", not r_blob.get("success", true),
		"got: %s" % str(r_blob))
	var blob_code: String = r_blob.get("error_code", "")
	check("get_blob with no grant → capability_not_granted",
		blob_code == "capability_not_granted",
		"got error_code: '%s'" % blob_code)

	# Both denials should now be in the log.
	var denied_after: Array = audit.get_entries("no_grant_plugin", "capability_denied")
	check("both cap denials in audit log",
		denied_after.size() >= 2,
		"denied_after count: %d" % denied_after.size())
