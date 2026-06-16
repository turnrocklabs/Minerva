extends SceneTree
## Integration test for the host.core.session capability (media-plugins A1a, Option A).
##
## Run: godot --headless --path src --script test/test_host_capability_core_session.gd
##
## host.core.session mints a NEW, distinct Core session (an independent re-login) so a
## plugin can open its OWN Core connection without colliding with Minerva's live
## session. The mint performs a real HTTP login, so the happy/error mint outcomes are
## validated in the live HITL — here we assert the deterministic, network-free parts:
##   - Deny:    capability not granted -> structured error, no creds leaked
##   - Wiring:  the capability is dispatchable (not unknown) and Core exposes
##              mint_plugin_session() (and no longer the old get_media_credentials).

const POLICY := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const BROKER := "res://Scripts/Services/Plugins/CapabilityBroker.gd"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== host.core.session capability test ===\n")
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
	const PID := "session_probe"

	# --- Deny: not granted (no mint attempted) ---
	var deny: Dictionary = await broker.dispatch(PID, "host.core.session", {})
	check("ungranted -> success=false", not deny.get("success", true), "got: %s" % str(deny))
	check("ungranted -> capability_not_granted",
		deny.get("error_code", "") == "capability_not_granted",
		"got error_code: '%s'" % deny.get("error_code", ""))
	check("ungranted leaks no token", not deny.has("token") and not deny.has("ws_url"))

	# --- Wiring: Core exposes the mint method and not the old accessor ---
	var core = root.get_node_or_null("/root/Core")
	if core == null:
		print("  SKIP wiring check — Core autoload not present headless")
		return
	check("Core has mint_plugin_session()", core.has_method("mint_plugin_session"))
	check("Core no longer exposes get_media_credentials()",
		not core.has_method("get_media_credentials"),
		"old live-token accessor should be removed (it collided)")

	# Note: a GRANTED dispatch would perform a real HTTP login (mint), so it is
	# exercised in the live HITL, not here, to keep this test network-free.


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
