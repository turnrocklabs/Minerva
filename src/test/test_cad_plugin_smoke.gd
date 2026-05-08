extends SceneTree
## CAD plugin lifecycle smoke test — broker-DCR regression baseline.
##
## Run: godot --headless --path src --script test/test_cad_plugin_smoke.gd
##
## Tracks docket: minerva 019e08fdd00c72a19e1cf8e6fde6a0b0
## Parent DCR:    minerva 019df8e2d0937613a326389a4df133fb (broker refactor)
##
## Goal (v1): integration-boundary coverage of the plugin lifecycle path that
## the broker refactor will touch — subprocess spawn, MCP handshake, clean
## stop. Spawns the real cad-plugin Go binary (no stubs).
##
## Out of scope (v1): MCP dispatch surface, geometry evaluation, snapshots.
## See the docket item's "v2 — MCP dispatch surface" section for the planned
## follow-up.

## NOTE: PluginManager.gd and MCPServerConnection.gd reference the SingletonObject
## autoload at parse time. In `--script` mode autoloads register lazily, so an
## eager `preload(...)` at top-of-file fails to compile. Defer to a runtime
## `load(...)` once the autoload chain has had a chance to wire up.
const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"

# Plugin source layout (dev-mode install). Not strictly portable, but matches
# the data_directory the user's plugins.json already records.
const CAD_PLUGIN_DIR_REL := "/github/plugins/cad"
const CAD_BINARY_REL := "/cad-plugin"
const CAD_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== CAD Plugin Lifecycle Smoke Test (v1) ===\n")
	print("Purpose: integration-boundary regression baseline for broker DCR 019df8e2.")
	print("         Spawns the real cad-plugin Go binary — no stubs.\n")

	var home: String = OS.get_environment("HOME")
	if home == "":
		printerr("FAIL: $HOME is unset — can't locate plugin source dir.")
		quit(1)
		return

	var plugin_dir: String = home + CAD_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + CAD_BINARY_REL
	var manifest_path: String = plugin_dir + CAD_MANIFEST_REL

	if not FileAccess.file_exists(binary_path):
		print("SKIP: cad-plugin binary not built at %s" % binary_path)
		print("      Build with: cd %s && go build -o cad-plugin ." % plugin_dir)
		quit(0)
		return

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: CAD manifest not found at %s" % manifest_path)
		quit(1)
		return

	print("CAD plugin source: %s" % plugin_dir)
	print("CAD binary:        %s\n" % binary_path)

	await _run_test(manifest_path)

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_test(manifest_path: String) -> void:
	# Wait one frame so autoloads (SingletonObject) have a chance to register
	# before we trigger PluginManager.gd compilation via load().
	await process_frame

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("FAIL: could not load PluginManager.gd")
		_fail_count += 1
		return

	# Instantiate the real PluginManager. Attaching to root triggers _ready,
	# which lazy-loads the persisted PluginDB from user://plugins/plugins.json.
	# The user's existing CAD install is reused if present; otherwise we install.
	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame

	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id("cad")

	if def == null:
		print("CAD not in PluginDB — installing from manifest...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true)
		def = db.get_by_id("cad")

	check("CAD definition loaded into DB", def != null)
	if def == null:
		return

	# Defensive: ensure plugin is not already RUNNING (stale state from a prior
	# crashed run, or another Minerva instance writing to the shared plugins.json).
	if def.state == S_RUNNING:
		print("Plugin already RUNNING — stopping first for clean baseline.")
		await pm.stop_plugin("cad")

	# --- START ---
	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin("cad")
	check("start_plugin returns ok",
			start_result.get("ok", false) == true,
			"got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING,
			"got state=%d (expected %d)" % [def.state, S_RUNNING])

	var conn = pm.get_connection("cad")
	check("connection exists post-start", conn != null)

	# --- HANDSHAKE ---
	# tools/list is the canonical MCP handshake check. The cad-plugin Go
	# backend already advertises a real tool surface (mcad_validate, etc.)
	# even though the user-facing minerva_cad_* tools still live in core
	# today. Asserting size > 0 + a known tool name locks in the
	# refresh_tools parser fix (docket bug 019e09126b48) so the broker's
	# eventual dynamic tool discovery starts on solid ground.
	if conn != null:
		print("\n-- tools/list handshake --")
		var refresh_err: int = await conn.refresh_tools()
		check("refresh_tools returns OK",
				refresh_err == OK,
				"got Error=%d" % refresh_err)
		var tools = await conn.list_tools()
		check("tools/list returns an Array", tools is Array,
				"got type %s" % typeof(tools))
		var tool_count: int = tools.size() if tools is Array else 0
		check("tools/list is non-empty",
				tool_count > 0,
				"cad-plugin reported %d tools" % tool_count)
		var tool_names: Array[String] = []
		var malformed_count: int = 0
		if tools is Array:
			for t in tools:
				if t == null:
					malformed_count += 1
					continue
				var has_name: bool = ("name" in t) and str(t.name) != ""
				if not has_name:
					malformed_count += 1
					continue
				tool_names.append(str(t.name))
				# A correctly parsed MCPToolDefinition should carry a non-empty
				# description and an input schema. If from_dict silently degrades
				# (regressed parser, malformed wire response), these will be empty
				# even though .name survives.
				var has_desc: bool = ("description" in t) and str(t.description) != ""
				var has_schema: bool = ("input_schema" in t) and (t.input_schema != null)
				if not has_desc or not has_schema:
					malformed_count += 1
		check("known tool 'mcad_validate' is present",
				"mcad_validate" in tool_names,
				"got tools: %s" % str(tool_names))
		check("every tool has populated name + description + input_schema",
				malformed_count == 0,
				"%d of %d tools were missing required fields" % [malformed_count, tool_count])
		print("    cad-plugin reported %d tool(s): %s" % [tool_count, str(tool_names).left(200)])

	# --- STOP ---
	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin("cad")
	check("stop_plugin returns ok",
			stop_result.get("ok", false) == true,
			"got: %s" % str(stop_result))
	check("plugin state == STOPPED", def.state == S_STOPPED,
			"got state=%d (expected %d)" % [def.state, S_STOPPED])
	check("connection cleared post-stop", pm.get_connection("cad") == null)


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
