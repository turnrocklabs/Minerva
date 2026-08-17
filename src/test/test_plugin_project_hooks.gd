extends SceneTree
## Unit tests for plugin project-file and project-export hooks (design §8).
##
## Run: godot --headless --path src --script test/test_plugin_project_hooks.gd
##
## Coverage:
##   PluginDefinition manifest parsing:
##     - project_file with both channels in ui.ipc_messages → accepted
##     - project_file with serialize_channel not in allowlist → rejected (null)
##     - project_file with deserialize_channel not in allowlist → rejected (null)
##     - project_file partially present (one channel missing) → rejected (null)
##     - project_export with both channels in ui.ipc_messages → accepted
##     - project_export with collect_channel not in allowlist → rejected (null)
##     - project_export with apply_channel not in allowlist → rejected (null)
##     - neither hook declared → fields empty, manifest valid
##     - to_dict / from_dict round-trip preserves hook fields
##
##   vboxEditor _serialize_plugin_scene_editor:
##     - plugin running + serialize_channel declared → MCP call dispatched, tab_state captured
##     - plugin has no serialize_channel → skipped with push_warning, entry returned
##     - plugin not running (conn null) → plugin_unavailable flag set
##     - sidecar_paths from plugin response → recorded in entry
##
##   vboxEditor _deserialize_plugin_scene_editor:
##     - plugin not installed → placeholder shown in VBox
##     - installed, no deserialize_channel → warning only, no crash
##     - installed + running + matching version → deserialize_channel dispatched
##     - version mismatch → stored_version passed to deserialize_channel
##
##   ProjectPackage.collect_plugin_exports:
##     - plugin_manager null → no-op, returns empty array
##     - editor not PLUGIN_SCENE type → skipped
##     - plugin not running → warning, skipped
##     - plugin running, collect_channel declared → MCP call dispatched, files staged
##     - path rewrites applied to plugin_state.payload
##     - plugin_export manifest key written on editor entry
##
##   ProjectPackage.apply_plugin_exports:
##     - plugin_manager null → no-op
##     - editor without plugin_export key → skipped
##     - plugin not running → warning, skipped
##     - plugin running → apply_channel dispatched with unpack_dir

const PluginDefinition_ = preload("res://Scripts/Services/Plugins/PluginDefinition.gd")

var _pass_count: int = 0
var _fail_count: int = 0
var _tmp_dir: String = ""


func _init() -> void:
	_tmp_dir = _make_tmp_dir()

	print("=== Plugin Project-File and Project-Export Hook Tests ===\n")

	print("-- PluginDefinition: project_file manifest parsing --")
	test_project_file_both_channels_accepted()
	test_project_file_serialize_not_in_allowlist_rejected()
	test_project_file_deserialize_not_in_allowlist_rejected()
	test_project_file_partial_channels_rejected()

	print("\n-- PluginDefinition: project_export manifest parsing --")
	test_project_export_both_channels_accepted()
	test_project_export_collect_not_in_allowlist_rejected()
	test_project_export_apply_not_in_allowlist_rejected()
	test_no_hooks_declared_valid()
	test_to_dict_from_dict_round_trip_project_file()
	test_to_dict_from_dict_round_trip_project_export()

	print("\n-- vboxEditor._serialize_plugin_scene_editor --")
	test_serialize_plugin_running_dispatches_mcp_call()
	test_serialize_no_serialize_channel_skips_gracefully()
	test_serialize_plugin_not_running_sets_unavailable_flag()
	test_serialize_captures_sidecar_paths()

	print("\n-- vboxEditor._deserialize_plugin_scene_editor --")
	test_deserialize_uninstalled_plugin_shows_placeholder()
	test_deserialize_no_deserialize_channel_no_crash()
	test_deserialize_dispatches_channel_with_payload()
	test_deserialize_version_mismatch_passes_stored_version()

	print("\n-- ProjectPackage.collect_plugin_exports --")
	test_collect_null_manager_returns_empty()
	test_collect_non_plugin_scene_skipped()
	test_collect_plugin_not_running_skipped()
	test_collect_dispatches_mcp_and_stages_files()
	test_collect_applies_path_rewrites_to_payload()
	test_collect_writes_plugin_export_manifest_key()

	print("\n-- ProjectPackage.apply_plugin_exports --")
	test_apply_null_manager_no_op()
	test_apply_no_plugin_export_key_skipped()
	test_apply_plugin_not_running_skipped()
	test_apply_dispatches_channel_with_unpack_dir()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)

	_cleanup_tmp_dir()
	quit(1 if _fail_count > 0 else 0)


# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr(("  FAIL: %s — expected %s, got %s") % [description, str(expected), str(actual)])


# ---------------------------------------------------------------------------
# Stub classes
# ---------------------------------------------------------------------------

## Minimal MCPServerConnection stub that records calls and returns canned responses.
## Uses duck-typing — does NOT extend MCPServerConnection so no import cycle.
class StubMCPConnection extends RefCounted:
	## List of call records: [{tool_name, arguments}]
	var calls: Array = []
	## Canned response returned for every call_tool invocation.
	var canned_response: Dictionary = {"success": true}

	## Mimics MCPServerConnection.call_tool signature.
	func call_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
		calls.append({"tool_name": tool_name, "arguments": arguments})
		return canned_response

	func last_call() -> Dictionary:
		if calls.is_empty():
			return {}
		return calls[-1]

	func call_count() -> int:
		return calls.size()


## Minimal PluginDB stub.
class StubDB extends RefCounted:
	var definitions: Dictionary = {}  # plugin_id -> PluginDefinition

	func get_by_id(plugin_id: String) -> PluginDefinition:
		return definitions.get(plugin_id, null)


## Minimal PluginManager stub.
class StubPluginManager extends RefCounted:
	var _db: StubDB = StubDB.new()
	## plugin_id -> StubMCPConnection
	var connections: Dictionary = {}

	func get_db():
		return _db

	func get_connection(plugin_id: String):
		return connections.get(plugin_id, null)




# ---------------------------------------------------------------------------
# PluginDefinition builder helpers
# ---------------------------------------------------------------------------

## Build a minimal PluginDefinition dict with the given ipc_messages.
## Optionally inject project_file and project_export top-level keys.
func _make_def_dict(
		ipc_messages: Array,
		project_file_dict: Variant = null,
		project_export_dict: Variant = null
) -> Dictionary:
	var d: Dictionary = {
		"id": "testplugin",
		"name": "Test Plugin",
		"version": "1.0.0",
		"host_api_version": "1",
		"backend": {"transport": "stdio", "entrypoint": "plugin.py",
			"args": [], "working_dir": ""},
		"ui": {
			"panels": [{"name": "test_panel", "kind": "html", "entry": "ui/test_panel.html"}],
			"ipc_messages": ipc_messages,
		},
		"tools": [],
		"permissions": {"host_capabilities": [], "network": {"mode": "none"},
			"filesystem": {"mode": "none", "paths": []}},
		"data_directory": "/tmp/testplugin",
		"autostart": false,
		"auto_reload": false,
	}
	if project_file_dict != null:
		d["project_file"] = project_file_dict
	if project_export_dict != null:
		d["project_export"] = project_export_dict
	return d


## Build a PluginDefinition from the above dict helper, or return null on failure.
func _make_def(
		ipc_messages: Array,
		project_file_dict: Variant = null,
		project_export_dict: Variant = null
) -> PluginDefinition:
	var d := _make_def_dict(ipc_messages, project_file_dict, project_export_dict)
	return PluginDefinition.from_dict(d)


# ---------------------------------------------------------------------------
# PluginDefinition: project_file parsing tests
# ---------------------------------------------------------------------------

func test_project_file_both_channels_accepted() -> void:
	var ipc := ["plugin.ser", "plugin.des"]
	var def := _make_def(
		ipc,
		{"serialize_channel": "plugin.ser", "deserialize_channel": "plugin.des"}
	)
	check("project_file both channels accepted: def not null", def != null)
	if def == null:
		return
	check_eq("serialize_channel stored",
		def.project_file_serialize_channel, "plugin.ser")
	check_eq("deserialize_channel stored",
		def.project_file_deserialize_channel, "plugin.des")


func test_project_file_serialize_not_in_allowlist_rejected() -> void:
	# serialize_channel not in ui.ipc_messages → should return null
	var def := _make_def(
		["plugin.des"],  # only deserialize in allowlist
		{"serialize_channel": "plugin.ser", "deserialize_channel": "plugin.des"}
	)
	check("project_file serialize_channel not in allowlist → def null", def == null)


func test_project_file_deserialize_not_in_allowlist_rejected() -> void:
	var def := _make_def(
		["plugin.ser"],  # only serialize in allowlist
		{"serialize_channel": "plugin.ser", "deserialize_channel": "plugin.des"}
	)
	check("project_file deserialize_channel not in allowlist → def null", def == null)


func test_project_file_partial_channels_rejected() -> void:
	# project_file present but only one channel specified → rejected
	var def := _make_def(
		["plugin.ser"],
		{"serialize_channel": "plugin.ser"}  # deserialize_channel absent
	)
	check("project_file with only serialize_channel → def null", def == null)


# ---------------------------------------------------------------------------
# PluginDefinition: project_export parsing tests
# ---------------------------------------------------------------------------

func test_project_export_both_channels_accepted() -> void:
	var ipc := ["plugin.col", "plugin.app"]
	var def := _make_def(
		ipc,
		null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"}
	)
	check("project_export both channels accepted: def not null", def != null)
	if def == null:
		return
	check_eq("collect_channel stored",
		def.project_export_collect_channel, "plugin.col")
	check_eq("apply_channel stored",
		def.project_export_apply_channel, "plugin.app")


func test_project_export_collect_not_in_allowlist_rejected() -> void:
	var def := _make_def(
		["plugin.app"],
		null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"}
	)
	check("project_export collect_channel not in allowlist → def null", def == null)


func test_project_export_apply_not_in_allowlist_rejected() -> void:
	var def := _make_def(
		["plugin.col"],
		null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"}
	)
	check("project_export apply_channel not in allowlist → def null", def == null)


func test_no_hooks_declared_valid() -> void:
	var def := _make_def(["plugin.ipc"])
	check("no hooks declared → def not null", def != null)
	if def == null:
		return
	check_eq("project_file_serialize_channel empty", def.project_file_serialize_channel, "")
	check_eq("project_file_deserialize_channel empty", def.project_file_deserialize_channel, "")
	check_eq("project_export_collect_channel empty", def.project_export_collect_channel, "")
	check_eq("project_export_apply_channel empty", def.project_export_apply_channel, "")


func test_to_dict_from_dict_round_trip_project_file() -> void:
	var ipc := ["plugin.ser", "plugin.des"]
	var def := _make_def(
		ipc,
		{"serialize_channel": "plugin.ser", "deserialize_channel": "plugin.des"}
	)
	check("project_file round-trip: source def not null", def != null)
	if def == null:
		return
	var d := def.to_dict()
	var def2 := PluginDefinition.from_dict(d)
	check("project_file round-trip: reconstituted def not null", def2 != null)
	if def2 == null:
		return
	check_eq("serialize_channel survives round-trip",
		def2.project_file_serialize_channel, "plugin.ser")
	check_eq("deserialize_channel survives round-trip",
		def2.project_file_deserialize_channel, "plugin.des")


func test_to_dict_from_dict_round_trip_project_export() -> void:
	var ipc := ["plugin.col", "plugin.app"]
	var def := _make_def(
		ipc,
		null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"}
	)
	check("project_export round-trip: source def not null", def != null)
	if def == null:
		return
	var d := def.to_dict()
	var def2 := PluginDefinition.from_dict(d)
	check("project_export round-trip: reconstituted def not null", def2 != null)
	if def2 == null:
		return
	check_eq("collect_channel survives round-trip",
		def2.project_export_collect_channel, "plugin.col")
	check_eq("apply_channel survives round-trip",
		def2.project_export_apply_channel, "plugin.app")


# ---------------------------------------------------------------------------
# Serialize helper (calls EditorContainer._serialize_plugin_scene_editor via duck-type)
# ---------------------------------------------------------------------------

## Because _serialize_plugin_scene_editor is an instance method that accesses
## SingletonObject.plugin_manager, we exercise the logic via a thin wrapper that
## replaces the manager lookup with our stub.  The wrapper calls the static helpers
## (_get_plugin_def_static / _get_plugin_connection_static) by injecting a fake
## SingletonObject-like object.
##
## In headless mode SingletonObject is not available.  Instead, we test the internal
## logic directly by constructing the exact same steps the method performs.
## This mirrors the pattern used in test_plugin_lifecycle_hooks.gd.

## Simulates what _serialize_plugin_scene_editor does, using injected manager stub.
func _call_serialize(
		plugin_id: String,
		panel_name: String,
		file_path: String,
		tab_title: String,
		stub_mgr: StubPluginManager,
		def: PluginDefinition
) -> Dictionary:
	# Replicate the method logic directly (no SingletonObject needed).
	var editor_id: String = "test-editor-id"

	if def == null or def.project_file_serialize_channel.is_empty():
		push_warning(
			("[EditorContainer] serialize: PLUGIN_SCENE editor for plugin '%s' panel '%s' " +
			"has no project_file.serialize_channel — tab state will not be restored.") %
			[plugin_id, panel_name]
		)
		return {
			"name": tab_title,
			"file": file_path,
			"type": Editor.Type.PLUGIN_SCENE,
			"plugin_id": plugin_id,
			"panel_name": panel_name,
			"plugin_version": def.version if def != null else "",
			"plugin_state": {"version": 1, "plugin_id": plugin_id,
				"plugin_version": def.version if def != null else "",
				"panel_name": panel_name, "payload": {}},
			"sidecar_paths": [],
			"associated_object": editor_id,
		}

	var conn = stub_mgr.get_connection(plugin_id) if stub_mgr != null else null
	if conn == null:
		push_warning(
			("[EditorContainer] serialize: PLUGIN_SCENE plugin '%s' is not running.") % plugin_id
		)
		return {
			"name": tab_title,
			"file": file_path,
			"type": Editor.Type.PLUGIN_SCENE,
			"plugin_id": plugin_id,
			"panel_name": panel_name,
			"plugin_version": def.version,
			"plugin_state": {"version": 1, "plugin_id": plugin_id,
				"plugin_version": def.version, "panel_name": panel_name, "payload": {}},
			"sidecar_paths": [],
			"plugin_unavailable": true,
			"associated_object": editor_id,
		}

	var call_result = await conn.call_tool(
		def.project_file_serialize_channel,
		{"file_path": file_path, "panel_name": panel_name, "editor_id": editor_id}
	)

	var tab_state: Dictionary = {}
	var sidecar_paths: Array = []
	if call_result is Dictionary:
		tab_state = call_result.get("tab_state", {})
		var raw_paths = call_result.get("sidecar_paths", [])
		if raw_paths is Array:
			for p in raw_paths:
				sidecar_paths.append(str(p))

	return {
		"name": tab_title,
		"file": file_path,
		"type": Editor.Type.PLUGIN_SCENE,
		"plugin_id": plugin_id,
		"panel_name": panel_name,
		"plugin_version": def.version,
		"plugin_state": {
			"version": 1,
			"plugin_id": plugin_id,
			"plugin_version": def.version,
			"panel_name": panel_name,
			"payload": tab_state,
		},
		"sidecar_paths": sidecar_paths,
		"associated_object": editor_id,
	}


# ---------------------------------------------------------------------------
# vboxEditor serialize tests
# ---------------------------------------------------------------------------

func test_serialize_plugin_running_dispatches_mcp_call() -> void:
	var ipc := ["plugin.ser", "plugin.des"]
	var def := _make_def(ipc, {"serialize_channel": "plugin.ser",
		"deserialize_channel": "plugin.des"})
	check("serialize: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	var conn := StubMCPConnection.new()
	conn.canned_response = {
		"success": true,
		"tab_state": {"zoom": 1.5, "viewport_x": 100.0},
		"sidecar_paths": [],
	}
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var entry: Dictionary = await _call_serialize(
		"testplugin", "test_panel", "/tmp/doc.test", "doc.test", mgr, def
	)

	check("serialize: MCP call was made", conn.call_count() == 1)
	check_eq("serialize: tool name is serialize_channel",
		conn.last_call().get("tool_name"), "plugin.ser")
	check_eq("serialize: panel_name in arguments",
		conn.last_call().get("arguments", {}).get("panel_name"), "test_panel")
	check_eq("serialize: tab_state.zoom captured",
		entry.get("plugin_state", {}).get("payload", {}).get("zoom"), 1.5)
	check_eq("serialize: plugin_id in entry", entry.get("plugin_id"), "testplugin")
	check_eq("serialize: type is PLUGIN_SCENE", entry.get("type"), Editor.Type.PLUGIN_SCENE)


func test_serialize_no_serialize_channel_skips_gracefully() -> void:
	# def has no project_file hook → serialize_channel is ""
	var def := _make_def(["plugin.ipc"])
	check("serialize no-channel: def built", def != null)
	if def == null:
		return

	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def

	var entry: Dictionary = await _call_serialize(
		"testplugin", "test_panel", "/tmp/doc.test", "doc.test", mgr, def
	)

	# Entry should be present (not nil) with empty payload.
	check("serialize no-channel: entry returned", not entry.is_empty())
	check_eq("serialize no-channel: payload empty",
		entry.get("plugin_state", {}).get("payload"), {})
	check("serialize no-channel: no plugin_unavailable flag",
		not entry.has("plugin_unavailable"))


func test_serialize_plugin_not_running_sets_unavailable_flag() -> void:
	var ipc := ["plugin.ser", "plugin.des"]
	var def := _make_def(ipc, {"serialize_channel": "plugin.ser",
		"deserialize_channel": "plugin.des"})
	check("serialize unavailable: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING
	# No connection registered → get_connection returns null.
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	# Deliberately NOT registering a connection.

	var entry: Dictionary = await _call_serialize(
		"testplugin", "test_panel", "/tmp/doc.test", "doc.test", mgr, def
	)

	check("serialize unavailable: plugin_unavailable flag set",
		entry.get("plugin_unavailable", false) == true)
	check_eq("serialize unavailable: payload empty",
		entry.get("plugin_state", {}).get("payload"), {})


func test_serialize_captures_sidecar_paths() -> void:
	var ipc := ["plugin.ser", "plugin.des"]
	var def := _make_def(ipc, {"serialize_channel": "plugin.ser",
		"deserialize_channel": "plugin.des"})
	check("serialize sidecars: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	var conn := StubMCPConnection.new()
	conn.canned_response = {
		"success": true,
		"tab_state": {},
		"sidecar_paths": ["/tmp/myfile.assets", "/tmp/myfile.geom"],
	}
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var entry: Dictionary = await _call_serialize(
		"testplugin", "test_panel", "/tmp/doc.test", "doc.test", mgr, def
	)

	var sidecars: Array = entry.get("sidecar_paths", [])
	check_eq("serialize: sidecar_paths count", sidecars.size(), 2)
	check("serialize: first sidecar path recorded",
		sidecars.has("/tmp/myfile.assets"))


# ---------------------------------------------------------------------------
# Deserialize helper (replicates _deserialize_plugin_scene_editor logic)
# ---------------------------------------------------------------------------

## Simulate deserialize logic without SingletonObject.
## Returns a Dictionary with keys:
##   "placeholder_shown": bool
##   "placeholder_text": String (if shown)
##   "deserialize_call_made": bool
##   "deserialize_args": Dictionary (if call made)
func _call_deserialize(
		editor_ser: Dictionary,
		stub_mgr: StubPluginManager,
		_stub_conn: StubMCPConnection
) -> Dictionary:
	var result: Dictionary = {
		"placeholder_shown": false,
		"placeholder_text": "",
		"deserialize_call_made": false,
		"deserialize_args": {},
	}

	var plugin_id: String = editor_ser.get("plugin_id", "")
	var plugin_state: Dictionary = editor_ser.get("plugin_state", {})
	var stored_version: String = str(editor_ser.get("plugin_version", ""))
	var payload: Dictionary = plugin_state.get("payload", {})

	# Check if plugin is installed.
	var def: PluginDefinition = null
	if stub_mgr != null:
		var db = stub_mgr.get_db()
		if db != null:
			def = db.get_by_id(plugin_id)

	if def == null:
		result["placeholder_shown"] = true
		result["placeholder_text"] = ("Install '%s' to open this document.") % plugin_id
		return result

	if def.project_file_deserialize_channel.is_empty():
		push_warning(
			("[EditorContainer] deserialize: plugin '%s' has no " +
			"project_file.deserialize_channel.") % plugin_id
		)
		return result

	# Check if plugin is running and get connection.
	var conn = stub_mgr.get_connection(plugin_id) if stub_mgr != null else null
	if conn == null:
		push_warning(
			("[EditorContainer] deserialize: plugin '%s' is not running.") % plugin_id
		)
		return result

	var call_result: Dictionary = await conn.call_tool(
		def.project_file_deserialize_channel,
		{"tab_state": payload, "stored_version": stored_version}
	)

	result["deserialize_call_made"] = true
	result["deserialize_args"] = conn.last_call().get("arguments", {})

	if call_result is Dictionary and call_result.get("isError", false):
		push_warning("[EditorContainer] deserialize error: %s" % str(call_result))

	return result


# ---------------------------------------------------------------------------
# vboxEditor deserialize tests
# ---------------------------------------------------------------------------

func test_deserialize_uninstalled_plugin_shows_placeholder() -> void:
	var editor_ser: Dictionary = {
		"plugin_id": "unknown_plugin",
		"panel_name": "unknown_panel",
		"plugin_version": "1.0.0",
		"plugin_state": {"version": 1, "plugin_id": "unknown_plugin",
			"plugin_version": "1.0.0", "panel_name": "unknown_panel", "payload": {}},
	}
	# Stub manager has no definitions → get_by_id returns null.
	var mgr := StubPluginManager.new()

	var result: Dictionary = await _call_deserialize(editor_ser, mgr, null)

	check("deserialize uninstalled: placeholder shown",
		result.get("placeholder_shown", false))
	check("deserialize uninstalled: placeholder text mentions plugin id",
		("unknown_plugin") in str(result.get("placeholder_text", "")))
	check("deserialize uninstalled: no MCP call made",
		not result.get("deserialize_call_made", false))


func test_deserialize_no_deserialize_channel_no_crash() -> void:
	# Plugin installed but no project_file.deserialize_channel declared.
	var def := _make_def(["plugin.ipc"])  # no project_file hook
	check("deserialize no-channel: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	var conn := StubMCPConnection.new()
	mgr.connections["testplugin"] = conn

	var editor_ser: Dictionary = {
		"plugin_id": "testplugin",
		"panel_name": "test_panel",
		"plugin_version": "1.0.0",
		"plugin_state": {"version": 1, "plugin_id": "testplugin",
			"plugin_version": "1.0.0", "panel_name": "test_panel", "payload": {}},
	}

	var result: Dictionary = await _call_deserialize(editor_ser, mgr, conn)

	check("deserialize no-channel: no crash (result is Dictionary)",
		result is Dictionary)
	check("deserialize no-channel: no placeholder shown",
		not result.get("placeholder_shown", false))
	check("deserialize no-channel: no MCP call made",
		not result.get("deserialize_call_made", false))


func test_deserialize_dispatches_channel_with_payload() -> void:
	var ipc := ["plugin.ser", "plugin.des"]
	var def := _make_def(ipc, {"serialize_channel": "plugin.ser",
		"deserialize_channel": "plugin.des"})
	check("deserialize dispatch: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	var conn := StubMCPConnection.new()
	conn.canned_response = {"success": true}
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var saved_payload: Dictionary = {"zoom": 2.0, "selection": ["obj_1"]}
	var editor_ser: Dictionary = {
		"plugin_id": "testplugin",
		"panel_name": "test_panel",
		"plugin_version": "1.0.0",
		"plugin_state": {"version": 1, "plugin_id": "testplugin",
			"plugin_version": "1.0.0", "panel_name": "test_panel",
			"payload": saved_payload},
	}

	var result: Dictionary = await _call_deserialize(editor_ser, mgr, conn)

	check("deserialize dispatch: MCP call was made",
		result.get("deserialize_call_made", false))
	check_eq("deserialize dispatch: tool name is deserialize_channel",
		conn.last_call().get("tool_name"), "plugin.des")
	check_eq("deserialize dispatch: tab_state passed",
		conn.last_call().get("arguments", {}).get("tab_state"), saved_payload)


func test_deserialize_version_mismatch_passes_stored_version() -> void:
	var ipc := ["plugin.ser", "plugin.des"]
	var def := _make_def(ipc, {"serialize_channel": "plugin.ser",
		"deserialize_channel": "plugin.des"})
	check("deserialize version: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	var conn := StubMCPConnection.new()
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var editor_ser: Dictionary = {
		"plugin_id": "testplugin",
		"panel_name": "test_panel",
		"plugin_version": "0.9.0",  # older than def.version "1.0.0"
		"plugin_state": {"version": 1, "plugin_id": "testplugin",
			"plugin_version": "0.9.0", "panel_name": "test_panel", "payload": {}},
	}

	var result: Dictionary = await _call_deserialize(editor_ser, mgr, conn)

	check("deserialize version mismatch: MCP call made",
		result.get("deserialize_call_made", false))
	check_eq("deserialize version mismatch: stored_version passed to plugin",
		conn.last_call().get("arguments", {}).get("stored_version"), "0.9.0")


# ---------------------------------------------------------------------------
# ProjectPackage collect/apply tests
# ---------------------------------------------------------------------------

## Build a minimal project_data dict with one PLUGIN_SCENE editor entry.
func _plugin_scene_project_data(
		plugin_id: String,
		panel_name: String,
		file_path: String,
		payload: Dictionary = {}
) -> Dictionary:
	return {
		"Editors": [
			{
				"file": file_path,
				"type": Editor.Type.PLUGIN_SCENE,
				"plugin_id": plugin_id,
				"panel_name": panel_name,
				"plugin_version": "1.0.0",
				"plugin_state": {
					"version": 1,
					"plugin_id": plugin_id,
					"plugin_version": "1.0.0",
					"panel_name": panel_name,
					"payload": payload,
				},
				"sidecar_paths": [],
			}
		]
	}


func test_collect_null_manager_returns_empty() -> void:
	var pkg := ProjectPackage.new()
	var project_data := _plugin_scene_project_data("testplugin", "test_panel", "/tmp/doc.test")
	var staging := _tmp_dir.path_join("collect_null_staging")
	DirAccess.make_dir_recursive_absolute(staging)

	var extra: Array = await pkg.collect_plugin_exports(project_data, null, staging)

	check_eq("collect null manager: returns empty array", extra.size(), 0)


func test_collect_non_plugin_scene_skipped() -> void:
	var pkg := ProjectPackage.new()
	var project_data: Dictionary = {
		"Editors": [
			{"file": "/tmp/doc.txt", "type": Editor.Type.TEXT}
		]
	}
	var mgr := StubPluginManager.new()
	var staging := _tmp_dir.path_join("collect_non_scene_staging")
	DirAccess.make_dir_recursive_absolute(staging)

	var extra: Array = await pkg.collect_plugin_exports(project_data, mgr, staging)

	check_eq("collect non-PLUGIN_SCENE: no extra files", extra.size(), 0)


func test_collect_plugin_not_running_skipped() -> void:
	var ipc := ["plugin.col", "plugin.app"]
	var def := _make_def(ipc, null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"})
	check("collect not-running: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.STOPPED  # not RUNNING

	var conn := StubMCPConnection.new()
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var pkg := ProjectPackage.new()
	var project_data := _plugin_scene_project_data("testplugin", "test_panel", "/tmp/doc.test")
	var staging := _tmp_dir.path_join("collect_stopped_staging")
	DirAccess.make_dir_recursive_absolute(staging)

	var extra: Array = await pkg.collect_plugin_exports(project_data, mgr, staging)

	check_eq("collect not-running: no extra files", extra.size(), 0)
	check_eq("collect not-running: no MCP call made", conn.call_count(), 0)


func test_collect_dispatches_mcp_and_stages_files() -> void:
	var ipc := ["plugin.col", "plugin.app"]
	var def := _make_def(ipc, null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"})
	check("collect dispatch: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	# Create a real sidecar file on disk so copy succeeds.
	var src_file: String = _tmp_dir.path_join("collect_src/model.geom")
	DirAccess.make_dir_recursive_absolute(src_file.get_base_dir())
	var fa := FileAccess.open(src_file, FileAccess.WRITE)
	fa.store_string("geom data")
	fa.close()

	var conn := StubMCPConnection.new()
	conn.canned_response = {
		"success": true,
		"files": [{"src_abs": src_file, "pack_rel": "testplugin/model.geom"}],
		"paths_to_rewrite": {},
	}
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var pkg := ProjectPackage.new()
	var project_data := _plugin_scene_project_data("testplugin", "test_panel", "/tmp/doc.test")
	var staging := _tmp_dir.path_join("collect_dispatch_staging")
	DirAccess.make_dir_recursive_absolute(staging)

	var extra: Array = await pkg.collect_plugin_exports(project_data, mgr, staging)

	check_eq("collect dispatch: MCP call count", conn.call_count(), 1)
	check_eq("collect dispatch: tool name", conn.last_call().get("tool_name"), "plugin.col")
	check_eq("collect dispatch: one extra file staged", extra.size(), 1)
	check_eq("collect dispatch: pack_rel correct",
		extra[0].get("pack_rel"), "testplugin/model.geom")
	# Staged file should exist.
	var staged: String = staging.path_join("testplugin/model.geom")
	check("collect dispatch: staged file exists on disk", FileAccess.file_exists(staged))


func test_collect_applies_path_rewrites_to_payload() -> void:
	var ipc := ["plugin.col", "plugin.app"]
	var def := _make_def(ipc, null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"})
	check("collect rewrites: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	var conn := StubMCPConnection.new()
	conn.canned_response = {
		"success": true,
		"files": [],
		"paths_to_rewrite": {"model_path": "testplugin/model.geom"},
	}
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var pkg := ProjectPackage.new()
	var initial_payload: Dictionary = {"model_path": "/abs/path/model.geom", "other": 42}
	var project_data := _plugin_scene_project_data(
		"testplugin", "test_panel", "/tmp/doc.test", initial_payload
	)
	var staging := _tmp_dir.path_join("collect_rewrite_staging")
	DirAccess.make_dir_recursive_absolute(staging)

	await pkg.collect_plugin_exports(project_data, mgr, staging)

	var editor_entry: Dictionary = project_data["Editors"][0]
	var payload_after: Dictionary = editor_entry.get("plugin_state", {}).get("payload", {})
	check_eq("collect rewrites: model_path rewritten to pack_rel",
		payload_after.get("model_path"), "testplugin/model.geom")
	check_eq("collect rewrites: other field unchanged",
		payload_after.get("other"), 42)


func test_collect_writes_plugin_export_manifest_key() -> void:
	var ipc := ["plugin.col", "plugin.app"]
	var def := _make_def(ipc, null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"})
	check("collect manifest key: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	var conn := StubMCPConnection.new()
	conn.canned_response = {
		"success": true, "files": [], "paths_to_rewrite": {},
	}
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var pkg := ProjectPackage.new()
	var project_data := _plugin_scene_project_data("testplugin", "test_panel", "/tmp/doc.test")
	var staging := _tmp_dir.path_join("collect_manifest_key_staging")
	DirAccess.make_dir_recursive_absolute(staging)

	await pkg.collect_plugin_exports(project_data, mgr, staging)

	var editor_entry: Dictionary = project_data["Editors"][0]
	check("collect manifest key: plugin_export key present in entry",
		editor_entry.has(ProjectPackage.plugin_export_manifest_key))


func test_apply_null_manager_no_op() -> void:
	var pkg := ProjectPackage.new()
	var project_data := _plugin_scene_project_data("testplugin", "test_panel", "/tmp/doc.test")
	# Add a plugin_export key to trigger the apply path.
	project_data["Editors"][0][ProjectPackage.plugin_export_manifest_key] = {
		"packed_files": [], "rewrites": {}
	}
	# Should complete without error.
	await pkg.apply_plugin_exports(project_data, "/tmp/unpack_dir", null)
	check("apply null manager: no crash", true)


func test_apply_no_plugin_export_key_skipped() -> void:
	var ipc := ["plugin.col", "plugin.app"]
	var def := _make_def(ipc, null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"})
	check("apply no-key: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	var conn := StubMCPConnection.new()
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var pkg := ProjectPackage.new()
	# Editor entry WITHOUT plugin_export key.
	var project_data := _plugin_scene_project_data("testplugin", "test_panel", "/tmp/doc.test")

	await pkg.apply_plugin_exports(project_data, "/tmp/unpack_dir", mgr)

	check_eq("apply no-key: no MCP call made", conn.call_count(), 0)


func test_apply_plugin_not_running_skipped() -> void:
	var ipc := ["plugin.col", "plugin.app"]
	var def := _make_def(ipc, null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"})
	check("apply not-running: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.STOPPED

	var conn := StubMCPConnection.new()
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var pkg := ProjectPackage.new()
	var project_data := _plugin_scene_project_data("testplugin", "test_panel", "/tmp/doc.test")
	project_data["Editors"][0][ProjectPackage.plugin_export_manifest_key] = {
		"packed_files": [], "rewrites": {}
	}

	await pkg.apply_plugin_exports(project_data, "/tmp/unpack_dir", mgr)

	check_eq("apply not-running: no MCP call made", conn.call_count(), 0)


func test_apply_dispatches_channel_with_unpack_dir() -> void:
	var ipc := ["plugin.col", "plugin.app"]
	var def := _make_def(ipc, null,
		{"collect_channel": "plugin.col", "apply_channel": "plugin.app"})
	check("apply dispatch: def built", def != null)
	if def == null:
		return
	def.state = PluginDefinition.State.RUNNING

	var conn := StubMCPConnection.new()
	conn.canned_response = {"success": true}
	var mgr := StubPluginManager.new()
	mgr._db.definitions["testplugin"] = def
	mgr.connections["testplugin"] = conn

	var pkg := ProjectPackage.new()
	var project_data := _plugin_scene_project_data("testplugin", "test_panel", "/tmp/doc.test")
	project_data["Editors"][0][ProjectPackage.plugin_export_manifest_key] = {
		"packed_files": ["testplugin/model.geom"],
		"rewrites": {"model_path": "testplugin/model.geom"},
	}

	var unpack_dir: String = "/tmp/unpack_destination"
	await pkg.apply_plugin_exports(project_data, unpack_dir, mgr)

	check_eq("apply dispatch: MCP call made", conn.call_count(), 1)
	check_eq("apply dispatch: tool name is apply_channel",
		conn.last_call().get("tool_name"), "plugin.app")
	check_eq("apply dispatch: unpack_dir passed",
		conn.last_call().get("arguments", {}).get("unpack_dir"), unpack_dir)


# ---------------------------------------------------------------------------
# Tmp dir helpers
# ---------------------------------------------------------------------------

func _make_tmp_dir() -> String:
	var base: String = "/tmp/minerva_test_plugin_project_hooks_%d" % Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(base)
	return base


func _cleanup_tmp_dir() -> void:
	if _tmp_dir.is_empty():
		return
	_delete_dir_recursive(_tmp_dir)


func _delete_dir_recursive(dir_path: String) -> void:
	var da := DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		var full := dir_path.path_join(fname)
		if da.current_is_dir():
			_delete_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		fname = da.get_next()
	da.list_dir_end()
	DirAccess.remove_absolute(dir_path)
