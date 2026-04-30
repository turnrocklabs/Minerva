extends SceneTree

const TextEditorAnnotationHostScript = preload("res://Scripts/Services/Annotations/TextEditorAnnotationHost.gd")
const AnnotationOverlayScript = preload("res://Scripts/Services/Annotations/AnnotationOverlay.gd")
const AnnotationDockPaneScript = preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationDockPane.gd")
const AnnotationWorkbenchScript = preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationWorkbench.gd")
const AnnotationV2SchemaScript = preload("res://Scripts/Services/Annotations/AnnotationV2Schema.gd")
const AnnotationToolbarScript = preload("res://Scripts/Services/Annotations/AnnotationToolbar.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit,ux]")
	print("=== test_annotation_ux_substrate ===\n")
	test_text_host_capabilities()
	test_display_numbers_are_persisted_and_gap_preserving()
	test_callout_accepts_plugin_anchor()
	test_toolbar_filters_by_host_capabilities()
	test_overlay_mouse_filter_contract()
	test_dock_pane_mounts_shared_workbench()
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


func test_text_host_capabilities() -> void:
	var host = TextEditorAnnotationHostScript.new()
	var caps: Dictionary = host.get_capabilities()
	check("text host declares text kind", "text" in caps.get("kinds", []))
	check("text host declares callout kind", "callout" in caps.get("kinds", []))
	check("text host supports resolve", bool(caps.get("lifecycle", {}).get("resolve", false)))
	check("text host exposes core/text.range anchor", "core/text.range" in caps.get("anchor_types", []))


func test_display_numbers_are_persisted_and_gap_preserving() -> void:
	var host = TextEditorAnnotationHostScript.new()
	host.set_text("alpha beta gamma")
	var a := host.add_comment_at(0, 5, "first")
	var b := host.add_comment_at(6, 10, "second")
	check("first comment added", not a.is_empty())
	check("second comment added", not b.is_empty())
	var anns: Array = host.get_annotations()
	check("first display_index is 1", int(anns[0].get("display_index", 0)) == 1)
	check("second display_index is 2", int(anns[1].get("display_index", 0)) == 2)
	host.update_annotation_lifecycle(a, "resolved", {"resolved": {"by": {"kind": "human"}}})
	var c := host.add_comment_at(11, 16, "third")
	check("third comment added", not c.is_empty())
	check("third display_index leaves gap after resolved #1", int(host.get_by_id(c).get("display_index", 0)) == 3)
	var saved := host.get_annotations().duplicate(true)
	var reloaded = TextEditorAnnotationHostScript.new()
	reloaded.set_text("alpha beta gamma")
	reloaded.load_annotations(saved)
	check("reload preserves display index #2", int(reloaded.get_by_id(b).get("display_index", 0)) == 2)


func test_callout_accepts_plugin_anchor() -> void:
	var schema = AnnotationV2SchemaScript.new()
	var envelope := {
		"id": "ann_callout",
		"kind": "callout",
		"schema_version": 2,
		"anchor": {"plugin": "cad", "type": "edge", "id": "edge-7", "snapshot": {"position": [12.0, 8.0]}},
		"kind_payload": {"text": "Fillet this edge"},
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "cad:iso",
		"visible_in_views": ["all"],
		"summary": "Fillet this edge",
	}
	check("callout accepts cad/edge anchor", not schema.validate(envelope).has_errors())


func test_toolbar_filters_by_host_capabilities() -> void:
	var host = TextEditorAnnotationHostScript.new()
	var toolbar = AnnotationToolbarScript.new()
	root.add_child(toolbar)
	toolbar.set_host(host)
	toolbar.set_registry(host.get_registry())
	check("toolbar shows text kind from capabilities", toolbar._buttons.has(&"2d_text"))
	check("toolbar hides arrow kind outside capabilities", not toolbar._buttons.has(&"2d_arrow"))
	root.remove_child(toolbar)
	toolbar.queue_free()


func test_overlay_mouse_filter_contract() -> void:
	var overlay = AnnotationOverlayScript.new()
	root.add_child(overlay)
	overlay._ready()
	check("overlay idle mouse_filter is IGNORE", overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	overlay.set_active_tool(RefCounted.new())
	check("overlay active mouse_filter is STOP", overlay.mouse_filter == Control.MOUSE_FILTER_STOP)
	overlay.clear_active_tool()
	check("overlay restore mouse_filter is IGNORE", overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	root.remove_child(overlay)
	overlay.queue_free()


func test_dock_pane_mounts_shared_workbench() -> void:
	var pane = AnnotationDockPaneScript.new()
	root.add_child(pane)
	pane._ready()
	var host = TextEditorAnnotationHostScript.new()
	pane.set_host(host)
	check("dock pane exposes workbench", pane.get_workbench() != null)
	check("dock pane workbench uses shared script", pane.get_workbench().get_script() == AnnotationWorkbenchScript)
	check("dock pane starts collapsed", not pane.get_workbench().visible)
	check("bottom collapsed height is compact", pane.custom_minimum_size.y <= 24.0)
	check("chevron keeps compact width", pane._chevron.custom_minimum_size.x <= 24.0)
	pane.set_dock_mode(pane.DockMode.RIGHT)
	check("right collapsed width is compact", pane.custom_minimum_size.x <= 30.0)
	pane.begin_add_comment_flow()
	check("begin add expands workbench", pane.get_workbench().visible)
	check("right expanded dock sets minimum width", pane.custom_minimum_size.x >= 260.0)
	root.remove_child(pane)
	pane.queue_free()
