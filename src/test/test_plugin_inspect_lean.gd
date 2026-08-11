extends SceneTree
## minerva_plugin_inspect LEAN mode (Epoch UX2 station 7, docket 019fde56e6c3).
##
## HITL-4 F8: the full reply for the pcb plugin ran ~87KB on one line (74 tool
## schemas + manifest + audit) and overflowed the calling agent's tool-result
## budget. The contract now: LEAN summary by default — {id, name, version,
## status, tool_count, capabilities, recent_audit_count} — with the heavy
## sections opt-in via include:["manifest","tools","audit"] (docket_get's
## include convention).
##
## Pure-unit: PluginMCPTools takes its manager/policy/audit injected, so the
## whole surface is exercised against duck-typed fakes — no plugin install, no
## running host.
##
## PluginMCPTools is load()-ed at RUNTIME after the first process_frame (the
## test_plugin_autogrant idiom, Codex 1049 finding 3): the script references
## SingletonObject, so a parse-time class_name reference from this test would
## fail to compile before the autoload is live and hang instead of quitting.

const MCP_TOOLS_SCRIPT := "res://Scripts/Services/Plugins/PluginMCPTools.gd"

var _pass := 0
var _fail := 0


class FakeDef extends RefCounted:
	var id := "pcb"
	var name := "PCB Plugin"
	var version := "1.2.3"
	var host_api_version := "1"
	var transport := "stdio"
	var entrypoint := "pcb-plugin"
	var args := []
	var working_dir := "."
	var autostart := true
	var network_mode := "none"
	var filesystem_mode := "sandbox"
	var tools := [
		{"name": "minerva_pcb_a", "input_schema": {"type": "object"}},
		{"name": "minerva_pcb_b", "input_schema": {"type": "object"}},
		{"name": "minerva_pcb_c", "input_schema": {"type": "object"}},
	]


class FakeDB extends RefCounted:
	var def = null
	func get_by_id(_id: String):
		return def


class FakeManager extends RefCounted:
	var db = null
	func get_db():
		return db
	func get_plugin_status(_id: String) -> Dictionary:
		return {"state_name": "running"}


class FakePolicy extends RefCounted:
	func get_granted_capabilities(_id: String) -> Array:
		return ["host.documents.read"]
	func get_requested_capabilities(_id: String) -> Array:
		return ["host.documents.read", "host.terminal.exec"]


class FakeAudit extends RefCounted:
	func get_entries(_id: String, _kind: String, _limit: int) -> Array:
		return [{"event": "tool_call"}, {"event": "tool_call"}]


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + desc)
	else:
		_fail += 1
		printerr("  FAIL: " + desc)


func _init() -> void:
	print("=== plugin_inspect lean mode (UX2 station 7) ===\n")
	await process_frame

	var MCPTools = load(MCP_TOOLS_SCRIPT)
	check("PluginMCPTools loads at runtime", MCPTools != null)
	if MCPTools == null:
		print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
		quit(1)
		return

	var def := FakeDef.new()
	var db := FakeDB.new()
	db.def = def
	var manager := FakeManager.new()
	manager.db = db
	var mcp = MCPTools.new(manager, FakePolicy.new(), FakeAudit.new())

	# ── lean default ──
	var lean: Dictionary = mcp._handle_plugin_inspect({"id": "pcb"})
	check("lean reply succeeds", bool(lean.get("success", false)))
	check("lean carries id/name/version",
		str(lean.get("id", "")) == "pcb" and str(lean.get("version", "")) == "1.2.3")
	check("lean carries status", (lean.get("status", {}) as Dictionary).has("state_name"))
	check("lean carries tool_count, not tools", int(lean.get("tool_count", -1)) == 3)
	check("lean does NOT carry tools", not lean.has("tools"))
	check("lean does NOT carry manifest", not lean.has("manifest"))
	check("lean does NOT carry recent_audit_log", not lean.has("recent_audit_log"))
	check("lean carries recent_audit_count", int(lean.get("recent_audit_count", -1)) == 2)
	var caps: Dictionary = lean.get("capabilities", {})
	check("lean keeps the capability summary (small string lists)",
		(caps.get("requested", []) as Array).size() == 2
		and (caps.get("granted", []) as Array).size() == 1)

	# ── opt-in sections ──
	var with_tools: Dictionary = mcp._handle_plugin_inspect(
		{"id": "pcb", "include": ["tools"]})
	check("include tools returns the full tool defs",
		(with_tools.get("tools", []) as Array).size() == 3)
	check("...without dragging manifest along", not with_tools.has("manifest"))

	var with_manifest: Dictionary = mcp._handle_plugin_inspect(
		{"id": "pcb", "include": ["manifest"]})
	var manifest: Dictionary = with_manifest.get("manifest", {})
	check("include manifest returns the manifest summary",
		str(manifest.get("entrypoint", "")) == "pcb-plugin"
		and str(manifest.get("network_mode", "")) == "none")
	check("...without dragging tools along", not with_manifest.has("tools"))

	var with_all: Dictionary = mcp._handle_plugin_inspect(
		{"id": "pcb", "include": ["manifest", "tools", "audit"]})
	check("include all three restores the full pre-station reply surface",
		with_all.has("manifest") and with_all.has("tools")
		and (with_all.get("recent_audit_log", []) as Array).size() == 2)

	# ── degrade: a malformed include is the lean default, not an error ──
	var bad_include: Dictionary = mcp._handle_plugin_inspect(
		{"id": "pcb", "include": "tools"})
	check("non-array include degrades to lean (no crash, no sections)",
		bool(bad_include.get("success", false)) and not bad_include.has("tools"))

	# ── unknown plugin unchanged ──
	db.def = null
	var missing: Dictionary = mcp._handle_plugin_inspect({"id": "nope"})
	check("unknown plugin still errors by name", missing.has("error"))

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)
