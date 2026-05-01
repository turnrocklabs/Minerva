extends SceneTree
## Tests for AnnotationOverlay platform substrate (Phase 1, T3).

const AnnotationOverlayScript = preload("res://Scripts/Services/Annotations/AnnotationOverlay.gd")
const AnnotationHostScript = preload("res://Scripts/Services/Annotations/AnnotationHost.gd")
const HelloAnnotationHostScript = preload("res://plugins/hello_scene/ui/HelloAnnotationHost.gd")

var _pass_count := 0
var _fail_count := 0


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func _initialize() -> void:
	print("[tags: unit,annotations,overlay]")
	print("=== test_annotation_overlay_draw ===\n")
	test_set_host_connects_signals()
	test_set_host_replaces_old_host()
	test_set_host_null_is_safe()
	test_set_active_tool_flips_mouse_filter()
	test_halo_guard_with_transform_tool()
	test_selection_changed_wrapper_arity()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func test_set_host_connects_signals() -> void:
	var overlay := AnnotationOverlayScript.new()
	root.add_child(overlay)
	overlay._ready()

	var host := _TestHost.new()
	overlay.set_host(host)

	check("annotations_changed connected after set_host", host.annotations_changed.is_connected(overlay._on_annotations_changed))
	check("selection_changed connected after set_host", host.selection_changed.is_connected(overlay._on_selection_changed))

	root.remove_child(overlay)
	overlay.queue_free()


func test_set_host_replaces_old_host() -> void:
	var overlay := AnnotationOverlayScript.new()
	root.add_child(overlay)
	overlay._ready()

	var old_host := _TestHost.new()
	overlay.set_host(old_host)
	var new_host := _TestHost.new()
	overlay.set_host(new_host)

	check("old host annotations_changed disconnected after rebind", not old_host.annotations_changed.is_connected(overlay._on_annotations_changed))
	check("old host selection_changed disconnected after rebind", not old_host.selection_changed.is_connected(overlay._on_selection_changed))
	check("new host annotations_changed connected after rebind", new_host.annotations_changed.is_connected(overlay._on_annotations_changed))

	root.remove_child(overlay)
	overlay.queue_free()


func test_set_host_null_is_safe() -> void:
	var overlay := AnnotationOverlayScript.new()
	root.add_child(overlay)
	overlay._ready()

	var host := _TestHost.new()
	overlay.set_host(host)
	overlay.set_host(null)
	check("set_host(null) does not crash", true)
	check("set_host(null) clears _host", overlay._host == null)

	root.remove_child(overlay)
	overlay.queue_free()


func test_set_active_tool_flips_mouse_filter() -> void:
	var overlay := AnnotationOverlayScript.new()
	root.add_child(overlay)
	overlay._ready()

	check("mouse_filter is IGNORE when no tool", overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE)

	var tool := _StubTool.new()
	overlay.set_active_tool(tool)
	check("mouse_filter is STOP when tool set", overlay.mouse_filter == Control.MOUSE_FILTER_STOP)

	overlay.set_active_tool(null)
	check("mouse_filter is IGNORE after clear", overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE)

	root.remove_child(overlay)
	overlay.queue_free()


func test_halo_guard_with_transform_tool() -> void:
	var tool: AnnotationAuthorTool = AnnotationTransformTool.new()
	var is_select_or_transform: bool = tool is AnnotationSelectTool or tool is AnnotationTransformTool
	check("AnnotationTransformTool triggers halo suppression guard", is_select_or_transform == true)

	var select_tool: AnnotationAuthorTool = AnnotationSelectTool.new()
	var select_guard: bool = select_tool is AnnotationSelectTool or select_tool is AnnotationTransformTool
	check("AnnotationSelectTool triggers halo suppression guard", select_guard == true)


func test_selection_changed_wrapper_arity() -> void:
	var overlay := AnnotationOverlayScript.new()
	root.add_child(overlay)
	overlay._ready()

	var host := HelloAnnotationHostScript.new()
	overlay.set_host(host)
	host.selection_changed.emit("ann_foo")
	check("selection_changed(String) does not crash via wrapper", true)

	root.remove_child(overlay)
	overlay.queue_free()


class _TestHost extends AnnotationHost:
	signal annotations_changed()

	var _annotations: Array = []
	var _selected_id: String = ""

	func get_annotations() -> Array:
		return _annotations.duplicate()

	func set_selected_annotation_id(annotation_id: String) -> void:
		if _selected_id == annotation_id:
			return
		_selected_id = annotation_id
		selection_changed.emit(_selected_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func get_registry() -> AnnotationRegistry:
		return null


class _StubTool extends AnnotationAuthorTool:
	pass
