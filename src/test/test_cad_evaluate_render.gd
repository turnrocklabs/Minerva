extends SceneTree
## Per-plugin functional test (W5) — F3. The CAD plugin evaluates a simple
## solid through the REAL MCPServerConnection and returns real 3D geometry.
##
## Run: godot --headless --path src --script test/test_cad_evaluate_render.gd
##
## Tracks docket: minerva RCA 019e46b5 / work-item W5 019e470b444f
##
## SCOPE — F3 is a per-plugin GEOMETRY GUARD, not a fail-first repro. It asserts
## cad.evaluate returns a mesh with triangle count > 0 and a finite,
## non-degenerate bounding box. It passes pre- and post-W1: it proves W1 did
## not break the CAD plugin, the same role the scansort/presentation tests
## play for their plugins.
##
## F3b extends this: it re-runs cad.evaluate through
## PluginScenePanelBroker._dispatch_to_plugin_backend — the broker→panel path
## the direct call_tool of F3 bypasses. F3b is the regression guard for bug #2
## (RCA 019e46b5 comment 20): the broker must deliver the {success:true,
## result:...} envelope CADPanel._evaluate_and_render is written against. F3
## passing 12/0 while CAD rendered nothing in the panel is exactly because its
## call_tool-only scope never exercised the broker — that gap is what F3b closes.
##
## Why F3 is NOT a headless concurrency repro: the cad plugin's MCP server is
## single-threaded over stdio (main.go:566 `for scanner.Scan() { dispatch(...) }`
## — no goroutine), so it serializes its own requests regardless of W1. W1 is a
## host-side fix; its CAD benefit (cad.evaluate is no longer queued behind other
## HOST traffic) is reproduced deterministically by the fixture test F2 and
## verified end-to-end by the W7 HITL panel check. See docket W5 019e470b444f.
##
## NOTE on the fixture: the .mcad format is a plain-text DSL, not a file, and
## cad.evaluate takes a `source` string. The repo ships no T-Beam example, so
## the verified cube source from the worker's own tests is used.
##
## NOTE: PluginManager.gd / MCPServerConnection.gd reference the SingletonObject
## autoload at parse time; in --script mode autoloads register lazily, so use a
## deferred load() rather than a top-level preload().

const PLUGIN_MANAGER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginManager.gd"
const BROKER_SCRIPT_PATH := "res://Scripts/Services/Plugins/PluginScenePanelBroker.gd"
const PLUGIN_ID := "cad"
const PLUGIN_DIR_REL := "/github/plugins/cad"
const BINARY_REL := "/cad-plugin"
const MANIFEST_REL := "/manifest.json"

const S_RUNNING := 2
const S_STOPPED := 3

## Verified cube source (worker tests/test_dispatcher.py) — a 10mm cube.
const CUBE_SOURCE := "sketch:\n    s = rect(10, 10)\nb = extrude(s, 10)"

var _pass: int = 0
var _fail: int = 0


func _init() -> void:
	print("=== CAD Plugin Evaluate/Render Functional Test (W5 / F3) ===\n")
	print("Drives the real cad-plugin + MCPServerConnection — no stubs.\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	var home: String = OS.get_environment("HOME")
	if home == "":
		printerr("FAIL: $HOME unset — cannot locate the plugin source dir.")
		_fail += 1
		return
	var plugin_dir: String = home + PLUGIN_DIR_REL
	var binary_path: String = plugin_dir + BINARY_REL
	var manifest_path: String = plugin_dir + MANIFEST_REL

	if not FileAccess.file_exists(binary_path):
		print("SKIP: cad-plugin binary not built at %s" % binary_path)
		print("      Build with: cd %s && go build -o cad-plugin ." % plugin_dir)
		quit(0)
		return
	if not FileAccess.file_exists(manifest_path):
		printerr("FAIL: CAD manifest not found at %s" % manifest_path)
		_fail += 1
		return

	print("CAD binary: %s\n" % binary_path)

	await process_frame
	var so_node = Engine.get_main_loop().root.get_node_or_null("SingletonObject")
	if so_node != null:
		var deadline_ms: int = Time.get_ticks_msec() + 10000
		while so_node.get("plugin_tool_registry") == null and Time.get_ticks_msec() < deadline_ms:
			await Engine.get_main_loop().create_timer(0.1).timeout

	var pm_script = load(PLUGIN_MANAGER_SCRIPT_PATH)
	if pm_script == null:
		printerr("FAIL: could not load PluginManager.gd")
		_fail += 1
		return
	var pm = pm_script.new()
	root.add_child(pm)
	await process_frame
	check("PluginManager initialised", pm._db != null)
	if pm._db == null:
		return

	var db = pm._db
	var def = db.get_by_id(PLUGIN_ID)
	if def == null:
		print("CAD not in PluginDB — installing from manifest...")
		var install_result = await pm.install_plugin(manifest_path, true)
		check("install_plugin returns ok", install_result.get("ok", false) == true,
				"got: %s" % str(install_result))
		def = db.get_by_id(PLUGIN_ID)
	check("CAD definition loaded into DB", def != null)
	if def == null:
		return

	if def.state == S_RUNNING:
		print("Plugin already RUNNING — stopping first for a clean baseline.")
		await pm.stop_plugin(PLUGIN_ID)

	print("\n-- start_plugin --")
	var start_result = await pm.start_plugin(PLUGIN_ID)
	check("start_plugin returns ok", start_result.get("ok", false) == true,
			"got: %s" % str(start_result))
	check("plugin state == RUNNING", def.state == S_RUNNING,
			"got state=%d" % def.state)

	var conn = pm.get_connection(PLUGIN_ID)
	check("connection exists post-start", conn != null)
	if conn != null:
		await _test_f3(conn)
		await _test_f3b_broker(pm)

	print("\n-- stop_plugin --")
	var stop_result = await pm.stop_plugin(PLUGIN_ID)
	check("stop_plugin returns ok", stop_result.get("ok", false) == true,
			"got: %s" % str(stop_result))


## F3 — cad.evaluate of a 10mm cube must return a real, finite mesh.
func _test_f3(conn) -> void:
	print("\n-- F3: cad.evaluate geometry guard --")
	var t0: int = Time.get_ticks_msec()
	var res = await conn.call_tool("cad.evaluate", {"source": CUBE_SOURCE})
	var elapsed: int = Time.get_ticks_msec() - t0
	print("    cad.evaluate completed in %dms; result keys: %s"
			% [elapsed, str(res.keys() if res is Dictionary else res)])

	check("F3: cad.evaluate returned a Dictionary", res is Dictionary,
			"got type %d" % typeof(res))
	if not (res is Dictionary):
		return
	check("F3: cad.evaluate did not return an error",
			not res.has("error"), "error: %s" % str(res.get("error", "")))

	var mesh = _find_mesh(res)
	check("F3: cad.evaluate result carries a mesh", mesh is Dictionary,
			"got: %s" % str(res).left(200))
	if not (mesh is Dictionary):
		return

	var faces = mesh.get("faces", [])
	var verts = mesh.get("vertices", [])
	check("F3: mesh has triangles (face count > 0)",
			faces is Array and faces.size() > 0,
			"face count: %d" % (faces.size() if faces is Array else -1))
	check("F3: mesh has vertices (vertex count > 0)",
			verts is Array and verts.size() > 0,
			"vertex count: %d" % (verts.size() if verts is Array else -1))

	var bbox := _bbox_check(verts)
	check("F3: mesh has a finite, non-degenerate bounding box",
			bbox.get("ok", false), str(bbox.get("detail", "")))
	if bbox.get("ok", false):
		print("    %s" % str(bbox.get("detail", "")))


## F3b — cad.evaluate routed through PluginScenePanelBroker._dispatch_to_plugin_backend,
## the broker→panel path F3's direct call_tool bypasses. This is the bug #2 site
## (RCA 019e46b5 comment 20): a successful eval must arrive as the
## {success:true, result:<worker_payload>} envelope CADPanel._evaluate_and_render
## is written against — NOT the raw {ok,...} worker payload (which the panel
## reads as a transport failure -> blank render).
func _test_f3b_broker(pm) -> void:
	print("\n-- F3b: cad.evaluate through PluginScenePanelBroker --")
	var broker_script = load(BROKER_SCRIPT_PATH)
	check("F3b: PluginScenePanelBroker.gd loaded", broker_script != null)
	if broker_script == null:
		return
	var broker = broker_script.new()
	broker.plugin_manager = pm

	# --- success case: a valid solid must arrive as the wrapped envelope ---
	var res = await broker._dispatch_to_plugin_backend(
			PLUGIN_ID, "cad.evaluate", {"source": CUBE_SOURCE})
	print("    broker result keys: %s" % str(res.keys() if res is Dictionary else res))
	check("F3b: broker returned a Dictionary", res is Dictionary,
			"got type %d" % typeof(res))
	if not (res is Dictionary):
		return
	# THE bug #2 assertion: the broker must stamp success == true. Pre-fix it
	# returned the raw {ok,...} payload with no success key, which the panel
	# (CADPanel.gd:591) read as a transport failure -> blank render.
	check("F3b: broker reply has success == true (bug #2 guard)",
			res.get("success", null) == true,
			"got: %s" % str(res).left(200))
	var worker_payload = res.get("result")
	check("F3b: broker nested the worker payload under 'result'",
			worker_payload is Dictionary,
			"got: %s" % str(worker_payload).left(120))
	if worker_payload is Dictionary:
		check("F3b: nested worker payload has ok == true",
				worker_payload.get("ok", null) == true,
				"got: %s" % str(worker_payload).left(160))
		check("F3b: a mesh is reachable through the wrapped envelope",
				_find_mesh(worker_payload) is Dictionary,
				"no mesh in %s" % str(worker_payload).left(160))

	# --- worker-error case: a domain error must ride through as a worker result
	# ({success:true, result:{ok:false,…}}), NOT be re-shaped into a transport
	# backend_error. Guards the ok-before-error ordering in _dispatch_to_plugin_backend. ---
	var err_res = await broker._dispatch_to_plugin_backend(
			PLUGIN_ID, "cad.evaluate", {"source": "@@@ not a valid mcad program @@@"})
	print("    broker error-case keys: %s"
			% str(err_res.keys() if err_res is Dictionary else err_res))
	check("F3b: worker-error case returned a Dictionary", err_res is Dictionary)
	if err_res is Dictionary:
		var err_payload = err_res.get("result")
		if err_payload is Dictionary and err_payload.has("ok"):
			check("F3b: worker domain error stays a worker result, not backend_error",
					err_res.get("success", null) == true
						and err_res.get("error_code", null) == null,
					"got: %s" % str(err_res).left(200))
			check("F3b: worker-error payload carries ok == false",
					err_payload.get("ok", null) == false,
					"got: %s" % str(err_payload).left(160))
		else:
			# Worker emitted a no-ok / transport-shaped error; the broker is then
			# correct to surface it as backend_error. Informational, not a fail.
			print("    (worker returned a non-{ok} shape; broker -> %s)"
					% str(err_res).left(160))


## Locate the mesh dict in a cad.evaluate result, tolerating the {ok, result}
## envelope the worker bridge wraps around the payload.
func _find_mesh(res):
	if not (res is Dictionary):
		return null
	if res.get("mesh") is Dictionary:
		return res.get("mesh")
	var inner = res.get("result")
	if inner is Dictionary and inner.get("mesh") is Dictionary:
		return inner.get("mesh")
	return null


## Verify the vertex cloud yields a finite, positive-extent bounding box.
func _bbox_check(vertices) -> Dictionary:
	if not (vertices is Array) or vertices.size() == 0:
		return {"ok": false, "detail": "no vertices"}
	var mn := [INF, INF, INF]
	var mx := [-INF, -INF, -INF]
	for v in vertices:
		if not (v is Array) or v.size() < 3:
			continue
		for a in range(3):
			var c := float(v[a])
			if not is_finite(c):
				return {"ok": false, "detail": "non-finite coordinate on axis %d" % a}
			mn[a] = minf(mn[a], c)
			mx[a] = maxf(mx[a], c)
	for a in range(3):
		if not (mx[a] > mn[a]):
			return {"ok": false, "detail": "zero extent on axis %d (min=%f max=%f)" % [a, mn[a], mx[a]]}
	return {"ok": true, "detail": "bbox min=%s max=%s" % [str(mn), str(mx)]}


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % description)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)
