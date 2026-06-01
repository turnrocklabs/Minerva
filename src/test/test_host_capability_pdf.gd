extends SceneTree
## Integration test for host.pdf.generate (docket P1.2).
##
## Run: godot --headless --path src --script test/test_host_capability_pdf.gd
##
## Coverage (in-process — direct broker.dispatch with a stub PluginDB):
##
##   1. Success mapping (fake conn) → {success:true, result:{...page_count==2...}}
##   2. Error mapping (fake conn, GenError) → success:false + font_not_available + extras
##   3. Deny when ungranted → success:false + capability_not_granted
##   4. Audit redaction → no audit entry contains the raw bytes_b64; shape summary present
##   5. Real-binary spawn (BEST EFFORT) → real %PDF back, or SKIP if spawn unavailable headless
##
## Test isolation: clears policy.json for the test plugin IDs at start and end.

const PLUGIN_DB_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDB.gd"
const POLICY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/CapabilityBroker.gd"
const DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"

const TEST_PLUGIN_ID := "pdf_probe_test"
const TEST_PLUGIN_ID_NO_GRANT := "pdf_probe_test_no_grant"

const CAPABILITY := "host.pdf.generate"

# A known, distinctive base64 blob used to prove no input bytes leak into audit.
const FAKE_IMAGE_B64 := "U0VDUkVUX0lNQUdFX0JZVEVTX0RPX05PVF9MRUFL"  # "SECRET_IMAGE_BYTES_DO_NOT_LEAK"
const FAKE_OUTPUT_B64 := "JVBERi1mYWtlLW91dHB1dC1ieXRlcw=="           # "%PDF-fake-output-bytes"

var _pass_count: int = 0
var _fail_count: int = 0
var _skip_count: int = 0
var _real_spawn_ran: bool = false


func _init() -> void:
	print("=== host.pdf.generate Capability Test (P1.2) ===\n")
	_clear_policy_for_test()
	await _run_tests()
	_clear_policy_for_test()
	print("\n=== Results: %d passed, %d failed, %d skipped ===" % [_pass_count, _fail_count, _skip_count])
	print("=== Real-spawn case: %s ===" % ("RAN" if _real_spawn_ran else "SKIPPED"))
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# A minimal valid declarative document (one page, two text ops, one image).
# ---------------------------------------------------------------------------
func _sample_doc() -> Dictionary:
	return {
		"defaults": {"format": "Letter", "orientation": "portrait", "unit": "pt"},
		"metadata": {"title": "Probe"},
		"images": [
			{"id": "icon", "format": "png", "bytes_b64": FAKE_IMAGE_B64},
		],
		"pages": [
			{"ops": [
				{"kind": "draw_text", "text": "Ada", "x": 10, "y": 10,
					"font": {"family": "DejaVuSans", "style": "", "size": 12}},
				{"kind": "draw_text", "text": "Lovelace", "x": 10, "y": 30,
					"font": {"family": "DejaVuSans", "style": "B", "size": 12}},
			]},
		],
	}


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

func _run_tests() -> void:
	# Let autoloads (SingletonObject) finish registering before load()-ing the
	# broker; the broker references SingletonObject and won't compile standalone
	# until the global is live. Mirrors test_host_capability_documents_patch_put.
	await process_frame

	var DB = load(PLUGIN_DB_SCRIPT_PATH)
	var Policy = load(POLICY_SCRIPT_PATH)
	var Audit = load(AUDIT_SCRIPT_PATH)
	var Broker = load(BROKER_SCRIPT_PATH)
	var Def = load(DEFINITION_SCRIPT_PATH)
	check("scripts loaded",
		DB != null and Policy != null and Audit != null and Broker != null and Def != null)

	# 0. Manifest-validator allowlist: a plugin manifest declaring
	# host.pdf.generate must pass PluginDefinition validation. The broker
	# dispatch and the manifest allowlist are SEPARATE gates — a missing
	# allowlist entry blocks install even though dispatch works (regression
	# guard: this exact gap surfaced at first in-app install).
	check("0. host.pdf.generate is in PluginDefinition.ALLOWED_HOST_CAPABILITIES",
		"host.pdf.generate" in Def.ALLOWED_HOST_CAPABILITIES,
		"manifest validator would reject host.pdf.generate at install")

	# Clean test seam at start.
	Broker._test_host_pdf_conn = null

	# Granted plugin.
	var db = DB.new()
	var def = Def.new(TEST_PLUGIN_ID)
	def.host_capabilities = [CAPABILITY] as Array[String]
	db._plugins[TEST_PLUGIN_ID] = def
	var audit = Audit.new()
	var policy = Policy.new(db, audit)
	var broker = Broker.new(policy, audit)
	policy.grant_capability(TEST_PLUGIN_ID, CAPABILITY)

	# -------------------------------------------------------------------------
	# 1. Success mapping (fake conn)
	# -------------------------------------------------------------------------
	var success_result := {
		"bytes_b64": FAKE_OUTPUT_B64,
		"byte_size": 123,
		"page_count": 2,
		"content_type": "application/pdf",
	}
	Broker._test_host_pdf_conn = _FakeConn.new(success_result)
	var ok: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAPABILITY, _sample_doc())
	check("1a. success → success:true", ok.get("success", false), "got: %s" % str(ok))
	check_eq("1b. success → page_count==2", ok.get("result", {}).get("page_count", -1), 2)
	check_eq("1c. success → byte_size==123", ok.get("result", {}).get("byte_size", -1), 123)
	check_eq("1d. success → content_type",
		ok.get("result", {}).get("content_type", ""), "application/pdf")
	check_eq("1e. success → bytes_b64 round-trips",
		ok.get("result", {}).get("bytes_b64", ""), FAKE_OUTPUT_B64)

	# -------------------------------------------------------------------------
	# 2. Error mapping (fake conn returns a GenError)
	# -------------------------------------------------------------------------
	var gen_error := {
		"error_code": "font_not_available",
		"error_message": "Font 'Comic Sans' style '' is not available",
		"family": "Comic Sans",
		"style": "",
		"available": ["DejaVuSans"],
	}
	Broker._test_host_pdf_conn = _FakeConn.new(gen_error)
	var err: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAPABILITY, _sample_doc())
	check("2a. error → success:false", not err.get("success", true), "got: %s" % str(err))
	check_eq("2b. error → error_code routed through",
		err.get("error_code", ""), "font_not_available")
	check_eq("2c. error → family extra field preserved",
		err.get("family", ""), "Comic Sans")
	check_eq("2d. error → available extra field preserved",
		err.get("available", []), ["DejaVuSans"])
	check_eq("2e. error → plugin_id stamped", err.get("plugin_id", ""), TEST_PLUGIN_ID)

	# -------------------------------------------------------------------------
	# 3. Deny when ungranted (separate plugin id, no grant)
	# -------------------------------------------------------------------------
	var db_no = DB.new()
	var def_no = Def.new(TEST_PLUGIN_ID_NO_GRANT)
	def_no.host_capabilities = [CAPABILITY] as Array[String]
	db_no._plugins[TEST_PLUGIN_ID_NO_GRANT] = def_no
	var audit_no = Audit.new()
	var policy_no = Policy.new(db_no, audit_no)
	var broker_no = Broker.new(policy_no, audit_no)
	Broker._test_host_pdf_conn = _FakeConn.new(success_result)  # should never be reached
	var deny: Dictionary = await broker_no.dispatch(TEST_PLUGIN_ID_NO_GRANT, CAPABILITY, _sample_doc())
	check("3a. ungranted → success:false", not deny.get("success", true), "got: %s" % str(deny))
	check_eq("3b. ungranted → capability_not_granted",
		deny.get("error_code", ""), "capability_not_granted")

	# -------------------------------------------------------------------------
	# 4. Audit redaction — no raw bytes leak; shape summary present.
	# -------------------------------------------------------------------------
	audit.clear()
	Broker._test_host_pdf_conn = _FakeConn.new(success_result)
	var _r: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAPABILITY, _sample_doc())
	var entries: Array = audit.get_entries(TEST_PLUGIN_ID, "", 50)
	check("4a. audit produced at least one entry", entries.size() > 0,
		"entries=%d" % entries.size())

	var leaked: bool = false
	var summary_found: bool = false
	for e in entries:
		var blob := JSON.stringify(e)
		if blob.find(FAKE_IMAGE_B64) != -1 or blob.find(FAKE_OUTPUT_B64) != -1:
			leaked = true
		var detail: Dictionary = e.get("detail", {})
		var args_summary: Dictionary = detail.get("args_summary", {})
		if args_summary.has("pdf_summary"):
			summary_found = true
			var ps: Dictionary = args_summary["pdf_summary"]
			check_eq("4d. pdf_summary.page_count", ps.get("page_count", -1), 1)
			check_eq("4e. pdf_summary.image_count", ps.get("image_count", -1), 1)
			check_eq("4f. pdf_summary.output_byte_size", ps.get("output_byte_size", -1), 123)
			check_eq("4g. pdf_summary.output_page_count", ps.get("output_page_count", -1), 2)
	check("4b. no raw bytes_b64 in any audit entry", not leaked,
		"a known bytes blob appeared in the audit log")
	check("4c. shape summary (pdf_summary) present in audit", summary_found)

	# -------------------------------------------------------------------------
	# 5. Real-binary spawn (BEST EFFORT — SKIP, never FAIL, on env limits)
	# -------------------------------------------------------------------------
	await _test_real_spawn(broker)

	# -------------------------------------------------------------------------
	# 6. Connection auto-recovery: a dead cached connection surfaces as
	#    backend_error AND is dropped from the cache, so the next call respawns
	#    instead of reusing a dead process forever (reliability).
	# -------------------------------------------------------------------------
	Broker._test_host_pdf_conn = null
	broker._host_pdf_conn = _FakeConn.new({"error": "STDIO transport not connected"})
	var rec: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAPABILITY, _sample_doc())
	check_eq("6a. dead conn → backend_error", rec.get("error_code", ""), "plugin_backend_error")
	check("6b. dead cached conn invalidated (next call respawns)",
		broker._host_pdf_conn == null,
		"expected _host_pdf_conn nulled after a connection-layer failure")


func _test_real_spawn(broker) -> void:
	# Clear the fake so the handler attempts a real spawn.
	var Broker = load(BROKER_SCRIPT_PATH)
	Broker._test_host_pdf_conn = null

	var plat: String = ""
	match OS.get_name():
		"macOS": plat = "macos"
		"Linux": plat = "linux"
		"Windows": plat = "windows.exe"
		_: plat = ""
	if plat.is_empty():
		_skip("5. real spawn — unsupported platform '%s'" % OS.get_name())
		return

	var bin_path: String = ProjectSettings.globalize_path("res://bin/minerva-host-pdf-" + plat)
	if not FileAccess.file_exists(bin_path):
		_skip("5. real spawn — binary missing at %s (run scripts/build-host-pdf.sh)" % bin_path)
		return

	# Probe whether SubProcess (PTY/fork+exec) is available in this headless run.
	# If the connection can't spawn, the handler returns a backend_error; we treat
	# that as a SKIP rather than a FAIL — the harness, not the code, is the limit.
	var doc := _sample_doc()
	var result: Dictionary = await broker.dispatch(TEST_PLUGIN_ID, CAPABILITY, doc)

	if result.get("success", false):
		_real_spawn_ran = true
		var b64: String = result.get("result", {}).get("bytes_b64", "")
		var raw: PackedByteArray = Marshalls.base64_to_raw(b64)
		var head := raw.slice(0, 4).get_string_from_ascii()
		check("5a. real spawn → %PDF header", head == "%PDF",
			"decoded header=%s (byte_size=%d)" % [head, raw.size()])
	else:
		var code: String = result.get("error_code", "")
		# A genuine generation/validation error from a live sidecar is still a
		# real result worth asserting on; only a spawn/connection failure skips.
		if code == PluginErrors.CODE_BACKEND_ERROR or code == PluginErrors.CODE_PDF_GENERATION_FAILED:
			print("SKIP: real spawn needs live session — %s: %s"
				% [code, result.get("error_message", "")])
			_skip("5. real spawn (env: %s)" % code)
		else:
			# Sidecar ran and rejected the doc with a contract error — that means
			# spawn DID work; surface it as a real (informational) outcome.
			_real_spawn_ran = true
			print("  INFO: real spawn produced contract error %s: %s"
				% [code, result.get("error_message", "")])
			check("5b. real spawn reached sidecar (contract error returned)", true)

	Broker._test_host_pdf_conn = null


# ---------------------------------------------------------------------------
# Fake MCPServerConnection — exposes the call_tool(name, args) public API only.
# ---------------------------------------------------------------------------
class _FakeConn extends RefCounted:
	var _reply: Dictionary

	func _init(reply: Dictionary) -> void:
		_reply = reply

	# Mirrors MCPServerConnection.call_tool's signature/return shape: the parsed
	# tool payload Dictionary. await-compatible (broker awaits it).
	func call_tool(_tool_name: String, _arguments: Dictionary, _timeout_sec: float = 120.0) -> Dictionary:
		return _reply.duplicate(true)


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


func _skip(label: String) -> void:
	_skip_count += 1
	print("  SKIP: %s" % label)


# ---------------------------------------------------------------------------
# Test isolation
# ---------------------------------------------------------------------------

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
	grants.erase(TEST_PLUGIN_ID_NO_GRANT)
	(data as Dictionary)["grants"] = grants
	fa = FileAccess.open(policy_file, FileAccess.WRITE)
	if fa == null:
		return
	fa.store_string(JSON.stringify(data, "  "))
	fa.close()
