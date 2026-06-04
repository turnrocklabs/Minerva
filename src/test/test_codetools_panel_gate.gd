extends SceneTree
## Gate-A functional test — code_graph panel registers + opens via the REAL PluginManager.
##
## P1.4 R3 (DCR 019e7b6609): proves the code_graph godot_scene panel in the codetools
## plugin is REGISTERED on the installed PluginDefinition and can be MOUNTED via the
## real PluginScenePanelHost.instantiate_into() into a live host node tree, without the
## scripts-audit rejecting it.
##
## No stubs for PluginManager, MarketplaceClient, or PluginScenePanelHost. The whole
## install→start→register→mount path is real.
##
## Rendering with real graph data is the human-in-the-loop gate (NOT this test).
## get_graph data contract has its own worker unit tests.
##
## SKIP conditions (mirrors sibling tests):
##   - ~/github/minerva-plugins/codetools not checked out
##   - go toolchain not on PATH
##   - host platform has no embedded-bundle triple
##   - fixture tarball build fails
##
## Run with:
##   godot --headless --path src --script test/test_codetools_panel_gate.gd

const PLUGIN_ID := "codetools"
const SRC_REL := "/github/minerva-plugins/codetools"
const BINARY_NAME := "codetools-plugin"
const PANEL_NAME := "code_graph"
const HELPER_GD := "res://test/marketplace_test_helpers.gd"
const PANEL_HOST_GD := "res://Scripts/Services/Plugins/PluginScenePanelHost.gd"
const TOOL_CALL_TIMEOUT := 60.0  # first call extracts the embedded bundle

var _helper = null  # MarketplaceTestHelpers
var _pm = null
var _temp_dir: String = ""
var _pass: int = 0
var _fail: int = 0
var _skipped: bool = false
var _skip_reason: String = ""


func _init() -> void:
	print("=== code_graph panel Gate-A: register + mount (codetools P1.4 R3) ===")
	await _run()
	_teardown()
	if _skipped:
		print("\n=== SKIPPED — %s ===" % _skip_reason)
		quit(0)
		return
	print("\n=== %d passed, %d failed ===" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	await process_frame

	var helper_cls = load(HELPER_GD)
	if helper_cls == null:
		_skip("could not load %s" % HELPER_GD)
		return
	_helper = helper_cls.new(self)

	# --- Preconditions: plugins source + toolchain + platform ---
	var home: String = OS.get_environment("HOME")
	if home == "":
		_skip("$HOME unset")
		return
	var src_dir: String = home + SRC_REL
	var src_manifest: String = src_dir + "/manifest.json"
	if not FileAccess.file_exists(src_manifest):
		_skip("no codetools source at %s" % src_dir)
		return
	if not _helper.have_cmd("go"):
		_skip("go toolchain not on PATH")
		return
	var triple: String = _helper.host_bundle_triple()
	if triple == "":
		_skip("unsupported host %s/arm64=%s" % [OS.get_name(), OS.has_feature("arm64")])
		return

	# --- Build fixture tarball (include_ui: the panel gate mounts ui/ scripts) ---
	_temp_dir = "%s/cp_gate_%d" % [OS.get_user_data_dir(), Time.get_ticks_msec()]
	var fx: Dictionary = _helper.build_codetools_fixture(src_dir, triple, _temp_dir, BINARY_NAME, true)
	if not fx.get("ok", false):
		if fx.has("skip"):
			_skip(fx["skip"])
		else:
			_fail += 1
			print("FAIL: fixture build — %s" % fx.get("fail", "?"))
		return

	var port: int = _helper.random_high_port()
	if not await _helper.start_http_server(_temp_dir, port, 15.0):
		_fail += 1
		print("FAIL: http.server didn't come up")
		return
	var url := "http://127.0.0.1:%d/codetools-fixture.tar.gz" % port
	print("  serving at: %s" % url)

	# --- PluginManager: use SingletonObject's PM so PluginScenePanelHost can find it.
	# PluginScenePanelHost._get_plugin_manager() reads SingletonObject.plugin_manager,
	# so we must use that exact instance (not a second bootstrapped one) for the
	# instantiate_into mount to succeed. bootstrap_plugin_manager() is intentionally
	# NOT used here; instead we wait for SingletonObject to be ready and then take
	# its PM directly.
	await process_frame
	var so = root.get_node_or_null("SingletonObject")
	if so != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await create_timer(0.1).timeout
	if so == null or so.get("plugin_manager") == null:
		_skip("SingletonObject or its plugin_manager not available")
		return
	_pm = so.get("plugin_manager")
	print("  using SingletonObject.plugin_manager (has %d plugin(s))" % _pm._db.get_all().size())
	await _helper.scrub_plugin(_pm, PLUGIN_ID)
	_helper.clear_runtime_cache(PLUGIN_ID)

	# =========================================================================
	# Step 1: install via the real marketplace path
	# =========================================================================
	print("\n-- step 1: install_from_url --")
	var mc = _helper.make_marketplace_client()
	var install_result: Dictionary = await mc.install_from_url(url, _pm)
	if not install_result.get("ok", false):
		print("FAIL: install_from_url returned: %s" % JSON.stringify(install_result))
		_fail += 1
		return
	print("  install ok: plugin_id=%s manifest_path=%s"
			% [install_result.get("plugin_id"), install_result.get("manifest_path")])

	var def = _pm._db.get_by_id(PLUGIN_ID)
	if def == null:
		print("FAIL: post-install — PluginManager has no codetools definition")
		_fail += 1
		return
	print("  data_directory: %s" % def.data_directory)

	# =========================================================================
	# Step 2: start_plugin
	# =========================================================================
	print("\n-- step 2: start_plugin --")
	var start_result: Dictionary = await _pm.start_plugin(PLUGIN_ID)
	print("  start_result: %s" % JSON.stringify(start_result))
	if not start_result.get("ok", false):
		print("FAIL: start_plugin failed — error=%s" % start_result.get("error", "?"))
		_fail += 1
		return
	if def.state != _helper.S_RUNNING:
		print("FAIL: expected state RUNNING(%d), got %d" % [_helper.S_RUNNING, def.state])
		_fail += 1
		await _pm.stop_plugin(PLUGIN_ID)
		return
	var conn = _pm.get_connection(PLUGIN_ID)
	if conn == null:
		print("FAIL: no MCP connection after start_plugin")
		_fail += 1
		await _pm.stop_plugin(PLUGIN_ID)
		return
	print("PASS: install + start (state=RUNNING, conn live)")
	_pass += 1

	# =========================================================================
	# Step 3: MUST-HAVE — assert code_graph panel is REGISTERED on the def
	# =========================================================================
	print("\n-- step 3: code_graph panel registration check --")

	# 3a. ui_panels contains a Dictionary entry named "code_graph"
	var found_panel_def: Dictionary = {}
	for panel_entry in def.ui_panels:
		if panel_entry is Dictionary and panel_entry.get("name", "") == PANEL_NAME:
			found_panel_def = panel_entry
			break
	if found_panel_def.is_empty():
		print("FAIL: def.ui_panels has no '%s' Dictionary entry; ui_panels=%s"
				% [PANEL_NAME, JSON.stringify(def.ui_panels)])
		_fail += 1
	else:
		print("PASS: '%s' panel found in def.ui_panels" % PANEL_NAME)
		_pass += 1

	# 3b. ui_panel_names also contains the name (the fast-lookup parallel array)
	if not def.ui_panel_names.has(PANEL_NAME):
		print("FAIL: '%s' missing from def.ui_panel_names: %s"
				% [PANEL_NAME, str(def.ui_panel_names)])
		_fail += 1
	else:
		print("PASS: '%s' in def.ui_panel_names" % PANEL_NAME)
		_pass += 1

	# 3c. editor_items references the panel
	var found_editor_item := false
	for ei in def.editor_items:
		if ei is Dictionary and ei.get("panel", "") == PANEL_NAME:
			found_editor_item = true
			break
	if not found_editor_item:
		print("FAIL: no editor_items entry references panel '%s'; editor_items=%s"
				% [PANEL_NAME, JSON.stringify(def.editor_items)])
		_fail += 1
	else:
		print("PASS: editor_items has entry referencing '%s'" % PANEL_NAME)
		_pass += 1

	# 3d. Panel kind is godot_scene
	var panel_kind: String = found_panel_def.get("kind", "")
	if panel_kind != "godot_scene":
		print("FAIL: panel kind is '%s', expected 'godot_scene'" % panel_kind)
		_fail += 1
	else:
		print("PASS: panel kind == 'godot_scene'")
		_pass += 1

	# 3e. Panel has a non-empty entry_scene
	var entry_scene: String = found_panel_def.get("entry_scene", "")
	if entry_scene.is_empty():
		print("FAIL: panel 'entry_scene' is empty")
		_fail += 1
	else:
		print("PASS: panel entry_scene = '%s'" % entry_scene)
		_pass += 1

	# 3f. Panel has non-empty scripts list
	var scripts: Array = found_panel_def.get("scripts", [])
	if scripts.is_empty():
		print("FAIL: panel 'scripts' is empty")
		_fail += 1
	else:
		print("PASS: panel declares %d script(s)" % scripts.size())
		_pass += 1

	# =========================================================================
	# Step 4: MUST-HAVE — MOUNT via real PluginScenePanelHost.instantiate_into()
	# =========================================================================
	print("\n-- step 4: mount via PluginScenePanelHost.instantiate_into() --")

	# Load via path (not class_name) to avoid GDScript parse-order issues in headless
	# mode — same pattern used in test_plugin_scene_panel_host.gd.
	var PanelHostClass = load(PANEL_HOST_GD)
	if PanelHostClass == null:
		print("FAIL: could not load PluginScenePanelHost from %s" % PANEL_HOST_GD)
		_fail += 1
		await _pm.stop_plugin(PLUGIN_ID)
		return

	# The host needs a parent Control in the tree so resize/anchor calls don't
	# crash. Attach a VBoxContainer to the SceneTree root for the duration.
	var host_vbox := VBoxContainer.new()
	host_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host_vbox)

	var mounted: Control = PanelHostClass.instantiate_into(
		host_vbox, PLUGIN_ID, PANEL_NAME, null)

	# 4a. A Control node was returned (not null)
	if mounted == null:
		print("FAIL: instantiate_into returned null")
		_fail += 1
	else:
		print("PASS: instantiate_into returned a Control node")
		_pass += 1

	# 4b. The returned node is a Control
	if mounted != null and not (mounted is Control):
		print("FAIL: returned node is %s, expected Control" % mounted.get_class())
		_fail += 1
	elif mounted != null:
		print("PASS: returned node is Control (class=%s)" % mounted.get_class())
		_pass += 1

	# 4c. The mounted node was added as a child of host_vbox
	# (a placeholder is ALSO added as child — the key is that something was mounted)
	var child_count := host_vbox.get_child_count()
	if child_count == 0:
		print("FAIL: host_vbox has no children after instantiate_into")
		_fail += 1
	else:
		print("PASS: host_vbox has %d child(ren) after mount" % child_count)
		_pass += 1

	# 4d. The mounted node is NOT a placeholder (i.e. scripts-audit didn't reject it).
	# We detect a placeholder by checking if the result is a VBoxContainer containing
	# a red-colored Label (the placeholder builder pattern from PluginScenePanelHost).
	# If the scene was loaded cleanly, the root class will differ.
	# Since code_graph_panel.gd extends MinervaPluginPanel which extends Control,
	# a successful mount will NOT be a plain VBoxContainer created by _build_placeholder.
	# However, we must also handle the case where the scene root IS a VBoxContainer
	# (legitimate). The most reliable check is: does the child contain a red Label?
	var is_placeholder := false
	if mounted != null:
		is_placeholder = _looks_like_placeholder(mounted)
	if is_placeholder:
		print("FAIL: instantiate_into returned a diagnostic placeholder — scripts-audit")
		print("      or scene load failed. Check panel scripts are present at data_directory.")
		_fail += 1
	else:
		print("PASS: mounted panel is NOT a placeholder (scripts-audit accepted scene)")
		_pass += 1

	# Cleanup: remove vbox (and mounted child) from tree before stop
	root.remove_child(host_vbox)
	host_vbox.free()

	# =========================================================================
	# Step 5 (BONUS): check minerva_codetools_get_graph tool is reachable.
	# Rather than indexing a real store (which is the HITL gate), we check that
	# the tool is advertised in the running plugin's tool list. This proves the
	# install→start→tool-discovery path works for the get_graph surface.
	# =========================================================================
	print("\n-- step 5 (bonus): minerva_codetools_get_graph tool presence --")
	# conn.list_tools() will call tools/list if the cache is empty.
	var tools_list: Array = await conn.list_tools()
	var found_get_graph := false
	for tool_entry in tools_list:
		var tool_name: String = ""
		if tool_entry is Dictionary:
			tool_name = str(tool_entry.get("name", ""))
		elif tool_entry != null and "name" in tool_entry:
			tool_name = str(tool_entry.name)
		if tool_name == "minerva_codetools_get_graph":
			found_get_graph = true
			break
	# Also check via the connection's has_tool convenience (populated by list_tools).
	if not found_get_graph:
		found_get_graph = conn.has_tool("minerva_codetools_get_graph")
	if not found_get_graph:
		# Non-fatal: codetools "tools" in manifest is [] (runtime-registered tools
		# are returned by tools/list at runtime). If the list came back empty or the
		# tool wasn't listed, emit a WARN rather than FAIL — this bonus step should
		# not block Gate-A from passing.
		print("WARN: minerva_codetools_get_graph not found in tools/list (tools=%d entries)" % tools_list.size())
		print("      This may mean the tool is registered under a different name or")
		print("      that the worker's tools/list handler omits it. (Non-blocking WARN.)")
	else:
		print("PASS: minerva_codetools_get_graph found in running plugin tool list")
		_pass += 1

	# =========================================================================
	# Step 6: clean stop
	# =========================================================================
	print("\n-- step 6: stop_plugin --")
	var stop_result: Dictionary = await _pm.stop_plugin(PLUGIN_ID)
	if not stop_result.get("ok", false):
		print("WARN: stop_plugin failed (non-fatal): %s" % JSON.stringify(stop_result))
	elif def.state == _helper.S_STOPPED:
		print("PASS: clean stop (state=STOPPED)")
		_pass += 1


# ---------------------------------------------------------------------------
# Fixture build (mirrors test_marketplace_install_start_codetools.gd exactly)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Placeholder detection
# ---------------------------------------------------------------------------

## Return true if `node` looks like the diagnostic placeholder built by
## PluginScenePanelHost._build_placeholder() — a VBoxContainer with a red Label.
## The check is heuristic: real panel scenes from minerva-plugins are unlikely to
## be plain VBoxContainers with red-colored labels as their only significant child.
func _looks_like_placeholder(node: Control) -> bool:
	if not (node is VBoxContainer):
		return false
	# Walk children looking for a red-colored Label (the placeholder diagnostic).
	for child in node.get_children():
		if child is Label:
			# _build_placeholder sets font_color to Color(1.0, 0.4, 0.4).
			# A real panel's label would not start with "[PluginScenePanelHost]".
			var lbl := child as Label
			if lbl.text.begins_with("[PluginScenePanelHost]"):
				return true
	return false


func _skip(reason: String) -> void:
	_skipped = true
	_skip_reason = reason


func _teardown() -> void:
	if _helper != null:
		if _pm != null and _pm._db != null and _pm._db.has_plugin(PLUGIN_ID):
			_pm._db.remove(PLUGIN_ID)
			_helper.rm_dir_recursive("user://plugins/%s" % PLUGIN_ID)
		_helper.teardown()
	if not _temp_dir.is_empty():
		OS.execute("rm", ["-rf", _temp_dir], [], true)
