extends SceneTree
## PCB plugin lifecycle smoke test — handshake baseline for the new pcb scaffold.
##
## Run: godot --headless --path src --script test/test_pcb_plugin_smoke.gd
##
## Goal: prove the first pcb artifact installs, starts, answers the MCP
## tools/list handshake with its one real tool (ping), and that dynamic tool
## discovery auto-prefixes it to "minerva_pcb_ping". This is the lean
## handshake baseline — NOT the full CAD suite (no wired-registry signal-chain,
## no geometry). Modeled on test_cad_plugin_smoke.gd.
##
## Out of scope: real PCB logic, worker, canvas (later rounds).

## PluginManager.gd / PluginToolRegistry.gd reference the SingletonObject autoload
## at parse time. In `--script` mode autoloads register lazily, so we defer to a
## runtime load() once the autoload chain has wired up.
const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_TOOL_REGISTRY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginToolRegistry.gd"

# Plugin source layout (dev-mode install). Canonical home is the
# minerva-plugins monorepo. Override with MINERVA_PCB_PLUGIN_DIR (absolute path)
# for CI / other layouts.
const PCB_PLUGIN_DIR_REL := "/github/minerva-plugins/pcb"
const PCB_BINARY_REL := "/pcb-plugin"
const PCB_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PCB Plugin Lifecycle Smoke Test ===\n")
	print("Purpose: handshake baseline for the pcb scaffold.")
	print("         Spawns the real pcb-plugin Go binary — no stubs.\n")

	var plugin_dir: String = OS.get_environment("MINERVA_PCB_PLUGIN_DIR")
	if plugin_dir == "":
		var home: String = OS.get_environment("HOME")
		if home == "":
			printerr("FAIL: $HOME is unset — can't locate plugin source dir.")
			quit(1)
			return
		plugin_dir = home + PCB_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + PCB_BINARY_REL
	var manifest_path: String = plugin_dir + PCB_MANIFEST_REL

	if not FileAccess.file_exists(binary_path):
		print("SKIP: pcb-plugin binary not built at %s" % binary_path)
		print("      Build with: cd %s && go build -o pcb-plugin ." % plugin_dir)
		quit(0)
		return

	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: PCB manifest not found at %s" % manifest_path)
		quit(1)
		return

	print("PCB plugin source: %s" % plugin_dir)
	print("PCB binary:        %s\n" % binary_path)

	await _run_test(manifest_path)

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_test(manifest_path: String) -> void:
	# Wait one frame so autoloads (SingletonObject) have a chance to register
	# before we trigger PluginManager.gd compilation via load().
	await process_frame

	# Wait for SingletonObject.initialize_plugins() to complete (it assigns
	# plugin_tool_registry after a 2s timer + mcp_manager.initialize()).
	var so_node_init = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node_init != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node_init.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout
		print("SingletonObject.plugin_tool_registry ready")

	# --- MANIFEST PARSE: zero validate() errors ---
	print("-- manifest validation --")
	var def_script = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
	check("PluginDefinition script loaded", def_script != null)
	if def_script != null:
		var parsed_def = def_script.from_manifest(manifest_path)
		# from_manifest returns null if validate() found errors (errors are pushed).
		check("manifest parses with zero validate() errors", parsed_def != null,
				"from_manifest returned null — see pushed validation errors above")

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("FAIL: could not load PluginManager.gd")
		_fail_count += 1
		return

	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame

	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id("pcb")

	if def == null:
		print("PCB not in PluginDB — installing from manifest...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true,
				"got: %s" % str(install_result))
		def = db.get_by_id("pcb")

	check("PCB definition loaded into DB", def != null)
	if def == null:
		return

	# --- IDEMPOTENT INSTALL ---
	# install_plugin is intentionally non-idempotent: re-installing an
	# already-installed plugin is rejected with an "already installed" error
	# (not a duplicate). Assert that contract — the definition stays single.
	print("\n-- idempotent install (re-install rejected) --")
	var reinstall_result = await pm.install_plugin(manifest_path, true)
	check("re-install rejected as already installed",
			str(reinstall_result.get("error", "")).find("already installed") != -1,
			"got: %s" % str(reinstall_result))
	check("PCB still single definition after re-install attempt", db.get_by_id("pcb") != null)

	# Defensive: ensure not already RUNNING from a stale prior run.
	if def.state == S_RUNNING:
		print("Plugin already RUNNING — stopping first for clean baseline.")
		await pm.stop_plugin("pcb")

	# --- START ---
	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin("pcb")
	check("start_plugin returns ok", start_result.get("ok", false) == true,
			"got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING,
			"got state=%d (expected %d)" % [def.state, S_RUNNING])

	var conn = pm.get_connection("pcb")
	check("connection exists post-start", conn != null)

	# --- HANDSHAKE: tools/list non-empty, ping present ---
	if conn != null:
		print("\n-- tools/list handshake --")
		var refresh_err: int = await conn.refresh_tools()
		check("refresh_tools returns OK", refresh_err == OK, "got Error=%d" % refresh_err)
		var tools = await conn.list_tools()
		check("tools/list returns an Array", tools is Array, "got type %s" % typeof(tools))
		var tool_names: Array[String] = []
		if tools is Array:
			for t in tools:
				if t != null and ("name" in t) and str(t.name) != "":
					tool_names.append(str(t.name))
		check("tools/list is non-empty", tool_names.size() > 0,
				"pcb-plugin reported %d tools" % tool_names.size())
		check("known tool 'ping' is present", "ping" in tool_names,
				"got tools: %s" % str(tool_names))
		print("    pcb-plugin reported %d tool(s): %s" % [tool_names.size(), str(tool_names)])

	# --- DYNAMIC TOOL DISCOVERY: auto-prefix policy ---
	print("\n-- dynamic tool discovery --")
	var registry_script = load(PLUGIN_TOOL_REGISTRY_SCRIPT_PATH)
	check("PluginToolRegistry script loaded", registry_script != null)
	if registry_script != null and conn != null:
		var registry = registry_script.new()
		check("PluginToolRegistry instantiated", registry != null)
		if registry != null:
			var reg_result: Dictionary = await registry.register_backend_tools("pcb", conn)
			check("register_backend_tools returns ok", reg_result.get("ok", false) == true,
					"got: %s" % str(reg_result))
			var registered_names: Array = reg_result.get("registered", [])
			check("at least one backend tool registered", registered_names.size() > 0,
					"registered: %s" % str(registered_names))

			# ping → minerva_pcb_ping (auto-prefix, Option B).
			check("'minerva_pcb_ping' is in registry after backend discovery",
					registry.is_plugin_tool("minerva_pcb_ping"),
					"registered names: %s" % str(registered_names))
			check("get_tool_owner('minerva_pcb_ping') returns 'pcb'",
					registry.get_tool_owner("minerva_pcb_ping") == "pcb",
					"got: '%s'" % registry.get_tool_owner("minerva_pcb_ping"))
			# Raw (unprefixed) name must NOT be in the registry.
			check("raw name 'ping' is NOT in registry (prefixed correctly)",
					not registry.is_plugin_tool("ping"))

			# --- IDEMPOTENT RE-REGISTER (tools) ---
			print("\n-- idempotency: re-register same tools --")
			var reg_result2: Dictionary = await registry.register_backend_tools("pcb", conn)
			check("second register_backend_tools returns ok", reg_result2.get("ok", false) == true,
					"got: %s" % str(reg_result2))
			var registered2: Array = reg_result2.get("registered", [])
			check("re-register produces same count (idempotent)",
					registered2.size() == registered_names.size(),
					"first=%d second=%d" % [registered_names.size(), registered2.size()])

			# --- STOP clears tools ---
			print("\n-- unregister on stop --")
			registry.on_plugin_stopped("pcb")
			check("tools gone after on_plugin_stopped", registry.get_tool_count() == 0,
					"count=%d" % registry.get_tool_count())
			check("is_plugin_tool returns false after stop",
					not registry.is_plugin_tool("minerva_pcb_ping"))

			# --- RESTART: tools come back ---
			print("\n-- restart cycle: re-discover after stop --")
			var reg_result3: Dictionary = await registry.register_backend_tools("pcb", conn)
			check("register_backend_tools after stop returns ok", reg_result3.get("ok", false) == true,
					"got: %s" % str(reg_result3))
			var registered3: Array = reg_result3.get("registered", [])
			check("tools re-registered after stop+restart cycle",
					registered3.size() == registered_names.size(),
					"first=%d after_restart=%d" % [registered_names.size(), registered3.size()])
			check("'minerva_pcb_ping' present again after restart cycle",
					registry.is_plugin_tool("minerva_pcb_ping"))

	# --- STOP ---
	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin("pcb")
	check("stop_plugin returns ok", stop_result.get("ok", false) == true,
			"got: %s" % str(stop_result))
	check("plugin state == STOPPED", def.state == S_STOPPED,
			"got state=%d (expected %d)" % [def.state, S_STOPPED])
	check("connection cleared post-stop", pm.get_connection("pcb") == null)


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
