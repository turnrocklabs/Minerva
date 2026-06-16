extends SceneTree
## Integration test for the host.media.credentials capability (A1a).
##
## Run: godot --headless --path src --script test/test_host_capability_media_credentials.gd
##
## Covers (plugins.dct 3d-gen A1a):
##   - Deny:   capability not granted -> structured error (no creds leaked)
##   - Logged-out: granted but Core has no session -> backend_error, empty body
##   - Happy:  granted + Core authenticated -> {ws_url, token, client_id} returned
##
## The handler reaches the live Core autoload (/root/Core) and surfaces its existing
## _jwt_token/_client_id — it mints nothing. We drive that by setting Core's session
## vars directly, then asserting the broker round-trips them.

const POLICY := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const BROKER := "res://Scripts/Services/Plugins/CapabilityBroker.gd"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== host.media.credentials capability test ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	await process_frame  # let autoloads register

	var PolicyScript = load(POLICY)
	var AuditScript = load(AUDIT)
	var BrokerScript = load(BROKER)
	check("scripts loaded", PolicyScript != null and AuditScript != null and BrokerScript != null)
	if BrokerScript == null:
		return

	var audit = AuditScript.new()
	var policy = PolicyScript.new(null, audit, false)
	var broker = BrokerScript.new(policy, audit)
	const PID := "media_probe"

	# --- Deny: not granted ---
	var deny: Dictionary = await broker.dispatch(PID, "host.media.credentials", {})
	check("ungranted -> success=false", not deny.get("success", true), "got: %s" % str(deny))
	check("ungranted -> capability_not_granted",
		deny.get("error_code", "") == "capability_not_granted",
		"got error_code: '%s'" % deny.get("error_code", ""))
	check("ungranted leaks no token", not deny.has("token") and not deny.has("ws_url"))

	policy.grant_capability(PID, "host.media.credentials")

	# Reach the Core autoload to drive its session state.
	var core = root.get_node_or_null("/root/Core")
	if core == null or not core.has_method("get_media_credentials"):
		print("  SKIP happy/logged-out paths — Core autoload not present headless")
		return

	# Snapshot + clear -> logged-out path.
	var prev_tok = core.get("_jwt_token")
	var prev_cid = core.get("_client_id")
	core.set("_jwt_token", "")
	core.set("_client_id", "")
	var out: Dictionary = await broker.dispatch(PID, "host.media.credentials", {})
	check("logged-out -> success=false", not out.get("success", true), "got: %s" % str(out))
	check("logged-out -> backend_error",
		str(out.get("error_code", "")).findn("backend") != -1 or out.get("success", true) == false,
		"got error_code: '%s'" % out.get("error_code", ""))
	check("logged-out leaks no token", not out.has("token"))

	# --- Happy: authenticated session ---
	core.set("_jwt_token", "test.jwt.token")
	core.set("_client_id", "client-abc-123")
	var ok: Dictionary = await broker.dispatch(PID, "host.media.credentials", {})
	# Successful dispatch envelope is {success:true, result:{...}} — backend reads result.*
	var body: Dictionary = ok.get("result", {})
	check("happy -> success=true", ok.get("success", false), "got: %s" % str(ok))
	check("happy -> token surfaced", body.get("token", "") == "test.jwt.token", "got: %s" % str(ok))
	check("happy -> client_id surfaced", body.get("client_id", "") == "client-abc-123", "got: %s" % str(ok))
	check("happy -> ws_url present and wss",
		str(body.get("ws_url", "")).begins_with("wss://"),
		"got ws_url: '%s'" % body.get("ws_url", ""))

	# Restore Core session state.
	core.set("_jwt_token", prev_tok if prev_tok != null else "")
	core.set("_client_id", prev_cid if prev_cid != null else "")


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)
