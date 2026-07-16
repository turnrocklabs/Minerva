extends SceneTree
## E2E-P1: panel-executed plugin tools (executor == "panel").
##
## Run: godot --headless --path src --script test/test_panel_executed_tools.gd
##
## Contract: Docs/design/panel-executed-tools.md §2 (DCR 019f6c3d0e3d,
## C1 dispatcher round, docket 019f6c45b614).
##
## Boots the REAL stack headless: a real PluginToolRegistry wired to a real
## PluginManager (stub DB, no subprocess) and a real PluginScenePanelBroker
## with live fixture panels. Scenario coverage:
##   A) manifest executor field: validate() accepts panel/backend/absent;
##      registry entries carry the executor (absent ⇒ "backend").
##   B) fixture panel Control implementing handle_tool, registered with the
##      broker under an editor name owned by the fixture plugin.
##   C) handle_tool_call for the panel tool succeeds WITHOUT the plugin
##      subprocess running; panel dict passes through verbatim; audit events
##      carry executor:"panel".
##   D) structured errors: editor_name_required, editor_not_found (with
##      known-editors list), panel_not_owned, panel_no_handler,
##      tool_unhandled (non-dict + empty dict), tool_executor_invalid.
##   E) async: a handle_tool that awaits a frame still resolves.
##   F) regression: backend-executor tools still route through the
##      subprocess path (plugin_not_running when nothing runs).
##   G) fallback resolution via AnnotationHostRegistry host.get_panel(),
##      with duck-typed panel.plugin_id ownership (deny when absent).
##
## Conventions follow test_plugin_scene_panel_broker.gd (stubs, check()) and
## test_cad_plugin_smoke.gd (async _init + runtime load() for scripts whose
## parse chain touches the SingletonObject autoload).

## NOTE: PluginManager.gd and PluginToolRegistry.gd reference autoload state
## at parse time — load them at runtime, after the first frame (see
## test_cad_plugin_smoke.gd header note).
const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_TOOL_REGISTRY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginToolRegistry.gd"

var _pass_count: int = 0
var _fail_count: int = 0

# Shared fixtures (built in _init, used across test funcs).
var _registry = null        # PluginToolRegistry
var _manager = null         # PluginManager (real, off-tree, no subprocess)
var _broker = null          # PluginScenePanelBroker
var _audit: StubAuditLog = null
var _panels: Array = []     # every Control we must free at the end


func _init() -> void:
	print("=== Panel-Executed Tools E2E-P1 (DCR 019f6c3d0e3d / C1) ===\n")

	# Let autoloads register before load() pulls PluginManager's parse chain.
	await process_frame

	var ok := _build_fixture_stack()
	if not ok:
		printerr("FATAL: fixture stack failed to build — aborting")
		quit(1)
		return

	print("-- A: manifest executor field --")
	test_validate_accepts_panel_and_backend()
	test_registry_entries_carry_executor()
	test_absent_executor_defaults_to_backend()

	print("\n-- B: fixture panel registration --")
	test_panel_registered_and_resolvable()

	print("\n-- C: panel tool dispatch (no subprocess) --")
	await test_panel_tool_succeeds_without_subprocess()

	print("\n-- D: structured errors --")
	await test_editor_name_required()
	await test_editor_not_found_lists_known_editors()
	await test_panel_not_owned()
	await test_panel_no_handler()
	await test_tool_unhandled_non_dict()
	await test_tool_unhandled_empty_dict()
	test_tool_executor_invalid_fails_validation()
	test_registry_rejects_invalid_executor()

	print("\n-- E: async handle_tool --")
	await test_async_panel_tool_resolves()

	print("\n-- F: backend regression --")
	await test_backend_tool_still_requires_running_plugin()
	await test_absent_executor_tool_routes_to_backend()

	print("\n-- G: AnnotationHostRegistry fallback --")
	await test_fallback_host_resolution()
	await test_fallback_without_ownership_is_denied()

	print("\n-- H: lifecycle preserves panel tools (bug 019f6d2dc767) --")
	await test_stop_preserves_panel_tools()
	test_started_reregisters_missing_manifest_tools()
	await test_backend_discovery_empty_preserves_panel_tools()

	_teardown()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail.is_empty():
			printerr("  FAIL: %s" % description)
		else:
			printerr("  FAIL: %s — %s" % [description, detail])


# ===========================================================================
# Stubs / fixture classes
# ===========================================================================

## PluginDB stub (copied from test_plugin_scene_panel_broker.gd — test-local
## stub classes can't be imported across suite files).
class StubDB extends RefCounted:
	var definitions: Dictionary = {}   # id -> PluginDefinition

	func get_by_id(plugin_id: String) -> PluginDefinition:
		return definitions.get(plugin_id, null)

	func get_all() -> Array:
		return definitions.values()


## PluginAuditLog stub: captures events (same pattern as the broker suite).
class StubAuditLog extends PluginAuditLog:
	var events: Array[Dictionary] = []

	func log_event(plugin_id: String, event_type: String, detail: Dictionary = {}) -> void:
		events.append({"plugin_id": plugin_id, "event_type": event_type, "detail": detail})

	func find_events(event_type: String) -> Array:
		var out: Array = []
		for e in events:
			if e["event_type"] == event_type:
				out.append(e)
		return out


## Panel that handles tools by echoing its inputs (contract convention:
## func handle_tool(tool_name, args) -> Dictionary).
class EchoPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)

	func handle_tool(tool_name: String, args: Dictionary) -> Dictionary:
		return {
			"echoed_tool": tool_name,
			"echoed_args": args,
			"editor_name": str(args.get("editor_name", "")),
		}


## Panel whose handle_tool awaits a frame before returning (async-capable path).
class AsyncPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)

	func handle_tool(tool_name: String, _args: Dictionary) -> Dictionary:
		await Engine.get_main_loop().process_frame
		return {"async": true, "tool": tool_name}


## Panel WITHOUT handle_tool (panel_no_handler path).
class NoHandlerPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)


## Panel whose handle_tool returns a non-Dictionary (tool_unhandled path).
class NonDictPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)

	func handle_tool(_tool_name: String, _args: Dictionary):
		return "not-a-dictionary"


## Panel whose handle_tool returns {} (also tool_unhandled).
class EmptyDictPanel extends Control:
	signal request(channel: String, payload: Dictionary, reply_id: String)

	func handle_tool(_tool_name: String, _args: Dictionary) -> Dictionary:
		return {}


## AnnotationHost stub exposing get_panel() (fallback resolution path).
class StubHost extends AnnotationHost:
	var panel: Control = null

	func get_panel() -> Control:
		return panel


## Fallback panel carrying duck-typed ownership (plugin_id property).
class OwnedFallbackPanel extends Control:
	var plugin_id: String = ""

	func handle_tool(tool_name: String, _args: Dictionary) -> Dictionary:
		return {"via": "fallback", "tool": tool_name}


# ===========================================================================
# Fixture plumbing
# ===========================================================================

## Minimal manifest dict (same shape as test_plugin_scene_panel_broker's
## _make_def) with a caller-supplied tools array.
func _make_def_dict(plugin_id: String, tools: Array) -> Dictionary:
	return {
		"id": plugin_id,
		"name": plugin_id,
		"version": "0.0.1",
		"host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": "stub.py", "args": [], "working_dir": ""},
		"ui": {"panels": [], "ipc_messages": []},
		"tools": tools,
		"permissions": {"host_capabilities": [], "network": {"mode": "none"},
			"filesystem": {"mode": "none", "paths": []}},
		"data_directory": "/tmp/stub_plugin_%s" % plugin_id,
		"autostart": false,
		"auto_reload": false,
	}


func _tool(name: String, executor: Variant = null) -> Dictionary:
	var t := {
		"name": name,
		"description": "fixture tool %s" % name,
		"input_schema": {"type": "object", "properties": {}},
	}
	if executor != null:
		t["executor"] = executor
	return t


var _def_a: PluginDefinition = null
var _def_b: PluginDefinition = null


func _build_fixture_stack() -> bool:
	# Fixture plugin A: one panel tool, one explicit-backend tool, one
	# absent-executor tool (default check).
	_def_a = PluginDefinition.from_dict(_make_def_dict("pxa", [
		_tool("minerva_pxa_panel_echo", "panel"),
		_tool("minerva_pxa_backend_echo", "backend"),
		_tool("minerva_pxa_plain_echo"),
	]))
	# Fixture plugin B: a second plugin whose panel tool we aim at A's panel.
	_def_b = PluginDefinition.from_dict(_make_def_dict("pxb", [
		_tool("minerva_pxb_panel_probe", "panel"),
	]))
	if _def_a == null or _def_b == null:
		return false

	# Real PluginManager, off-tree (never added to the tree ⇒ _ready/_process
	# never run ⇒ no health checks, no real PluginDB touching user://).
	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		return false
	_manager = pm_script.new()
	var db := StubDB.new()
	db.definitions["pxa"] = _def_a
	db.definitions["pxb"] = _def_b
	_manager._db = db

	_audit = StubAuditLog.new()

	# Real broker. It only needs a manager for scene-request dispatch, which
	# this suite never exercises — registration/ownership paths take null.
	_broker = PluginScenePanelBroker.new(null, null, null, null)

	# Real registry wired to the real manager + broker.
	var reg_script = load(PLUGIN_TOOL_REGISTRY_SCRIPT_PATH)
	if reg_script == null:
		return false
	_registry = reg_script.new()
	_registry.plugin_manager = _manager
	_registry.audit_log = _audit
	_registry.scene_panel_broker = _broker

	var reg_a: Dictionary = _registry.register_plugin_tools("pxa", _def_a.tools)
	var reg_b: Dictionary = _registry.register_plugin_tools("pxb", _def_b.tools)
	if reg_a.has("error") or reg_b.has("error"):
		printerr("fixture tool registration failed: %s / %s" % [str(reg_a), str(reg_b)])
		return false

	# Live fixture panels, all owned by pxa, keyed by editor name.
	var echo := EchoPanel.new()
	var async_panel := AsyncPanel.new()
	var no_handler := NoHandlerPanel.new()
	var non_dict := NonDictPanel.new()
	var empty_dict := EmptyDictPanel.new()
	_panels = [echo, async_panel, no_handler, non_dict, empty_dict]
	_broker.register_panel(echo, "pxa", "PanelA", PackedStringArray())
	_broker.register_panel(async_panel, "pxa", "PanelAsync", PackedStringArray())
	_broker.register_panel(no_handler, "pxa", "PanelNoHandler", PackedStringArray())
	_broker.register_panel(non_dict, "pxa", "PanelNonDict", PackedStringArray())
	_broker.register_panel(empty_dict, "pxa", "PanelEmptyDict", PackedStringArray())
	return true


func _teardown() -> void:
	AnnotationHostRegistry._reset_for_test()
	for p in _panels:
		if is_instance_valid(p):
			p.free()
	_panels.clear()
	if _manager != null and is_instance_valid(_manager):
		_manager.free()


# ===========================================================================
# A: manifest executor field
# ===========================================================================

func test_validate_accepts_panel_and_backend() -> void:
	print("test_validate_accepts_panel_and_backend:")
	var errors_a: Array = _def_a.validate()
	var errors_b: Array = _def_b.validate()
	check("def with panel+backend+absent executors validates clean",
			errors_a.is_empty(), str(errors_a))
	check("second fixture def validates clean",
			errors_b.is_empty(), str(errors_b))


func test_registry_entries_carry_executor() -> void:
	print("test_registry_entries_carry_executor:")
	var panel_entry: Dictionary = _registry.find_tool("minerva_pxa_panel_echo")
	var backend_entry: Dictionary = _registry.find_tool("minerva_pxa_backend_echo")
	check("panel tool entry carries executor 'panel'",
			panel_entry.get("executor", "") == "panel", str(panel_entry))
	check("backend tool entry carries executor 'backend'",
			backend_entry.get("executor", "") == "backend", str(backend_entry))


func test_absent_executor_defaults_to_backend() -> void:
	print("test_absent_executor_defaults_to_backend:")
	var plain_entry: Dictionary = _registry.find_tool("minerva_pxa_plain_echo")
	check("absent executor defaults to 'backend' in the registry entry",
			plain_entry.get("executor", "") == "backend", str(plain_entry))


# ===========================================================================
# B: panel registration
# ===========================================================================

func test_panel_registered_and_resolvable() -> void:
	print("test_panel_registered_and_resolvable:")
	check("broker owns PanelA under plugin pxa",
			_broker.get_panel_owner("PanelA") == "pxa")
	var panel = _broker.get_panel_for_editor("PanelA")
	check("get_panel_for_editor resolves the live panel root",
			panel != null and panel == _panels[0])
	check("get_panel_for_editor returns null for unknown editor",
			_broker.get_panel_for_editor("NoSuchPanel") == null)
	check("list_panel_editor_names includes PanelA",
			_broker.list_panel_editor_names().has("PanelA"))


# ===========================================================================
# C: panel dispatch happy path
# ===========================================================================

func test_panel_tool_succeeds_without_subprocess() -> void:
	print("test_panel_tool_succeeds_without_subprocess:")
	# Prove the precondition: the plugin subprocess is NOT running.
	var status: Dictionary = _manager.get_plugin_status("pxa")
	check("fixture plugin pxa is not running", status.get("running", true) == false,
			str(status))

	_audit.events.clear()
	var args := {"editor_name": "PanelA", "x": 1, "s": "hello"}
	var result: Dictionary = await _registry.handle_tool_call("minerva_pxa_panel_echo", args)

	check("panel tool call succeeded (no error key)",
			not result.has("error") and not result.has("error_code"), str(result))
	check("result is the panel's dict verbatim: echoed_tool",
			result.get("echoed_tool", "") == "minerva_pxa_panel_echo", str(result))
	check("result is the panel's dict verbatim: echoed_args",
			result.get("echoed_args", {}) == args, str(result))
	check("result is the panel's dict verbatim: editor_name",
			result.get("editor_name", "") == "PanelA", str(result))
	# Verbatim also means: NO host envelope keys were injected.
	check("no success/result envelope injected around the panel dict",
			not result.has("success") and not result.has("result"), str(result))

	var dispatched: Array = _audit.find_events("tool_call_dispatched")
	check("tool_call_dispatched audit event emitted", dispatched.size() == 1)
	if dispatched.size() == 1:
		check("dispatched event carries executor 'panel'",
				dispatched[0]["detail"].get("executor", "") == "panel",
				str(dispatched[0]))
	var results: Array = _audit.find_events("tool_call_result")
	check("tool_call_result audit event emitted", results.size() == 1)
	if results.size() == 1:
		check("result event carries executor 'panel' and success true",
				results[0]["detail"].get("executor", "") == "panel"
					and results[0]["detail"].get("success", false) == true,
				str(results[0]))


# ===========================================================================
# D: structured errors
# ===========================================================================

func test_editor_name_required() -> void:
	print("test_editor_name_required:")
	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_panel_echo", {"x": 1})
	check("missing editor_name yields editor_name_required",
			result.get("error_code", "") == "editor_name_required", str(result))
	check("error names the tool",
			result.get("tool_name", "") == "minerva_pxa_panel_echo", str(result))


func test_editor_not_found_lists_known_editors() -> void:
	print("test_editor_not_found_lists_known_editors:")
	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_panel_echo", {"editor_name": "NoSuchPanel"})
	check("unknown editor yields editor_not_found",
			result.get("error_code", "") == "editor_not_found", str(result))
	var known: Array = result.get("known_editors", [])
	check("known_editors lists the registered panel names",
			known.has("PanelA") and known.has("PanelAsync"), str(result))
	check("error_message includes the known-editors list",
			result.get("error_message", "").contains("Known editors:")
				and result.get("error_message", "").contains("PanelA"),
			str(result))


func test_panel_not_owned() -> void:
	print("test_panel_not_owned:")
	# Plugin B's panel tool aimed at plugin A's panel.
	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxb_panel_probe", {"editor_name": "PanelA"})
	check("cross-plugin panel access yields panel_not_owned",
			result.get("error_code", "") == "panel_not_owned", str(result))
	check("error reports the actual owner",
			result.get("owner_plugin_id", "") == "pxa", str(result))


func test_panel_no_handler() -> void:
	print("test_panel_no_handler:")
	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_panel_echo", {"editor_name": "PanelNoHandler"})
	check("panel without handle_tool yields panel_no_handler",
			result.get("error_code", "") == "panel_no_handler", str(result))


func test_tool_unhandled_non_dict() -> void:
	print("test_tool_unhandled_non_dict:")
	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_panel_echo", {"editor_name": "PanelNonDict"})
	check("non-Dictionary return yields tool_unhandled",
			result.get("error_code", "") == "tool_unhandled", str(result))


func test_tool_unhandled_empty_dict() -> void:
	print("test_tool_unhandled_empty_dict:")
	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_panel_echo", {"editor_name": "PanelEmptyDict"})
	check("empty Dictionary return yields tool_unhandled",
			result.get("error_code", "") == "tool_unhandled", str(result))


func test_tool_executor_invalid_fails_validation() -> void:
	print("test_tool_executor_invalid_fails_validation:")
	var def_bad := PluginDefinition.from_dict(_make_def_dict("pxc", [
		_tool("minerva_pxc_bad_tool", "sidecar"),
	]))
	check("bad-executor manifest still parses (loose parse)", def_bad != null)
	if def_bad == null:
		return
	var errors: Array = def_bad.validate()
	var found := false
	for e in errors:
		if str(e).begins_with("tool_executor_invalid:minerva_pxc_bad_tool"):
			found = true
			break
	check("validate() reports tool_executor_invalid:<tool name>", found, str(errors))


func test_registry_rejects_invalid_executor() -> void:
	print("test_registry_rejects_invalid_executor:")
	# Defensive re-validation at the registry boundary (mirrors prefix check).
	var result: Dictionary = _registry.register_plugin_tools("pxc", [
		_tool("minerva_pxc_bad_tool", "sidecar"),
	])
	check("register_plugin_tools rejects invalid executor",
			str(result.get("error", "")).begins_with("tool_executor_invalid:minerva_pxc_bad_tool"),
			str(result))


# ===========================================================================
# E: async handle_tool
# ===========================================================================

func test_async_panel_tool_resolves() -> void:
	print("test_async_panel_tool_resolves:")
	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_panel_echo", {"editor_name": "PanelAsync"})
	check("async handle_tool (awaits a frame) still resolves",
			result.get("async", false) == true
				and result.get("tool", "") == "minerva_pxa_panel_echo",
			str(result))


# ===========================================================================
# F: backend regression — running check still guards backend tools
# ===========================================================================

func test_backend_tool_still_requires_running_plugin() -> void:
	print("test_backend_tool_still_requires_running_plugin:")
	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_backend_echo", {"editor_name": "PanelA"})
	check("backend tool with no subprocess yields plugin_not_running",
			result.get("error_code", "") == "plugin_not_running", str(result))


func test_absent_executor_tool_routes_to_backend() -> void:
	print("test_absent_executor_tool_routes_to_backend:")
	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_plain_echo", {})
	check("absent-executor tool also routes to the subprocess path",
			result.get("error_code", "") == "plugin_not_running", str(result))


# ===========================================================================
# G: AnnotationHostRegistry fallback
# ===========================================================================

func test_fallback_host_resolution() -> void:
	print("test_fallback_host_resolution:")
	var panel := OwnedFallbackPanel.new()
	panel.plugin_id = "pxa"
	_panels.append(panel)
	var host := StubHost.new()
	host.panel = panel
	AnnotationHostRegistry.register("FallbackEd", host)

	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_panel_echo", {"editor_name": "FallbackEd"})
	check("fallback-resolved panel executes the tool",
			result.get("via", "") == "fallback", str(result))

	AnnotationHostRegistry.deregister("FallbackEd")


func test_fallback_without_ownership_is_denied() -> void:
	print("test_fallback_without_ownership_is_denied:")
	# EchoPanel has no plugin_id property and the broker doesn't know this
	# editor — ownership is undeterminable, which must DENY (fail-safe).
	var panel := EchoPanel.new()
	_panels.append(panel)
	var host := StubHost.new()
	host.panel = panel
	AnnotationHostRegistry.register("OrphanEd", host)

	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_panel_echo", {"editor_name": "OrphanEd"})
	check("undeterminable ownership yields panel_not_owned (fail-safe)",
			result.get("error_code", "") == "panel_not_owned", str(result))
	check("owner_plugin_id is empty when ownership is unknown",
			result.get("owner_plugin_id", "x") == "", str(result))

	AnnotationHostRegistry.deregister("OrphanEd")


## H1 — a plugin stop must NOT unregister its manifest panel tools: they run
## host-side and never need the subprocess. This was the live HITL-caught
## clobber (bug 019f6d2dc767): stop wiped everything, start's non-empty guard
## then never restored, so panel tools vanished until an app reboot.
func test_stop_preserves_panel_tools() -> void:
	print("test_stop_preserves_panel_tools:")
	check("panel tool resolvable before stop",
			_registry.is_plugin_tool("minerva_pxa_panel_echo"))
	check("backend tool resolvable before stop",
			_registry.is_plugin_tool("minerva_pxa_backend_echo"))

	_registry.on_plugin_stopped("pxa")

	check("panel tool STILL resolvable after stop",
			_registry.is_plugin_tool("minerva_pxa_panel_echo"))
	check("backend tool dropped by stop",
			not _registry.is_plugin_tool("minerva_pxa_backend_echo"))

	var result: Dictionary = await _registry.handle_tool_call(
			"minerva_pxa_panel_echo", {"editor_name": "PanelA"})
	check("panel tool still EXECUTES after stop",
			result.get("echoed_tool", "") == "minerva_pxa_panel_echo", str(result))


## H2 — on_plugin_started must re-register manifest tools whenever any are
## missing (the old guard bailed on ANY non-empty set, masking the clobber).
func test_started_reregisters_missing_manifest_tools() -> void:
	print("test_started_reregisters_missing_manifest_tools:")
	check("backend tool still missing (precondition)",
			not _registry.is_plugin_tool("minerva_pxa_backend_echo"))

	_registry.on_plugin_started("pxa")

	check("backend manifest tool restored by started hook",
			_registry.is_plugin_tool("minerva_pxa_backend_echo"))
	check("panel tool survived the started re-register",
			_registry.is_plugin_tool("minerva_pxa_panel_echo"))


## H3 — backend discovery with an empty tools/list (the churn moment that
## killed the live session's panel tools) must preserve panel entries and drop
## only backend ones.
func test_backend_discovery_empty_preserves_panel_tools() -> void:
	print("test_backend_discovery_empty_preserves_panel_tools:")
	var ConnScript = load("res://Scripts/Services/MCP/MCPServerConnection.gd")
	if ConnScript == null:
		check("MCPServerConnection loadable for discovery churn", false)
		return
	var conn = ConnScript.new()
	# A fresh connection reports no tools — exactly the churn shape that used
	# to trigger the full unregister.
	var result: Dictionary = await _registry.register_backend_tools("pxa", conn)
	check("empty backend discovery returns ok", not result.has("error"), str(result))
	check("panel tool survives empty backend discovery",
			_registry.is_plugin_tool("minerva_pxa_panel_echo"))
	check("backend tool dropped by empty discovery",
			not _registry.is_plugin_tool("minerva_pxa_backend_echo"))
	if conn != null and conn is Object and not (conn is RefCounted):
		conn.free()
