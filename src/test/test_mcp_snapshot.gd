extends SceneTree
## Contract tests inject readback; visible GPU pixels remain a HITL check.
var failures: int = 0
var ctx: Dictionary
var last_target: Dictionary
var captures: int = 0

class Surface extends Control:
	var tab_title: String
	var type: int
	var plugin_scene_root: Control = null

class Manager extends RefCounted:
	var tool_registry: Dictionary = {}
	var http_server: Object = null

func context() -> Dictionary:
	return ctx

func readback(target: Dictionary) -> Image:
	last_target = target
	captures += 1
	await process_frame
	return Image.create(24, 12, false, Image.FORMAT_RGBA8)

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL: " + label)

func _init() -> void:
	await process_frame
	var services = load("res://Scripts/Services/Plugins/PanelServices.gd")
	var panel = load("res://test/fixtures/panel_probe/PanelProbe.gd").new()
	root.add_child(panel)
	var broker = load("res://Scripts/Services/Plugins/PluginScenePanelBroker.gd").new()
	broker.register_panel(panel, "probe", "Probe", PackedStringArray(), "Text")
	var editor_script = load("res://Scripts/UI/Controls/Editor.gd")
	var text := Surface.new()
	text.type = editor_script.Type.TEXT
	text.tab_title = "Text"
	var sheet := Surface.new()
	sheet.type = editor_script.Type.SPREADSHEET
	sheet.tab_title = "Sheet"
	root.add_child(text)
	root.add_child(sheet)
	ctx = {"broker": broker, "editors": [text, sheet]}
	var manager := Manager.new()
	var server = load("res://Scripts/Services/MCP/MinervaMCPServer.gd").new()
	server.mcp_manager = manager
	var tools = load("res://Scripts/Services/MCP/Modules/MCPSnapshotTools.gd").new(
		server, context, readback)
	tools.register_tools()
	check(manager.tool_registry.has("minerva_snapshot") and server.get_tool_count() == 1,
		"snapshot registered in real host catalog")
	check(manager.tool_registry.minerva_snapshot.input_schema.required == ["editor_name"],
		"optional snapshot arguments remain optional")
	var named: Dictionary = await tools.handle("minerva_snapshot", {
		"editor_name": "Probe", "view": "detail", "max_edge": 12})
	check(named.get("success", false) and last_target.viewport == panel.slot,
		"named snapshot routes to declared slot")
	check(named.get("width") == 12 and named.get("height") == 6 and named.get("view") == "detail",
		"max edge preserves aspect ratio and authoritative dimensions/view")
	check(str(named.get("path", "")).begins_with("user://snapshots/")
		and FileAccess.file_exists(named.get("path", "")), "PNG written in snapshot directory")
	check(named.get("projection") == "detail" and not named.has("base64"),
		"extras merged without overriding path/dimensions or adding unsolicited base64")
	var png := Image.load_from_file(named.get("path", ""))
	check(png != null and png.get_size() == Vector2i(12, 6), "saved image matches reply")
	var active: Dictionary = await tools.handle("minerva_snapshot", {
		"editor_name": "Probe", "return_base64": true})
	check(last_target.surface == panel and active.get("view") == "active",
		"omitted view captures current visible panel")
	check(Marshalls.base64_to_raw(active.get("base64", "")) == FileAccess.get_file_as_bytes(active.path),
		"requested base64 represents the saved PNG")
	for surface in [text, sheet]:
		var reply: Dictionary = await tools.handle("minerva_snapshot", {"editor_name": surface.tab_title})
		check(reply.get("success", false) and last_target.surface == surface
			and last_target.viewport == root, "text/spreadsheet exact tab uses visible surface")
		DirAccess.remove_absolute(reply.path)
	check(services.resolve("Text", broker, [text, sheet], true).panel == panel,
		"panel tools retain broker preference for the same source-tab alias")
	var before_errors := captures
	var bad_view: Dictionary = await tools.handle("minerva_snapshot", {"editor_name": "Probe", "view": "unknown"})
	check(bad_view.isError and bad_view.available_views == ["active", "detail"],
		"unknown slot isError lists available slots")
	var bad_editor: Dictionary = await tools.handle("minerva_snapshot", {"editor_name": "missing"})
	check(bad_editor.isError and bad_editor.available_editors.has("Probe")
		and bad_editor.available_views == ["active"], "unknown editor reports choices")
	var bad_limit: Dictionary = await tools.handle("minerva_snapshot", {"editor_name": "Probe", "max_edge": 0})
	check(bad_limit.isError and captures == before_errors, "invalid requests never read back")
	DirAccess.remove_absolute(named.path)
	DirAccess.remove_absolute(active.path)
	panel.free()
	text.free()
	sheet.free()
	print("MCPSnapshotTools: %d failures" % failures)
	quit(1 if failures else 0)
