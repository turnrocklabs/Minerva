extends SceneTree
## Scansort plugin lifecycle smoke test — T4 DCR regression baseline +
## dynamic tool discovery assertions.
##
## Run: godot --headless --path src --script test/test_scansort_plugin_smoke.gd
##
## Tracks docket: minerva 019e1cdb451076ae8c344f6e6ec605e1 (scansort plugin DCR)
## Parent DCR:    T4 skeleton — Rust binary + MCP handshake + probe tool
##
## Goal: integration-boundary coverage of the plugin lifecycle path.
##       Spawns the real scansort-plugin Rust binary — no stubs.
##       Asserts minerva_scansort_probe is registered after backend discovery.

## NOTE: PluginManager.gd and MCPServerConnection.gd reference the SingletonObject
## autoload at parse time. In `--script` mode autoloads register lazily, so an
## eager `preload(...)` at top-of-file fails to compile. Defer to a runtime
## `load(...)` once the autoload chain has had a chance to wire up.
const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_TOOL_REGISTRY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginToolRegistry.gd"

# Plugin source layout (dev-mode install).
const SCANSORT_PLUGIN_DIR_REL := "/github/plugins/scansort"
const SCANSORT_BINARY_REL := "/scansort-plugin"
const SCANSORT_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Scansort Plugin Lifecycle Smoke Test (T4) ===\n")
	print("Purpose: integration-boundary regression baseline for scansort DCR 019e1cdb.")
	print("         Spawns the real scansort-plugin Rust binary — no stubs.\n")

	var home: String = OS.get_environment("HOME")
	if home == "":
		printerr("FAIL: $HOME is unset — can't locate plugin source dir.")
		quit(1)
		return

	var plugin_dir: String = home + SCANSORT_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + SCANSORT_BINARY_REL
	var manifest_path: String = plugin_dir + SCANSORT_MANIFEST_REL

	if not FileAccess.file_exists(binary_path):
		print("SKIP: scansort-plugin binary not built at %s" % binary_path)
		print("      Build with: cd %s && cargo build --release && cp target/release/scansort-plugin ." % plugin_dir)
		quit(0)
		return

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: scansort manifest not found at %s" % manifest_path)
		quit(1)
		return

	print("Scansort plugin source: %s" % plugin_dir)
	print("Scansort binary:        %s\n" % binary_path)

	await _run_test(manifest_path)

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_test(manifest_path: String) -> void:
	# Wait one frame so autoloads (SingletonObject) have a chance to register
	# before we trigger PluginManager.gd compilation via load().
	await process_frame

	# Wait for SingletonObject.initialize_plugins() to complete. Its _ready()
	# awaits a 2s timer + mcp_manager.initialize() before assigning
	# plugin_tool_registry — see hint minerva-singleton/plugin-tool-registry-late-init.
	# Without this wait, PluginManager._discover_backend_tools silently skips
	# because the wired registry is still null.
	var so_node_init = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node_init != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node_init.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout
		var ready_at: int = Time.get_ticks_msec()
		print("SingletonObject.plugin_tool_registry available after %dms" % (ready_at - (deadline_ms - 10000)))

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("FAIL: could not load PluginManager.gd")
		_fail_count += 1
		return

	# Instantiate the real PluginManager. Attaching to root triggers _ready,
	# which lazy-loads the persisted PluginDB from user://plugins/plugins.json.
	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame

	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id("scansort")

	if def == null:
		print("Scansort not in PluginDB — installing from manifest...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true)
		def = db.get_by_id("scansort")

	check("Scansort definition loaded into DB", def != null)
	if def == null:
		return

	# Defensive: ensure plugin is not already RUNNING (stale state from a prior
	# crashed run, or another Minerva instance writing to the shared plugins.json).
	if def.state == S_RUNNING:
		print("Plugin already RUNNING — stopping first for clean baseline.")
		await pm.stop_plugin("scansort")

	# --- START ---
	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin("scansort")
	check("start_plugin returns ok",
			start_result.get("ok", false) == true,
			"got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING,
			"got state=%d (expected %d)" % [def.state, S_RUNNING])

	var conn = pm.get_connection("scansort")
	check("connection exists post-start", conn != null)

	# --- HANDSHAKE ---
	# tools/list confirms the Rust binary started cleanly and speaks MCP.
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
				"scansort-plugin reported %d tools" % tool_count)
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
				var has_desc: bool = ("description" in t) and str(t.description) != ""
				var has_schema: bool = ("input_schema" in t) and (t.input_schema != null)
				if not has_desc or not has_schema:
					malformed_count += 1
		check("known tool 'minerva_scansort_probe' is present",
				"minerva_scansort_probe" in tool_names,
				"got tools: %s" % str(tool_names))
		check("every tool has populated name + description + input_schema",
				malformed_count == 0,
				"%d of %d tools were missing required fields" % [malformed_count, tool_count])
		print("    scansort-plugin reported %d tool(s): %s" % [tool_count, str(tool_names).left(200)])

	# --- DYNAMIC TOOL DISCOVERY ---
	# After start_plugin, PluginManager._discover_backend_tools runs in the
	# background. We exercise PluginToolRegistry.register_backend_tools directly
	# here to confirm the auto-prefix policy and registry state.
	print("\n-- dynamic tool discovery --")
	var registry_script = load(PLUGIN_TOOL_REGISTRY_SCRIPT_PATH)
	check("PluginToolRegistry script loaded", registry_script != null)
	if registry_script != null and conn != null:
		var registry = registry_script.new()
		check("PluginToolRegistry instantiated", registry != null)

		if registry != null:
			# Register backend tools from the live connection.
			var reg_result: Dictionary = await registry.register_backend_tools("scansort", conn)
			check("register_backend_tools returns ok",
					reg_result.get("ok", false) == true,
					"got: %s" % str(reg_result))

			var registered_names: Array = reg_result.get("registered", [])
			check("at least one backend tool registered",
					registered_names.size() > 0,
					"registered: %s" % str(registered_names))

			# Prefix policy: every registered name must start with "minerva_scansort_"
			var all_prefixed := true
			for n in registered_names:
				if not str(n).begins_with("minerva_scansort_"):
					all_prefixed = false
					break
			check("all registered names start with 'minerva_scansort_'",
					all_prefixed,
					"got: %s" % str(registered_names))

			# Specific known tool: "minerva_scansort_probe" in registry
			check("'minerva_scansort_probe' is in registry after backend discovery",
					registry.is_plugin_tool("minerva_scansort_probe"),
					"registered names: %s" % str(registered_names))

			check("is_plugin_tool('minerva_scansort_probe') returns true",
					registry.is_plugin_tool("minerva_scansort_probe"))

			check("get_tool_owner('minerva_scansort_probe') returns 'scansort'",
					registry.get_tool_owner("minerva_scansort_probe") == "scansort",
					"got: '%s'" % registry.get_tool_owner("minerva_scansort_probe"))

			var tool_count_after: int = registry.get_tool_count()
			print("    %d tool(s) registered with prefix: %s" % [tool_count_after, str(registered_names)])

			# --- IDEMPOTENCY ---
			print("\n-- idempotency: re-register same tools --")
			var reg_result2: Dictionary = await registry.register_backend_tools("scansort", conn)
			check("second register_backend_tools returns ok",
					reg_result2.get("ok", false) == true,
					"got: %s" % str(reg_result2))
			var registered2: Array = reg_result2.get("registered", [])
			check("re-register produces same count (idempotent)",
					registered2.size() == registered_names.size(),
					"first=%d second=%d" % [registered_names.size(), registered2.size()])
			check("'minerva_scansort_probe' still present after re-register",
					registry.is_plugin_tool("minerva_scansort_probe"))

			# --- POST-STOP: tools unregistered ---
			print("\n-- unregister on stop --")
			registry.on_plugin_stopped("scansort")
			check("tools gone after on_plugin_stopped",
					registry.get_tool_count() == 0,
					"count=%d" % registry.get_tool_count())
			check("is_plugin_tool returns false after stop",
					not registry.is_plugin_tool("minerva_scansort_probe"))

			# --- RESTART CYCLE ---
			print("\n-- restart cycle: re-discover after stop --")
			var reg_result3: Dictionary = await registry.register_backend_tools("scansort", conn)
			check("register_backend_tools after stop returns ok",
					reg_result3.get("ok", false) == true,
					"got: %s" % str(reg_result3))
			var registered3: Array = reg_result3.get("registered", [])
			check("tools re-registered after stop+restart cycle",
					registered3.size() == registered_names.size(),
					"first=%d after_restart=%d" % [registered_names.size(), registered3.size()])
			check("'minerva_scansort_probe' present again after restart cycle",
					registry.is_plugin_tool("minerva_scansort_probe"))
			print("    restart cycle restored %d tool(s)" % registered3.size())

	# --- WIRED REGISTRY: signal-propagation integration ---
	print("\n-- wired registry: signal propagation --")
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload reachable", so_node != null)
	if so_node != null:
		var wired_registry = so_node.get("plugin_tool_registry") if "plugin_tool_registry" in so_node else null
		var mcp_mgr = so_node.get("mcp_manager") if "mcp_manager" in so_node else null
		check("SingletonObject.plugin_tool_registry exists", wired_registry != null)
		check("SingletonObject.mcp_manager exists", mcp_mgr != null)
		if wired_registry != null:
			check("wired registry.is_plugin_tool('minerva_scansort_probe') is true",
					wired_registry.is_plugin_tool("minerva_scansort_probe"),
					"wired registry tool count=%d" % wired_registry.get_tool_count())
		if mcp_mgr != null and "tool_registry" in mcp_mgr:
			var mcp_registry: Dictionary = mcp_mgr.tool_registry
			check("mcp_manager.tool_registry has 'minerva_scansort_probe' (signal propagated)",
					mcp_registry.has("minerva_scansort_probe"),
					"signal lambda did not push backend tool into mcp_manager.tool_registry")

		# --- WIRED REGISTRY: unregister signal chain ---
		if wired_registry != null:
			wired_registry.on_plugin_stopped("scansort")
			check("wired registry cleared after on_plugin_stopped",
					not wired_registry.is_plugin_tool("minerva_scansort_probe"),
					"on_plugin_stopped did not clear the wired registry")
			if mcp_mgr != null and "tool_registry" in mcp_mgr:
				var mcp_registry_after: Dictionary = mcp_mgr.tool_registry
				check("mcp_manager.tool_registry cleared after on_plugin_stopped (unregister signal propagated)",
						not mcp_registry_after.has("minerva_scansort_probe"),
						"tools_unregistered signal did not propagate to mcp_manager.tool_registry erase")

	# --- STOP ---
	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin("scansort")
	check("stop_plugin returns ok",
			stop_result.get("ok", false) == true,
			"got: %s" % str(stop_result))
	check("plugin state == STOPPED", def.state == S_STOPPED,
			"got state=%d (expected %d)" % [def.state, S_STOPPED])
	check("connection cleared post-stop", pm.get_connection("scansort") == null)


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
