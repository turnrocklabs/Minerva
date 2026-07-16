extends SceneTree
## CAD panel-tool adoption E2E — second-plugin proof for the panel-executed
## MCP tools substrate (DCR 019f6c3d0e3d; round C6 docket 019f6c469422).
##
## Run: godot --headless --path src --script test/test_cad_panel_tool_adoption.gd
##
## Purpose (DCR acceptance criterion d): prove the executor:"panel" dispatch
## path (Docs/design/panel-executed-tools.md §2) is generic, not a pcb
## special case, by driving a SECOND plugin's panel tool
## (minerva_cad_view_state, cad/ui/panel_tools.gd) through the REAL
## PluginToolRegistry.handle_tool_call path against a REAL CADPanel scene —
## no stubs, no subprocess (panel tools never need one, contract §2 step 1).
##
## THIS FILE (+ its .uid) IS THE ENTIRE MINERVA-SIDE DIFF FOR THIS ROUND.
## Every other C6 change lives in minerva-plugins' cad/** + docs/ (the DCR's
## scope fence). The diffstat is the assertion the DCR asks for — this test
## exists to prove the *behavior* the diffstat implies, not to touch core.
##
## REUSE SCAN: fixture stack is test/helpers/panel_tool_registry_driver.gd —
## the same helper test_pcb_panel_tools_migration.gd (C2/C3) uses, extracted
## from the C1 round's own test_panel_executed_tools.gd fixture wiring. That
## reuse is itself part of the proof: no new dispatch-test plumbing was
## needed to onboard a second plugin.
##
## Scene-mounting note: unlike PCBPanel (built via plugin_panel_driver.gd,
## which instantiates the bare script — PCBPanel builds its host in _init()),
## CADPanel builds its layout/camera/host state in _ready() from child nodes
## declared in CADPanel.tscn. So this test loads the real .tscn as a
## PackedScene, instantiates it, adds it under `root`, and awaits one
## process_frame so _ready() runs — mirroring how test_cad_evaluate_render.gd
## / test_cad_plugin_smoke.gd already await process_frame for autoload/node
## readiness, and how PluginScenePanelHost.gd mounts production scene panels
## (steps 8-9: instantiate + add_child), just without that path's
## broker-audit/whitelist machinery, which this fixture doesn't need to
## prove the dispatcher contract.

const CAD_PANEL_TSCN := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")

const EDITOR := "CADViewStateAdoption"
const CAD_PLUGIN_ID := "cad"
const TOOL_NAME := "minerva_cad_view_state"

## A second, wholly separate plugin id used ONLY to prove ownership
## enforcement generalizes to cad (mirrors test_panel_executed_tools.gd's
## pxa/pxb cross-plugin fixture and test_pcb_panel_tools_migration.gd's
## single-plugin gate — here the "other plugin" trying to reach into cad's
## panel is the new wrinkle this round needs to prove).
const DECOY_PLUGIN_ID := "cad_decoy_probe_plugin"
const DECOY_TOOL_NAME := "minerva_cad_decoy_probe_plugin_probe"

var _pass := 0
var _fail := 0

var panel: Node = null  # CADPanel (duck-typed Node — off-tree, never typed by class_name)
var registry: PluginToolRegistry = null


func _init() -> void:
	print("=== CAD Panel-Tool Adoption E2E (C6 second-plugin proof) ===\n")

	if not await _setup():
		printerr("SETUP FAILED — cannot mount CADPanel; aborting")
		quit(1)
		return

	await _run_happy_path()
	await _run_structured_errors()

	_teardown()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── setup / teardown ──────────────────────────────────────────────────────────

func _setup() -> bool:
	var packed: PackedScene = load(CAD_PANEL_TSCN) as PackedScene
	if packed == null:
		printerr("could not load CADPanel.tscn at %s" % CAD_PANEL_TSCN)
		return false

	var instance: Node = packed.instantiate()
	if instance == null:
		printerr("PackedScene.instantiate() returned null for CADPanel.tscn")
		return false
	panel = instance

	root.add_child(panel)
	# _ready() runs at end-of-frame for nodes added to an already-running
	# tree — the same reason test_cad_evaluate_render.gd / test_cad_plugin_smoke.gd
	# await process_frame after root.add_child(pm) before touching pm state.
	await process_frame

	if not panel.has_method("get_view_state"):
		printerr("CADPanel instance has no get_view_state() — C6 panel change missing")
		return false
	if not panel.has_method("handle_tool"):
		printerr("CADPanel instance has no handle_tool() — C6 panel change missing")
		return false

	registry = REGISTRY_DRIVER.new().build(panel, CAD_PLUGIN_ID, EDITOR, [TOOL_NAME])
	if registry == null:
		return false

	# Register the decoy plugin's tool against the SAME broker/registry so
	# test_ownership_enforced_for_cad below can prove a second plugin cannot
	# reach cad's panel through it.
	var decoy_result: Dictionary = registry.register_plugin_tools(DECOY_PLUGIN_ID, [{
		"name": DECOY_TOOL_NAME,
		"description": "test fixture — decoy plugin probing another plugin's panel",
		"input_schema": {"type": "object", "properties": {}},
		"executor": "panel",
	}])
	if decoy_result.has("error"):
		printerr("decoy plugin tool registration failed: %s" % str(decoy_result))
		return false

	return true


func _teardown() -> void:
	if panel != null and is_instance_valid(panel):
		panel.queue_free()


# ── assertion helpers ─────────────────────────────────────────────────────────

func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail.is_empty():
			printerr("  FAIL: %s" % desc)
		else:
			printerr("  FAIL: %s — %s" % [desc, detail])


## Dispatch through the REAL PluginToolRegistry — the (1) proof: this suite
## never calls CADPanel.handle_tool or panel_tools.gd directly.
func d(tool_name: String, args: Dictionary) -> Dictionary:
	return await registry.handle_tool_call(tool_name, args)


# ── happy path ─────────────────────────────────────────────────────────────────

func _run_happy_path() -> void:
	print("-- minerva_cad_view_state: happy path --")
	var r: Dictionary = await d(TOOL_NAME, {"editor_name": EDITOR})

	check("dispatched ok (no error key)", not r.has("error") and not r.has("error_code"), str(r))
	check("success == true", r.get("success", false) == true, str(r))

	var got_keys := r.keys()
	got_keys.sort()
	var want_keys := ["active_viewport_id", "camera", "is_narrow_layout", "projection_preset", "success", "width_class"]
	want_keys.sort()
	check("result shape — keys %s == %s" % [str(got_keys), str(want_keys)], got_keys == want_keys)

	var width_class := str(r.get("width_class", ""))
	check("width_class is a known ResponsiveContainer breakpoint",
		["xs", "sm", "md", "lg", "xl"].has(width_class), "got '%s'" % width_class)

	check("is_narrow_layout is a bool", typeof(r.get("is_narrow_layout")) == TYPE_BOOL)

	var viewport_id := str(r.get("active_viewport_id", ""))
	check("active_viewport_id is non-empty", not viewport_id.is_empty())

	check("projection_preset is non-empty",
		not str(r.get("projection_preset", "")).is_empty())

	var camera = r.get("camera")
	check("camera is present (not null) — CADPanel.tscn always has at least one OrbitCamera",
		camera is Dictionary, str(r))
	if camera is Dictionary:
		var cam_keys: Array = (camera as Dictionary).keys()
		cam_keys.sort()
		var want_cam_keys := ["distance", "pitch", "target", "view_preset", "yaw"]
		want_cam_keys.sort()
		check("camera shape — keys %s == %s" % [str(cam_keys), str(want_cam_keys)], cam_keys == want_cam_keys)
		var target = camera.get("target")
		check("camera.target is a 3-element array", target is Array and (target as Array).size() == 3,
			str(target))
		check("camera.distance is finite and positive",
			typeof(camera.get("distance")) in [TYPE_FLOAT, TYPE_INT] and float(camera.get("distance", 0.0)) > 0.0,
			str(camera.get("distance")))
		check("camera.yaw is numeric", typeof(camera.get("yaw")) in [TYPE_FLOAT, TYPE_INT])
		check("camera.pitch is numeric", typeof(camera.get("pitch")) in [TYPE_FLOAT, TYPE_INT])
		check("camera.view_preset is a non-empty string",
			not str(camera.get("view_preset", "")).is_empty())

	print("    view_state: %s" % str(r).left(300))

	# Cross-check: get_view_state() called directly on the panel must match
	# what the dispatcher returned (minus the success envelope) — proves
	# panel_tools.gd's _ok() wraps verbatim, no silent mutation.
	var direct: Dictionary = panel.get_view_state()
	check("dispatcher result matches panel.get_view_state() directly (verbatim passthrough)",
		r.get("width_class") == direct.get("width_class")
			and r.get("active_viewport_id") == direct.get("active_viewport_id")
			and r.get("projection_preset") == direct.get("projection_preset"),
		"dispatched=%s direct=%s" % [str(r), str(direct)])


# ── structured errors (contract §2, proven again for a SECOND plugin) ──────────

func _run_structured_errors() -> void:
	print("\n-- structured errors hold for cad (a second plugin) --")

	print("editor_name_required:")
	var e1: Dictionary = await d(TOOL_NAME, {})
	check("missing editor_name -> editor_name_required",
		e1.get("error_code", "") == "editor_name_required", str(e1))

	print("editor_not_found:")
	var e2: Dictionary = await d(TOOL_NAME, {"editor_name": "NoSuchCadEditor"})
	check("unknown editor -> editor_not_found", e2.get("error_code", "") == "editor_not_found", str(e2))
	var known: Array = e2.get("known_editors", [])
	check("known_editors lists the registered cad editor", known.has(EDITOR), str(e2))

	print("panel_not_owned (second plugin against cad's panel):")
	var e3: Dictionary = await d(DECOY_TOOL_NAME, {"editor_name": EDITOR})
	check("a different plugin's tool cannot execute against cad's panel -> panel_not_owned",
		e3.get("error_code", "") == "panel_not_owned", str(e3))
	check("error reports cad as the actual owner",
		e3.get("owner_plugin_id", "") == CAD_PLUGIN_ID, str(e3))
