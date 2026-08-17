extends SceneTree
## Focused async tests for annotation MCP render_overlay.
##
## This covers the MCP-facing contract for the overlay/canvas payload shapes:
## sidecar-backed render, live-host render with host position resolution, tool
## registration, and output_path validation. It deliberately does not exercise
## the older broad MCPAnnotationTools test, which still has separate tech debt
## for synchronous handle() calls.

const MCPAnnotationToolsScript := preload("res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd")
const AnnotationSidecarScript := preload("res://Scripts/Services/Annotations/AnnotationSidecar.gd")
const AnnotationHostRegistryScript := preload("res://Scripts/Services/Annotations/AnnotationHostRegistry.gd")
const CoreAnchorsScript := preload("res://Scripts/Services/Annotations/CoreAnchors.gd")

var _pass_count := 0
var _fail_count := 0
var _tmp_dir := ""


func _initialize() -> void:
	print("[tags: unit,integration,mcp,annotations]")
	print("=== test_mcp_annotations_render_overlay ===\n")
	_tmp_dir = _make_tmp_dir()
	AnnotationHostRegistryScript._reset_for_test()

	_test_register_tools_exposes_render_overlay_schema()
	await _test_sidecar_render_overlay_async_payload_shapes()
	await _test_render_overlay_include_kinds_filter()
	await _test_live_host_render_uses_host_registry_and_position_resolution()
	await _test_render_overlay_output_path_validation()

	AnnotationHostRegistryScript._reset_for_test()
	_cleanup_tmp_dir()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	check("%s — expected %s, got %s" % [description, str(expected), str(actual)], actual == expected)


func _test_register_tools_exposes_render_overlay_schema() -> void:
	print("-- register_tools schema --")
	var server := _ToolRegistrationServer.new()
	var tools := MCPAnnotationToolsScript.new(server)
	tools.register_tools()
	var render_tool := server.by_name("minerva_annotations_render_overlay")
	check("render_overlay tool registered", not render_tool.is_empty())
	check("render_overlay required args include view", "view" in render_tool.get("schema", {}).get("required", []))
	check("render_overlay schema exposes editor_name", render_tool.get("schema", {}).get("properties", {}).has("editor_name"))
	check("render_overlay schema exposes document_path", render_tool.get("schema", {}).get("properties", {}).has("document_path"))


func _test_sidecar_render_overlay_async_payload_shapes() -> void:
	print("-- sidecar render_overlay async payload shapes --")
	var doc := _doc_path("sidecar_payloads.hello")
	_write_sidecar(doc, _payload_shape_annotations())
	var out := _doc_path("sidecar_payloads.png")

	var result: Dictionary = await MCPAnnotationToolsScript.new(null).handle(
		"minerva_annotations_render_overlay",
		{"document_path": doc, "view": "hello", "output_path": out, "width": 360, "height": 260}
	)

	check("render_overlay succeeds", result.get("success", false))
	check_eq("annotations_drawn includes all payload-shape annotations", result.get("annotations_drawn", -1), 3)
	check("PNG was written", FileAccess.file_exists(out))
	var img := _load_image(out)
	check("PNG has expected dimensions", img != null and img.get_width() == 360 and img.get_height() == 260)
	check("PNG has non-transparent annotation pixels", img != null and _count_nontransparent(img, Rect2i(0, 0, 360, 260)) > 20)


func _test_render_overlay_include_kinds_filter() -> void:
	print("-- include_kinds filter --")
	var doc := _doc_path("filter_payloads.hello")
	_write_sidecar(doc, _payload_shape_annotations())
	var out := _doc_path("filter_payloads.png")

	var result: Dictionary = await MCPAnnotationToolsScript.new(null).handle(
		"minerva_annotations_render_overlay",
		{
			"document_path": doc,
			"view": "hello",
			"output_path": out,
			"width": 360,
			"height": 260,
			"include_kinds": ["2d_arrow"],
		}
	)

	check("filtered render succeeds", result.get("success", false))
	check_eq("filtered render draws only arrow", result.get("annotations_drawn", -1), 1)
	var img := _load_image(out)
	check("filtered PNG has arrow pixels", img != null and _count_nontransparent(img, Rect2i(20, 20, 220, 120)) > 5)


func _test_live_host_render_uses_host_registry_and_position_resolution() -> void:
	print("-- live host render uses host context --")
	var host := _LiveHost.new()
	AnnotationHostRegistryScript.register("Hello MCP Render Test", host)
	var out := _doc_path("live_host.png")

	var result: Dictionary = await MCPAnnotationToolsScript.new(null).handle(
		"minerva_annotations_render_overlay",
		{"editor_name": "Hello MCP Render Test", "view": "hello", "output_path": out, "width": 180, "height": 140}
	)

	check("live render succeeds", result.get("success", false))
	check_eq("live render draws one annotation", result.get("annotations_drawn", -1), 1)
	var img := _load_image(out)
	var live_segment_pixels := _count_nontransparent(img, Rect2i(117, 28, 7, 55)) if img != null else 0
	check("live render uses host-resolved endpoint, not snapshot fallback", live_segment_pixels > 8)
	AnnotationHostRegistryScript.deregister("Hello MCP Render Test")


func _test_render_overlay_output_path_validation() -> void:
	print("-- output_path validation --")
	var doc := _doc_path("validation.hello")
	_write_sidecar(doc, _payload_shape_annotations())
	var tools := MCPAnnotationToolsScript.new(null)

	var missing: Dictionary = await tools.handle(
		"minerva_annotations_render_overlay",
		{"document_path": doc, "view": "hello"}
	)
	check("missing output_path returns error", not missing.get("success", true) and str(missing.get("error", "")).contains("output_path"))

	var relative: Dictionary = await tools.handle(
		"minerva_annotations_render_overlay",
		{"document_path": doc, "view": "hello", "output_path": "relative.png"}
	)
	check("relative output_path returns error", not relative.get("success", true) and str(relative.get("error", "")).contains("absolute"))

	var missing_parent: Dictionary = await tools.handle(
		"minerva_annotations_render_overlay",
		{"document_path": doc, "view": "hello", "output_path": _tmp_dir.path_join("missing_parent/out.png")}
	)
	check("missing output parent returns error", not missing_parent.get("success", true) and str(missing_parent.get("error", "")).contains("parent"))


func _payload_shape_annotations() -> Array:
	return [
		{
			"id": "ann_mcp_callout",
			"schema_version": 2,
			"kind": "callout",
			"author": {"kind": "human", "id": "test"},
			"anchor": CoreAnchorsScript.make_canvas_point(48.0, 52.0),
			"kind_payload": {"text": "Callout", "bubble_pos": [92.0, 30.0]},
			"lifecycle": "open",
			"view_context": "hello",
			"visible_in_views": ["hello"],
			"summary": "Callout fixture",
		},
		{
			"id": "ann_mcp_arrow",
			"schema_version": 2,
			"kind": "2d_arrow",
			"author": {"kind": "ai", "model": "test"},
			"kind_payload": {
				"endpoint_a": CoreAnchorsScript.make_canvas_point(34.0, 130.0),
				"endpoint_b": CoreAnchorsScript.make_canvas_point(210.0, 130.0),
				"head_size": 14.0,
			},
			"lifecycle": "open",
			"view_context": "hello",
			"visible_in_views": ["hello"],
			"summary": "Arrow fixture",
		},
		{
			"id": "ann_mcp_text",
			"schema_version": 2,
			"kind": "2d_text",
			"author": {"kind": "human", "id": "test"},
			"anchor": CoreAnchorsScript.make_canvas_point(42.0, 210.0),
			"kind_payload": {"text": "Free text", "font_size": 16.0},
			"lifecycle": "open",
			"view_context": "hello",
			"visible_in_views": ["hello"],
			"summary": "Text fixture",
		},
	]


func _write_sidecar(doc_path: String, annotations: Array) -> void:
	var err := AnnotationSidecarScript.write_sidecar(doc_path, {
		"substrate_version": AnnotationSidecarScript.SUBSTRATE_VERSION,
		"document": {"path": doc_path.get_file(), "kind": "hello_scene"},
		"annotations": annotations,
		"unknown_kinds": [],
	})
	check("sidecar write succeeds for %s" % doc_path.get_file(), err == OK)


func _load_image(path: String) -> Image:
	var img := Image.new()
	var err := img.load(path)
	if err != OK:
		printerr("  FAIL: could not load image %s: %d" % [path, err])
		_fail_count += 1
		return null
	return img


func _count_nontransparent(img: Image, rect: Rect2i) -> int:
	if img == null:
		return 0
	var clipped := rect.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	var count := 0
	for y in range(clipped.position.y, clipped.position.y + clipped.size.y):
		for x in range(clipped.position.x, clipped.position.x + clipped.size.x):
			if img.get_pixel(x, y).a > 0.01:
				count += 1
	return count


func _doc_path(name: String) -> String:
	return _tmp_dir.path_join(name)


func _make_tmp_dir() -> String:
	var base := "user://tmp/test_mcp_annotations_render_overlay_%d" % int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(base)
	return base


func _cleanup_tmp_dir() -> void:
	if _tmp_dir.is_empty():
		return
	var dir := DirAccess.open(_tmp_dir)
	if dir == null:
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			dir.remove(_tmp_dir.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(_tmp_dir)


class _ToolRegistrationServer extends RefCounted:
	var registrations: Array = []

	func _register_tool(name: String, description: String, schema: Dictionary, tool_set: String) -> void:
		registrations.append({
			"name": name,
			"description": description,
			"schema": schema,
			"tool_set": tool_set,
		})

	func by_name(name: String) -> Dictionary:
		for entry in registrations:
			if str((entry as Dictionary).get("name", "")) == name:
				return entry as Dictionary
		return {}


class _LiveHost extends AnnotationHost:
	var _registry := AnnotationRegistry.new()
	var _annotations := []

	func _init() -> void:
		BuiltinKinds.register_all(_registry)
		_annotations = [
			{
				"id": "ann_live_arrow",
				"schema_version": 2,
				"kind": "2d_arrow",
				"author": {"kind": "human", "id": "test"},
				"kind_payload": {
					"endpoint_a": {
						"plugin": "hello_scene",
						"type": "widget.point",
						"id": "live-target",
						"snapshot": {"position": [10.0, 10.0]},
					},
					"endpoint_b": CoreAnchorsScript.make_canvas_point(120.0, 100.0),
					"head_size": 10.0,
				},
				"lifecycle": "open",
				"view_context": "hello",
				"visible_in_views": ["hello"],
				"summary": "Live host resolved arrow",
			},
		]

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_annotations() -> Array:
		return _annotations.duplicate(true)

	func get_view_context() -> String:
		return "hello"

	func resolve_position_source(source: Variant) -> Variant:
		if source is Dictionary:
			var d: Dictionary = source
			if str(d.get("plugin", "")) == "hello_scene" and str(d.get("type", "")) == "widget.point":
				return Vector2(120.0, 20.0)
			if str(d.get("plugin", "")) == "core" and str(d.get("type", "")) == "canvas.point":
				var id: Variant = d.get("id", {})
				if id is Dictionary:
					return Vector2(float((id as Dictionary).get("x", 0.0)), float((id as Dictionary).get("y", 0.0)))
		if source is Vector2:
			return source
		if source is Array and (source as Array).size() >= 2:
			return Vector2(float((source as Array)[0]), float((source as Array)[1]))
		return null
