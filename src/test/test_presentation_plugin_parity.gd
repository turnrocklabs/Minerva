extends SceneTree
## T7 case 6 — presentation plugin parity through plugin-owned MCP tools.
##
## Run: godot --headless --path src --script test/test_presentation_plugin_parity.gd
##
## Tracks docket: minerva 019e1957d815783292d1ff477984a280 (T7 case-6 follow-up)
## Parent test:    minerva 019df8e3c9d57472a7d721785f5f783c (T7)
## Parent DCR:     minerva 019df8e2d0937613a326389a4df133fb (broker DCR)
##
## Drives the presentation plugin end-to-end through PluginManager +
## MCPServerConnection.call_tool. Verifies the migration contract from T6 +
## T6 tail: every minerva_presentation_* tool is served by the plugin and
## ZERO are still resident in Minerva core (MCPPresentationTools.gd has
## been deleted).
##
## Coverage:
##   - tools/list reports ≥27 minerva_presentation_* tools after start
##   - Core MinervaMCPServer.tool_registry has zero minerva_presentation_*
##     entries (regression guard — the heart of case 6)
##   - create_deck writes a real .mdeck to disk
##   - add_slide returns the expected slide_index
##   - add_text_tile + list_tiles + modify_tile round-trip
##   - list_annotation_kinds returns substrate-valid [callout, 2d_arrow, 2d_text]
##     (regression for the contract bug fixed in T6 tail R2)
##   - add_annotation + list_open_annotations + remove_annotation round-trip
##   - open_deck wire path: in headless editor_pane is unavailable so the
##     plugin surfaces editor_pane_unavailable cleanly (rather than crashing)
##
## NOTE: live UI-state piggyback (selected_slide_index via get_state) is
## NOT covered here — that requires a real SlideEditorPanel scene running
## in-tree. The Go-side unit tests for toolGetState cover the wire shape.
## Live verification is deferred to manual HITL.

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_ID := "presentation"
const MANIFEST_PATH := "/home/imran/github/plugins/presentation/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

const HOST_CAPS := [
	"host.documents.list_open",
	"host.documents.get_state",
	"host.documents.set_state",
	"host.documents.get_node",
	"host.documents.get_blob",
	"host.documents.patch_state",
	"host.documents.put_blob",
	"host.editors.export",
	"host.editors.open",
]

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== T7 case 6 — presentation plugin parity ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	if not FileAccess.file_exists(MANIFEST_PATH):
		printerr("FAIL: presentation plugin manifest not found at %s" % MANIFEST_PATH)
		_fail += 1
		return

	await process_frame
	var so = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload exists", so != null)
	if so == null:
		return

	# Wait for plugin_scene_panel_broker (SingletonObject wired).
	var deadline := Time.get_ticks_msec() + 10000
	while so.get("plugin_scene_panel_broker") == null and Time.get_ticks_msec() < deadline:
		await Engine.get_main_loop().create_timer(0.1).timeout
	check("plugin_scene_panel_broker initialised",
		so.get("plugin_scene_panel_broker") != null)

	# -------------------------------------------------------------------
	# Regression guard #1: Minerva core has ZERO minerva_presentation_* tools.
	# This is the case-6 acceptance criterion — MCPPresentationTools.gd was
	# deleted in T6 tail R6; if any presentation tool name reappears in
	# core's registry, something has been re-introduced.
	# -------------------------------------------------------------------
	# SingletonObject.mcp_manager holds the tool_registry where _register_tool
	# inserts every minerva_* tool name. Path: so.mcp_manager.tool_registry.
	var mgr = so.get("mcp_manager") if "mcp_manager" in so else null
	check("SingletonObject.mcp_manager available", mgr != null)
	if mgr != null and "tool_registry" in mgr:
		var registry: Dictionary = mgr.tool_registry
		var core_pres_count := 0
		var core_pres_names: Array = []
		for name in registry.keys():
			if str(name).begins_with("minerva_presentation_"):
				core_pres_count += 1
				core_pres_names.append(name)
		check("ZERO minerva_presentation_* tools in core registry (case 6 regression guard)",
			core_pres_count == 0,
			"Found %d in core: %s" % [core_pres_count, str(core_pres_names)])

	# -------------------------------------------------------------------
	# Bring up the presentation plugin via PluginManager.
	# -------------------------------------------------------------------
	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame
	check("PluginManager initialised", pm._db != null)

	var db = pm._db
	var def = db.get_by_id(PLUGIN_ID)
	if def == null:
		var install = await pm.install_plugin(MANIFEST_PATH, true)
		check("install_plugin ok", install.get("ok", false) == true,
			"got: %s" % str(install))
		def = db.get_by_id(PLUGIN_ID)
	check("presentation definition loaded", def != null)
	if def == null:
		return

	if def.state == S_RUNNING:
		await pm.stop_plugin(PLUGIN_ID)

	# Grant all 9 host capabilities the manifest declares.
	var policy = pm.get_policy()
	if policy == null:
		policy = so.get("plugin_policy") if "plugin_policy" in so else null
	check("plugin policy available", policy != null)
	if policy != null:
		for cap in HOST_CAPS:
			policy.grant_capability(PLUGIN_ID, cap)

	var start = await pm.start_plugin(PLUGIN_ID)
	check("start_plugin ok", start.get("ok", false) == true,
		"got: %s" % str(start))
	check("state == RUNNING", def.state == S_RUNNING,
		"state=%d" % def.state)

	var conn = pm.get_connection(PLUGIN_ID)
	check("connection exists", conn != null)
	if conn == null:
		await pm.stop_plugin(PLUGIN_ID)
		return

	# Wait for tools/list discovery to settle.
	await Engine.get_main_loop().create_timer(2.0).timeout

	# -------------------------------------------------------------------
	# Regression guard #2: plugin advertises the full 27-tool surface.
	# -------------------------------------------------------------------
	var ptr = so.get("plugin_tool_registry") if "plugin_tool_registry" in so else null
	check("plugin_tool_registry available", ptr != null)
	if ptr != null and ptr.has_method("get_tools_for_plugin"):
		var plugin_tools: Array = ptr.get_tools_for_plugin(PLUGIN_ID)
		check("plugin advertises ≥27 tools (19 from T6 + 8 from T6 tail)",
			plugin_tools.size() >= 27,
			"plugin tool count=%d" % plugin_tools.size())
		# Every plugin tool must use the minerva_presentation_ prefix
		# (enforced at manifest validation, but worth catching here too).
		var all_prefixed := true
		var bad_names: Array = []
		for t in plugin_tools:
			var name: String = ""
			if t is Dictionary and t.has("name"):
				name = str(t["name"])
			else:
				name = str(t)
			if not name.begins_with("minerva_presentation_"):
				all_prefixed = false
				bad_names.append(name)
		check("all plugin tools use minerva_presentation_ prefix",
			all_prefixed,
			"bad names: %s" % str(bad_names))

	# -------------------------------------------------------------------
	# Fresh temp deck for the round-trip block.
	# -------------------------------------------------------------------
	var deck_path: String = OS.get_user_data_dir().path_join(
		"case6_deck_%d.mdeck" % Time.get_ticks_msec())
	if FileAccess.file_exists(deck_path):
		DirAccess.remove_absolute(deck_path)

	# -------------------------------------------------------------------
	# create_deck — wire-level happy path.
	# -------------------------------------------------------------------
	print("\n-- create_deck --")
	var c_call = await conn.call_tool("minerva_presentation_create_deck", {
		"path": deck_path,
		"title": "Case6",
	})
	check("create_deck returned Dictionary", c_call is Dictionary)
	if c_call is Dictionary:
		check("create_deck reports success",
			c_call.get("success", false) == true,
			"got: %s" % str(c_call).substr(0, 200))
	check("deck file written to disk", FileAccess.file_exists(deck_path))

	# -------------------------------------------------------------------
	# add_slide — slide_index=1 (deck starts with 1 slide).
	# -------------------------------------------------------------------
	print("\n-- add_slide --")
	var s_call = await conn.call_tool("minerva_presentation_add_slide", {
		"path": deck_path,
		"title": "Second Slide",
	})
	check("add_slide reported success", s_call is Dictionary and s_call.get("success", false) == true,
		"got: %s" % str(s_call).substr(0, 200))
	if s_call is Dictionary:
		var sidx = s_call.get("slide_index")
		check("add_slide slide_index == 1", sidx != null and int(sidx) == 1,
			"got slide_index=%s" % str(sidx))

	# -------------------------------------------------------------------
	# add_text_tile + list_tiles + modify_tile.
	# -------------------------------------------------------------------
	print("\n-- add_text_tile --")
	var t_call = await conn.call_tool("minerva_presentation_add_text_tile", {
		"path": deck_path,
		"slide_index": 0,
		"x": 0.1, "y": 0.1, "w": 0.5, "h": 0.2,
		"content": "case 6 text",
	})
	check("add_text_tile reported success", t_call is Dictionary and t_call.get("success", false) == true,
		"got: %s" % str(t_call).substr(0, 200))
	var tile_id: String = ""
	if t_call is Dictionary:
		tile_id = str(t_call.get("tile_id", ""))

	print("\n-- list_tiles --")
	var lt_call = await conn.call_tool("minerva_presentation_list_tiles", {
		"path": deck_path,
		"slide_index": 0,
	})
	check("list_tiles reported success", lt_call is Dictionary and lt_call.get("success", false) == true,
		"got: %s" % str(lt_call).substr(0, 200))
	if lt_call is Dictionary:
		var tiles: Variant = lt_call.get("tiles")
		check("list_tiles returned 1 tile",
			tiles is Array and tiles.size() == 1,
			"got: %s" % str(tiles))

	if not tile_id.is_empty():
		print("\n-- modify_tile --")
		var m_call = await conn.call_tool("minerva_presentation_modify_tile", {
			"path": deck_path,
			"slide_index": 0,
			"tile_id": tile_id,
			"content": "case 6 modified",
		})
		check("modify_tile reported success", m_call is Dictionary and m_call.get("success", false) == true,
			"got: %s" % str(m_call).substr(0, 200))

	# -------------------------------------------------------------------
	# list_annotation_kinds — regression for the substrate-invalid catalogue
	# bug fixed in T6 tail R2. Must return exactly [callout, 2d_arrow, 2d_text].
	# -------------------------------------------------------------------
	print("\n-- list_annotation_kinds --")
	var lak_call = await conn.call_tool("minerva_presentation_list_annotation_kinds", {})
	check("list_annotation_kinds reported success",
		lak_call is Dictionary and lak_call.get("success", false) == true,
		"got: %s" % str(lak_call).substr(0, 200))
	if lak_call is Dictionary:
		var kinds: Variant = lak_call.get("kinds")
		var kind_names: Array = []
		if kinds is Array:
			for k in kinds:
				if k is Dictionary and k.has("kind"):
					kind_names.append(str(k["kind"]))
		check("list_annotation_kinds returns substrate-valid set [callout, 2d_arrow, 2d_text]",
			kind_names.size() == 3
				and "callout" in kind_names
				and "2d_arrow" in kind_names
				and "2d_text" in kind_names,
			"got: %s" % str(kind_names))
		var schema_version = lak_call.get("schema_version")
		check("list_annotation_kinds reports schema_version=2",
			schema_version != null and int(schema_version) == 2,
			"got: %s" % str(schema_version))

	# -------------------------------------------------------------------
	# add_annotation + list_open_annotations + remove_annotation round-trip.
	# -------------------------------------------------------------------
	print("\n-- add_annotation --")
	var a_call = await conn.call_tool("minerva_presentation_add_annotation", {
		"path": deck_path,
		"slide_index": 0,
		"kind": "callout",
		"summary": "case 6 todo",
	})
	check("add_annotation reported success", a_call is Dictionary and a_call.get("success", false) == true,
		"got: %s" % str(a_call).substr(0, 200))
	var ann_id: String = ""
	if a_call is Dictionary:
		ann_id = str(a_call.get("annotation_id", ""))
		check("add_annotation returned annotation_id", not ann_id.is_empty())

	print("\n-- list_open_annotations --")
	var loa_call = await conn.call_tool("minerva_presentation_list_open_annotations", {
		"path": deck_path,
	})
	check("list_open_annotations reported success",
		loa_call is Dictionary and loa_call.get("success", false) == true,
		"got: %s" % str(loa_call).substr(0, 200))
	if loa_call is Dictionary:
		var count_raw = loa_call.get("count")
		check("list_open_annotations count == 1",
			count_raw != null and int(count_raw) == 1,
			"got count=%s" % str(count_raw))

	if not ann_id.is_empty():
		print("\n-- remove_annotation --")
		var ra_call = await conn.call_tool("minerva_presentation_remove_annotation", {
			"path": deck_path,
			"slide_index": 0,
			"annotation_id": ann_id,
		})
		check("remove_annotation reported success",
			ra_call is Dictionary and ra_call.get("success", false) == true,
			"got: %s" % str(ra_call).substr(0, 200))

	# -------------------------------------------------------------------
	# open_deck — wire path verification. In headless editor_pane isn't
	# available, so the plugin's open_deck surfaces editor_pane_unavailable
	# cleanly (rather than crashing). The full happy path is HITL.
	# -------------------------------------------------------------------
	print("\n-- open_deck (headless wire check) --")
	var o_call = await conn.call_tool("minerva_presentation_open_deck", {
		"path": deck_path,
	})
	check("open_deck returned Dictionary (wire path completed)", o_call is Dictionary)
	if o_call is Dictionary:
		var ok: bool = o_call.get("success", false) == true
		var code: String = str(o_call.get("error_code", ""))
		# Either headless dispatch fails cleanly with editor_pane_unavailable,
		# OR the full Minerva is up and the open succeeds. Both are acceptable
		# wire-level outcomes here; the plugin and broker just need to talk.
		check("open_deck either succeeded or failed cleanly with editor_pane_unavailable",
			ok or code == "editor_pane_unavailable",
			"got success=%s error_code=%s" % [str(ok), code])

	# -------------------------------------------------------------------
	# Teardown.
	# -------------------------------------------------------------------
	print("\n-- Teardown --")
	await pm.stop_plugin(PLUGIN_ID)
	if FileAccess.file_exists(deck_path):
		DirAccess.remove_absolute(deck_path)


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		var msg := "  FAIL: %s" % desc
		if not detail.is_empty():
			msg += " | %s" % detail
		printerr(msg)
