extends SceneTree
## Locks the MCPKnownServers registry contract after codetools was extracted to a
## plugin (fix: remove codetools from core known-servers so it stops being
## auto-registered into mcp_config.json and shadowing the codetools plugin's
## minerva_codetools_* namespace).
##
## Guard: codetools must NOT be a core known server; nudge + cobrowser must remain
## (they are still core for now). If a future change re-adds codetools here, or
## drops nudge/cobrowser without intent, this fails.
##
## NOTE: the load-path auto-prune of a persisted origin:"known" codetools entry in
## user://mcp_config.json lives in MCPConfig (which depends on the SingletonObject
## autoload + a hardcoded user:// path), so that end-to-end behavior is covered by
## the HITL runbook, not here.
##
## Run: godot --headless --path src --script test/test_mcp_known_servers.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== MCPKnownServers registry tests ===")
	_check("codetools is NOT a known server", not MCPKnownServers.is_known("codetools"))
	_check("get_server('codetools') is null", MCPKnownServers.get_server("codetools") == null)
	_check("nudge IS still known", MCPKnownServers.is_known("nudge"))
	_check("cobrowser IS still known", MCPKnownServers.is_known("cobrowser"))

	var names := MCPKnownServers.get_names()
	_check("get_names() excludes codetools", not names.has("codetools"))
	_check("get_names() includes nudge + cobrowser", names.has("nudge") and names.has("cobrowser"))

	# Sanity: the surviving entries still resolve their ports (no accidental wipe).
	_check("nudge default port is 8765", MCPKnownServers.get_default_port("nudge") == 8765)
	_check("cobrowser default port is 8677", MCPKnownServers.get_default_port("cobrowser") == 8677)
	_check("unknown server port is 0", MCPKnownServers.get_default_port("codetools") == 0)

	print("=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)
