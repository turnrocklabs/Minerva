extends SceneTree
## Full CAD reply contract: MCP adapter -> scene broker -> real CAD panel mesh.

const CYLINDER_FIXTURE := "res://test/fixtures/cad_cylinder_worker_reply.json"
const TALL_CYLINDER_FIXTURE := (
	"res://test/fixtures/cad_cylinder_h180_r60_worker_reply.json")
const DEFAULT_PANEL_SCENE := "res://../../minerva-plugins/cad/ui/CADPanel.tscn"
const BROKER_SCRIPT := preload(
	"res://Scripts/Services/Plugins/PluginScenePanelBroker.gd")
const RESULT_SCRIPT := preload("res://Scripts/Services/MCP/MCPToolResult.gd")
const ADAPTER_SCRIPT := preload(
	"res://Scripts/Services/MCP/MCPToolResultAdapter.gd")
const OUTCOME_SCRIPT := preload(
	"res://Scripts/Services/MCP/MCPToolCallOutcome.gd")
const ISO_MESH_INSTANCE := (
	"ResponsiveContainer/WideLayout/VBoxContainer/GridContainer/IsoView/"
	+ "SubViewport/MeshRoot/MeshInstance")
const SOURCE := "result = cylinder(50, 100)\n"
const TALL_SOURCE := "result = cylinder(h=180, r=60, center=true)\n"


class FixtureConnection extends MCPServerConnection:
	var next_outcome = null
	func call_tool_outcome(_tool_name: String, _arguments: Dictionary,
			_timeout_sec: float = 120.0):
		return next_outcome


class RunningDefinition extends RefCounted:
	var state := 2


class FixtureDB extends RefCounted:
	var definition := RunningDefinition.new()
	func get_by_id(plugin_id: String):
		return definition if plugin_id == "cad" else null


class FixturePluginManager extends RefCounted:
	var db := FixtureDB.new()
	var connection := FixtureConnection.new()
	func get_db():
		return db
	func get_connection(plugin_id: String):
		return connection if plugin_id == "cad" else null


var passed := 0
var failed := 0
var rigs: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	await _test_full_cylinder_reaches_mesh()
	await _test_alternate_shortest_decimal_reaches_expected_dimensions()
	await _test_failure_and_existing_envelopes()
	await _test_worker_failure_reaches_panel()
	await _test_malformed_payload_is_actionable()
	_cleanup()
	await process_frame
	await process_frame
	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)


func _test_full_cylinder_reaches_mesh() -> void:
	var raw := FileAccess.get_file_as_string(CYLINDER_FIXTURE)
	var outcome = await _adapt_text(raw)
	var rig := _make_rig("cad-envelope-cylinder")
	if rig.is_empty():
		return
	var reply: Dictionary = await _dispatch(rig, outcome)
	check("adapter/broker wraps the raw cylinder worker reply exactly once",
		reply.get("success") == true
		and reply.get("result") is Dictionary
		and reply.result.get("ok") == true
		and reply.result.get("result") is Dictionary)
	await _evaluate_with_reply(rig, reply)
	var panel: Node = rig.panel
	var last_eval: Dictionary = panel._on_panel_save_request().get("last_eval", {})
	var mesh_instance := panel.get_node_or_null(ISO_MESH_INSTANCE) as MeshInstance3D
	check("the captured 506-vertex cylinder reaches CADPanel evaluation state",
		last_eval.get("status") == "ok"
		and int(last_eval.get("vertex_count", 0)) == 506,
		str(last_eval))
	check("the captured cylinder constructs a real viewport mesh",
		mesh_instance != null and mesh_instance.mesh != null
		and mesh_instance.mesh.get_surface_count() > 0)


func _test_alternate_shortest_decimal_reaches_expected_dimensions() -> void:
	var raw := FileAccess.get_file_as_string(TALL_CYLINDER_FIXTURE)
	var outcome = await _adapt_text(raw)
	var rig := _make_rig("cad-envelope-h180-r60")
	if rig.is_empty():
		return
	var reply: Dictionary = await _dispatch(rig, outcome, TALL_SOURCE)
	check("a valid alternate shortest binary64 spelling passes adaptation",
		reply.get("success") == true and reply.get("result", {}).get("ok") == true,
		str(reply).left(512))
	await _evaluate_with_reply(rig, reply, TALL_SOURCE)
	var mesh_instance := rig.panel.get_node_or_null(ISO_MESH_INSTANCE) as MeshInstance3D
	var bounds := AABB()
	if mesh_instance != null and mesh_instance.mesh != null:
		bounds = mesh_instance.mesh.get_aabb()
	var center := bounds.get_center()
	check("the h=180 r=60 reply renders the requested centered cylinder dimensions",
		is_equal_approx(bounds.size.x, 120.0)
		and absf(bounds.size.y - 120.0) <= 0.1
		and is_equal_approx(bounds.size.z, 180.0)
		and center.length() <= 0.001, str(bounds))


func _test_failure_and_existing_envelopes() -> void:
	var rig := _make_rig("cad-envelope-shapes")
	if rig.is_empty():
		return

	var transport = OUTCOME_SCRIPT.failure("worker pipe closed", "pipe_closed")
	var transport_reply: Dictionary = await _dispatch(rig, transport)
	check("envelope-less transport failure stays a scene failure",
		transport_reply.get("success") == false
		and transport_reply.get("error_code") == "plugin_backend_error"
		and str(transport_reply.get("error_message", "")).contains("pipe closed"))

	var worker_looking_error := {
		"ok": false,
		"error": {"kind": "translate", "message": "must remain MCP failure"},
	}
	var is_error_outcome = await _adapt_text(
		JSON.stringify(worker_looking_error), true)
	var is_error_reply: Dictionary = await _dispatch(rig, is_error_outcome)
	check("MCP isError outranks a worker-looking ok field",
		is_error_reply.get("success") == false
		and is_error_reply.get("error_code") == "mcp_tool_error"
		and not is_error_reply.has("result"))

	var unsafe_outcome = await _adapt_text(
		'{"ok":true,"result":{"value":0.10000000000000001}}')
	var unsafe_reply: Dictionary = await _dispatch(rig, unsafe_outcome)
	check("numeric adapter rejection remains a failure with diagnostics",
		unsafe_reply.get("success") == false
		and unsafe_reply.get("error_code") == "unsupported_number"
		and unsafe_reply.get("error_details", {}).get("pointer") == "/result/value"
		and unsafe_reply.get("error_details", {}).get("original") \
			== "0.10000000000000001")

	var non_boolean_outcome = await _adapt_text(
		'{"ok":"true","result":{"shape_name":"bad-marker"}}')
	var non_boolean_reply: Dictionary = await _dispatch(rig, non_boolean_outcome)
	check("broker requires a boolean worker ok marker",
		non_boolean_reply.get("success") == false
		and non_boolean_reply.get("error_code") == "malformed_plugin_payload"
		and str(non_boolean_reply.get("error_message", "")).contains("boolean"))

	var worker := {"ok": true, "result": {"shape_name": "already-wrapped"}}
	var scene_envelope := {"success": true, "result": worker}
	var wrapped_outcome = await _adapt_text(JSON.stringify(scene_envelope))
	var wrapped_reply: Dictionary = await _dispatch(rig, wrapped_outcome)
	check("an existing scene envelope is not double wrapped",
		wrapped_reply.get("success") == true
		and wrapped_reply.get("result") is Dictionary
		and wrapped_reply.result.get("ok") == true
		and not wrapped_reply.result.has("success"))
	var explicit_mixed_success := {"success": true, "ok": true,
		"result": {"shape_name": "explicit-scene"}}
	var mixed_success_outcome = await _adapt_text(
		JSON.stringify(explicit_mixed_success))
	var mixed_success_reply: Dictionary = await _dispatch(rig, mixed_success_outcome)
	check("an explicit mixed-marker scene success retains its original level",
		mixed_success_reply.get("success") == true
		and mixed_success_reply.get("ok") == true
		and mixed_success_reply.get("result", {}).get("shape_name") == "explicit-scene")

	var explicit_failure := {"success": false, "ok": false,
		"error_message": "permission denied", "error_code": "permission_denied"}
	var explicit_failure_outcome = await _adapt_text(JSON.stringify(explicit_failure))
	var explicit_failure_reply: Dictionary = await _dispatch(
		rig, explicit_failure_outcome)
	check("an explicit mixed-marker scene failure is preserved before worker classification",
		explicit_failure_reply.get("success") == false
		and explicit_failure_reply.get("ok") == false
		and explicit_failure_reply.get("error_code") == "permission_denied"
		and explicit_failure_reply.get("error_message") == "permission denied"
		and not explicit_failure_reply.has("result"))


func _test_worker_failure_reaches_panel() -> void:
	var rig := _make_rig("cad-envelope-worker-error")
	if rig.is_empty():
		return
	var worker_error := {"ok": false, "error": {
		"kind": "translate", "message": "unexpected end of input",
		"frame": "result = cylinder("}}
	var outcome = await _adapt_text(JSON.stringify(worker_error))
	var reply: Dictionary = await _dispatch(rig, outcome)
	check("worker failure is carried inside a successful scene dispatch",
		reply.get("success") == true and reply.get("result") is Dictionary
		and reply.result.get("ok") == false)
	await _evaluate_with_reply(rig, reply)
	var last_eval: Dictionary = rig.panel._on_panel_save_request().get(
		"last_eval", {})
	check("CADPanel preserves the worker's structured failure",
		last_eval.get("status") == "error"
		and last_eval.get("error_kind") == "translate"
		and last_eval.get("error_message") == "unexpected end of input")


func _test_malformed_payload_is_actionable() -> void:
	var rig := _make_rig("cad-envelope-malformed")
	if rig.is_empty():
		return
	var worker: Dictionary = JSON.parse_string(
		FileAccess.get_file_as_string(CYLINDER_FIXTURE))
	var old_broken_shape := {"success": true, "result": worker.get("result", {})}
	await _evaluate_with_reply(rig, old_broken_shape)
	var last_eval: Dictionary = rig.panel._on_panel_save_request().get(
		"last_eval", {})
	var message := str(last_eval.get("error_message", ""))
	check("CADPanel diagnoses the old unwrapped geometry shape without logging it",
		last_eval.get("error_kind") == "malformed_worker_payload"
		and message.contains("'ok'") and message.contains("keys=")
		and message.length() < 512)


func _adapt_text(text: String, is_error: bool = false):
	var envelope = RESULT_SCRIPT.from_mcp({
		"content": [{"type": "text", "text": text}],
		"isError": is_error,
	}, false)
	return await ADAPTER_SCRIPT.adapt(envelope)


func _dispatch(rig: Dictionary, outcome, source: String = SOURCE) -> Dictionary:
	(rig.manager.connection as FixtureConnection).next_outcome = outcome
	return await rig.broker._dispatch_to_plugin_backend(
		"cad", "cad.evaluate", {"source": source})


func _evaluate_with_reply(rig: Dictionary, reply: Dictionary,
		source: String = SOURCE) -> void:
	var panel: Node = rig.panel
	panel._eval_await_chunk_ms = 1000
	panel._eval_give_up_ms = 10000
	panel._evaluate_with_request_id(source)
	await process_frame
	var evaluation: Dictionary = {}
	for entry: Dictionary in rig.dispatched:
		if entry.get("channel") == "cad.evaluate":
			evaluation = entry
			break
	check("real CADPanel dispatched cad.evaluate", not evaluation.is_empty())
	if evaluation.is_empty():
		return
	rig.broker._deliver_reply(str(rig.panel_name),
		str(evaluation.get("reply_id", "")), reply)
	await create_timer(0.25).timeout


func _make_rig(panel_name: String) -> Dictionary:
	var panel_path := OS.get_environment("MINERVA_CAD_PANEL_SCENE")
	if panel_path.is_empty():
		panel_path = DEFAULT_PANEL_SCENE
	var packed := load(panel_path) as PackedScene
	if packed == null:
		check("CADPanel scene loads", false, panel_path)
		return {}
	var panel := packed.instantiate()
	root.add_child(panel)
	var manager := FixturePluginManager.new()
	var broker = BROKER_SCRIPT.new(manager)
	broker.register_panel(panel, "cad", panel_name,
		PackedStringArray(["cad.evaluate", "cad.cancel_eval"]))
	for connection: Dictionary in panel.get_signal_connection_list("request"):
		panel.disconnect("request", connection.callable as Callable)
	panel._on_panel_loaded({"plugin_id": "cad", "panel_name": panel_name,
		"broker": broker, "host_api_version": "1"})
	var dispatched: Array[Dictionary] = []
	panel.request.connect(func(channel: String, payload: Dictionary,
			reply_id: String) -> void:
		dispatched.append({"channel": channel, "payload": payload,
			"reply_id": reply_id}))
	var rig := {"panel": panel, "panel_name": panel_name, "manager": manager,
		"broker": broker, "dispatched": dispatched}
	rigs.append(rig)
	return rig


func _cleanup() -> void:
	for rig: Dictionary in rigs:
		var panel: Node = rig.get("panel")
		var broker = rig.get("broker")
		if panel != null and is_instance_valid(panel):
			broker.unregister_panel("cad", str(rig.get("panel_name", "")))
			if panel.get_parent() != null:
				panel.get_parent().remove_child(panel)
			panel.free()
	rigs.clear()


func check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: %s%s" % [label,
			" — " + detail if not detail.is_empty() else ""])
