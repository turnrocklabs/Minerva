extends SceneTree
## CAD plugin lifecycle smoke test — broker-DCR regression baseline + dynamic
## tool discovery assertions.
##
## Run: godot --headless --path src --script test/test_cad_plugin_smoke.gd
##
## Tracks docket: minerva 019e08fdd00c72a19e1cf8e6fde6a0b0
## Parent DCR:    minerva 019df8e2d0937613a326389a4df133fb (broker refactor)
##
## Goal (v1): integration-boundary coverage of the plugin lifecycle path.
## Goal (v2): dynamic tool discovery via PluginToolRegistry.register_backend_tools.
##   Prefix policy: Option B (auto-prefix) — "mcad_validate" becomes
##   "minerva_cad_mcad_validate", "cad.evaluate" becomes "minerva_cad_cad_evaluate".
##
## Out of scope: geometry evaluation, snapshots (separate test files).

## NOTE: PluginManager.gd and MCPServerConnection.gd reference the SingletonObject
## autoload at parse time. In `--script` mode autoloads register lazily, so an
## eager `preload(...)` at top-of-file fails to compile. Defer to a runtime
## `load(...)` once the autoload chain has had a chance to wire up.
const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_TOOL_REGISTRY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginToolRegistry.gd"

# Plugin source layout (dev-mode install). Canonical home is the
# minerva-plugins monorepo (ipeerbhai/plugins is a deprecated mirror).
# Override with MINERVA_CAD_PLUGIN_DIR (absolute path) for CI / other layouts.
const CAD_PLUGIN_DIR_REL := "/github/minerva-plugins/cad"
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

	var plugin_dir: String = OS.get_environment("MINERVA_CAD_PLUGIN_DIR")
	if plugin_dir == "":
		var home: String = OS.get_environment("HOME")
		if home == "":
			printerr("FAIL: $HOME is unset — can't locate plugin source dir.")
			quit(1)
			return
		plugin_dir = home + CAD_PLUGIN_DIR_REL
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

	# --- DYNAMIC TOOL DISCOVERY (v2) ---
	# After start_plugin, PluginManager._discover_backend_tools runs in the
	# background. We exercise PluginToolRegistry.register_backend_tools directly
	# here to confirm the auto-prefix policy and registry state.
	print("\n-- dynamic tool discovery --")
	var registry_script = load(PLUGIN_TOOL_REGISTRY_SCRIPT_PATH)
	check("PluginToolRegistry script loaded", registry_script != null)
	if registry_script != null and conn != null:
		# Instantiate a fresh registry (no PluginManager — headless test mode).
		var registry = registry_script.new()
		check("PluginToolRegistry instantiated", registry != null)

		if registry != null:
			# Register backend tools from the live connection.
			var reg_result: Dictionary = await registry.register_backend_tools("cad", conn)
			check("register_backend_tools returns ok",
					reg_result.get("ok", false) == true,
					"got: %s" % str(reg_result))

			var registered_names: Array = reg_result.get("registered", [])
			check("at least one backend tool registered",
					registered_names.size() > 0,
					"registered: %s" % str(registered_names))

			# Prefix policy assertion: every registered name must start with "minerva_cad_"
			var all_prefixed := true
			for n in registered_names:
				if not str(n).begins_with("minerva_cad_"):
					all_prefixed = false
					break
			check("all registered names start with 'minerva_cad_'",
					all_prefixed,
					"got: %s" % str(registered_names))

			# Specific known tool: "mcad_validate" → "minerva_cad_mcad_validate"
			check("'minerva_cad_mcad_validate' is in registry after backend discovery",
					registry.is_plugin_tool("minerva_cad_mcad_validate"),
					"registered names: %s" % str(registered_names))

			# is_plugin_tool lookup works for the prefixed name
			check("is_plugin_tool('minerva_cad_mcad_validate') returns true",
					registry.is_plugin_tool("minerva_cad_mcad_validate"))

			# get_tool_owner returns "cad"
			check("get_tool_owner('minerva_cad_mcad_validate') returns 'cad'",
					registry.get_tool_owner("minerva_cad_mcad_validate") == "cad",
					"got: '%s'" % registry.get_tool_owner("minerva_cad_mcad_validate"))

			# No raw backend names in registry (prefix policy enforced)
			check("raw name 'mcad_validate' is NOT in registry (prefixed correctly)",
					not registry.is_plugin_tool("mcad_validate"))

			var tool_count_after: int = registry.get_tool_count()
			print("    %d tool(s) registered with prefix: %s" % [tool_count_after, str(registered_names)])

			# --- STOP + RESTART IDEMPOTENCY ---
			# Verify re-registration is clean: call register_backend_tools again on the
			# same registry and confirm the count stays the same (idempotent).
			print("\n-- idempotency: re-register same tools --")
			var reg_result2: Dictionary = await registry.register_backend_tools("cad", conn)
			check("second register_backend_tools returns ok",
					reg_result2.get("ok", false) == true,
					"got: %s" % str(reg_result2))
			var registered2: Array = reg_result2.get("registered", [])
			check("re-register produces same count (idempotent)",
					registered2.size() == registered_names.size(),
					"first=%d second=%d" % [registered_names.size(), registered2.size()])
			check("'minerva_cad_mcad_validate' still present after re-register",
					registry.is_plugin_tool("minerva_cad_mcad_validate"))

			# --- POST-STOP: tools unregistered ---
			print("\n-- unregister on stop --")
			registry.on_plugin_stopped("cad")
			check("tools gone after on_plugin_stopped",
					registry.get_tool_count() == 0,
					"count=%d" % registry.get_tool_count())
			check("is_plugin_tool returns false after stop",
					not registry.is_plugin_tool("minerva_cad_mcad_validate"))

			# --- RESTART CYCLE: re-discover after stop ---
			print("\n-- restart cycle: re-discover after stop --")
			var reg_result3: Dictionary = await registry.register_backend_tools("cad", conn)
			check("register_backend_tools after stop returns ok",
					reg_result3.get("ok", false) == true,
					"got: %s" % str(reg_result3))
			var registered3: Array = reg_result3.get("registered", [])
			check("tools re-registered after stop+restart cycle",
					registered3.size() == registered_names.size(),
					"first=%d after_restart=%d" % [registered_names.size(), registered3.size()])
			check("'minerva_cad_mcad_validate' present again after restart cycle",
					registry.is_plugin_tool("minerva_cad_mcad_validate"))
			print("    restart cycle restored %d tool(s)" % registered3.size())

	# --- WIRED REGISTRY: signal-propagation integration ---
	# The fresh-registry tests above prove the registry contract in isolation.
	# This block proves the integration path works end-to-end: PluginManager
	# called register_backend_tools on the SingletonObject's wired registry
	# during start_plugin (now awaited, post-fix), and the tools_registered
	# signal propagated through the lambda at singleton_object.gd:617 into
	# mcp_manager.tool_registry. Cold-review found this gap — without these
	# assertions, a future regression in the signal-emission path would not
	# be caught.
	print("\n-- wired registry: signal propagation --")
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload reachable", so_node != null)
	if so_node != null:
		var wired_registry = so_node.get("plugin_tool_registry") if "plugin_tool_registry" in so_node else null
		var mcp_mgr = so_node.get("mcp_manager") if "mcp_manager" in so_node else null
		check("SingletonObject.plugin_tool_registry exists", wired_registry != null)
		check("SingletonObject.mcp_manager exists", mcp_mgr != null)
		if wired_registry != null:
			check("wired registry.is_plugin_tool('minerva_cad_mcad_validate') is true",
					wired_registry.is_plugin_tool("minerva_cad_mcad_validate"),
					"wired registry tool count=%d" % wired_registry.get_tool_count())
		if mcp_mgr != null and "tool_registry" in mcp_mgr:
			var mcp_registry: Dictionary = mcp_mgr.tool_registry
			check("mcp_manager.tool_registry has 'minerva_cad_mcad_validate' (signal propagated)",
					mcp_registry.has("minerva_cad_mcad_validate"),
					"signal lambda did not push backend tool into mcp_manager.tool_registry")

		# --- WIRED REGISTRY: unregister signal chain ---
		# Manually invoke the wired registry's on_plugin_stopped to exercise
		# the path: on_plugin_stopped → unregister_plugin_tools →
		# tools_unregistered.emit → singleton lambda → mcp_manager.tool_registry erase.
		# (The chain normally fires via SingletonObject.plugin_manager's
		# plugin_stopped signal, but this test uses an independent PluginManager
		# so we trigger on_plugin_stopped directly.) Reviewer's Issue 1 fix
		# (signal emission on purge) is what makes the second assertion possible.
		if wired_registry != null:
			wired_registry.on_plugin_stopped("cad")
			check("wired registry cleared after on_plugin_stopped",
					not wired_registry.is_plugin_tool("minerva_cad_mcad_validate"),
					"on_plugin_stopped did not clear the wired registry")
			if mcp_mgr != null and "tool_registry" in mcp_mgr:
				var mcp_registry_after: Dictionary = mcp_mgr.tool_registry
				check("mcp_manager.tool_registry cleared after on_plugin_stopped (unregister signal propagated)",
						not mcp_registry_after.has("minerva_cad_mcad_validate"),
						"tools_unregistered signal did not propagate to mcp_manager.tool_registry erase")

	# --- STOP ---
	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin("cad")
	check("stop_plugin returns ok",
			stop_result.get("ok", false) == true,
			"got: %s" % str(stop_result))
	check("plugin state == STOPPED", def.state == S_STOPPED,
			"got state=%d (expected %d)" % [def.state, S_STOPPED])
	check("connection cleared post-stop", pm.get_connection("cad") == null)

	# Note: we do NOT re-assert wired-registry post-stop here because our test's
	# independent PluginManager doesn't share signal connections with
	# SingletonObject.plugin_manager — pm.stop_plugin emits plugin_stopped on
	# the test's pm, which the wired registry isn't listening to. The wired
	# unregister chain is exercised above by calling on_plugin_stopped directly.


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
