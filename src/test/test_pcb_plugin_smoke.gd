extends SceneTree
## PCB plugin walking-skeleton smoke test.
##
## Run: godot --headless --path src --script test/test_pcb_plugin_smoke.gd
##
## Two independent sections:
##
##   A. SUBSTRATE-SEAM behavior (pure GDScript — NO Go binary, NO autoloads):
##        - PcbAnnotationHost instantiates and registers the pcb_route_hint kind.
##        - add_route_hint_at() builds a v2 envelope that passes
##          AnnotationV2Schema.validate_with_registry (the CONFORMANT path —
##          modeled on TextEditorAnnotationHost, not CadAnnotationHost; C-32).
##        - AnnotationHostRegistry.register + get_host round-trips (the seam the
##          MCP annotation tools use to reach a live host by editor_name).
##        - AnnotationSidecar write+read round-trips through the host.
##        - PluginEditorRegistry: `.minpcb` is silently skipped (core-extension
##          claim; confirms gap register A-10), `.pcbskel` registers cleanly.
##      This section is what runs on THIS machine (Go toolchain absent, so the
##      backend binary can't be built; project autoloads need Godot 4.5+).
##
##   B. PLUGIN LIFECYCLE handshake (needs the built pcb-plugin Go binary +
##      autoloads): install → start → tools/list → dynamic tool discovery →
##      stop. SKIPPED gracefully when the binary isn't present. Preserved from
##      the scaffold round so it runs in CI where the binary exists.
##
## Tests assert BEHAVIOR (call methods, check return values), never
## class_exists/has_method — stale native registrations can shadow dead GDScript.

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const PLUGIN_TOOL_REGISTRY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginToolRegistry.gd"
const PLUGIN_EDITOR_REGISTRY_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginEditorRegistry.gd"
const PLUGIN_DEFINITION_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"

# Off-tree plugin scripts (loaded at RUNTIME via load() so a bad path FAILS a
# test rather than aborting the whole script at parse time). res:// == src/, so
# res://../../minerva-plugins == C:/github/minerva-plugins.
const PCB_HOST_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PcbAnnotationHost.gd"
const PCB_KIND_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/kinds/pcb_route_hint_kind.gd"
const PCB_PANEL_SCRIPT_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"

const PCB_PLUGIN_DIR_REL := "/github/minerva-plugins/pcb"
const PCB_BINARY_REL := "/pcb-plugin"
const PCB_MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== PCB Plugin Walking-Skeleton Smoke Test ===\n")

	# Autoloads register lazily in --script mode; wait a frame before touching
	# any autoload / class registration.
	await process_frame

	# ── Section A: substrate-seam behavior (no binary needed) ─────────────────
	print("########## SECTION A — substrate-seam behavior ##########\n")
	_test_annotation_host_and_kind()
	_test_envelope_validation()
	_test_host_registry_roundtrip()
	_test_sidecar_roundtrip()
	_test_panel_save_flow()
	_test_editor_registry_extension_routing()

	# ── Section B: plugin lifecycle (needs built Go binary) ───────────────────
	print("\n########## SECTION B — plugin lifecycle handshake ##########\n")
	var home: String = OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	var plugin_dir: String = OS.get_environment("MINERVA_PCB_PLUGIN_DIR")
	if plugin_dir == "" and home != "":
		plugin_dir = home + PCB_PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + PCB_BINARY_REL
	var manifest_path: String = plugin_dir + PCB_MANIFEST_REL
	# Windows builds carry a .exe suffix (same fallback as PluginManager.gd)
	if not FileAccess.file_exists(binary_path) and FileAccess.file_exists(binary_path + ".exe"):
		binary_path += ".exe"

	if plugin_dir == "" or not FileAccess.file_exists(binary_path):
		print("SKIP: pcb-plugin binary not built at '%s'." % binary_path)
		print("      (Go toolchain absent on this host — Section B not exercised.)")
		print("      Build with: cd %s && go build -o pcb-plugin ." % plugin_dir)
	else:
		await _run_lifecycle_tests(manifest_path)

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ──────────────────────────────────────────────────────────────────────────────
# Section A tests
# ──────────────────────────────────────────────────────────────────────────────

func _load_host() -> AnnotationHost:
	var host_script: Script = load(PCB_HOST_SCRIPT_PATH)
	if host_script == null:
		return null
	return host_script.new() as AnnotationHost


func _test_annotation_host_and_kind() -> void:
	print("-- host instantiates + registers pcb_route_hint kind --")
	var host := _load_host()
	check("PcbAnnotationHost loads + instantiates", host != null)
	if host == null:
		return
	var registry: AnnotationRegistry = host.get_registry()
	check("host.get_registry() returns a registry", registry != null)
	if registry == null:
		return
	check("registry has pcb_route_hint kind", registry.has_kind(&"pcb_route_hint"))
	var kind := registry.get_annotation_kind(&"pcb_route_hint")
	check("pcb_route_hint kind owned by 'pcb'", kind != null and kind.owning_plugin == &"pcb")
	check("kind accepts pcb/board.point anchor",
			kind != null and "pcb/board.point" in kind.accepted_anchor_types())


func _test_envelope_validation() -> void:
	print("\n-- add_route_hint_at builds a schema-conformant v2 envelope --")
	var host := _load_host()
	if host == null:
		check("PcbAnnotationHost loads (envelope test)", false)
		return
	var ann_id: String = host.add_route_hint_at(
			12.0, 9.0, "keep 50R away from U1", "F.Cu", "waypoint", [[12.0, 9.0], [30.0, 9.0]], "human")
	check("add_route_hint_at returns a non-empty id (envelope validated + stored)", ann_id != "",
			"got id='%s' — validation likely failed (see warnings)" % ann_id)
	check("host now holds exactly one annotation", host.get_annotations().size() == 1)

	# Independently validate the stored envelope against the shipped schema.
	if host.get_annotations().size() == 1:
		var env: Dictionary = host.get_annotations()[0]
		var schema = load("res://Scripts/Services/Annotations/AnnotationV2Schema.gd").new()
		var result = schema.validate_with_registry(env, host.get_registry())
		check("stored envelope passes AnnotationV2Schema.validate_with_registry",
				not result.has_errors(),
				"errors: %s" % (str(result.to_error_dicts()) if result != null else "<null>"))
		# Spot-check the conformant field set (kind_payload, not payload).
		check("envelope uses 'kind_payload' (conformant) not 'payload'",
				env.has("kind_payload") and not env.has("payload"))
		check("envelope has lifecycle/visible_in_views/summary/author-dict",
				env.get("lifecycle", "") == "open"
				and env.get("visible_in_views", []) == ["all"]
				and str(env.get("summary", "")) != ""
				and env.get("author", {}) is Dictionary)

	# Negative: a CadAnnotationHost-style envelope (payload, no kind_payload,
	# no lifecycle/summary) must be REJECTED — proves the conformance gate bites.
	print("\n-- non-conformant (Cad-style) envelope is rejected --")
	var bad_id: String = host.add_annotation_v2({
		"kind": "pcb_route_hint",
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 1.0, "y": 1.0}},
		"payload": {"text": "no kind_payload here"},
	})
	check("non-conformant envelope rejected (empty id returned)", bad_id == "",
			"got id='%s' — schema gate did NOT bite" % bad_id)


func _test_host_registry_roundtrip() -> void:
	print("\n-- AnnotationHostRegistry register/get round-trip (MCP reach seam) --")
	AnnotationHostRegistry._reset_for_test()
	var host := _load_host()
	if host == null:
		check("PcbAnnotationHost loads (registry test)", false)
		return
	var editor_name := "PCB Skeleton Board"
	AnnotationHostRegistry.register(editor_name, host)
	check("host retrievable by editor_name", AnnotationHostRegistry.get_host(editor_name) == host)
	check("editor_name listed in registry", editor_name in AnnotationHostRegistry.list_editor_names())

	# The MCP annotation tools read a live host's annotations via get_annotations()
	# / get_all_annotations(). Author one hint and confirm it's visible that way.
	host.add_route_hint_at(20.0, 15.0, "bus to J1", "B.Cu", "bus", [], "ai")
	var reached: AnnotationHost = AnnotationHostRegistry.get_host(editor_name)
	check("live host exposes the hint via get_all_annotations() (query seam)",
			reached != null and reached.get_all_annotations().size() == 1)
	# Deregister (panel _on_panel_unload contract).
	AnnotationHostRegistry.deregister(editor_name)
	check("host gone after deregister", AnnotationHostRegistry.get_host(editor_name) == null)
	AnnotationHostRegistry._reset_for_test()


func _test_sidecar_roundtrip() -> void:
	print("\n-- AnnotationSidecar write+read round-trip through the host --")
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var board_dir: String = driver.make_temp_board_dir("pcb_skel_smoke")
	var board_path := board_dir + "/board.pcbskel"
	var sidecar_path: String = driver.sidecar_path_for(board_path)
	# Clean any leftover from a prior run.
	driver.cleanup_sidecar(board_path)

	var host := _load_host()
	if host == null:
		check("PcbAnnotationHost loads (sidecar test)", false)
		return
	var id1: String = host.add_route_hint_at(5.0, 5.0, "hint one", "F.Cu", "waypoint", [], "human")
	var id2: String = host.add_route_hint_at(25.0, 18.0, "hint two", "B.Cu", "single_trace", [[25.0, 18.0], [40.0, 18.0]], "ai")
	check("authored two hints pre-save", id1 != "" and id2 != "")

	var werr: int = host.save_sidecar(board_path)
	check("save_sidecar returns OK", werr == OK, "got Error=%d" % werr)
	check("sidecar file exists on disk", FileAccess.file_exists(sidecar_path))

	# Fresh host reads it back.
	var host2 := _load_host()
	var loaded: int = host2.load_sidecar(board_path) if host2 != null else -1
	check("load_sidecar returns 2 annotations", loaded == 2, "got %d" % loaded)
	if host2 != null and loaded == 2:
		var round := host2.get_annotations()
		var ids: Array = []
		var summaries: Array = []
		for a in round:
			ids.append(str(a.get("id", "")))
			summaries.append(str(a.get("summary", "")))
		check("round-tripped ids preserved", id1 in ids and id2 in ids,
				"ids=%s" % str(ids))
		check("round-tripped envelope still schema-valid",
				_all_valid(round, host2))
		check("summaries survived round-trip", summaries.size() == 2 and summaries[0] != "")

	# Cleanup.
	driver.cleanup_sidecar(board_path)


## Regression for W-15 (live 3b failure): the PANEL's own load→annotate→save
## flow must write the sidecar. The load document mirrors Editor.gd:1117's
## shape — file_path merged with the JSON body — which the panel's JSON branch
## previously dropped, leaving _file_path empty and the sidecar never written.
func _test_panel_save_flow() -> void:
	print("\n-- Panel load→annotate→save writes the sidecar (W-15) --")
	var driver = preload("res://test/helpers/plugin_panel_driver.gd").new()
	var board_dir := driver.make_temp_board_dir("pcb_skel_smoke")
	var board_path := board_dir + "/flow.pcbskel"
	var sidecar_path := driver.sidecar_path_for(board_path)
	driver.cleanup_sidecar(board_path)

	var panel: Variant = driver.load_panel(PCB_PANEL_SCRIPT_PATH)
	check("PCBPanel script loads", panel != null)
	if panel == null:
		return
	driver.drive_load_merged(panel, board_path, {
		"version": 1,
		"kind": "pcbskel_board",
		"board": {"width_mm": 60.0, "height_mm": 40.0},
		"components": [],
	})
	var host: Variant = panel.get_annotation_host()
	var hid: String = host.add_route_hint_at(3.0, 3.0, "flow hint")
	check("panel flow: hint authored after load", hid != "")
	driver.drive_save(panel)
	check("panel flow: save request writes sidecar beside board file",
			FileAccess.file_exists(sidecar_path))
	driver.cleanup_sidecar(board_path)
	driver.free_panel(panel)


func _all_valid(annotations: Array, host: AnnotationHost) -> bool:
	var schema = load("res://Scripts/Services/Annotations/AnnotationV2Schema.gd").new()
	for a in annotations:
		if not a is Dictionary:
			return false
		var result = schema.validate_with_registry(a, host.get_registry())
		if result.has_errors():
			push_warning("[pcb-smoke] round-trip envelope invalid: %s" % str(result.to_error_dicts()))
			return false
	return true


func _test_editor_registry_extension_routing() -> void:
	print("\n-- PluginEditorRegistry: .minpcb silently skipped, .pcbskel routes --")
	var reg_script: Script = load(PLUGIN_EDITOR_REGISTRY_SCRIPT_PATH)
	check("PluginEditorRegistry loads", reg_script != null)
	if reg_script == null:
		return
	var reg = reg_script.new()

	# Build a minimal duck-typed def object with .id / .ui_panels / .editor_items.
	var def := _FakeDef.new()
	def.id = "pcb"
	def.ui_panels = [{
		"name": "pcb_panel",
		"kind": "godot_scene",
		"file_extensions": [".pcbskel", ".minpcb"],
	}]
	def.editor_items = [{"id": "new_pcb", "name": "New PCB", "panel": "pcb_panel", "default_filename": "untitled.pcbskel"}]

	var warnings: Array = reg.register_plugin(def)
	# .minpcb is a CORE_EXTENSION → declaration produces a warning + is skipped.
	var minpcb_skipped := false
	for w in warnings:
		if str(w).find(".minpcb") != -1:
			minpcb_skipped = true
			break
	check("declaring '.minpcb' produces a skip warning (confirms A-10 silent-skip)", minpcb_skipped,
			"warnings: %s" % str(warnings))
	check("'.minpcb' does NOT resolve to the plugin (core claim wins)",
			reg.resolve_extension(".minpcb").is_empty())
	# .pcbskel is not a core extension → registers and routes to the pcb panel.
	var resolved: Dictionary = reg.resolve_extension(".pcbskel")
	check("'.pcbskel' resolves to plugin 'pcb' / panel 'pcb_panel'",
			resolved.get("plugin_id", "") == "pcb" and resolved.get("panel_name", "") == "pcb_panel",
			"resolved: %s" % str(resolved))
	check("editor_item 'new_pcb' resolves to the pcb panel",
			reg.resolve_editor_kind("new_pcb").get("panel_name", "") == "pcb_panel")


## Minimal stand-in for PluginDefinition — PluginEditorRegistry only reads
## .id / .ui_panels / .editor_items via `in` + property access.
class _FakeDef extends RefCounted:
	var id: String = ""
	var ui_panels: Array = []
	var editor_items: Array = []


# ──────────────────────────────────────────────────────────────────────────────
# Section B — plugin lifecycle (binary-gated; preserved from scaffold round)
# ──────────────────────────────────────────────────────────────────────────────

func _run_lifecycle_tests(manifest_path: String) -> void:
	# Wait for SingletonObject.initialize_plugins() to finish wiring the tool
	# registry before exercising PluginManager.
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout

	var def_script = load(PLUGIN_DEFINITION_SCRIPT_PATH)
	check("PluginDefinition script loaded", def_script != null)
	if def_script != null:
		var parsed_def = def_script.from_manifest(manifest_path)
		check("manifest parses with zero validate() errors", parsed_def != null,
				"from_manifest returned null — see pushed validation errors above")

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		check("PluginManager.gd loads", false)
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
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true,
				"got: %s" % str(install_result))
		def = db.get_by_id("pcb")
	check("PCB definition loaded into DB", def != null)
	if def == null:
		return
	if def.state == S_RUNNING:
		await pm.stop_plugin("pcb")

	var start_result = await pm.start_plugin("pcb")
	check("start_plugin returns ok", start_result.get("ok", false) == true, "got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING, "got state=%d" % def.state)

	var conn = pm.get_connection("pcb")
	check("connection exists post-start", conn != null)
	if conn != null:
		var refresh_err: int = await conn.refresh_tools()
		check("refresh_tools returns OK", refresh_err == OK, "got Error=%d" % refresh_err)
		var tools = await conn.list_tools()
		var tool_names: Array[String] = []
		if tools is Array:
			for t in tools:
				if t != null and ("name" in t) and str(t.name) != "":
					tool_names.append(str(t.name))
		check("tools/list non-empty", tool_names.size() > 0)
		check("ping present", "ping" in tool_names, "got: %s" % str(tool_names))
		# New project channels must be advertised (dual-registration seam).
		check("pcb.serialize registered as backend tool", "pcb.serialize" in tool_names,
				"got: %s" % str(tool_names))

	var stop_result = await pm.stop_plugin("pcb")
	check("stop_plugin returns ok", stop_result.get("ok", false) == true)
	check("plugin state == STOPPED", def.state == S_STOPPED)


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
